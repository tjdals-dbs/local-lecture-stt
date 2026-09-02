import Foundation
import SwiftUI
import XCTest
@testable import LocalLectureSTT

final class RecordingSessionCoordinatorTests: XCTestCase {
    func testFrameworkBoundaryConstructionRootAndPermissionFailuresHaveNoResourceSideEffects() async throws {
        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(RecordingStartConfiguration(title: "", timeZone: .init(secondsFromGMT: 0)!))
        requireSendable(RecordingSessionSnapshot.idle())
        requireSendable(RecordingSessionResult.error(.busy))

        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let contract = try String(
            contentsOf: repositoryRoot.appendingPathComponent("LocalLectureSTT/Application/RecordingSessionCoordinator.swift"),
            encoding: .utf8
        )
        for forbidden in ["AVFoundation", "AVFAudio", "CoreAudio", "AppKit", "SwiftUI", "URL", "NSError"] {
            XCTAssertFalse(contract.contains(forbidden), "Coordinator contract leaked \(forbidden)")
        }

        let noRoot = CoordinatorFixture(rootAvailability: .noRootSelected)
        let coordinator = noRoot.makeCoordinator()
        let initialPermissionCounts = await noRoot.permission.counts()
        let initialCaptureCounts = await noRoot.capture.counts()
        let initialCreateCount = await noRoot.repository.createCount()
        XCTAssertEqual(initialPermissionCounts, .zero)
        XCTAssertEqual(initialCaptureCounts, .zero)
        XCTAssertEqual(noRoot.recorders.makeCount(), 0)
        XCTAssertEqual(initialCreateCount, 0)

        let noRootFailure = await startFailure(coordinator)
        XCTAssertEqual(noRootFailure, .storageRoot(.noActiveRoot))
        let rejectedPermissionCounts = await noRoot.permission.counts()
        let rejectedCaptureCounts = await noRoot.capture.counts()
        let rejectedCreateCount = await noRoot.repository.createCount()
        XCTAssertEqual(rejectedPermissionCounts, .zero)
        XCTAssertEqual(rejectedCaptureCounts, .zero)
        XCTAssertEqual(noRoot.recorders.makeCount(), 0)
        XCTAssertEqual(rejectedCreateCount, 0)

        let cases: [(MicrophonePermissionStatus, MicrophonePermissionStatus, Int)] = [
            (.notDetermined, .denied, 1),
            (.denied, .denied, 0),
            (.restricted, .restricted, 0),
            (.unavailable, .unavailable, 0)
        ]
        for (status, requestResult, expectedRequests) in cases {
            let fixture = CoordinatorFixture(permissionStatus: status, requestResult: requestResult)
            let failure = await startFailure(fixture.makeCoordinator())
            let permissionCounts = await fixture.permission.counts()
            let createCount = await fixture.repository.createCount()
            let captureCounts = await fixture.capture.counts()
            XCTAssertEqual(failure, .permission(requestResult))
            XCTAssertEqual(permissionCounts.request, expectedRequests)
            XCTAssertEqual(createCount, 0)
            XCTAssertEqual(captureCounts.start, 0)
            XCTAssertEqual(fixture.recorders.makeCount(), 0)
        }

        let time = AbsoluteTime(Date(timeIntervalSince1970: 1_788_262_440))
        let zone = TimeZone(secondsFromGMT: 9 * 3_600)!
        XCTAssertEqual(
            RecordingSessionCoordinator.normalizedTitle("  자료구조  \n", createdAt: time, timeZone: zone),
            "자료구조"
        )
        XCTAssertEqual(
            RecordingSessionCoordinator.normalizedTitle(" \n", createdAt: time, timeZone: zone),
            "2026-09-01 20:34 녹음"
        )
    }

    func testMinimalUIContainsRequiredStateActionsAndNoOutOfScopeControls() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let recordingView = try String(
            contentsOf: repositoryRoot.appendingPathComponent("LocalLectureSTT/Features/RecordingSessionView.swift"),
            encoding: .utf8
        )
        let mainWindow = try String(
            contentsOf: repositoryRoot.appendingPathComponent("LocalLectureSTT/Features/MainWindowView.swift"),
            encoding: .utf8
        )
        let appComposition = try String(
            contentsOf: repositoryRoot.appendingPathComponent("LocalLectureSTT/App/LocalLectureSTTApp.swift"),
            encoding: .utf8
        )

        for required in [
            "recording-title", "recording-language", "microphone-permission-status", "recording-start",
            "recording-preparing", "active-recording-title", "recording-elapsed", "recording-input-level",
            "recording-no-input-warning", "recording-stop", "recording-securing", "recording-reset",
            "복구 오디오 저장 완료 · 마무리 대기"
        ] {
            XCTAssertTrue(recordingView.contains(required), "Missing minimal UI state/action: \(required)")
        }
        for prohibited in ["recording-pause", "transcript-control", "model-picker"] {
            XCTAssertFalse(recordingView.contains(prohibited), "Out-of-scope UI leaked: \(prohibited)")
        }
        for rootState in ["case .noRoot", "case let .available", "case .reauthorizationRequired", "case let .failed"] {
            XCTAssertTrue(mainWindow.contains(rootState), "Storage-root state was not preserved: \(rootState)")
        }
        for forbiddenLaunchSideEffect in ["requestAuthorization()", "capture.start()", "createSession("] {
            XCTAssertFalse(appComposition.contains(forbiddenLaunchSideEffect), "App construction starts a recording resource")
        }
    }

    func testStartTransactionBuffersPrimaryPCMRejectsConcurrentStartsAndPersistsConfigurationInOrder() async throws {
        let startGate = ControlledTestGate()
        let trace = TestTrace()
        let fixture = CoordinatorFixture(
            permissionStatus: .notDetermined,
            requestResult: .authorized,
            prebufferedFrameCounts: [3, 5, 2],
            recorderStartGate: startGate,
            trace: trace
        )
        let coordinator = fixture.makeCoordinator()
        let config = RecordingStartConfiguration(
            title: "  운영체제  ",
            languageMode: .english,
            timeZone: TimeZone(secondsFromGMT: 9 * 3_600)!
        )

        let startTask = Task { try await coordinator.start(config) }
        await startGate.waitForArrival()
        let preparing = await coordinator.currentSnapshot()
        XCTAssertEqual(preparing.phase, .preparing)
        XCTAssertNotEqual(preparing.persistedStatus, .recording)

        let competing = await withTaskGroup(of: RecordingSessionFailure?.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { await startFailure(coordinator, configuration: config) }
            }
            var failures: [RecordingSessionFailure?] = []
            for await failure in group { failures.append(failure) }
            return failures
        }
        XCTAssertEqual(competing.compactMap { $0 }, Array(repeating: .busy, count: 8))
        await startGate.release()

        let started = try await startTask.value
        XCTAssertEqual(started.phase, .recording)
        XCTAssertEqual(started.title, "운영체제")
        XCTAssertEqual(started.languageMode, .english)
        XCTAssertEqual(started.microphoneDisplayName, "Synthetic Microphone")
        let permissionCounts = await fixture.permission.counts()
        let captureCounts = await fixture.capture.counts()
        XCTAssertEqual(permissionCounts.request, 1)
        XCTAssertEqual(captureCounts.start, 1)
        XCTAssertEqual(fixture.recorders.makeCount(), 1)

        let recorder = try XCTUnwrap(fixture.recorders.recorders().first)
        await waitUntil { await recorder.appendedChunks().count == 3 }
        let chunks = await recorder.appendedChunks()
        XCTAssertEqual(chunks.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(chunks.map(\.frameCount), [3, 5, 2])

        let metadata = await fixture.repository.metadataDocuments()
        XCTAssertEqual(metadata.map(\.status), [.preparing, .recording])
        let recording = try XCTUnwrap(metadata.last)
        XCTAssertEqual(recording.title, "운영체제")
        XCTAssertEqual(recording.languageMode, .english)
        XCTAssertNil(recording.engine)
        XCTAssertNil(recording.model)
        XCTAssertNil(recording.detectedLanguage)
        XCTAssertEqual(recording.transcript.segmentCount.rawValue, 0)
        XCTAssertEqual(recording.audio?.sampleRate, 48_000)
        XCTAssertEqual(recording.audio?.channels, 1)
        XCTAssertEqual(recording.audio?.bitRate, 96_000)
        XCTAssertEqual(recording.appVersion, "7.0-test")
        XCTAssertEqual(recording.osVersion, "testOS")

        let operations = await trace.values()
        assertOrdered(
            ["repository.create", "metadata.preparing", "capture.start", "recorder.start", "metadata.recording", "event.recordingStarted"],
            in: operations
        )
    }

    func testStopClosesCaptureDrainsBufferedPCMFinishesOnceAndUsesRecorderDuration() async throws {
        let appendGate = ControlledTestGate()
        let trace = TestTrace()
        let fixture = CoordinatorFixture(
            prebufferedFrameCounts: [4],
            recorderAppendGate: (sequence: 1, gate: appendGate),
            recorderDurationMilliseconds: 2_222,
            trace: trace
        )
        let coordinator = fixture.makeCoordinator()
        _ = try await coordinator.start(.init(title: "Drain", timeZone: .init(secondsFromGMT: 0)!))
        let recorder = try XCTUnwrap(fixture.recorders.recorders().first)
        try await fixture.capture.emit(frameCount: 7)
        await appendGate.waitForArrival()

        let stopTasks = (0 ..< 6).map { _ in Task { await coordinator.stop() } }
        await waitUntil { await fixture.capture.counts().stop == 1 }
        let startDuringStop = await startFailure(
            coordinator,
            configuration: .init(title: "Too early", timeZone: .init(secondsFromGMT: 0)!)
        )
        XCTAssertEqual(startDuringStop, .busy)
        XCTAssertEqual(fixture.recorders.makeCount(), 1)
        let countsWhileDraining = await recorder.counts()
        XCTAssertEqual(countsWhileDraining.flush, 0)
        XCTAssertEqual(countsWhileDraining.stop, 0)
        await appendGate.release()

        let results = await withTaskGroup(of: RecordingSessionResult.self) { group in
            for task in stopTasks { group.addTask { await task.value } }
            var values: [RecordingSessionResult] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.count, 6)
        for result in results {
            guard case let .secured(secured) = result else { return XCTFail("Expected secured result") }
            XCTAssertEqual(secured.metadata.status, .securing)
            XCTAssertEqual(secured.metadata.captureOutcome, .completed)
            XCTAssertEqual(secured.metadata.activeDurationMs.rawValue, 2_222)
            XCTAssertEqual(secured.recorderSummary.mediaDurationMilliseconds, 2_222)
        }

        let captureTerminalCounts = await fixture.capture.counts()
        let recorderTerminalCounts = await recorder.counts()
        let appendedSequences = await recorder.appendedChunks().map(\.sequence)
        let startedEvents = await fixture.repository.events(kind: .recordingStarted)
        let endedEvents = await fixture.repository.events(kind: .recordingEnded)
        let terminalDocuments = await fixture.repository.metadataDocuments()
        XCTAssertEqual(captureTerminalCounts.stop, 1)
        XCTAssertEqual(recorderTerminalCounts.flush, 1)
        XCTAssertEqual(recorderTerminalCounts.stop, 1)
        XCTAssertEqual(appendedSequences, [0, 1])
        XCTAssertEqual(startedEvents.count, 1)
        XCTAssertEqual(endedEvents.count, 1)
        XCTAssertEqual(terminalDocuments.filter { $0.status == .securing }.count, 1)

        let final = await coordinator.currentSnapshot()
        XCTAssertEqual(final.phase, .securedAwaitingFinalization)
        XCTAssertEqual(final.persistedStatus, .securing)
        XCTAssertEqual(final.elapsedMilliseconds, 2_222)
        XCTAssertTrue(final.canReset)
        let operations = await trace.values()
        assertOrdered(
            ["capture.stop", "recorder.append.1.end", "recorder.flush", "recorder.stop", "event.recordingEnded", "metadata.securing", "catalog.reconcile"],
            in: operations
        )

        await coordinator.reset()
        let reset = await coordinator.currentSnapshot()
        XCTAssertEqual(reset.phase, .idle)
        _ = try await coordinator.start(.init(title: "Next", timeZone: .init(secondsFromGMT: 0)!))
        XCTAssertEqual(fixture.recorders.makeCount(), 2)
        _ = await coordinator.stop()
    }

    func testStopDuringWriterStartCancelsAttemptAndCleansStartedResourcesExactlyOnce() async throws {
        let writerStartGate = ControlledTestGate()
        let trace = TestTrace()
        let fixture = CoordinatorFixture(
            prebufferedFrameCounts: [4],
            recorderStartGate: writerStartGate,
            trace: trace
        )
        let coordinator = fixture.makeCoordinator()

        let startTask = Task {
            do {
                _ = try await coordinator.start(.init(title: "Cancel start", timeZone: .init(secondsFromGMT: 0)!))
                return nil as RecordingSessionFailure?
            } catch let failure as RecordingSessionFailure {
                return failure
            } catch {
                return .unknown
            }
        }
        await writerStartGate.waitForArrival()
        let stopTask = Task { await coordinator.stop() }
        await waitUntil { await fixture.capture.counts().stop == 1 }
        await writerStartGate.release()

        let callerCancellationFailure = await startTask.value
        let stopResult = await stopTask.value
        XCTAssertEqual(callerCancellationFailure, .cancelled)
        XCTAssertEqual(stopResult, .error(.cancelled))
        let recorder = try XCTUnwrap(fixture.recorders.recorders().first)
        let recorderCounts = await recorder.counts()
        let appended = await recorder.appendedChunks()
        let captureCounts = await fixture.capture.counts()
        let metadataDocuments = await fixture.repository.metadataDocuments()
        let terminalMetadata = metadataDocuments.last
        let terminalEvents = await fixture.repository.events(kind: .recordingEnded)
        XCTAssertEqual(captureCounts.stop, 1)
        XCTAssertEqual(appended.map(\.sequence), [0])
        XCTAssertEqual(appended.map(\.frameCount), [4])
        XCTAssertEqual(recorderCounts.flush, 1)
        XCTAssertEqual(recorderCounts.stop, 1)
        XCTAssertEqual(terminalEvents.count, 1)
        XCTAssertEqual(metadataDocuments.filter { $0.status == .error }.count, 1)
        XCTAssertEqual(terminalMetadata?.status, .error)
        XCTAssertEqual(terminalMetadata?.captureOutcome, .notStarted)
        let hasRecoveryArtifact = await recorder.hasRecoveryArtifact()
        XCTAssertTrue(hasRecoveryArtifact)
        let deleteCount = await fixture.repository.deleteCount()
        XCTAssertEqual(deleteCount, 0)
        assertOrdered(
            ["capture.stop", "recorder.append.0.end", "recorder.flush", "recorder.stop", "event.recordingEnded", "metadata.error"],
            in: await trace.values()
        )
    }

    func testCaptureTerminalDuringWriterStartWinsBeforeRecordingBecomesDurable() async throws {
        let writerStartGate = ControlledTestGate()
        let trace = TestTrace()
        let fixture = CoordinatorFixture(
            prebufferedFrameCounts: [4],
            recorderStartGate: writerStartGate,
            trace: trace
        )
        let coordinator = fixture.makeCoordinator()
        let startTask = Task {
            await startFailure(
                coordinator,
                configuration: .init(title: "Route race", timeZone: .init(secondsFromGMT: 0)!)
            )
        }

        await writerStartGate.waitForArrival()
        await fixture.capture.emitTerminal(.activeDeviceDisconnected)
        await writerStartGate.release()

        let failure = await startTask.value
        await waitUntil {
            let phase = await coordinator.currentSnapshot().phase
            return phase == .error || phase == .interrupted
        }
        let snapshot = await coordinator.currentSnapshot()
        let recorder = try XCTUnwrap(fixture.recorders.recorders().first)
        let recorderCounts = await recorder.counts()
        let appended = await recorder.appendedChunks()
        let metadata = await fixture.repository.metadataDocuments()
        let startedEvents = await fixture.repository.events(kind: .recordingStarted)
        let terminalEvents = await fixture.repository.events(kind: .microphoneDisconnected)
        XCTAssertEqual(failure, .capture(.activeDeviceDisconnected))
        XCTAssertEqual(snapshot.phase, .error)
        XCTAssertEqual(snapshot.failure, .capture(.activeDeviceDisconnected))
        XCTAssertEqual(appended.map(\.sequence), [0])
        XCTAssertEqual(appended.map(\.frameCount), [4])
        XCTAssertEqual(recorderCounts.flush, 1)
        XCTAssertEqual(recorderCounts.stop, 1)
        XCTAssertEqual(startedEvents.count, 0)
        XCTAssertEqual(terminalEvents.count, 1)
        XCTAssertEqual(metadata.last?.status, .error)
        XCTAssertEqual(metadata.last?.captureOutcome, .notStarted)
        XCTAssertEqual(metadata.filter { $0.status == .error }.count, 1)
        let hasRecoveryArtifact = await recorder.hasRecoveryArtifact()
        let deleteCount = await fixture.repository.deleteCount()
        XCTAssertTrue(hasRecoveryArtifact)
        XCTAssertEqual(deleteCount, 0)
        assertOrdered(
            ["capture.stop", "recorder.append.0.end", "recorder.flush", "recorder.stop", "event.microphoneDisconnected", "metadata.error"],
            in: await trace.values()
        )
    }

    func testCallerCancellationDuringWriterStartDrainsPCMAndDoesNotLeaveOwnedWork() async throws {
        let writerStartGate = ControlledTestGate()
        let trace = TestTrace()
        let fixture = CoordinatorFixture(
            prebufferedFrameCounts: [3, 5],
            recorderStartGate: writerStartGate,
            trace: trace
        )
        let coordinator = fixture.makeCoordinator()
        let callerConfiguration = RecordingStartConfiguration(title: "Caller cancel", timeZone: .init(secondsFromGMT: 0)!)
        let startTask: Task<RecordingSessionFailure?, Never> = Task {
            await startFailure(coordinator, configuration: callerConfiguration)
        }

        await writerStartGate.waitForArrival()
        startTask.cancel()
        await waitUntil { await fixture.capture.counts().stop == 1 }
        await writerStartGate.release()

        let callerCancellationFailure = await startTask.value
        let recorder = try XCTUnwrap(fixture.recorders.recorders().first)
        let appended = await recorder.appendedChunks()
        let captureCounts = await fixture.capture.counts()
        let recorderCounts = await recorder.counts()
        let hasRecoveryArtifact = await recorder.hasRecoveryArtifact()
        let deleteCount = await fixture.repository.deleteCount()
        let metadata = await fixture.repository.metadataDocuments()
        let terminalEvents = await fixture.repository.events(kind: .recordingEnded)
        XCTAssertEqual(callerCancellationFailure, .cancelled)
        XCTAssertEqual(appended.map(\.sequence), [0, 1])
        XCTAssertEqual(appended.map(\.frameCount), [3, 5])
        XCTAssertEqual(captureCounts.stop, 1)
        XCTAssertEqual(recorderCounts.flush, 1)
        XCTAssertEqual(recorderCounts.stop, 1)
        XCTAssertTrue(hasRecoveryArtifact)
        XCTAssertEqual(deleteCount, 0)
        XCTAssertEqual(metadata.last?.status, .error)
        XCTAssertEqual(terminalEvents.count, 1)
        assertOrdered(
            ["capture.stop", "recorder.append.0.end", "recorder.append.1.end", "recorder.flush", "recorder.stop"],
            in: await trace.values()
        )
        let nextStartFailure = await startFailure(coordinator)
        XCTAssertEqual(nextStartFailure, nil, "new start is allowed only after the first cleanup finished")
        _ = await coordinator.stop()
    }

    func testUnexpectedPrimaryRecordingStreamTerminalsAreTypedInterruptedAndPreserveRecovery() async throws {
        enum Terminal {
            case normal
            case thrown(CaptureErrorCode)
        }
        let cases: [(Terminal, RecordingSessionFailure)] = [
            (.normal, .recordingStreamEnded),
            (.thrown(.runtimeFailure), .capture(.runtimeFailure)),
            (.thrown(.recordingBackpressure), .capture(.recordingBackpressure))
        ]
        for (terminal, expectedFailure) in cases {
            let fixture = CoordinatorFixture(prebufferedFrameCounts: [2, 4])
            let coordinator = fixture.makeCoordinator()
            _ = try await coordinator.start(.init(title: "Unexpected stream", timeZone: .init(secondsFromGMT: 0)!))
            let recorder = try XCTUnwrap(fixture.recorders.recorders().first)
            await waitUntil { await recorder.appendedChunks().count == 2 }
            switch terminal {
            case .normal: await fixture.capture.finishRecordingNormallyUnexpectedly()
            case let .thrown(code): await fixture.capture.finishRecordingThrowing(code)
            }
            await waitUntil { await coordinator.currentSnapshot().phase == .interrupted }
            let snapshot = await coordinator.currentSnapshot()
            let appended = await recorder.appendedChunks()
            let recorderCounts = await recorder.counts()
            let captureCounts = await fixture.capture.counts()
            let hasRecoveryArtifact = await recorder.hasRecoveryArtifact()
            let deleteCount = await fixture.repository.deleteCount()
            let metadata = await fixture.repository.metadataDocuments()
            XCTAssertEqual(snapshot.phase, .interrupted)
            XCTAssertEqual(snapshot.failure, expectedFailure)
            XCTAssertNotEqual(snapshot.persistedStatus, .securing)
            XCTAssertEqual(appended.map(\.sequence), [0, 1])
            XCTAssertEqual(recorderCounts.stop, 1)
            XCTAssertEqual(captureCounts.stop, 1)
            XCTAssertTrue(hasRecoveryArtifact)
            XCTAssertEqual(deleteCount, 0)
            XCTAssertEqual(metadata.last?.status, .interrupted)
        }
    }

    func testStorageRootFailuresHaveNoSideEffectsAndChangedRootPreservesCreatedFolderMetadata() async throws {
        let summary = StorageRootSummary(
            id: StorageRootID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!),
            displayName: "Reauthorization root",
            displayPath: "/temporary/requires-auth",
            updatedAt: AbsoluteTime(Date(timeIntervalSince1970: 1_788_262_440))
        )
        let unavailable: [(StorageRootAvailability, RecordingSessionFailure)] = [
            (.noRootSelected, .storageRoot(.noActiveRoot)),
            (.reauthorizationRequired(summary), .storageRoot(.reauthorizationRequired)),
            (.failed(.rootNotWritable), .storageRoot(.rootNotWritable))
        ]
        for (availability, expected) in unavailable {
            let fixture = CoordinatorFixture(rootAvailability: availability)
            let failure = await startFailure(fixture.makeCoordinator())
            let createCount = await fixture.repository.createCount()
            let captureCounts = await fixture.capture.counts()
            let permissionCounts = await fixture.permission.counts()
            XCTAssertEqual(failure, expected)
            XCTAssertEqual(createCount, 0)
            XCTAssertEqual(captureCounts.start, 0)
            XCTAssertEqual(permissionCounts, .zero)
            XCTAssertEqual(fixture.recorders.makeCount(), 0)
        }

        let redirectedRootID = StorageRootID(UUID(uuidString: "99999999-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!)
        let changed = CoordinatorFixture(createdLocationRootID: redirectedRootID)
        let failure = await startFailure(changed.makeCoordinator())
        XCTAssertEqual(failure, .storageRoot(.noActiveRoot))
        let didCreateFolder = await changed.repository.didCreateFolder()
        let captureCounts = await changed.capture.counts()
        let deleteCount = await changed.repository.deleteCount()
        let metadata = await changed.repository.metadataDocuments()
        XCTAssertTrue(didCreateFolder)
        XCTAssertEqual(captureCounts.start, 0)
        XCTAssertEqual(changed.recorders.makeCount(), 0)
        XCTAssertEqual(deleteCount, 0)
        let errorMetadata = try XCTUnwrap(metadata.last)
        XCTAssertEqual(errorMetadata.status, .error)
        XCTAssertEqual(errorMetadata.captureOutcome, .notStarted)
    }

    func testRecordingEndedWriteFailurePreservesFirstFailureTerminalMetadataAndRecovery() async throws {
        let fixture = CoordinatorFixture(prebufferedFrameCounts: [6], repositoryFault: .eventWrite(2))
        let coordinator = fixture.makeCoordinator()
        _ = try await coordinator.start(.init(title: "Ended write", timeZone: .init(secondsFromGMT: 0)!))
        let recorder = try XCTUnwrap(fixture.recorders.recorders().first)
        let result = await coordinator.stop()
        let recorderCounts = await recorder.counts()
        let hasRecoveryArtifact = await recorder.hasRecoveryArtifact()
        let deleteCount = await fixture.repository.deleteCount()
        let endedEvents = await fixture.repository.events(kind: .recordingEnded)
        let storageEvents = await fixture.repository.events(kind: .storageAccessError)
        let metadata = await fixture.repository.metadataDocuments()

        XCTAssertEqual(result, .interrupted(.persistence(.jsonlAppendFailed)))
        XCTAssertEqual(recorderCounts.stop, 1)
        XCTAssertTrue(hasRecoveryArtifact)
        XCTAssertEqual(deleteCount, 0)
        XCTAssertEqual(endedEvents.count, 0)
        XCTAssertEqual(storageEvents.count, 1)
        let terminal = try XCTUnwrap(metadata.last)
        XCTAssertEqual(terminal.status, .interrupted)
        XCTAssertEqual(terminal.captureOutcome, .interrupted)
        XCTAssertEqual(metadata.filter { $0.status == .interrupted }.count, 1)
    }

    func testPreDurableTerminalSignalsWaitForPersistenceOwnerBeforeExactOnceSettlement() async throws {
        enum PersistenceStep: CaseIterable, Equatable {
            case recordingMetadata
            case recordingStartedEvent
        }
        enum Terminal: CaseIterable, Equatable {
            case primaryStreamThrow
            case captureTerminal
            case recorderTerminal
            case callerCancellation

            var failure: RecordingSessionFailure {
                switch self {
                case .primaryStreamThrow: .capture(.runtimeFailure)
                case .captureTerminal: .capture(.activeDeviceDisconnected)
                case .recorderTerminal: .recorder(.writerFinishFailed)
                case .callerCancellation: .cancelled
                }
            }

            var failureEventKind: SessionEventKind {
                switch self {
                case .captureTerminal: .microphoneDisconnected
                case .recorderTerminal: .fileWriteError
                case .primaryStreamThrow, .callerCancellation: .recordingEnded
                }
            }
        }

        for step in PersistenceStep.allCases {
            for terminal in Terminal.allCases {
                let gate = ControlledTestGate()
                let trace = TestTrace()
                let repositoryGate: TestRepositoryGate = switch step {
                case .recordingMetadata: .metadataWrite(2, gate)
                case .recordingStartedEvent: .eventWrite(1, gate)
                }
                let fixture = CoordinatorFixture(
                    prebufferedFrameCounts: [3, 5],
                    repositoryGate: repositoryGate,
                    trace: trace
                )
                let coordinator = fixture.makeCoordinator()
                let startTask: Task<RecordingSessionFailure?, Never> = Task {
                    await startFailure(
                        coordinator,
                        configuration: .init(title: "Pre-durable terminal", timeZone: .init(secondsFromGMT: 0)!)
                    )
                }

                await gate.waitForArrival()
                let recorder = try XCTUnwrap(fixture.recorders.recorders().first)
                switch terminal {
                case .primaryStreamThrow:
                    await fixture.capture.finishRecordingThrowing(.runtimeFailure)
                case .captureTerminal:
                    await fixture.capture.emitTerminal(.activeDeviceDisconnected)
                case .recorderTerminal:
                    await recorder.emitTerminal(.writerFinishFailed)
                case .callerCancellation:
                    startTask.cancel()
                }
                await waitUntil { await fixture.capture.counts().stop == 1 }

                let beforeReleaseRecorderCounts = await recorder.counts()
                let beforeReleaseMetadata = await fixture.repository.metadataDocuments()
                XCTAssertEqual(beforeReleaseRecorderCounts.flush, 0, "\(step)/\(terminal) settled before start persistence returned")
                XCTAssertEqual(beforeReleaseRecorderCounts.stop, 0, "\(step)/\(terminal) settled before start persistence returned")
                XCTAssertEqual(beforeReleaseMetadata.last?.status, step == .recordingMetadata ? .preparing : .recording)

                await gate.release()
                let observedFailure = await startTask.value
                await waitUntil {
                    let phase = await coordinator.currentSnapshot().phase
                    return phase == .error || phase == .interrupted
                }

                let becameDurable = step == .recordingStartedEvent
                let expectedStatus: SessionStatus = becameDurable ? .interrupted : .error
                let expectedOutcome: CaptureOutcome = becameDurable ? .interrupted : .notStarted
                let expectedTerminalEndCount = becameDurable ? 1 : 0
                let expectedFailure = terminal.failure
                let chunks = await recorder.appendedChunks()
                let recorderCounts = await recorder.counts()
                let captureCounts = await fixture.capture.counts()
                let metadata = await fixture.repository.metadataDocuments()
                let allEvents = await fixture.repository.events()
                let startedEvents = await fixture.repository.events(kind: .recordingStarted)
                let failureEvents = await fixture.repository.events(kind: terminal.failureEventKind)
                let endedEvents = await fixture.repository.events(kind: .recordingEnded)
                let hasRecoveryArtifact = await recorder.hasRecoveryArtifact()
                let deleteCount = await fixture.repository.deleteCount()

                XCTAssertEqual(observedFailure, expectedFailure, "\(step)/\(terminal) lost its first typed failure")
                XCTAssertEqual(chunks.map(\.sequence), [0, 1])
                XCTAssertEqual(chunks.map(\.frameCount), [3, 5])
                XCTAssertEqual(captureCounts.stop, 1)
                XCTAssertEqual(recorderCounts.flush, 1)
                XCTAssertEqual(recorderCounts.stop, 1)
                XCTAssertTrue(hasRecoveryArtifact)
                XCTAssertEqual(deleteCount, 0)
                XCTAssertEqual(metadata.last?.status, expectedStatus)
                XCTAssertEqual(metadata.last?.captureOutcome, expectedOutcome)
                XCTAssertEqual(metadata.filter { $0.status == expectedStatus }.count, 1)
                XCTAssertEqual(startedEvents.count, becameDurable ? 1 : 0)
                XCTAssertEqual(
                    allEvents.map(\.kind),
                    becameDurable
                        ? [.recordingStarted, terminal.failureEventKind, .recordingEnded]
                        : [terminal.failureEventKind]
                )
                XCTAssertEqual(failureEvents.filter { $0.detail?.code == expectedFailure.stableCode }.count, 1)
                XCTAssertEqual(
                    endedEvents.filter { $0.detail?.code == "interrupted.\(expectedFailure.stableCode)" }.count,
                    expectedTerminalEndCount
                )
                assertOrdered(
                    ["recorder.append.0.end", "recorder.append.1.end", "recorder.flush", "recorder.stop", "event.\(terminal.failureEventKind.rawValue)", "metadata.\(expectedStatus.rawValue)"],
                    in: await trace.values()
                )
            }
        }
    }

    func testPreDurablePersistenceFailureKeepsEarlierTerminalFailureAsPublicStartResult() async throws {
        enum PersistenceStep: CaseIterable, Equatable {
            case recordingMetadata
            case recordingStartedEvent
        }
        enum Terminal: CaseIterable, Equatable {
            case primaryStreamThrow
            case captureTerminal
            case recorderTerminal
            case callerCancellation

            var failure: RecordingSessionFailure {
                switch self {
                case .primaryStreamThrow: .capture(.runtimeFailure)
                case .captureTerminal: .capture(.activeDeviceDisconnected)
                case .recorderTerminal: .recorder(.writerFinishFailed)
                case .callerCancellation: .cancelled
                }
            }

            var failureEventKind: SessionEventKind {
                switch self {
                case .captureTerminal: .microphoneDisconnected
                case .recorderTerminal: .fileWriteError
                case .primaryStreamThrow, .callerCancellation: .recordingEnded
                }
            }
        }

        let persistenceFailure = RecordingSessionFailure.persistence(.temporaryWriteFailed)
        for step in PersistenceStep.allCases {
            for terminal in Terminal.allCases {
                let gate = ControlledTestGate()
                let repositoryGate: TestRepositoryGate = switch step {
                case .recordingMetadata: .metadataWriteThenFail(2, gate, .temporaryWriteFailed)
                case .recordingStartedEvent: .eventWriteThenFail(1, gate, .temporaryWriteFailed)
                }
                let fixture = CoordinatorFixture(
                    prebufferedFrameCounts: [3, 5],
                    repositoryGate: repositoryGate
                )
                let coordinator = fixture.makeCoordinator()
                let startTask: Task<RecordingSessionFailure?, Never> = Task {
                    await startFailure(
                        coordinator,
                        configuration: .init(title: "First terminal wins", timeZone: .init(secondsFromGMT: 0)!)
                    )
                }

                await gate.waitForArrival()
                let recorder = try XCTUnwrap(fixture.recorders.recorders().first)
                switch terminal {
                case .primaryStreamThrow:
                    await fixture.capture.finishRecordingThrowing(.runtimeFailure)
                case .captureTerminal:
                    await fixture.capture.emitTerminal(.activeDeviceDisconnected)
                case .recorderTerminal:
                    await recorder.emitTerminal(.writerFinishFailed)
                case .callerCancellation:
                    startTask.cancel()
                }
                await waitUntil { await fixture.capture.counts().stop == 1 }

                await gate.release()
                let expectedFailure = terminal.failure
                let observedFailure = await startTask.value
                await waitUntil {
                    let phase = await coordinator.currentSnapshot().phase
                    return phase == .error
                }

                let snapshot = await coordinator.currentSnapshot()
                let lastResult = await coordinator.stop()
                let chunks = await recorder.appendedChunks()
                let recorderCounts = await recorder.counts()
                let captureCounts = await fixture.capture.counts()
                let metadata = await fixture.repository.metadataDocuments()
                let events = await fixture.repository.events()
                let recoveryArtifactExists = await recorder.hasRecoveryArtifact()
                let deleteCount = await fixture.repository.deleteCount()

                XCTAssertEqual(observedFailure, expectedFailure, "\(step)/\(terminal) returned the later persistence failure")
                XCTAssertEqual(snapshot.failure, expectedFailure)
                XCTAssertEqual(lastResult, .error(expectedFailure))
                XCTAssertEqual(snapshot.persistenceWarningCode, persistenceFailure.stableCode)
                XCTAssertEqual(snapshot.phase, .error)
                XCTAssertEqual(snapshot.persistedStatus, .error)
                XCTAssertEqual(chunks.map(\.sequence), [0, 1])
                XCTAssertEqual(chunks.map(\.frameCount), [3, 5])
                XCTAssertEqual(captureCounts.stop, 1)
                XCTAssertEqual(recorderCounts.flush, 1)
                XCTAssertEqual(recorderCounts.stop, 1)
                XCTAssertTrue(recoveryArtifactExists)
                XCTAssertEqual(deleteCount, 0)
                XCTAssertEqual(metadata.map(\.status), step == .recordingMetadata ? [.preparing, .error] : [.preparing, .recording, .error])
                XCTAssertEqual(metadata.last?.captureOutcome, .notStarted)
                XCTAssertEqual(metadata.filter { $0.status == .error }.count, 1)
                XCTAssertEqual(
                    events.map(\.kind),
                    [terminal.failureEventKind],
                    "\(step)/\(terminal) duplicated a failure or ended event"
                )
                XCTAssertEqual(events.first?.detail?.code, expectedFailure.stableCode)
            }
        }
    }

    func testSettlementWaitsForPriorPumpDrainAndObserverTerminationBeforeNewSessionStarts() async throws {
        let appendGate = ControlledTestGate()
        let fixture = CoordinatorFixture(
            prebufferedFrameCounts: [3],
            recorderAppendGate: (sequence: 0, gate: appendGate)
        )
        let coordinator = fixture.makeCoordinator()
        _ = try await coordinator.start(.init(title: "First", timeZone: .init(secondsFromGMT: 0)!))
        let firstRecorder = try XCTUnwrap(fixture.recorders.recorders().first)
        await appendGate.waitForArrival()

        let stopTask = Task { await coordinator.stop() }
        await waitUntil { await fixture.capture.counts().stop == 1 }
        let blockedStart = await startFailure(
            coordinator,
            configuration: .init(title: "Must wait", timeZone: .init(secondsFromGMT: 0)!)
        )
        let countsWhilePumpBlocked = await firstRecorder.counts()
        XCTAssertEqual(blockedStart, .busy)
        XCTAssertEqual(countsWhilePumpBlocked.flush, 0)
        XCTAssertEqual(countsWhilePumpBlocked.stop, 0)

        await appendGate.release()
        _ = await stopTask.value
        await waitUntil { await fixture.capture.observerTerminationCounts() == .init(event: 1, level: 1) }
        await waitUntil { await firstRecorder.eventStreamTerminationCount() == 1 }
        await coordinator.reset()
        let second = try await coordinator.start(.init(title: "Second", timeZone: .init(secondsFromGMT: 0)!))
        let secondRecorder = try XCTUnwrap(fixture.recorders.recorders().last)
        let current = await coordinator.currentSnapshot()
        let appended = await secondRecorder.appendedChunks()
        let recorderCounts = await secondRecorder.counts()
        let captureObserverTerminations = await fixture.capture.observerTerminationCounts()
        let recorderObserverTerminations = await firstRecorder.eventStreamTerminationCount()
        XCTAssertEqual(current.phase, .recording)
        XCTAssertEqual(current.sessionID, second.sessionID)
        XCTAssertNil(current.failure)
        XCTAssertEqual(appended.map(\.sequence), [0])
        XCTAssertEqual(recorderCounts.stop, 0)
        XCTAssertEqual(captureObserverTerminations, .init(event: 1, level: 1))
        XCTAssertEqual(recorderObserverTerminations, 1)
        _ = await coordinator.stop()
    }

    func testTerminalMetadataFailureRecordsInterruptedOnceWithoutDuplicatingEndedEvent() async throws {
        let fixture = CoordinatorFixture(
            prebufferedFrameCounts: [8],
            repositoryFault: .metadataWrite(3)
        )
        let coordinator = fixture.makeCoordinator()
        _ = try await coordinator.start(.init(title: "Terminal persistence", timeZone: .init(secondsFromGMT: 0)!))

        let result = await coordinator.stop()
        let endedEvents = await fixture.repository.events(kind: .recordingEnded)
        let storageEvents = await fixture.repository.events(kind: .storageAccessError)
        let metadata = await fixture.repository.metadataDocuments()
        XCTAssertEqual(result, .interrupted(.persistence(.temporaryWriteFailed)))
        XCTAssertEqual(endedEvents.count, 1)
        XCTAssertEqual(storageEvents.count, 1)
        XCTAssertEqual(metadata.last?.status, .interrupted)
        XCTAssertEqual(metadata.last?.captureOutcome, .interrupted)
    }

    func testStartFaultMatrixPreservesOriginalFailureSessionFolderAndNotStartedMetadata() async throws {
        let cases: [(TestRepositoryFault?, CaptureErrorCode?, AudioRecorderErrorCode?, RecordingSessionFailure, Bool)] = [
            (.create, nil, nil, .persistence(.sessionLayoutCreationFailed), false),
            (.metadataWrite(1), nil, nil, .persistence(.temporaryWriteFailed), true),
            (nil, .engineStartFailed, nil, .capture(.engineStartFailed), true),
            (nil, nil, .writerStartFailed, .recorder(.writerStartFailed), true),
            (.metadataWrite(2), nil, nil, .persistence(.temporaryWriteFailed), true),
            (.eventWrite(1), nil, nil, .persistence(.jsonlAppendFailed), true)
        ]

        for (repositoryFault, captureFault, recorderFault, expected, folderCreated) in cases {
            let fixture = CoordinatorFixture(
                prebufferedFrameCounts: [4],
                repositoryFault: repositoryFault,
                captureStartFailure: captureFault,
                recorderStartFailure: recorderFault
            )
            let coordinator = fixture.makeCoordinator()
            let failure = await startFailure(coordinator)
            let didCreateFolder = await fixture.repository.didCreateFolder()
            let deleteCount = await fixture.repository.deleteCount()
            let captureCounts = await fixture.capture.counts()
            XCTAssertEqual(failure, expected)
            XCTAssertEqual(didCreateFolder, folderCreated)
            XCTAssertEqual(deleteCount, 0)
            XCTAssertLessThanOrEqual(captureCounts.stop, 1)
            if folderCreated {
                let last = await fixture.repository.metadataDocuments().last
                if let last {
                    XCTAssertEqual(last.status, .error)
                    XCTAssertEqual(last.captureOutcome, .notStarted)
                }
            }
            let snapshot = await coordinator.currentSnapshot()
            XCTAssertEqual(snapshot.phase, .error)
            XCTAssertEqual(snapshot.failure, expected)
        }
    }

    func testAppendFailureRecorderEventCaptureRaceAndUserStopSettleInterruptedOnce() async throws {
        let appendGate = ControlledTestGate()
        let fixture = CoordinatorFixture(
            prebufferedFrameCounts: [4],
            recorderAppendFailureSequence: 1,
            recorderAppendGate: (sequence: 1, gate: appendGate)
        )
        let coordinator = fixture.makeCoordinator()
        _ = try await coordinator.start(.init(title: "Race", timeZone: .init(secondsFromGMT: 0)!))
        let recorder = try XCTUnwrap(fixture.recorders.recorders().first)
        try await fixture.capture.emit(frameCount: 8)
        await appendGate.waitForArrival()

        await appendGate.release()
        await waitUntil {
            await coordinator.currentSnapshot().failure == .recorder(.writerAppendFailed)
        }
        let stopTask = Task { await coordinator.stop() }
        await fixture.capture.emitTerminal(.activeDeviceDisconnected)
        let result = await stopTask.value
        guard case let .interrupted(failure) = result else { return XCTFail("Expected interrupted result") }
        XCTAssertEqual(failure, .recorder(.writerAppendFailed))
        let captureCounts = await fixture.capture.counts()
        let recorderCounts = await recorder.counts()
        let fileEvents = await fixture.repository.events(kind: .fileWriteError)
        let endedEvents = await fixture.repository.events(kind: .recordingEnded)
        let metadata = await fixture.repository.metadataDocuments()
        XCTAssertEqual(captureCounts.stop, 1)
        XCTAssertEqual(recorderCounts.stop, 1)
        XCTAssertEqual(fileEvents.count, 1)
        XCTAssertEqual(fileEvents.first?.detail?.code, "recorder.writerAppendFailed")
        XCTAssertEqual(fileEvents.first?.mediaPositionMs?.rawValue, 100)
        XCTAssertEqual(endedEvents.filter { $0.detail?.code.contains("interrupted") == true }.count, 1)
        let terminalMetadata = try XCTUnwrap(metadata.last)
        XCTAssertEqual(terminalMetadata.status, .interrupted)
        XCTAssertEqual(terminalMetadata.captureOutcome, .interrupted)
    }

    func testZeroSampleStopAndCaptureDisconnectNeverReportNormalSecuring() async throws {
        let zero = CoordinatorFixture(prebufferedFrameCounts: [])
        let zeroCoordinator = zero.makeCoordinator()
        _ = try await zeroCoordinator.start(.init(title: "Zero", timeZone: .init(secondsFromGMT: 0)!))
        let zeroResult = await zeroCoordinator.stop()
        let zeroSnapshot = await zeroCoordinator.currentSnapshot()
        XCTAssertEqual(zeroResult, .interrupted(.recorder(.noAudioSamples)))
        XCTAssertEqual(zeroSnapshot.phase, .interrupted)

        let disconnected = CoordinatorFixture(prebufferedFrameCounts: [8])
        let disconnectedCoordinator = disconnected.makeCoordinator()
        _ = try await disconnectedCoordinator.start(.init(title: "Disconnect", timeZone: .init(secondsFromGMT: 0)!))
        await disconnected.capture.emitTerminal(.activeDeviceDisconnected)
        await waitUntil { await disconnectedCoordinator.currentSnapshot().phase == .interrupted }
        let snapshot = await disconnectedCoordinator.currentSnapshot()
        let disconnectedEvents = await disconnected.repository.events(kind: .microphoneDisconnected)
        let disconnectedMetadata = await disconnected.repository.metadataDocuments()
        XCTAssertEqual(snapshot.failure, .capture(.activeDeviceDisconnected))
        XCTAssertEqual(disconnectedEvents.count, 1)
        XCTAssertEqual(disconnectedEvents.first?.detail?.code, "capture.activeDeviceDisconnected")
        XCTAssertEqual(disconnectedEvents.first?.mediaPositionMs?.rawValue, 1_000)
        XCTAssertEqual(disconnectedMetadata.last?.status, .interrupted)

        let backpressure = CoordinatorFixture(prebufferedFrameCounts: [8])
        let backpressureCoordinator = backpressure.makeCoordinator()
        _ = try await backpressureCoordinator.start(.init(title: "Backpressure", timeZone: .init(secondsFromGMT: 0)!))
        await backpressure.capture.emitTerminal(.recordingBackpressure)
        await waitUntil { await backpressureCoordinator.currentSnapshot().phase == .interrupted }
        let backpressureSnapshot = await backpressureCoordinator.currentSnapshot()
        XCTAssertEqual(backpressureSnapshot.failure, .capture(.recordingBackpressure))

        let finishFailure = CoordinatorFixture(
            prebufferedFrameCounts: [8],
            recorderStopFailure: .writerFinishFailed
        )
        let finishCoordinator = finishFailure.makeCoordinator()
        _ = try await finishCoordinator.start(.init(title: "Finish failure", timeZone: .init(secondsFromGMT: 0)!))
        let finishResult = await finishCoordinator.stop()
        let finishMetadata = await finishFailure.repository.metadataDocuments()
        XCTAssertEqual(finishResult, .interrupted(.recorder(.writerFinishFailed)))
        XCTAssertEqual(finishMetadata.last?.status, .interrupted)
        XCTAssertEqual(finishMetadata.last?.captureOutcome, .interrupted)
    }

    func testNoInputEpisodeStaleGenerationElapsedAndCatalogWarningDoNotStopOrCorruptRecording() async throws {
        let clock = TestRecordingClock()
        let ticker = ManualRecordingTicker()
        let fixture = CoordinatorFixture(
            prebufferedFrameCounts: [4],
            catalogFailure: .stepFailed,
            clock: clock.value,
            ticker: ticker
        )
        let coordinator = fixture.makeCoordinator()
        _ = try await coordinator.start(.init(title: "Signals", timeZone: .init(secondsFromGMT: 0)!))
        let currentGeneration = await fixture.capture.currentGeneration()
        let generation = try XCTUnwrap(currentGeneration)

        await fixture.capture.emitSignal(generation: generation + 100, state: .noInput, level: 0)
        let staleSnapshot = await coordinator.currentSnapshot()
        XCTAssertFalse(staleSnapshot.noInputWarning)
        await fixture.capture.emitSignal(generation: generation, state: .noInput, level: 0)
        await fixture.capture.emitSignal(generation: generation, state: .noInput, level: 0)
        await waitUntil { await fixture.repository.events(kind: .noInputWarning).count == 1 }
        let noInputSnapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(noInputSnapshot.noInputWarning)

        await fixture.capture.emitSignal(generation: generation, state: .active, level: 0.75)
        await waitUntil { await coordinator.currentSnapshot().normalizedInputLevel == 0.75 }
        let activeSnapshot = await coordinator.currentSnapshot()
        XCTAssertFalse(activeSnapshot.noInputWarning)
        try await fixture.capture.emit(frameCount: 5)
        let recorder = try XCTUnwrap(fixture.recorders.recorders().first)
        await waitUntil { await recorder.appendedChunks().count == 2 }

        clock.advanceMonotonic(by: 7.25)
        ticker.tick()
        await waitUntil { await coordinator.currentSnapshot().elapsedMilliseconds == 7_250 }
        let result = await coordinator.stop()
        guard case let .secured(secured) = result else { return XCTFail("Expected secured result") }
        let securedSnapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(secured.metadata.activeDurationMs.rawValue, 1_000)
        XCTAssertEqual(securedSnapshot.elapsedMilliseconds, 1_000)
        XCTAssertEqual(securedSnapshot.catalogWarningCode, .stepFailed)
    }

    @MainActor
    func testViewModelSnapshotDisplaysActionsAndObservationResubscriptionDoNotOwnRecordingLifetime() async throws {
        let coordinator = ViewModelRecordingCoordinator()
        let viewModel = RecordingSessionViewModel(
            coordinator: coordinator,
            timeZone: { TimeZone(secondsFromGMT: 9 * 3_600)! }
        )
        _ = RecordingSessionView(viewModel: viewModel)
        let constructionCounts = coordinator.counts()
        XCTAssertEqual(constructionCounts, .zero)

        viewModel.title = "  UI title  "
        viewModel.languageMode = .automatic
        viewModel.startObserving()
        await waitUntil { await coordinator.counts().snapshotSubscriptions == 1 }
        await viewModel.refreshPermissionStatus()
        await viewModel.startRecording()
        let lastConfiguration = coordinator.lastConfiguration()
        let config = try XCTUnwrap(lastConfiguration)
        XCTAssertEqual(config.title, "  UI title  ")
        XCTAssertEqual(config.languageMode, .automatic)
        XCTAssertEqual(config.timeZone.secondsFromGMT(), 9 * 3_600)
        XCTAssertEqual(RecordingSessionViewModel.formatElapsed(3_661_999), "01:01:01")

        await viewModel.stopRecording()
        let stoppedCounts = coordinator.counts()
        XCTAssertEqual(stoppedCounts.stop, 1)
        await viewModel.beginAnotherRecording()
        XCTAssertEqual(viewModel.title, "")
        let resetCounts = coordinator.counts()
        XCTAssertEqual(resetCounts.reset, 1)

        let sessionID = SessionID(UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!)
        let displayCases: [(RecordingSessionPhase, RecordingSessionViewDisplayState, Bool, Bool, Bool)] = [
            (.preparing, .preparing, false, false, false),
            (.recording, .recording, false, true, false),
            (.securing, .securing, false, false, false),
            (.securedAwaitingFinalization, .secured, false, false, true),
            (.interrupted, .interrupted, false, false, true),
            (.error, .error, false, false, true)
        ]
        for (phase, display, canStart, canStop, canReset) in displayCases {
            coordinator.emit(snapshotForView(
                phase: phase,
                sessionID: sessionID,
                canStart: canStart,
                canStop: canStop,
                canReset: canReset
            ))
            await waitUntil {
                await MainActor.run {
                    viewModel.displayState == display
                        && viewModel.actions.canStart == canStart
                        && viewModel.actions.canStop == canStop
                        && viewModel.actions.canReset == canReset
                }
            }
            XCTAssertEqual(viewModel.displayState, display)
            XCTAssertEqual(viewModel.actions.canStart, canStart)
            XCTAssertEqual(viewModel.actions.canStop, canStop)
            XCTAssertEqual(viewModel.actions.canReset, canReset)
        }

        coordinator.emit(snapshotForView(phase: .recording, sessionID: sessionID, canStart: false, canStop: true, canReset: false))
        await waitUntil { await MainActor.run { viewModel.displayState == .recording } }
        let stopsBeforeObservationCancellation = coordinator.counts().stop
        viewModel.stopObserving()
        coordinator.emit(snapshotForView(phase: .securing, sessionID: sessionID, canStart: false, canStop: false, canReset: false))
        await Task.yield()
        XCTAssertEqual(coordinator.counts().stop, stopsBeforeObservationCancellation, "cancelling observation never sends a coordinator stop")
        viewModel.startObserving()
        await waitUntil { await coordinator.counts().snapshotSubscriptions == 2 }
        await waitUntil { await MainActor.run { viewModel.displayState == .securing } }
        XCTAssertEqual(viewModel.displayState, .securing, "a replacement observer receives the active coordinator snapshot")
        XCTAssertEqual(coordinator.counts().stop, stopsBeforeObservationCancellation)
    }
}

private final class CoordinatorFixture: @unchecked Sendable {
    let rootID = StorageRootID(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
    let roots: TestRootChecker
    let permission: TestPermission
    let capture: TestCapture
    let recorders: TestRecorderFactory
    let repository: TestSessionRepository
    let catalog: TestRecordingCatalog
    let clock: RecordingSessionClock
    let ticker: any RecordingTicking

    init(
        rootAvailability: StorageRootAvailability? = nil,
        permissionStatus: MicrophonePermissionStatus = .authorized,
        requestResult: MicrophonePermissionStatus? = nil,
        prebufferedFrameCounts: [Int] = [4],
        repositoryFault: TestRepositoryFault? = nil,
        captureStartFailure: CaptureErrorCode? = nil,
        recorderStartFailure: AudioRecorderErrorCode? = nil,
        recorderAppendFailureSequence: UInt64? = nil,
        recorderStopFailure: AudioRecorderErrorCode? = nil,
        recorderStartGate: ControlledTestGate? = nil,
        recorderAppendGate: (sequence: UInt64, gate: ControlledTestGate)? = nil,
        recorderDurationMilliseconds: UInt64 = 1_000,
        catalogFailure: CatalogErrorCode? = nil,
        createdLocationRootID: StorageRootID? = nil,
        repositoryGate: TestRepositoryGate? = nil,
        trace: TestTrace = TestTrace(),
        clock: RecordingSessionClock? = nil,
        ticker: (any RecordingTicking)? = nil
    ) {
        let summary = StorageRootSummary(
            id: rootID,
            displayName: "Temporary Root",
            displayPath: "/temporary/root",
            updatedAt: AbsoluteTime(Date(timeIntervalSince1970: 1_788_262_440))
        )
        roots = TestRootChecker(rootAvailability ?? .available(summary, refreshedBookmark: false))
        permission = TestPermission(status: permissionStatus, requestResult: requestResult ?? permissionStatus)
        capture = TestCapture(
            prebufferedFrameCounts: prebufferedFrameCounts,
            startFailure: captureStartFailure,
            trace: trace
        )
        repository = TestSessionRepository(
            rootID: createdLocationRootID ?? rootID,
            fault: repositoryFault,
            gate: repositoryGate,
            trace: trace
        )
        catalog = TestRecordingCatalog(failure: catalogFailure, trace: trace)
        recorders = TestRecorderFactory {
            TestAudioRecorder(
                startFailure: recorderStartFailure,
                appendFailureSequence: recorderAppendFailureSequence,
                stopFailure: recorderStopFailure,
                startGate: recorderStartGate,
                appendGate: recorderAppendGate,
                durationMilliseconds: recorderDurationMilliseconds,
                trace: trace
            )
        }
        self.clock = clock ?? RecordingSessionClock(
            wallNow: { AbsoluteTime(Date(timeIntervalSince1970: 1_788_262_440)) },
            monotonicNow: { 100 }
        )
        self.ticker = ticker ?? SilentRecordingTicker()
    }

    func makeCoordinator() -> RecordingSessionCoordinator {
        RecordingSessionCoordinator(
            roots: roots,
            permission: permission,
            capture: capture,
            recorders: recorders,
            repository: repository,
            catalog: catalog,
            clock: clock,
            ticker: ticker,
            environment: RecordingSessionEnvironment(appVersion: "7.0-test", osVersion: "testOS"),
            identifiers: RecordingSessionIdentifiers(
                sessionID: { SessionID(UUID()) },
                eventID: { SessionEventID(UUID()) }
            )
        )
    }
}

private struct DependencyCounts: Sendable, Equatable {
    var status = 0
    var request = 0
    var start = 0
    var stop = 0
    var snapshotSubscriptions = 0
    var reset = 0
    static let zero = DependencyCounts()
}

private struct CaptureObserverTerminationCounts: Sendable, Equatable {
    var event: Int = 0
    var level: Int = 0
}

private actor TestRootChecker: RecordingStorageRootChecking {
    let value: StorageRootAvailability
    private var count = 0
    init(_ value: StorageRootAvailability) { self.value = value }
    func availability() async -> StorageRootAvailability { count += 1; return value }
}

private actor TestPermission: MicrophonePermissionAuthorizing {
    let status: MicrophonePermissionStatus
    let requestResult: MicrophonePermissionStatus
    private var value = DependencyCounts.zero
    init(status: MicrophonePermissionStatus, requestResult: MicrophonePermissionStatus) {
        self.status = status
        self.requestResult = requestResult
    }
    func authorizationStatus() async -> MicrophonePermissionStatus { value.status += 1; return status }
    func requestAuthorization() async -> MicrophonePermissionStatus { value.request += 1; return requestResult }
    func counts() -> DependencyCounts { value }
}

private actor TestCapture: MicrophoneCapturing {
    private let prebufferedFrameCounts: [Int]
    private let startFailure: CaptureErrorCode?
    private let trace: TestTrace
    private var value = DependencyCounts.zero
    private var generation: UInt64 = 0
    private var nextSequence: UInt64 = 0
    private var lifecycle: CaptureLifecycle = .idle
    private var recordingContinuation: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    private var speechContinuation: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    private var eventContinuation: AsyncStream<CaptureEvent>.Continuation?
    private var levelContinuation: AsyncStream<InputSignalSample>.Continuation?
    private var observerTerminations = CaptureObserverTerminationCounts()

    init(prebufferedFrameCounts: [Int], startFailure: CaptureErrorCode?, trace: TestTrace) {
        self.prebufferedFrameCounts = prebufferedFrameCounts
        self.startFailure = startFailure
        self.trace = trace
    }

    func currentLifecycle() async -> CaptureLifecycle { lifecycle }

    func start() async throws -> CaptureHandle {
        value.start += 1
        await trace.append("capture.start")
        if let startFailure {
            lifecycle = .failed(startFailure)
            throw CaptureError(startFailure)
        }
        generation += 1
        nextSequence = 0
        lifecycle = .running
        let recording = AsyncThrowingStream<PCMChunk, Error>.makeStream(bufferingPolicy: .unbounded)
        let speech = AsyncThrowingStream<PCMChunk, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let events = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .unbounded)
        let levels = AsyncStream<InputSignalSample>.makeStream(bufferingPolicy: .unbounded)
        events.continuation.onTermination = { [weak self] _ in
            Task { await self?.recordEventStreamTermination() }
        }
        levels.continuation.onTermination = { [weak self] _ in
            Task { await self?.recordLevelStreamTermination() }
        }
        recordingContinuation = recording.continuation
        speechContinuation = speech.continuation
        eventContinuation = events.continuation
        levelContinuation = levels.continuation
        for frames in prebufferedFrameCounts { try emitChunk(frameCount: frames) }
        return CaptureHandle(
            generation: generation,
            device: InputDeviceSnapshot(identity: "synthetic", displayName: "Synthetic Microphone"),
            recordingPCM: recording.stream,
            speechPCM: speech.stream,
            events: events.stream,
            inputSignalStates: levels.stream
        )
    }

    func stop() async {
        value.stop += 1
        await trace.append("capture.stop")
        lifecycle = .idle
        eventContinuation?.yield(.stopped)
        recordingContinuation?.finish()
        speechContinuation?.finish()
        eventContinuation?.finish()
        levelContinuation?.finish()
    }

    func emit(frameCount: Int) throws { try emitChunk(frameCount: frameCount) }

    func emitTerminal(_ code: CaptureErrorCode) {
        lifecycle = .failed(code)
        eventContinuation?.yield(.terminalFailure(code))
        recordingContinuation?.finish(throwing: CaptureError(code))
    }

    func finishRecordingNormallyUnexpectedly() {
        lifecycle = .failed(.runtimeFailure)
        recordingContinuation?.finish()
    }

    func finishRecordingThrowing(_ code: CaptureErrorCode) {
        lifecycle = .failed(code)
        recordingContinuation?.finish(throwing: CaptureError(code))
    }

    func emitSignal(generation: UInt64, state: InputSignalState, level: Float) {
        levelContinuation?.yield(InputSignalSample(
            generation: generation,
            sequence: nil,
            monotonicSeconds: 100,
            normalizedLevel: level,
            rmsDBFS: level > 0 ? -10 : -120,
            peakDBFS: level > 0 ? -5 : -120,
            state: state
        ))
    }

    func currentGeneration() -> UInt64? { lifecycle == .running ? generation : nil }
    func counts() -> DependencyCounts { value }
    func observerTerminationCounts() -> CaptureObserverTerminationCounts { observerTerminations }

    private func recordEventStreamTermination() { observerTerminations.event += 1 }
    private func recordLevelStreamTermination() { observerTerminations.level += 1 }

    private func emitChunk(frameCount: Int) throws {
        let format = try PCMFormatDescription(sampleRate: 48_000, channelCount: 1)
        let chunk = try PCMChunk(
            generation: generation,
            sequence: nextSequence,
            format: format,
            frameCount: frameCount,
            sourceSampleTime: Int64(nextSequence) * Int64(frameCount),
            samples: Array(repeating: 0.25, count: frameCount)
        )
        nextSequence += 1
        recordingContinuation?.yield(chunk)
        speechContinuation?.yield(chunk)
    }
}

private struct RecorderCounts: Sendable, Equatable {
    var start = 0
    var append = 0
    var flush = 0
    var stop = 0
}

private actor TestAudioRecorder: AudioRecorder {
    private let startFailure: AudioRecorderErrorCode?
    private let appendFailureSequence: UInt64?
    private let stopFailure: AudioRecorderErrorCode?
    private let startGate: ControlledTestGate?
    private let appendGate: (sequence: UInt64, gate: ControlledTestGate)?
    private let durationMilliseconds: UInt64
    private let trace: TestTrace
    private let eventPair = AsyncStream<AudioRecorderEvent>.makeStream(bufferingPolicy: .unbounded)
    private var value = RecorderCounts()
    private var state: AudioRecorderState = .idle
    private var location: SessionLocation?
    private var chunks: [PCMChunk] = []
    private var recoveryArtifactExists = false
    private var eventStreamTerminations = 0

    init(
        startFailure: AudioRecorderErrorCode?,
        appendFailureSequence: UInt64?,
        stopFailure: AudioRecorderErrorCode?,
        startGate: ControlledTestGate?,
        appendGate: (sequence: UInt64, gate: ControlledTestGate)?,
        durationMilliseconds: UInt64,
        trace: TestTrace
    ) {
        self.startFailure = startFailure
        self.appendFailureSequence = appendFailureSequence
        self.stopFailure = stopFailure
        self.startGate = startGate
        self.appendGate = appendGate
        self.durationMilliseconds = durationMilliseconds
        self.trace = trace
        eventPair.continuation.onTermination = { [weak self] _ in
            Task { await self?.recordEventStreamTermination() }
        }
    }

    func start(at location: SessionLocation, expectedCaptureGeneration: UInt64) async throws {
        value.start += 1
        await trace.append("recorder.start")
        await startGate?.arriveAndWait()
        if let startFailure {
            state = .failed(startFailure)
            eventPair.continuation.yield(.terminalFailure(kind: .fileWriteError, code: startFailure, mediaPositionMilliseconds: 0))
            throw AudioRecorderError(startFailure)
        }
        self.location = location
        state = .recording
        recoveryArtifactExists = true
    }

    func append(_ chunk: PCMChunk) async throws {
        value.append += 1
        await trace.append("recorder.append.\(chunk.sequence).begin")
        if appendGate?.sequence == chunk.sequence { await appendGate?.gate.arriveAndWait() }
        if appendFailureSequence == chunk.sequence {
            state = .failed(.writerAppendFailed)
            eventPair.continuation.yield(.terminalFailure(
                kind: .fileWriteError,
                code: .writerAppendFailed,
                mediaPositionMilliseconds: UInt64(chunks.count * 100)
            ))
            await trace.append("recorder.append.\(chunk.sequence).failed")
            throw AudioRecorderError(.writerAppendFailed)
        }
        chunks.append(chunk)
        await trace.append("recorder.append.\(chunk.sequence).end")
    }

    func flush() async throws {
        value.flush += 1
        await trace.append("recorder.flush")
        if case let .failed(code) = state { throw AudioRecorderError(code) }
    }

    func stop() async throws -> AudioRecorderSummary {
        value.stop += 1
        await trace.append("recorder.stop")
        if case let .failed(code) = state { throw AudioRecorderError(code) }
        if let stopFailure {
            state = .failed(stopFailure)
            eventPair.continuation.yield(.terminalFailure(
                kind: .fileWriteError,
                code: stopFailure,
                mediaPositionMilliseconds: UInt64(chunks.count * 100)
            ))
            throw AudioRecorderError(stopFailure)
        }
        guard let location else { throw AudioRecorderError(.invalidLifecycle) }
        guard !chunks.isEmpty else {
            state = .failed(.noAudioSamples)
            eventPair.continuation.yield(.terminalFailure(kind: .fileWriteError, code: .noAudioSamples, mediaPositionMilliseconds: 0))
            throw AudioRecorderError(.noAudioSamples)
        }
        let summary = AudioRecorderSummary(
            location: location,
            artifact: .recoveryAudio,
            writtenFrameCount: UInt64(chunks.reduce(0) { $0 + $1.frameCount }),
            mediaDurationMilliseconds: durationMilliseconds,
            outputFormat: .recoveryAAC
        )
        state = .completed(summary)
        return summary
    }

    func currentState() async -> AudioRecorderState { state }
    func events() async -> AsyncStream<AudioRecorderEvent> { eventPair.stream }
    func counts() -> RecorderCounts { value }
    func appendedChunks() -> [PCMChunk] { chunks }
    func hasRecoveryArtifact() -> Bool { recoveryArtifactExists }
    func emitTerminal(_ code: AudioRecorderErrorCode) {
        eventPair.continuation.yield(.terminalFailure(kind: .fileWriteError, code: code, mediaPositionMilliseconds: 0))
    }
    func eventStreamTerminationCount() -> Int { eventStreamTerminations }
    private func recordEventStreamTermination() { eventStreamTerminations += 1 }
}

private final class TestRecorderFactory: AudioRecorderMaking, @unchecked Sendable {
    private let lock = NSLock()
    private let factory: @Sendable () -> TestAudioRecorder
    private var values: [TestAudioRecorder] = []
    init(factory: @escaping @Sendable () -> TestAudioRecorder) { self.factory = factory }
    func makeRecorder() -> any AudioRecorder {
        let recorder = factory()
        lock.withLock { values.append(recorder) }
        return recorder
    }
    func makeCount() -> Int { lock.withLock { values.count } }
    func recorders() -> [TestAudioRecorder] { lock.withLock { values } }
}

private enum TestRepositoryFault: Sendable, Equatable {
    case create
    case metadataWrite(Int)
    case eventWrite(Int)
}

private enum TestRepositoryGate: Sendable {
    case metadataWrite(Int, ControlledTestGate)
    case eventWrite(Int, ControlledTestGate)
    case metadataWriteThenFail(Int, ControlledTestGate, StorageErrorCode)
    case eventWriteThenFail(Int, ControlledTestGate, StorageErrorCode)
}

private actor TestSessionRepository: SessionRepository {
    private let rootID: StorageRootID
    private let fault: TestRepositoryFault?
    private let gate: TestRepositoryGate?
    private let trace: TestTrace
    private var creates = 0
    private var createdFolder = false
    private var deletes = 0
    private var metadataWrites = 0
    private var eventWrites = 0
    private var metadata: [SessionMetadataDocument] = []
    private var eventRecords: [SessionEventRecord] = []

    init(rootID: StorageRootID, fault: TestRepositoryFault?, gate: TestRepositoryGate?, trace: TestTrace) {
        self.rootID = rootID
        self.fault = fault
        self.gate = gate
        self.trace = trace
    }

    func createSession(sessionID: SessionID, createdAt: AbsoluteTime, timeZone: TimeZone) async throws -> SessionLocation {
        creates += 1
        await trace.append("repository.create")
        if fault == .create { throw StorageError(.sessionLayoutCreationFailed) }
        createdFolder = true
        return SessionLocation(
            rootID: rootID,
            sessionID: sessionID,
            folderName: SessionFolderName(sessionID: sessionID, createdAt: createdAt, timeZone: timeZone)
        )
    }

    func writeMetadata(_ document: SessionMetadataDocument, at location: SessionLocation) async throws {
        metadataWrites += 1
        if fault == .metadataWrite(metadataWrites) { throw StorageError(.temporaryWriteFailed) }
        if case let .metadataWrite(index, gate) = gate, metadataWrites == index {
            await trace.append("metadata.\(document.status.rawValue).gate")
            await gate.arriveAndWait()
        }
        if case let .metadataWriteThenFail(index, gate, failure) = gate, metadataWrites == index {
            await trace.append("metadata.\(document.status.rawValue).gate")
            await gate.arriveAndWait()
            throw StorageError(failure)
        }
        metadata.append(document)
        await trace.append("metadata.\(document.status.rawValue)")
    }

    func readMetadata(at location: SessionLocation) async throws -> SessionMetadataDocument {
        guard let last = metadata.last else { throw StorageError(.artifactMissing) }
        return last
    }

    func writeTranscript(_ document: TranscriptDocument, at location: SessionLocation) async throws {}
    func readTranscript(at location: SessionLocation) async throws -> TranscriptDocument { throw StorageError(.artifactMissing) }
    func writeFinalizationCheckpoint(_ document: FinalizationCheckpointDocument, at location: SessionLocation) async throws {}
    func readFinalizationCheckpoint(at location: SessionLocation) async throws -> FinalizationCheckpointDocument { throw StorageError(.artifactMissing) }

    func appendEvent(_ record: SessionEventRecord, at location: SessionLocation) async throws {
        eventWrites += 1
        if fault == .eventWrite(eventWrites) { throw StorageError(.jsonlAppendFailed) }
        if case let .eventWrite(index, gate) = gate, eventWrites == index {
            await trace.append("event.\(record.kind.rawValue).gate")
            await gate.arriveAndWait()
        }
        if case let .eventWriteThenFail(index, gate, failure) = gate, eventWrites == index {
            await trace.append("event.\(record.kind.rawValue).gate")
            await gate.arriveAndWait()
            throw StorageError(failure)
        }
        eventRecords.append(record)
        await trace.append("event.\(record.kind.rawValue)")
    }

    func appendTranscriptJournal(_ record: TranscriptJournalRecord, at location: SessionLocation) async throws {}
    nonisolated func artifactOwnership(_ artifact: SessionArtifact) -> SessionArtifactOwnership { artifact.ownership }
    func createCount() -> Int { creates }
    func didCreateFolder() -> Bool { createdFolder }
    func deleteCount() -> Int { deletes }
    func metadataDocuments() -> [SessionMetadataDocument] { metadata }
    func events() -> [SessionEventRecord] { eventRecords }
    func events(kind: SessionEventKind) -> [SessionEventRecord] { eventRecords.filter { $0.kind == kind } }
}

private actor TestRecordingCatalog: RecordingCatalogRefreshing {
    private let failure: CatalogErrorCode?
    private let trace: TestTrace
    init(failure: CatalogErrorCode?, trace: TestTrace) { self.failure = failure; self.trace = trace }
    func reconcile() async throws -> CatalogReconciliationReport {
        await trace.append("catalog.reconcile")
        if let failure { throw CatalogError(failure) }
        return CatalogReconciliationReport(rootResults: [], issues: [], recoveredFromCorruption: false)
    }
}

private actor TestTrace {
    private var entries: [String] = []
    func append(_ value: String) { entries.append(value) }
    func values() -> [String] { entries }
}

private actor ControlledTestGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func arriveAndWait() async {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
    func waitForArrival() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }
    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private struct SilentRecordingTicker: RecordingTicking {
    func ticks() -> AsyncStream<Void> { AsyncStream { _ in } }
}

private final class ManualRecordingTicker: RecordingTicking, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<Void>.Continuation] = []
    func ticks() -> AsyncStream<Void> {
        AsyncStream { continuation in lock.withLock { continuations.append(continuation) } }
    }
    func tick() { lock.withLock { continuations }.forEach { $0.yield(()) } }
}

private final class TestRecordingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wall = Date(timeIntervalSince1970: 1_788_262_440)
    private var monotonic: TimeInterval = 100
    var value: RecordingSessionClock {
        RecordingSessionClock(
            wallNow: { [weak self] in AbsoluteTime(self?.lock.withLock { self?.wall } ?? Date(timeIntervalSince1970: 0)) },
            monotonicNow: { [weak self] in self?.lock.withLock { self?.monotonic } ?? 0 }
        )
    }
    func advanceMonotonic(by value: TimeInterval) { lock.withLock { monotonic += value } }
}

@MainActor
private final class ViewModelRecordingCoordinator: RecordingSessionCoordinating, @unchecked Sendable {
    private var value = DependencyCounts.zero
    private var configuration: RecordingStartConfiguration?
    private var snapshot = RecordingSessionSnapshot.idle(permissionStatus: .notDetermined)
    private var continuations: [UUID: AsyncStream<RecordingSessionSnapshot>.Continuation] = [:]
    func snapshots() async -> AsyncStream<RecordingSessionSnapshot> {
        value.snapshotSubscriptions += 1
        let id = UUID()
        let pair = AsyncStream<RecordingSessionSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = pair.continuation
        pair.continuation.yield(snapshot)
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations.removeValue(forKey: id) }
        }
        return pair.stream
    }
    func currentSnapshot() async -> RecordingSessionSnapshot { snapshot }
    func refreshPermissionStatus() async { value.status += 1 }
    func start(_ configuration: RecordingStartConfiguration) async throws -> RecordingSessionSnapshot {
        value.start += 1
        self.configuration = configuration
        return snapshot
    }
    func stop() async -> RecordingSessionResult { value.stop += 1; return .error(.busy) }
    func reset() async { value.reset += 1 }
    func counts() -> DependencyCounts { value }
    func lastConfiguration() -> RecordingStartConfiguration? { configuration }
    func emit(_ snapshot: RecordingSessionSnapshot) {
        self.snapshot = snapshot
        continuations.values.forEach { $0.yield(snapshot) }
    }
}

private func snapshotForView(
    phase: RecordingSessionPhase,
    sessionID: SessionID?,
    canStart: Bool,
    canStop: Bool,
    canReset: Bool
) -> RecordingSessionSnapshot {
    RecordingSessionSnapshot(
        phase: phase,
        permissionStatus: .authorized,
        sessionID: sessionID,
        title: "UI snapshot",
        languageMode: .korean,
        persistedStatus: phase == .securedAwaitingFinalization ? .securing : nil,
        recordingStartedAt: AbsoluteTime(Date(timeIntervalSince1970: 1_788_262_440)),
        elapsedMilliseconds: 1_000,
        microphoneDisplayName: "Synthetic Microphone",
        normalizedInputLevel: 0.5,
        noInputWarning: false,
        failure: phase == .error || phase == .interrupted ? .capture(.runtimeFailure) : nil,
        persistenceWarningCode: nil,
        catalogWarningCode: nil,
        canStart: canStart,
        canStop: canStop,
        canReset: canReset
    )
}

private func startFailure(
    _ coordinator: RecordingSessionCoordinator,
    configuration: RecordingStartConfiguration = .init(title: "", timeZone: .init(secondsFromGMT: 0)!)
) async -> RecordingSessionFailure? {
    do {
        _ = try await coordinator.start(configuration)
        return nil
    } catch let failure as RecordingSessionFailure {
        return failure
    } catch {
        return .unknown
    }
}

private func waitUntil(
    iterations: Int = 5_000,
    _ predicate: @escaping @Sendable () async -> Bool
) async {
    for _ in 0 ..< iterations {
        if await predicate() { return }
        await Task.yield()
    }
    XCTFail("Condition did not become true")
}

private func assertOrdered(_ expected: [String], in actual: [String], file: StaticString = #filePath, line: UInt = #line) {
    var lowerBound = actual.startIndex
    for value in expected {
        guard let index = actual[lowerBound...].firstIndex(of: value) else {
            XCTFail("Missing ordered operation \(value) in \(actual)", file: file, line: line)
            return
        }
        lowerBound = actual.index(after: index)
    }
}
