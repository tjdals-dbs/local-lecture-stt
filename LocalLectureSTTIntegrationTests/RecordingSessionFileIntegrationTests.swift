import AVFoundation
import Foundation
import XCTest
@testable import LocalLectureSTT

final class RecordingSessionFileIntegrationTests: XCTestCase {
    /// T10 B06: this deliberately crosses the production root, repository,
    /// capture, recorder and catalog path.  It proves the sleep path keeps a
    /// readable MOV and does not accidentally submit normal finalization.
    func testT10SleepInterruptionRetainsReadableRecoveryMOVWithoutDerivedPlaceholders() async throws {
        let fixture = try RecordingFileIntegrationFixture()
        defer { fixture.cleanup() }
        let roots = StorageRootManager(applicationSupportDirectory: fixture.applicationSupport, bookmarkCodec: fixture.bookmarks)
        let rootSummary = try await roots.registerSelectedDirectory(fixture.root)
        let permission = AuthorizedIntegrationPermission()
        let capture = MicrophoneCaptureController(
            permission: permission,
            driver: SyntheticIntegrationCaptureDriver(chunkCount: 48, framesPerChunk: 2_048),
            buffers: CaptureBufferConfiguration(recordingCapacity: 64, speechCapacity: 4),
            monitor: InputSignalMonitor(clock: FixedIntegrationMonotonicClock(), scheduler: NoopIntegrationSignalScheduler())
        )
        let repository = FileSessionRepository(roots: roots)
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: fixture.applicationSupport)
        let catalog = SessionCatalogReconciler(scanner: SessionFileScanner(roots: roots), store: store)
        let coordinator = RecordingSessionCoordinator(
            roots: roots, permission: permission, capture: capture,
            recorders: ClosureAudioRecorderFactory { AVFoundationAudioRecorder(roots: roots) },
            repository: repository, catalog: catalog,
            environment: RecordingSessionEnvironment(appVersion: "T10-integration", osVersion: "synthetic")
        )

        let started = try await coordinator.start(.init(title: "sleep interruption", timeZone: .gmt))
        XCTAssertEqual(started.phase, .recording)
        let result = await coordinator.interrupt(.systemSleep)
        guard case let .interrupted(failure) = result else { return XCTFail("expected interrupted sleep result, got \(result)") }
        XCTAssertEqual(failure, .interrupted(.systemSleep))
        let sessionID = try XCTUnwrap(started.sessionID)
        let folderURL = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: fixture.root,
            includingPropertiesForKeys: [.isDirectoryKey]).first(where: { $0.hasDirectoryPath }))
        let folder = try SessionFolderName(validating: folderURL.lastPathComponent)
        let session = SessionLocation(rootID: rootSummary.id, sessionID: sessionID, folderName: folder)
        let recoveryURL = folderURL.appendingPathComponent(SessionArtifact.recoveryAudio.relativePath)
        let decoded = try await decodeIntegrationAsset(at: recoveryURL)
        XCTAssertGreaterThan(decoded.sampleBufferCount, 0)
        XCTAssertGreaterThan(decoded.decodedBytes, 0)
        XCTAssertGreaterThan(decoded.durationSeconds, 0)

        let metadata = try await repository.readMetadata(at: session)
        XCTAssertEqual(metadata.status, .interrupted)
        XCTAssertEqual(metadata.captureOutcome, .interrupted)
        let events = try decodeIntegrationEvents(at: folderURL.appendingPathComponent(SessionArtifact.events.relativePath))
        XCTAssertEqual(events.filter { $0.kind == .systemSleep }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .recordingEnded }.count, 1)
        for artifact in [SessionArtifact.finalAudio, .transcript, .transcriptText, .transcriptMarkdown, .transcriptJournal] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(artifact.relativePath).path))
        }
        try await store.close()
    }

    func testT09RecoversPreFinishMultiMoofSnapshotWithFreshServices() async throws {
        let fixture = try RecordingFileIntegrationFixture()
        defer { fixture.cleanup() }
        let initialRoots = StorageRootManager(applicationSupportDirectory: fixture.applicationSupport, bookmarkCodec: fixture.bookmarks)
        _ = try await initialRoots.registerSelectedDirectory(fixture.root)
        let initialRepository = FileSessionRepository(roots: initialRoots)
        let time = AbsoluteTime(Date())
        let originalLocation = try await initialRepository.createSession(sessionID: SessionID(), createdAt: time, timeZone: .gmt)
        let recorder = AVFoundationAudioRecorder(roots: initialRoots)
        try await recorder.start(at: originalLocation, expectedCaptureGeneration: 91)
        try await appendSyntheticRecoveryPCM(to: recorder, generation: 91, seconds: 22)
        try await recorder.flush()

        let sourceURL = fixture.root.appendingPathComponent(originalLocation.folderName.rawValue)
            .appendingPathComponent(SessionArtifact.recoveryAudio.relativePath)
        let snapshot = try await readableActiveSnapshot(at: sourceURL, recorder: recorder)
        let stateAtCopy = await recorder.currentState()
        XCTAssertEqual(stateAtCopy, .recording, "the snapshot must precede finish()")
        XCTAssertGreaterThanOrEqual(topLevelBoxCount(snapshot, named: "moof"), 2)
        let snapshotMedia = try await AVFoundationFinalizationMedia().inspect(sourceURL, requiresM4A: false, control: .init())
        XCTAssertGreaterThan(snapshotMedia.durationSeconds, 10)

        // Release the real writer only after taking its active snapshot, then
        // restore that exact pre-finish byte sequence as the crash fixture.
        _ = try await recorder.stop()
        try snapshot.write(to: sourceURL, options: .atomic)
        let models = FileModelRepository(sources: ModelImportSources(), validator: WhisperCppModelValidator(),
                                         references: SessionModelReferenceChecker(roots: initialRoots))
        let selected = try ProductionSpeechModel.make(repository: models)
        let recordingMetadata = try SessionMetadataDocument(
            sessionId: originalLocation.sessionID, title: "pre-finish snapshot", status: .recording,
            captureOutcome: .inProgress, createdAt: time, recordingStartedAt: time,
            activeDurationMs: try MediaMilliseconds(22_000), languageMode: .english,
            engine: selected.configuration.engine, model: selected.configuration.model, modelSettings: selected.settings,
            transcript: .init(segmentCount: try TranscriptSegmentCount(0)), appVersion: "T09", osVersion: "test",
            lastUpdatedAt: time
        )
        try await initialRepository.writeMetadata(recordingMetadata, at: originalLocation)

        // A new root manager/repository/catalog/finalizer/recovery owner has
        // no in-memory state from the writer or initial repository.
        let freshRoots = StorageRootManager(applicationSupportDirectory: fixture.applicationSupport.appendingPathComponent("fresh"), bookmarkCodec: fixture.bookmarks)
        let freshSummary = try await freshRoots.registerSelectedDirectory(fixture.root)
        let freshRepository = FileSessionRepository(roots: freshRoots)
        let freshLocation = SessionLocation(rootID: freshSummary.id, sessionID: originalLocation.sessionID,
            folderName: originalLocation.folderName)
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: fixture.applicationSupport.appendingPathComponent("fresh-catalog"))
        let catalog = SessionCatalogReconciler(scanner: SessionFileScanner(roots: freshRoots), store: store)
        let finalization = AudioFinalizationCoordinator(worker: FileAudioFinalizer(roots: freshRoots, catalog: catalog))
        let recovery = SessionRecoveryCoordinator(scanner: SessionFileScanner(roots: freshRoots), persistence: freshRepository,
            finalization: finalization, catalog: catalog)
        await recovery.start()
        await recovery.waitForCurrentPassSettlement()
        let recovered = await finalization.waitForResult(at: freshLocation)
        let result = try XCTUnwrap(recovered)
        XCTAssertNil(result.failure, "\(result)")
        let finalMedia = try XCTUnwrap(result.media)
        XCTAssertEqual(finalMedia.codec, "AAC-LC")
        XCTAssertEqual(finalMedia.sampleRate, 48_000)
        XCTAssertEqual(finalMedia.channels, 1)
        XCTAssertGreaterThan(finalMedia.first.byteCount, 0)
        XCTAssertGreaterThan(finalMedia.last.byteCount, 0)
        XCTAssertLessThan(finalMedia.maximumGapSeconds, 0.0001)

        let finalURL = fixture.root.appendingPathComponent(originalLocation.folderName.rawValue)
            .appendingPathComponent(SessionArtifact.finalAudio.relativePath)
        let sourceAfter = try Data(contentsOf: sourceURL)
        XCTAssertEqual(sourceAfter, snapshot, "T09 must retain the exact recoverable MOV bytes")
        let independentlyDecodedFinal = try await AVFoundationFinalizationMedia().inspect(finalURL, requiresM4A: true, control: .init())
        XCTAssertEqual(independentlyDecodedFinal.durationSeconds, snapshotMedia.durationSeconds, accuracy: 0.15)
        XCTAssertGreaterThan(independentlyDecodedFinal.first.byteCount, 0)
        XCTAssertGreaterThan(independentlyDecodedFinal.last.byteCount, 0)
        XCTAssertEqual(independentlyDecodedFinal.payloadSHA256, finalMedia.payloadSHA256)
        let metadata = try await freshRepository.readMetadata(at: freshLocation)
        XCTAssertEqual(metadata.engine, selected.configuration.engine)
        XCTAssertEqual(metadata.model, selected.configuration.model)
        XCTAssertEqual(metadata.modelSettings, selected.settings)
        XCTAssertEqual(metadata.status, .finalizing)
        XCTAssertEqual(metadata.captureOutcome, .interrupted)
        let checkpoint = try await freshRepository.readFinalizationCheckpoint(at: freshLocation)
        XCTAssertEqual(checkpoint.completedSteps, Array(FinalizationStep.allCases.prefix(3)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(originalLocation.folderName.rawValue)
            .appendingPathComponent(SessionArtifact.transcript.relativePath).path))
        try await store.close()
    }

    func testAppOwnedFinalizationDoesNotBlockEssentialSaveOrNextRecording() async throws {
        let fixture = try RecordingFileIntegrationFixture()
        defer { fixture.cleanup() }
        let roots = StorageRootManager(applicationSupportDirectory: fixture.applicationSupport, bookmarkCodec: fixture.bookmarks)
        _ = try await roots.registerSelectedDirectory(fixture.root)
        let permission = AuthorizedIntegrationPermission()
        let driver = SyntheticIntegrationCaptureDriver(chunkCount: 32, framesPerChunk: 2048, endFrequency: 1320)
        let capture = MicrophoneCaptureController(permission: permission, driver: driver,
            buffers: CaptureBufferConfiguration(recordingCapacity: 64, speechCapacity: 4),
            monitor: InputSignalMonitor(clock: FixedIntegrationMonotonicClock(), scheduler: NoopIntegrationSignalScheduler()))
        let repository = FileSessionRepository(roots: roots)
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: fixture.applicationSupport)
        let catalog = SessionCatalogReconciler(scanner: SessionFileScanner(roots: roots), store: store)
        let activity = SessionActivityRegistry()
        let recording = RecordingSessionCoordinator(roots: roots, permission: permission, capture: capture,
            recorders: ClosureAudioRecorderFactory { AVFoundationAudioRecorder(roots: roots) }, repository: repository,
            catalog: catalog, environment: RecordingSessionEnvironment(appVersion: "T08-integration", osVersion: "synthetic"), activity: activity)
        let gate = AppFinalizationGate()
        var worker = FileAudioFinalizer(roots: roots, catalog: catalog)
        worker.hook = { if $0 == .beforeExport { await gate.blockOnce() } }
        let finalization = AudioFinalizationCoordinator(worker: worker)
        let app = RecordingFinalizationCoordinator(recording: recording, finalization: finalization, activity: activity)
        _ = try await app.start(.init(title: "First synthetic", timeZone: .gmt))
        let essentialStart = ProcessInfo.processInfo.systemUptime
        let stopped = await app.stop()
        let essentialSeconds = ProcessInfo.processInfo.systemUptime - essentialStart
        guard case let .secured(first) = stopped else { return XCTFail("Essential save failed: \(stopped)") }
        await gate.waitEntered()
        let pending = await finalization.currentSnapshot(at: first.location)
        XCTAssertNil(pending?.result)
        let recovery = SessionRecoveryCoordinator(scanner: SessionFileScanner(roots: roots), persistence: repository,
            finalization: finalization, catalog: catalog, activity: activity)
        await recovery.start()
        await recovery.waitForCurrentPassSettlement()
        let recoverySnapshot = await recovery.currentSnapshot()
        let protectedReport = try XCTUnwrap(recoverySnapshot.report)
        XCTAssertTrue(protectedReport.items.contains { $0.sessionID == first.location.sessionID &&
            $0.folderName == first.location.folderName.rawValue && $0.code == .currentProcessActive },
                      "A root refresh must not mutate a T08-owned live session while its media gate is blocked")
        let second = try await app.start(.init(title: "Second synthetic", timeZone: .gmt))
        XCTAssertEqual(second.phase, .recording)
        XCTAssertNotEqual(second.sessionID, first.location.sessionID)
        let finalizationStart = ProcessInfo.processInfo.systemUptime
        await gate.open()
        let firstResult = await finalization.waitForResult(at: first.location)
        let finalizationSeconds = ProcessInfo.processInfo.systemUptime - finalizationStart
        XCTAssertNil(firstResult?.failure, "\(String(describing: firstResult))")
        let media = try XCTUnwrap(firstResult?.media)
        XCTAssertGreaterThan(media.first.byteCount, 0)
        XCTAssertGreaterThan(media.last.byteCount, 0)
        XCTAssertGreaterThan(media.last.zeroCrossings, media.first.zeroCrossings * 2)
        let stillRecording = await app.currentSnapshot()
        XCTAssertEqual(stillRecording.sessionID, second.sessionID)
        XCTAssertEqual(stillRecording.phase, .recording)
        let metadata = try await repository.readMetadata(at: first.location)
        XCTAssertEqual(metadata.status, .finalizing)
        XCTAssertEqual(metadata.captureOutcome, .completed)
        let session = fixture.root.appendingPathComponent(first.location.folderName.rawValue)
        let source = session.appendingPathComponent(SessionArtifact.recoveryAudio.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("transcript.json").path))
        let independentSource = try await AVFoundationFinalizationMedia().inspect(source, requiresM4A: false, control: .init())
        XCTAssertEqual(media.payloadSHA256, independentSource.payloadSHA256)
        XCTAssertEqual(media.first.rms, independentSource.first.rms, accuracy: 0.001)
        XCTAssertEqual(media.last.rms, independentSource.last.rms, accuracy: 0.001)
        let ended = await app.stop()
        guard case let .secured(secondSecured) = ended else { return XCTFail("Second essential save failed") }
        let secondResult = await finalization.waitForResult(at: secondSecured.location)
        XCTAssertNil(secondResult?.failure)
        let items = try await catalog.orderedItems()
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.metadataStatus == .finalizing })
        let scopes = await fixture.bookmarks.counts()
        XCTAssertEqual(scopes.start, scopes.stop)
        print("T08 A02/C02 essentialSave=\(essentialSeconds)s audioFinalizationAfterGate=\(finalizationSeconds)s")
        try await store.close()
    }

    func testT09BlockedRecoveryMediaDoesNotBlockNewT07RecordingOrOverwriteIt() async throws {
        let fixture = try RecordingFileIntegrationFixture()
        defer { fixture.cleanup() }
        let roots = StorageRootManager(applicationSupportDirectory: fixture.applicationSupport, bookmarkCodec: fixture.bookmarks)
        _ = try await roots.registerSelectedDirectory(fixture.root)
        let repository = FileSessionRepository(roots: roots)
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: fixture.applicationSupport)
        let catalog = SessionCatalogReconciler(scanner: SessionFileScanner(roots: roots), store: store)
        let permission = AuthorizedIntegrationPermission()

        // This is a real T07-secured file from a prior process: it has no
        // current activity reservation and is therefore eligible for T09.
        let oldCapture = MicrophoneCaptureController(permission: permission,
            driver: SyntheticIntegrationCaptureDriver(chunkCount: 16, framesPerChunk: 2_048),
            buffers: CaptureBufferConfiguration(recordingCapacity: 32, speechCapacity: 4),
            monitor: InputSignalMonitor(clock: FixedIntegrationMonotonicClock(), scheduler: NoopIntegrationSignalScheduler()))
        let oldRecording = RecordingSessionCoordinator(roots: roots, permission: permission, capture: oldCapture,
            recorders: ClosureAudioRecorderFactory { AVFoundationAudioRecorder(roots: roots) }, repository: repository,
            catalog: catalog, environment: RecordingSessionEnvironment(appVersion: "T09", osVersion: "synthetic"))
        _ = try await oldRecording.start(.init(title: "Interrupted predecessor", timeZone: .gmt))
        let oldStop = await oldRecording.stop()
        guard case let .secured(old) = oldStop else { return XCTFail("prior T07 session was not secured") }

        let activity = SessionActivityRegistry()
        let gate = AppFinalizationGate()
        var worker = FileAudioFinalizer(roots: roots, catalog: catalog)
        worker.hook = { if $0 == .beforeExport { await gate.blockOnce() } }
        let finalization = AudioFinalizationCoordinator(worker: worker)
        let recovery = SessionRecoveryCoordinator(scanner: SessionFileScanner(roots: roots), persistence: repository,
            finalization: finalization, catalog: catalog, activity: activity)
        let newCapture = MicrophoneCaptureController(permission: permission,
            driver: SyntheticIntegrationCaptureDriver(chunkCount: 16, framesPerChunk: 2_048, endFrequency: 1_320),
            buffers: CaptureBufferConfiguration(recordingCapacity: 32, speechCapacity: 4),
            monitor: InputSignalMonitor(clock: FixedIntegrationMonotonicClock(), scheduler: NoopIntegrationSignalScheduler()))
        let newRecording = RecordingSessionCoordinator(roots: roots, permission: permission, capture: newCapture,
            recorders: ClosureAudioRecorderFactory { AVFoundationAudioRecorder(roots: roots) }, repository: repository,
            catalog: catalog, environment: RecordingSessionEnvironment(appVersion: "T09", osVersion: "synthetic"), activity: activity)
        let app = RecordingFinalizationCoordinator(recording: newRecording, finalization: finalization,
            startupRecovery: recovery, activity: activity)

        let started = try await app.start(.init(title: "New recording during recovery", timeZone: .gmt))
        XCTAssertEqual(started.phase, .recording)
        XCTAssertNotEqual(started.sessionID, old.location.sessionID)
        await gate.waitEntered()
        let oldPending = await finalization.currentSnapshot(at: old.location)
        XCTAssertNil(oldPending?.result, "the predecessor must be genuinely blocked in recovery media work")

        let newStop = await app.stop()
        guard case let .secured(new) = newStop else { return XCTFail("new T07 essential save was blocked") }
        let newBeforeRecoveryCompletes = try await repository.readMetadata(at: new.location)
        XCTAssertEqual(newBeforeRecoveryCompletes.status, .securing)
        XCTAssertEqual(newBeforeRecoveryCompletes.captureOutcome, .completed)
        let oldBeforeRecoveryCompletes = try await repository.readMetadata(at: old.location)
        XCTAssertTrue([.securing, .finalizing].contains(oldBeforeRecoveryCompletes.status),
                      "only the prior recovery location may advance while its media gate is blocked")
        XCTAssertEqual(oldBeforeRecoveryCompletes.captureOutcome, .completed)

        await gate.open()
        let oldResult = await finalization.waitForResult(at: old.location)
        XCTAssertNil(oldResult?.failure)
        let newResult = await finalization.waitForResult(at: new.location)
        XCTAssertNil(newResult?.failure)
        let newAfter = try await repository.readMetadata(at: new.location)
        XCTAssertEqual(newAfter.sessionId, new.location.sessionID)
        XCTAssertEqual(newAfter.captureOutcome, .completed,
                       "a late predecessor callback must never relabel the current recording")
        XCTAssertEqual(newAfter.status, .finalizing)
        let oldAfter = try await repository.readMetadata(at: old.location)
        XCTAssertEqual(oldAfter.sessionId, old.location.sessionID)
        let scopes = await fixture.bookmarks.counts()
        XCTAssertEqual(scopes.start, scopes.stop)
        try await store.close()
    }

    func testProductionCaptureRepositoryRootRecorderAndCatalogPersistDecodableRecoveryAudio() async throws {
        let fixture = try RecordingFileIntegrationFixture()
        defer { fixture.cleanup() }

        let roots = StorageRootManager(
            applicationSupportDirectory: fixture.applicationSupport,
            bookmarkCodec: fixture.bookmarks
        )
        let rootSummary = try await roots.registerSelectedDirectory(fixture.root)
        let permission = AuthorizedIntegrationPermission()
        let driver = SyntheticIntegrationCaptureDriver(chunkCount: 32, framesPerChunk: 2_048)
        let monitor = InputSignalMonitor(
            clock: FixedIntegrationMonotonicClock(),
            scheduler: NoopIntegrationSignalScheduler()
        )
        let capture = MicrophoneCaptureController(
            permission: permission,
            driver: driver,
            buffers: CaptureBufferConfiguration(recordingCapacity: 64, speechCapacity: 4),
            monitor: monitor
        )
        let repository = FileSessionRepository(roots: roots)
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: fixture.applicationSupport)
        let catalog = SessionCatalogReconciler(
            scanner: SessionFileScanner(roots: roots),
            store: store
        )
        // CI exercises recording with a deterministic engine. An explicit local store exercises
        // the identical recording path with the packaged factory and its installed native model.
        let localStore = ProcessInfo.processInfo.environment["LLSTT_T17_TEST_MODEL_STORE"]
        let storeURL = localStore.map { URL(fileURLWithPath: $0) } ?? fixture.applicationSupport.appendingPathComponent("Models")
        let models = FileModelRepository(storeURL: { storeURL }, sources: ModelImportSources(), validator: WhisperCppModelValidator(),
                                         references: SessionModelReferenceChecker(roots: roots))
        let selected = try ProductionSpeechModel.make(repository: models)
        let speech: RecordingSpeechModel
        if localStore != nil {
            speech = selected
            print("T17 integration exercising the installed whisper.cpp model")
        } else {
            let fake = try FakeSTTEngine(engine: selected.configuration.engine, capabilities: selected.engine.capabilities)
            speech = RecordingSpeechModel(engine: fake, configuration: selected.configuration, settings: selected.settings)
        }
        let coordinator = RecordingSessionCoordinator(
            roots: roots,
            permission: permission,
            capture: capture,
            recorders: ClosureAudioRecorderFactory { AVFoundationAudioRecorder(roots: roots) },
            repository: repository,
            catalog: catalog,
            environment: RecordingSessionEnvironment(appVersion: "0.1.0-integration", osVersion: "integrationOS"),
            makeSpeechModel: { speech }
        )

        let initialBookmarkCounts = await fixture.bookmarks.counts()
        let initialPermissionCounts = await permission.counts()
        let initialDriverCounts = await driver.counts()
        XCTAssertEqual(initialBookmarkCounts.start, 0)
        XCTAssertEqual(initialBookmarkCounts.stop, 0)
        XCTAssertEqual(initialPermissionCounts, .init(status: 0, request: 0))
        XCTAssertEqual(initialDriverCounts, .init(prepare: 0, start: 0, stop: 0))

        let started = try await coordinator.start(.init(
            title: "  Production synthetic recording  ",
            languageMode: .english,
            timeZone: .gmt
        ))
        XCTAssertEqual(started.phase, .recording)
        XCTAssertEqual(started.title, "Production synthetic recording")
        XCTAssertEqual(started.languageMode, .english)
        XCTAssertEqual(started.microphoneDisplayName, "Synthetic Integration Input")

        let result = await coordinator.stop()
        guard case let .secured(secured) = result else {
            return XCTFail("Expected a secured recovery-audio result, got \(result)")
        }

        let sessionDirectory = fixture.root.appendingPathComponent(secured.location.folderName.rawValue, isDirectory: true)
        let recoveryURL = sessionDirectory.appendingPathComponent(SessionArtifact.recoveryAudio.relativePath)
        let recoveryBytes = try Data(contentsOf: recoveryURL).count
        let decode = try await decodeIntegrationAsset(at: recoveryURL)
        XCTAssertGreaterThan(recoveryBytes, 0)
        XCTAssertGreaterThan(decode.sampleBufferCount, 0)
        XCTAssertGreaterThan(decode.decodedBytes, 0)
        XCTAssertGreaterThan(decode.durationSeconds, 0)
        XCTAssertEqual(secured.recorderSummary.location, secured.location)
        XCTAssertEqual(secured.recorderSummary.artifact, .recoveryAudio)
        XCTAssertEqual(secured.recorderSummary.writtenFrameCount, 32 * 2_048)
        XCTAssertGreaterThan(secured.recorderSummary.mediaDurationMilliseconds, 0)

        let metadata = try await repository.readMetadata(at: secured.location)
        XCTAssertEqual(metadata.sessionId, secured.location.sessionID)
        XCTAssertEqual(metadata.title, "Production synthetic recording")
        XCTAssertEqual(metadata.languageMode, .english)
        XCTAssertEqual(metadata.status, .securing)
        XCTAssertEqual(metadata.captureOutcome, .completed)
        XCTAssertNotNil(metadata.recordingStartedAt)
        XCTAssertNotNil(metadata.recordingEndedAt)
        XCTAssertEqual(metadata.activeDurationMs.rawValue, Int64(secured.recorderSummary.mediaDurationMilliseconds))
        XCTAssertEqual(metadata.audio?.format, "AAC-LC fragmented QuickTime")
        XCTAssertEqual(metadata.audio?.sampleRate, 48_000)
        XCTAssertEqual(metadata.audio?.channels, 1)
        XCTAssertEqual(metadata.audio?.bitRate, 96_000)
        XCTAssertEqual(metadata.transcript.segmentCount.rawValue, 0)
        XCTAssertEqual(metadata.engine, selected.configuration.engine)
        XCTAssertEqual(metadata.model, selected.configuration.model)
        XCTAssertEqual(metadata.modelSettings, selected.settings)
        XCTAssertNil(metadata.detectedLanguage)

        let eventsURL = sessionDirectory.appendingPathComponent(SessionArtifact.events.relativePath)
        let events = try decodeIntegrationEvents(at: eventsURL)
        XCTAssertEqual(events.map(\.kind), [.recordingStarted, .recordingEnded])
        XCTAssertTrue(events.allSatisfy { $0.sessionId == secured.location.sessionID })
        XCTAssertEqual(Set(events.map { $0.eventId.rawValue }).count, events.count)
        XCTAssertEqual(events.first?.mediaPositionMs?.rawValue, 0)
        XCTAssertEqual(events.last?.mediaPositionMs?.rawValue, Int64(secured.recorderSummary.mediaDurationMilliseconds))

        for artifact in [
            SessionArtifact.finalAudio,
            .transcript,
            .transcriptText,
            .transcriptMarkdown,
            .transcriptJournal,
            .finalizationCheckpoint
        ] {
            let url = sessionDirectory.appendingPathComponent(artifact.relativePath)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Unexpected T08+ artifact: \(artifact)")
        }

        let catalogItems = try await catalog.orderedItems()
        XCTAssertEqual(catalogItems.count, 1)
        XCTAssertEqual(catalogItems.first?.sessionID, secured.location.sessionID)
        XCTAssertEqual(catalogItems.first?.rootID, rootSummary.id)
        XCTAssertEqual(catalogItems.first?.title, metadata.title)
        XCTAssertEqual(catalogItems.first?.metadataStatus, .securing)
        XCTAssertEqual(catalogItems.first?.captureOutcome, .completed)
        XCTAssertEqual(catalogItems.first?.activeDuration, metadata.activeDurationMs)

        let permissionCounts = await permission.counts()
        let driverCounts = await driver.counts()
        let bookmarkCounts = await fixture.bookmarks.counts()
        XCTAssertEqual(permissionCounts, .init(status: 2, request: 0))
        XCTAssertEqual(driverCounts, .init(prepare: 1, start: 1, stop: 1))
        XCTAssertGreaterThan(bookmarkCounts.start, 0)
        XCTAssertEqual(bookmarkCounts.start, bookmarkCounts.stop)

        try await store.close()
        print(
            "T07_INTEGRATION_EVIDENCE recoveryBytes=\(recoveryBytes) " +
            "sampleBuffers=\(decode.sampleBufferCount) decodedBytes=\(decode.decodedBytes) " +
            "durationMs=\(secured.recorderSummary.mediaDurationMilliseconds) " +
            "bookmarkScopes=\(bookmarkCounts.start)/\(bookmarkCounts.stop)"
        )
    }

    @MainActor
    func testT09HistoricalRootReauthorizationDoesNotHideLiveRecordingOrStop() async throws {
        let fixture = try RecordingFileIntegrationFixture()
        defer { fixture.cleanup() }
        let historicalURL = fixture.base.appendingPathComponent("historical-root", isDirectory: true)
        let nonDirectoryURL = fixture.base.appendingPathComponent("not-a-root")
        try FileManager.default.createDirectory(at: historicalURL, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: nonDirectoryURL)
        let roots = StorageRootManager(applicationSupportDirectory: fixture.applicationSupport, bookmarkCodec: fixture.bookmarks)
        let historical = try await roots.registerSelectedDirectory(historicalURL)
        let active = try await roots.registerSelectedDirectory(fixture.root)
        let permission = AuthorizedIntegrationPermission()
        let capture = MicrophoneCaptureController(permission: permission,
            driver: SyntheticIntegrationCaptureDriver(chunkCount: 16, framesPerChunk: 2_048),
            buffers: CaptureBufferConfiguration(recordingCapacity: 32, speechCapacity: 4),
            monitor: InputSignalMonitor(clock: FixedIntegrationMonotonicClock(), scheduler: NoopIntegrationSignalScheduler()))
        let repository = FileSessionRepository(roots: roots)
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: fixture.applicationSupport)
        let catalog = SessionCatalogReconciler(scanner: SessionFileScanner(roots: roots), store: store)
        let recording = RecordingSessionCoordinator(roots: roots, permission: permission, capture: capture,
            recorders: ClosureAudioRecorderFactory { AVFoundationAudioRecorder(roots: roots) }, repository: repository,
            catalog: catalog, environment: RecordingSessionEnvironment(appVersion: "T09", osVersion: "synthetic"))
        let finalization = AudioFinalizationCoordinator(worker: FileAudioFinalizer(roots: roots, catalog: catalog))
        let app = RecordingFinalizationCoordinator(recording: recording, finalization: finalization)
        _ = try await app.start(.init(title: "Active while historical root changes", timeZone: .gmt))
        let afterStart = await app.currentSnapshot()
        XCTAssertEqual(afterStart.phase, .recording)

        let failed = StorageRootViewModel(controller: roots,
            directorySelector: IntegrationDirectorySelector(selectedURL: nonDirectoryURL))
        await failed.restore(); await failed.reauthorize(rootID: historical.id)
        XCTAssertEqual(failed.state, .available(active, refreshedBookmark: false))
        XCTAssertEqual(failed.historicalReauthorizationErrors[historical.id], .rootNotDirectory)
        let afterFailure = await app.currentSnapshot()
        XCTAssertEqual(afterFailure.phase, .recording,
                       "A historical reauthorization failure must not hide active Recording/Stop state")

        let cancelled = StorageRootViewModel(controller: roots,
            directorySelector: IntegrationDirectorySelector(selectedURL: nil))
        await cancelled.restore(); await cancelled.reauthorize(rootID: historical.id)
        XCTAssertEqual(cancelled.state, .available(active, refreshedBookmark: false))
        XCTAssertNil(cancelled.historicalReauthorizationErrors[historical.id])
        let afterCancellation = await app.currentSnapshot()
        XCTAssertEqual(afterCancellation.phase, .recording)

        let succeeded = StorageRootViewModel(controller: roots,
            directorySelector: IntegrationDirectorySelector(selectedURL: historicalURL))
        await succeeded.restore(); await succeeded.reauthorize(rootID: historical.id)
        XCTAssertEqual(succeeded.state, .available(active, refreshedBookmark: false))
        XCTAssertNil(succeeded.historicalReauthorizationErrors[historical.id])
        let afterSuccess = await app.currentSnapshot()
        XCTAssertEqual(afterSuccess.phase, .recording)

        let stopped = await app.stop()
        guard case let .secured(saved) = stopped else { return XCTFail("Stop must remain usable: \(stopped)") }
        let finalized = await finalization.waitForResult(at: saved.location)
        XCTAssertNil(finalized?.failure)
        try await store.close()
    }
}

private struct IntegrationPermissionCounts: Sendable, Equatable {
    var status: Int
    var request: Int
}

private actor AuthorizedIntegrationPermission: MicrophonePermissionAuthorizing {
    private var value = IntegrationPermissionCounts(status: 0, request: 0)

    func authorizationStatus() async -> MicrophonePermissionStatus {
        value.status += 1
        return .authorized
    }

    func requestAuthorization() async -> MicrophonePermissionStatus {
        value.request += 1
        return .authorized
    }

    func counts() -> IntegrationPermissionCounts { value }
}

private struct IntegrationDriverCounts: Sendable, Equatable {
    var prepare: Int
    var start: Int
    var stop: Int
}

private actor SyntheticIntegrationCaptureDriver: MicrophoneCaptureDriving {
    private let chunkCount: Int
    private let framesPerChunk: Int
    private var generation: UInt64?
    private var chunkCallback: (@Sendable (PCMChunk) -> Void)?
    private var value = IntegrationDriverCounts(prepare: 0, start: 0, stop: 0)

    let endFrequency: Double

    init(chunkCount: Int, framesPerChunk: Int, endFrequency: Double = 440) {
        self.endFrequency = endFrequency
        self.chunkCount = chunkCount
        self.framesPerChunk = framesPerChunk
    }

    func prepare(
        generation: UInt64,
        onChunk: @escaping @Sendable (PCMChunk) -> Void,
        onRuntimeEvent: @escaping @Sendable (CaptureRuntimeEvent) -> Void
    ) async throws -> InputDeviceSnapshot {
        value.prepare += 1
        self.generation = generation
        chunkCallback = onChunk
        return InputDeviceSnapshot(identity: "synthetic-integration", displayName: "Synthetic Integration Input")
    }

    func start() async throws {
        value.start += 1
        guard let generation, let chunkCallback else { throw CaptureError(.engineStartFailed) }
        let format = try PCMFormatDescription(sampleRate: 48_000, channelCount: 1)
        for sequence in 0 ..< chunkCount {
            let sampleOffset = sequence * framesPerChunk
            let samples = (0 ..< framesPerChunk).map { frame -> Float in
                let frequency = sequence < chunkCount / 2 ? 440 : endFrequency
                let phase = Double(sampleOffset + frame) * 2 * Double.pi * frequency / 48_000
                return Float(sin(phase) * 0.2)
            }
            let chunk = try PCMChunk(
                generation: generation,
                sequence: UInt64(sequence),
                format: format,
                frameCount: framesPerChunk,
                sourceSampleTime: Int64(sampleOffset),
                samples: samples
            )
            chunkCallback(chunk)
        }
    }

    func stop() async {
        value.stop += 1
        generation = nil
        chunkCallback = nil
    }

    func counts() -> IntegrationDriverCounts { value }
}

private struct IntegrationBookmarkCounts: Sendable, Equatable {
    var start: Int
    var stop: Int
}

private actor CountingPathBookmarkCodec: SecurityScopedBookmarkCodec {
    private var value = IntegrationBookmarkCounts(start: 0, stop: 0)

    func makeBookmark(for directory: URL) async throws -> Data { Data(directory.path.utf8) }

    func resolve(_ bookmark: Data) async throws -> ResolvedBookmark {
        ResolvedBookmark(
            url: URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self), isDirectory: true),
            isStale: false
        )
    }

    func startAccessing(_ url: URL) async -> Bool {
        value.start += 1
        return true
    }

    func stopAccessing(_ url: URL) async { value.stop += 1 }
    func counts() -> IntegrationBookmarkCounts { value }
}

private struct FixedIntegrationMonotonicClock: MonotonicClock {
    func now() -> TimeInterval { 100 }
}

private final class NoopIntegrationSignalScheduler: InputSignalScheduling, @unchecked Sendable {
    func start(interval: TimeInterval, tick: @escaping @Sendable () -> Void) {}
    func stop() {}
}

@MainActor
private final class IntegrationDirectorySelector: DirectorySelecting {
    private let selectedURL: URL?
    init(selectedURL: URL?) { self.selectedURL = selectedURL }
    func chooseDirectory() -> URL? { selectedURL }
}

private final class RecordingFileIntegrationFixture: @unchecked Sendable {
    let base: URL
    let root: URL
    let applicationSupport: URL
    let bookmarks = CountingPathBookmarkCodec()

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalLectureSTT-T07-Integration-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("selected-root", isDirectory: true)
        applicationSupport = base.appendingPathComponent("application-support", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

private struct IntegrationDecodeEvidence: Sendable {
    let sampleBufferCount: Int
    let decodedBytes: Int
    let durationSeconds: Double
}

private func decodeIntegrationAsset(at url: URL) async throws -> IntegrationDecodeEvidence {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.load(.tracks)
    guard let track = tracks.first(where: { $0.mediaType == .audio }) else {
        throw AudioRecorderError(.writerFinishFailed)
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    )
    output.alwaysCopiesSampleData = true
    guard reader.canAdd(output) else { throw AudioRecorderError(.writerFinishFailed) }
    reader.add(output)
    guard reader.startReading() else { throw AudioRecorderError(.writerFinishFailed) }

    var count = 0
    var bytes = 0
    while let sample = output.copyNextSampleBuffer() {
        count += 1
        bytes += CMSampleBufferGetDataBuffer(sample).map(CMBlockBufferGetDataLength) ?? 0
    }
    guard reader.status == .completed else { throw AudioRecorderError(.writerFinishFailed) }
    let duration = try await asset.load(.duration)
    return IntegrationDecodeEvidence(
        sampleBufferCount: count,
        decodedBytes: bytes,
        durationSeconds: CMTimeGetSeconds(duration)
    )
}

private func decodeIntegrationEvents(at url: URL) throws -> [SessionEventRecord] {
    let data = try Data(contentsOf: url)
    return try data.split(separator: 0x0A).map { line in
        try JSONDecoder().decode(SessionEventRecord.self, from: Data(line))
    }
}

private func appendSyntheticRecoveryPCM(to recorder: AVFoundationAudioRecorder, generation: UInt64, seconds: Int) async throws {
    let totalFrames = seconds * 48_000
    var offset = 0
    var sequence: UInt64 = 0
    while offset < totalFrames {
        let frames = min(2_048, totalFrames - offset)
        var samples = [Float]()
        samples.reserveCapacity(frames)
        for frame in 0..<frames {
            let frequency = offset + frame < totalFrames / 2 ? 440.0 : 1_320.0
            let phase = Double(offset + frame) * 2 * Double.pi * frequency / 48_000
            samples.append(Float(sin(phase) * 0.2))
        }
        try await recorder.append(PCMChunk(generation: generation, sequence: sequence,
            format: try PCMFormatDescription(sampleRate: 48_000, channelCount: 1), frameCount: frames,
            sourceSampleTime: Int64(offset), samples: samples))
        offset += frames
        sequence += 1
    }
}

private func readableActiveSnapshot(at url: URL, recorder: AVFoundationAudioRecorder) async throws -> Data {
    // AVFoundation's writer flush is asynchronous.  This bounded polling is
    // intentionally media readiness polling (not a race-test sleep); the
    // assertion below proves the copy was made while the writer was recording.
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: url.path) {
            let bytes = try Data(contentsOf: url)
            if topLevelBoxCount(bytes, named: "moof") >= 2,
               let report = try? await AVFoundationFinalizationMedia().inspect(url, requiresM4A: false, control: .init()),
               report.durationSeconds > 10 {
                return bytes
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("active fragmented MOV never reached a readable multi-moof prefix")
    throw AudioRecorderError(.flushFailed)
}

private func topLevelBoxCount(_ data: Data, named name: String) -> Int {
    guard name.utf8.count == 4 else { return 0 }
    let target = Array(name.utf8)
    var cursor = 0
    var count = 0
    while cursor + 8 <= data.count {
        let size = data[cursor..<(cursor + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        if Array(data[(cursor + 4)..<(cursor + 8)]) == target { count += 1 }
        let length: UInt64
        if size == 1, cursor + 16 <= data.count {
            length = data[(cursor + 8)..<(cursor + 16)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        } else if size == 0 {
            break
        } else { length = size }
        guard length >= 8, length <= UInt64(data.count - cursor) else { break }
        cursor += Int(length)
    }
    return count
}

private actor AppFinalizationGate {
    private var entered = false
    private var openState = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func blockOnce() async {
        guard !entered else { return }
        entered = true
        for waiter in entryWaiters { waiter.resume() }; entryWaiters.removeAll()
        if !openState { await withCheckedContinuation { blocked = $0 } }
    }
    func waitEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func open() { openState = true; blocked?.resume(); blocked = nil }
}

extension RecordingSessionFileIntegrationTests {
    func testT10RequiredTerminalMetadataFaultRetainsDecodableAudioAndDeniesQuit() async throws {
        let fixture = try RecordingFileIntegrationFixture()
        defer { fixture.cleanup() }
        let roots = StorageRootManager(applicationSupportDirectory: fixture.applicationSupport, bookmarkCodec: fixture.bookmarks)
        let root = try await roots.registerSelectedDirectory(fixture.root)
        let fault = TerminalMetadataFault()
        let repository = FileSessionRepository(roots: roots, atomicWriter: AtomicFileWriter(fault: { try fault.check($0) }))
        let permission = AuthorizedIntegrationPermission()
        let capture = MicrophoneCaptureController(permission: permission,
            driver: SyntheticIntegrationCaptureDriver(chunkCount: 48, framesPerChunk: 2048),
            buffers: CaptureBufferConfiguration(recordingCapacity: 64, speechCapacity: 4),
            monitor: InputSignalMonitor(clock: FixedIntegrationMonotonicClock(), scheduler: NoopIntegrationSignalScheduler()))
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: fixture.applicationSupport)
        let catalog = SessionCatalogReconciler(scanner: SessionFileScanner(roots: roots), store: store)
        let recording = RecordingSessionCoordinator(roots: roots, permission: permission, capture: capture,
            recorders: ClosureAudioRecorderFactory { AVFoundationAudioRecorder(roots: roots) }, repository: repository,
            catalog: catalog, environment: .init(appVersion: "T10-fault", osVersion: "synthetic"))
        let started = try await recording.start(.init(title: "durability fault", timeZone: .gmt))
        fault.arm() // target terminal metadata explicitly, independent of start write ordinals
        let finalization = AudioFinalizationCoordinator(worker: FileAudioFinalizer(roots: roots, catalog: catalog))
        let recovery = SessionRecoveryCoordinator(scanner: SessionFileScanner(roots: roots), persistence: repository,
            finalization: finalization, catalog: catalog)
        let lifecycle = AppLifecycleCoordinator(recording: recording, finalization: finalization, recovery: recovery,
            activity: FileIntegrationActivity(), termination: FileIntegrationTermination())
        let allowed = await lifecycle.resolveTermination(.essentialSaveAndQuit)
        XCTAssertFalse(allowed); XCTAssertEqual(fault.deliveries(), 1)
        let evidence = await recording.essentialSaveEvidence()
        XCTAssertEqual(evidence?.firstFailure, .persistence(.atomicRenameFailed))
        XCTAssertEqual(evidence?.cleanupSettled, true); XCTAssertEqual(evidence?.requiresUserAttention, true)
        let directory = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: fixture.root,
            includingPropertiesForKeys: [.isDirectoryKey]).first(where: { $0.hasDirectoryPath }))
        let location = SessionLocation(rootID: root.id, sessionID: try XCTUnwrap(started.sessionID),
            folderName: try SessionFolderName(validating: directory.lastPathComponent))
        let metadata = try await repository.readMetadata(at: location)
        XCTAssertEqual(metadata.sessionId, started.sessionID)
        XCTAssertEqual(metadata.status, .recording)
        let decoded = try await decodeIntegrationAsset(at: directory.appendingPathComponent(SessionArtifact.recoveryAudio.relativePath))
        XCTAssertGreaterThan(decoded.decodedBytes, 0); XCTAssertGreaterThan(decoded.sampleBufferCount, 0)
        let events = try decodeIntegrationEvents(at: directory.appendingPathComponent(SessionArtifact.events.relativePath))
        XCTAssertEqual(events.filter { $0.kind == .recordingEnded }.count, 1)
        XCTAssertTrue(events.allSatisfy { $0.sessionId == started.sessionID })
        for artifact in [SessionArtifact.finalAudio, .transcript, .transcriptText, .transcriptMarkdown] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(artifact.relativePath).path))
        }
        let scopes = await fixture.bookmarks.counts()
        XCTAssertEqual(scopes.start, scopes.stop)
        try await store.close()
    }
}

private final class TerminalMetadataFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false, count = 0
    func arm() { lock.withLock { armed = true } }
    func deliveries() -> Int { lock.withLock { count } }
    func check(_ point: AtomicWriteStep) throws {
        try lock.withLock {
            if armed && point == .beforeRename { armed = false; count += 1; throw StorageError(.atomicRenameFailed) }
        }
    }
}
private actor FileIntegrationActivity: LifecycleActivityControlling {
    func setRelevantWorkActive(_ active: Bool) {}
}
private actor FileIntegrationTermination: LifecycleTerminationRequesting {
    func requestAutomaticTermination(isStillValid: @escaping @Sendable () async -> Bool) -> Bool { false }
}
