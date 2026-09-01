@preconcurrency import AVFoundation
@preconcurrency import AudioToolbox
@preconcurrency import CoreMedia
import Foundation
import XCTest
@testable import LocalLectureSTT

final class AudioRecorderContractAndFaultTests: XCTestCase {
    func testApplicationRecorderContractRemainsFrameworkIndependentAndConstructionHasNoSideEffects() async throws {
        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(AudioRecorderState.idle)
        requireSendable(AudioRecorderOutputFormat.recoveryAAC)
        requireSendable(AudioRecorderError(.writerAppendFailed))
        requireSendable(AudioRecorderEvent.terminalFailure(
            kind: .fileWriteError,
            code: .writerAppendFailed,
            mediaPositionMilliseconds: 0
        ))

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contract = try String(
            contentsOf: repositoryRoot.appendingPathComponent("LocalLectureSTT/Application/AudioRecorder.swift"),
            encoding: .utf8
        )
        for forbidden in ["AVFoundation", "AVFAudio", "AudioToolbox", "CoreMedia", "URL", "NSError"] {
            XCTAssertFalse(contract.contains(forbidden), "Application recorder contract leaked \(forbidden)")
        }

        let fixture = try FakeRecorderFixture()
        defer { fixture.cleanup() }
        let recorder: any AudioRecorder = fixture.makeRecorder()
        let initialState = await recorder.currentState()
        XCTAssertEqual(initialState, .idle)
        XCTAssertEqual(fixture.leases.acquireCount(), 0)
        XCTAssertEqual(fixture.writers.makeCount(), 0)
    }

    func testWriterCreateConfigureStartAndSessionFaultsPreserveFirstErrorEventScopeAndPartialFile() async throws {
        let cases: [(WriterFault, AudioRecorderErrorCode)] = [
            (.create(.writerCreationFailed), .writerCreationFailed),
            (.configure(.writerConfigurationFailed), .writerConfigurationFailed),
            (.start(.writerStartFailed), .writerStartFailed),
            (.session(.writerSessionStartFailed), .writerSessionStartFailed)
        ]

        for (fault, expectedCode) in cases {
            let fixture = try FakeRecorderFixture(writerFault: fault)
            defer { fixture.cleanup() }
            let recorder = fixture.makeRecorder()
            let stream = await recorder.events()

            let thrown = await recorderErrorCode {
                try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 11)
            }
            XCTAssertEqual(thrown, expectedCode)
            let failedState = await recorder.currentState()
            XCTAssertEqual(failedState, .failed(expectedCode))
            XCTAssertEqual(fixture.leases.acquireCount(), 1)
            XCTAssertEqual(fixture.leases.allLeases().first?.releaseCount(), 1)
            XCTAssertEqual(try Data(contentsOf: fixture.leases.allLeases()[0].outputURL), Data("partial-recovery".utf8))

            let event = await nextEvent(in: stream)
            XCTAssertEqual(event, .terminalFailure(
                kind: .fileWriteError,
                code: expectedCode,
                mediaPositionMilliseconds: 0
            ))
            let stopCode = await recorderErrorCode { try await recorder.stop() }
            XCTAssertEqual(stopCode, expectedCode)

            if let backend = fixture.writers.allBackends().first {
                let counts = await backend.counts()
                XCTAssertEqual(counts.markFinished, 1)
                XCTAssertEqual(counts.finish, 1)
            }
        }
    }

    func testStorageFaultsMapToTypedStorageEventsWithoutOpeningWriter() async throws {
        let cases: [(StorageErrorCode, AudioRecorderErrorCode)] = [
            (.noActiveRoot, .storageRootUnavailable),
            (.reauthorizationRequired, .storageReauthorizationRequired),
            (.rootMissing, .storageRootMissing),
            (.rootNotWritable, .storageRootNotWritable),
            (.registryCorrupt, .storageAccess)
        ]

        for (storageCode, recorderCode) in cases {
            let fixture = try FakeRecorderFixture(storageError: StorageError(storageCode))
            defer { fixture.cleanup() }
            let recorder = fixture.makeRecorder()
            let code = await recorderErrorCode {
                try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 1)
            }
            XCTAssertEqual(code, recorderCode)
            XCTAssertEqual(fixture.writers.makeCount(), 0)
            let stream = await recorder.events()
            let event = await nextEvent(in: stream)
            XCTAssertEqual(event, .terminalFailure(
                kind: .storageAccessError,
                code: recorderCode,
                mediaPositionMilliseconds: 0
            ))
        }
    }

    func testConverterCreationConversionReadinessSampleAppendAndDiskFullFaultsShareTerminalPolicy() async throws {
        let directDiskFull = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let nestedDiskFull = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileWriteUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: directDiskFull]
        )
        XCTAssertEqual(
            AVAssetWriterBackend.mapWriterError(directDiskFull, fallback: .writerAppendFailed),
            .diskFull
        )
        XCTAssertEqual(
            AVAssetWriterBackend.mapWriterError(nestedDiskFull, fallback: .writerAppendFailed),
            .diskFull
        )
        XCTAssertEqual(
            AVAssetWriterBackend.mapWriterError(nil, fallback: .writerAppendFailed),
            .writerAppendFailed
        )

        let writerCases: [(WriterFault, AudioRecorderErrorCode)] = [
            (.append(at: 1, code: .writerReadinessFailed), .writerReadinessFailed),
            (.append(at: 1, code: .sampleBufferCreationFailed), .sampleBufferCreationFailed),
            (.append(at: 1, code: .writerAppendFailed), .writerAppendFailed),
            (.append(at: 1, code: .diskFull), .diskFull)
        ]

        for (fault, expectedCode) in writerCases {
            let fixture = try FakeRecorderFixture(writerFault: fault)
            defer { fixture.cleanup() }
            let recorder = fixture.makeRecorder()
            try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 4)
            let code = await recorderErrorCode {
                try await recorder.append(try fixture.chunk(generation: 4, sequence: 0))
            }
            try await assertTerminalRecorder(
                recorder,
                fixture: fixture,
                expectedCode: expectedCode,
                expectedKind: .fileWriteError
            )
            XCTAssertEqual(code, expectedCode)
        }

        for expectedCode in [AudioRecorderErrorCode.inputFormatUnsupported, .conversionFailed] {
            let converterFactory: FakePCMConverterFactory
            if expectedCode == .inputFormatUnsupported {
                converterFactory = FakePCMConverterFactory(creationError: AudioRecorderError(expectedCode))
            } else {
                converterFactory = FakePCMConverterFactory {
                    FakePCMConverter(convertError: AudioRecorderError(expectedCode))
                }
            }
            let fixture = try FakeRecorderFixture(converterFactory: converterFactory)
            defer { fixture.cleanup() }
            let recorder = fixture.makeRecorder()
            try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 8)
            let code = await recorderErrorCode {
                try await recorder.append(try fixture.chunk(generation: 8, sequence: 0))
            }
            XCTAssertEqual(code, expectedCode)
            try await assertTerminalRecorder(
                recorder,
                fixture: fixture,
                expectedCode: expectedCode,
                expectedKind: .fileWriteError
            )
        }
    }

    func testFlushFinishAndZeroSampleStopNeverReturnFalseSuccessAndCleanExactlyOnce() async throws {
        do {
            let fixture = try FakeRecorderFixture(writerFault: .flush(.flushFailed))
            defer { fixture.cleanup() }
            let recorder = fixture.makeRecorder()
            try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 1)
            try await recorder.append(try fixture.chunk(generation: 1, sequence: 0))
            let flushCode = await recorderErrorCode { try await recorder.flush() }
            XCTAssertEqual(flushCode, .flushFailed)
            try await assertTerminalRecorder(
                recorder,
                fixture: fixture,
                expectedCode: .flushFailed,
                expectedMediaPositionMilliseconds: 1
            )
        }

        do {
            let fixture = try FakeRecorderFixture(writerFault: .finish(.writerFinishFailed))
            defer { fixture.cleanup() }
            let recorder = fixture.makeRecorder()
            try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 1)
            try await recorder.append(try fixture.chunk(generation: 1, sequence: 0))
            let finishCode = await recorderErrorCode { try await recorder.stop() }
            XCTAssertEqual(finishCode, .writerFinishFailed)
            try await assertTerminalRecorder(
                recorder,
                fixture: fixture,
                expectedCode: .writerFinishFailed,
                expectedMediaPositionMilliseconds: 1
            )
        }

        do {
            let fixture = try FakeRecorderFixture()
            defer { fixture.cleanup() }
            let recorder = fixture.makeRecorder()
            try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 1)
            let noSamplesCode = await recorderErrorCode { try await recorder.stop() }
            XCTAssertEqual(noSamplesCode, .noAudioSamples)
            try await assertTerminalRecorder(recorder, fixture: fixture, expectedCode: .noAudioSamples)
        }
    }

    func testStartCancellationAndConverterDrainFailureUseTheSameTerminalPolicy() async throws {
        do {
            let startGate = AsyncTestGate()
            let fixture = try FakeRecorderFixture(startGate: startGate)
            defer { fixture.cleanup() }
            let recorder = fixture.makeRecorder()
            let location = fixture.location()
            let startTask = Task { () -> AudioRecorderErrorCode? in
                do {
                    try await recorder.start(at: location, expectedCaptureGeneration: 4)
                    return nil
                } catch let error as AudioRecorderError {
                    return error.code
                } catch {
                    return .invalidLifecycle
                }
            }
            await startGate.waitUntilEntered()
            startTask.cancel()
            await startGate.open()
            let startCode = await startTask.value
            XCTAssertEqual(startCode, .cancelled)
            try await assertTerminalRecorder(recorder, fixture: fixture, expectedCode: .cancelled)
        }

        do {
            let converter = FakePCMConverter(drainError: AudioRecorderError(.conversionFailed))
            let fixture = try FakeRecorderFixture(
                converterFactory: FakePCMConverterFactory { converter }
            )
            defer { fixture.cleanup() }
            let recorder = fixture.makeRecorder()
            try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 5)
            try await recorder.append(try fixture.chunk(generation: 5, sequence: 0))
            let stopCode = await recorderErrorCode { try await recorder.stop() }
            XCTAssertEqual(stopCode, .conversionFailed)
            try await assertTerminalRecorder(
                recorder,
                fixture: fixture,
                expectedCode: .conversionFailed,
                expectedMediaPositionMilliseconds: 1
            )
            let drainCount = await converter.drainCount()
            XCTAssertEqual(drainCount, 1)
        }
    }

    func testCleanupFailureNeverOverwritesTheFirstAppendFailure() async throws {
        let fixture = try FakeRecorderFixture(
            writerFault: .append(at: 1, code: .writerAppendFailed),
            cleanupFinishError: .writerFinishFailed
        )
        defer { fixture.cleanup() }
        let recorder = fixture.makeRecorder()
        try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 9)
        let appendCode = await recorderErrorCode {
            try await recorder.append(try fixture.chunk(generation: 9, sequence: 0))
        }
        XCTAssertEqual(appendCode, .writerAppendFailed)
        try await assertTerminalRecorder(
            recorder,
            fixture: fixture,
            expectedCode: .writerAppendFailed
        )
    }

    private func assertTerminalRecorder(
        _ recorder: AVFoundationAudioRecorder,
        fixture: FakeRecorderFixture,
        expectedCode: AudioRecorderErrorCode,
        expectedKind: SessionEventKind = .fileWriteError,
        expectedMediaPositionMilliseconds: UInt64 = 0
    ) async throws {
        let state = await recorder.currentState()
        XCTAssertEqual(state, .failed(expectedCode))
        let stopCode = await recorderErrorCode { try await recorder.stop() }
        XCTAssertEqual(stopCode, expectedCode)
        XCTAssertEqual(fixture.leases.allLeases().first?.releaseCount(), 1)
        XCTAssertEqual(try Data(contentsOf: fixture.leases.allLeases()[0].outputURL), Data("partial-recovery".utf8))
        if let backend = fixture.writers.allBackends().first {
            let counts = await backend.counts()
            XCTAssertEqual(counts.markFinished, 1)
            XCTAssertEqual(counts.finish, 1)
        }
        let stream = await recorder.events()
        let event = await nextEvent(in: stream)
        XCTAssertEqual(event, .terminalFailure(
            kind: expectedKind,
            code: expectedCode,
            mediaPositionMilliseconds: expectedMediaPositionMilliseconds
        ))
    }
}

final class AudioRecorderLifecycleTests: XCTestCase {
    func testIdleCallsAndAppendQueuedDuringStopReturnStableLifecycleErrors() async throws {
        let finishGate = AsyncTestGate()
        let fixture = try FakeRecorderFixture(finishGate: finishGate)
        defer { fixture.cleanup() }
        let recorder = fixture.makeRecorder()
        let idleChunk = try fixture.chunk(generation: 1, sequence: 0)

        let idleAppendCode = await recorderErrorCode { try await recorder.append(idleChunk) }
        let idleFlushCode = await recorderErrorCode { try await recorder.flush() }
        let idleStopCode = await recorderErrorCode { try await recorder.stop() }
        XCTAssertEqual(idleAppendCode, .invalidLifecycle)
        XCTAssertEqual(idleFlushCode, .invalidLifecycle)
        XCTAssertEqual(idleStopCode, .invalidLifecycle)
        XCTAssertEqual(fixture.leases.acquireCount(), 0)

        try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 1)
        try await recorder.append(idleChunk)
        let queuedChunk = try fixture.chunk(generation: 1, sequence: 1)
        let stopTask = Task { try await recorder.stop() }
        await finishGate.waitUntilEntered()
        let appendTask = Task { await recorderErrorCode { try await recorder.append(queuedChunk) } }
        let stoppingState = await recorder.currentState()
        XCTAssertEqual(stoppingState, .stopping)
        await finishGate.open()

        let summary = try await stopTask.value
        XCTAssertEqual(summary.writtenFrameCount, 48)
        let queuedAppendCode = await appendTask.value
        XCTAssertEqual(queuedAppendCode, .invalidLifecycle)
        let counts = await fixture.writers.allBackends()[0].counts()
        XCTAssertEqual(counts.append, 1)
        XCTAssertEqual(counts.markFinished, 1)
        XCTAssertEqual(counts.finish, 1)
        XCTAssertEqual(fixture.leases.allLeases()[0].releaseCount(), 1)
    }

    func testReadinessCancellationAndFinishCancellationPreserveFileAndCleanExactlyOnce() async throws {
        do {
            let appendGate = AsyncTestGate()
            let fixture = try FakeRecorderFixture(appendGate: appendGate)
            defer { fixture.cleanup() }
            let recorder = fixture.makeRecorder()
            try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 3)
            let chunk = try fixture.chunk(generation: 3, sequence: 0)
            let appendTask = Task { () -> AudioRecorderErrorCode? in
                do {
                    try await recorder.append(chunk)
                    return nil
                } catch let error as AudioRecorderError {
                    return error.code
                } catch {
                    return .invalidLifecycle
                }
            }
            await appendGate.waitUntilEntered()
            appendTask.cancel()
            await appendGate.open()
            let appendCode = await appendTask.value
            XCTAssertEqual(appendCode, .cancelled)
            try await assertExactCleanup(recorder, fixture: fixture, code: .cancelled)
        }

        do {
            let finishGate = AsyncTestGate()
            let fixture = try FakeRecorderFixture(finishGate: finishGate)
            defer { fixture.cleanup() }
            let recorder = fixture.makeRecorder()
            try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 5)
            try await recorder.append(try fixture.chunk(generation: 5, sequence: 0))
            let stopTask = Task { () -> AudioRecorderErrorCode? in
                do {
                    _ = try await recorder.stop()
                    return nil
                } catch let error as AudioRecorderError {
                    return error.code
                } catch {
                    return .invalidLifecycle
                }
            }
            await finishGate.waitUntilEntered()
            stopTask.cancel()
            await finishGate.open()
            let stopCode = await stopTask.value
            XCTAssertEqual(stopCode, .cancelled)
            try await assertExactCleanup(recorder, fixture: fixture, code: .cancelled)
        }
    }

    func testConcurrentStartRepeatedStopAndNormalRestartUseOneOwnedBackendPerRecording() async throws {
        let fixture = try FakeRecorderFixture()
        defer { fixture.cleanup() }
        let recorder = fixture.makeRecorder()
        let firstLocation = fixture.location()

        let first = Task { () -> AudioRecorderErrorCode? in
            do {
                try await recorder.start(at: firstLocation, expectedCaptureGeneration: 1)
                return nil
            } catch let error as AudioRecorderError {
                return error.code
            } catch {
                return .invalidLifecycle
            }
        }
        let second = Task { () -> AudioRecorderErrorCode? in
            do {
                try await recorder.start(at: firstLocation, expectedCaptureGeneration: 1)
                return nil
            } catch let error as AudioRecorderError {
                return error.code
            } catch {
                return .invalidLifecycle
            }
        }
        let startResults = [await first.value, await second.value]
        XCTAssertEqual(startResults.filter { $0 == nil }.count, 1)
        XCTAssertEqual(startResults.filter { $0 == .alreadyStarted }.count, 1)
        XCTAssertEqual(fixture.leases.acquireCount(), 1)
        XCTAssertEqual(fixture.writers.makeCount(), 1)

        try await recorder.append(try fixture.chunk(generation: 1, sequence: 0, frames: 37))
        let summary = try await recorder.stop()
        let repeatedSummary = try await recorder.stop()
        XCTAssertEqual(repeatedSummary, summary)
        XCTAssertEqual(fixture.leases.allLeases()[0].releaseCount(), 1)
        let firstCounts = await fixture.writers.allBackends()[0].counts()
        XCTAssertEqual(firstCounts.finish, 1)

        let secondLocation = fixture.location()
        try await recorder.start(at: secondLocation, expectedCaptureGeneration: 2)
        try await recorder.append(try fixture.chunk(generation: 2, sequence: 0, frames: 29))
        let secondSummary = try await recorder.stop()
        XCTAssertEqual(secondSummary.location, secondLocation)
        XCTAssertEqual(fixture.leases.acquireCount(), 2)
        XCTAssertEqual(fixture.writers.makeCount(), 2)
        XCTAssertEqual(fixture.leases.allLeases()[1].releaseCount(), 1)
        let secondCounts = await fixture.writers.allBackends()[1].counts()
        XCTAssertEqual(secondCounts.finish, 1)
    }

    func testGenerationSequenceGapDuplicateReorderAndFormatChangeAreTerminalWithoutSilentAppend() async throws {
        enum Violation {
            case generation
            case gap
            case duplicate
            case reorder
            case format
        }
        for violation in [Violation.generation, .gap, .duplicate, .reorder, .format] {
            let fixture = try FakeRecorderFixture()
            defer { fixture.cleanup() }
            let recorder = fixture.makeRecorder()
            try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 9)

            let expectedCode: AudioRecorderErrorCode
            switch violation {
            case .generation:
                expectedCode = .inputGenerationMismatch
                let code = await recorderErrorCode {
                    try await recorder.append(try fixture.chunk(generation: 10, sequence: 0))
                }
                XCTAssertEqual(code, expectedCode)
            case .gap:
                expectedCode = .sequenceDiscontinuity
                let code = await recorderErrorCode {
                    try await recorder.append(try fixture.chunk(generation: 9, sequence: 1))
                }
                XCTAssertEqual(code, expectedCode)
            case .duplicate:
                expectedCode = .sequenceDiscontinuity
                try await recorder.append(try fixture.chunk(generation: 9, sequence: 0))
                let code = await recorderErrorCode {
                    try await recorder.append(try fixture.chunk(generation: 9, sequence: 0))
                }
                XCTAssertEqual(code, expectedCode)
            case .reorder:
                expectedCode = .sequenceDiscontinuity
                try await recorder.append(try fixture.chunk(generation: 9, sequence: 0))
                try await recorder.append(try fixture.chunk(generation: 9, sequence: 1))
                let code = await recorderErrorCode {
                    try await recorder.append(try fixture.chunk(generation: 9, sequence: 0))
                }
                XCTAssertEqual(code, expectedCode)
            case .format:
                expectedCode = .inputFormatChanged
                try await recorder.append(try fixture.chunk(generation: 9, sequence: 0))
                let code = await recorderErrorCode {
                    try await recorder.append(try fixture.chunk(
                        generation: 9,
                        sequence: 1,
                        sampleRate: 44_100,
                        channels: 2
                    ))
                }
                XCTAssertEqual(code, expectedCode)
            }
            let failedState = await recorder.currentState()
            XCTAssertEqual(failedState, .failed(expectedCode))
            XCTAssertEqual(fixture.leases.allLeases()[0].releaseCount(), 1)
        }
    }

    func testIrregularChunksHaveContiguousPTSAndConverterTailIsDrainedOnceWithoutSTTConsumer() async throws {
        let converter = FakePCMConverter(tail: [0.25, -0.25])
        let fixture = try FakeRecorderFixture(
            converterFactory: FakePCMConverterFactory { converter }
        )
        defer { fixture.cleanup() }
        let recorder = fixture.makeRecorder()
        try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 12)
        for (sequence, frames) in [3, 5, 2].enumerated() {
            try await recorder.append(try fixture.chunk(
                generation: 12,
                sequence: UInt64(sequence),
                frames: frames
            ))
        }
        try await recorder.flush()
        let summary = try await recorder.stop()
        XCTAssertEqual(summary.writtenFrameCount, 12)
        let repeatedSummary = try await recorder.stop()
        XCTAssertEqual(repeatedSummary, summary)
        let drainCount = await converter.drainCount()
        XCTAssertEqual(drainCount, 1)
        let maximumInputFrames = await converter.maxInputFrames()
        XCTAssertEqual(maximumInputFrames, 5)

        let backend = try XCTUnwrap(fixture.writers.allBackends().first)
        let appends = await backend.appendRecords()
        XCTAssertEqual(appends.map(\.presentationFrame), [0, 3, 8, 10])
        XCTAssertEqual(appends.map(\.sampleCount), [3, 5, 2, 2])
        let counts = await backend.counts()
        XCTAssertEqual(counts.flush, 1)
        XCTAssertEqual(counts.markFinished, 1)
        XCTAssertEqual(counts.finish, 1)
        XCTAssertEqual(fixture.leases.allLeases()[0].releaseCount(), 1)
    }

    func testManyChunksKeepConversionHighWaterBoundedByOneInputChunk() async throws {
        let converter = FakePCMConverter()
        let fixture = try FakeRecorderFixture(
            converterFactory: FakePCMConverterFactory { converter }
        )
        defer { fixture.cleanup() }
        let recorder = fixture.makeRecorder()
        try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 13)

        var expectedFrames: UInt64 = 0
        for sequence in 0..<512 {
            let frames = (sequence % 7) + 1
            try await recorder.append(try fixture.chunk(
                generation: 13,
                sequence: UInt64(sequence),
                frames: frames
            ))
            expectedFrames += UInt64(frames)
        }

        let summary = try await recorder.stop()
        XCTAssertEqual(summary.writtenFrameCount, expectedFrames)
        let maximumInputFrames = await converter.maxInputFrames()
        XCTAssertEqual(maximumInputFrames, 7)
        let appendCount = await fixture.writers.allBackends()[0].counts().append
        XCTAssertEqual(appendCount, 512)
    }

    func testStopDrainsTailWhenAcceptedInputHasNotYetProducedBodyFrames() async throws {
        let converter = FakePCMConverter(convertedSamples: [], tail: [0.2, -0.2, 0.1])
        let fixture = try FakeRecorderFixture(
            converterFactory: FakePCMConverterFactory { converter }
        )
        defer { fixture.cleanup() }
        let recorder = fixture.makeRecorder()
        try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 14)
        try await recorder.append(try fixture.chunk(generation: 14, sequence: 0, frames: 1))

        let summary = try await recorder.stop()
        XCTAssertEqual(summary.writtenFrameCount, 3)
        let records = await fixture.writers.allBackends()[0].appendRecords()
        XCTAssertEqual(records, [FakeAppendRecord(presentationFrame: 0, sampleCount: 3)])
        let drainCount = await converter.drainCount()
        XCTAssertEqual(drainCount, 1)
    }

    func testAppendStopFailureRaceReturnsSameCauseAndNoDoubleCleanupOrEvent() async throws {
        let appendGate = AsyncTestGate()
        let fixture = try FakeRecorderFixture(
            writerFault: .append(at: 1, code: .writerAppendFailed),
            appendGate: appendGate
        )
        defer { fixture.cleanup() }
        let recorder = fixture.makeRecorder()
        let eventStream = await recorder.events()
        try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 6)
        let chunk = try fixture.chunk(generation: 6, sequence: 0)

        let appendTask = Task { await recorderErrorCode {
            try await recorder.append(chunk)
        } }
        await appendGate.waitUntilEntered()
        let stopTask = Task { await recorderErrorCode { try await recorder.stop() } }
        await appendGate.open()
        let appendCode = await appendTask.value
        let stopCode = await stopTask.value
        XCTAssertEqual(appendCode, .writerAppendFailed)
        XCTAssertEqual(stopCode, .writerAppendFailed)

        let backend = fixture.writers.allBackends()[0]
        let counts = await backend.counts()
        XCTAssertEqual(counts.markFinished, 1)
        XCTAssertEqual(counts.finish, 1)
        XCTAssertEqual(fixture.leases.allLeases()[0].releaseCount(), 1)
        let event = await nextEvent(in: eventStream)
        XCTAssertEqual(event, .terminalFailure(
            kind: .fileWriteError,
            code: .writerAppendFailed,
            mediaPositionMilliseconds: 0
        ))
        let duplicateEvent = await nextEvent(in: eventStream, timeout: .milliseconds(40))
        XCTAssertNil(duplicateEvent)
    }

    func testRestartWaitsForCleanupAndPriorOperationCannotMutateNewRecording() async throws {
        let releaseGate = AsyncTestGate()
        let fixture = try FakeRecorderFixture(
            writerFault: .append(at: 1, code: .writerAppendFailed),
            releaseGates: [releaseGate, nil]
        )
        defer { fixture.cleanup() }
        let recorder = fixture.makeRecorder()
        try await recorder.start(at: fixture.location(), expectedCaptureGeneration: 1)
        let chunk = try fixture.chunk(generation: 1, sequence: 0)

        let failureTask = Task { await recorderErrorCode {
            try await recorder.append(chunk)
        } }
        await releaseGate.waitUntilEntered()
        let cleanupState = await recorder.currentState()
        XCTAssertEqual(cleanupState, .stopping)

        let newLocation = fixture.location()
        let restartTask = Task {
            try await recorder.start(at: newLocation, expectedCaptureGeneration: 2)
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.writers.makeCount(), 1)
        XCTAssertEqual(fixture.leases.acquireCount(), 1)

        await releaseGate.open()
        let failureCode = await failureTask.value
        XCTAssertEqual(failureCode, .writerAppendFailed)
        try await restartTask.value
        let restartedState = await recorder.currentState()
        XCTAssertEqual(restartedState, .recording)
        XCTAssertEqual(fixture.writers.makeCount(), 2)
        XCTAssertEqual(fixture.leases.acquireCount(), 2)
        XCTAssertEqual(fixture.leases.allLeases()[0].releaseCount(), 1)
        let noSamplesCode = await recorderErrorCode { try await recorder.stop() }
        XCTAssertEqual(noSamplesCode, .noAudioSamples)
    }

    private func assertExactCleanup(
        _ recorder: AVFoundationAudioRecorder,
        fixture: FakeRecorderFixture,
        code: AudioRecorderErrorCode
    ) async throws {
        let state = await recorder.currentState()
        XCTAssertEqual(state, .failed(code))
        XCTAssertEqual(fixture.leases.allLeases()[0].releaseCount(), 1)
        let backend = fixture.writers.allBackends()[0]
        let counts = await backend.counts()
        XCTAssertEqual(counts.markFinished, 1)
        XCTAssertEqual(counts.finish, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.leases.allLeases()[0].outputURL), Data("partial-recovery".utf8))
    }
}

final class AudioRecorderStorageAndConversionTests: XCTestCase {
    func testActualStoragePathUsesLocationRootRejectsSymlinkAndPreservesExistingBytes() async throws {
        do {
            let fixture = try ActualRecorderFixture()
            defer { fixture.cleanup() }
            let manager = fixture.manager()
            _ = try await manager.registerSelectedDirectory(fixture.rootA)
            let location = try await fixture.location(using: manager)
            let output = fixture.recoveryURL(for: location, root: fixture.rootA)
            let original = Data("never-overwrite".utf8)
            try original.write(to: output)
            let recorder = AVFoundationAudioRecorder(roots: manager)
            let collisionCode = await recorderErrorCode {
                try await recorder.start(at: location, expectedCaptureGeneration: 1)
            }
            XCTAssertEqual(collisionCode, .recoveryArtifactExists)
            XCTAssertEqual(try Data(contentsOf: output), original)
            let stream = await recorder.events()
            let event = await nextEvent(in: stream)
            XCTAssertEqual(event, .terminalFailure(
                kind: .storageAccessError,
                code: .recoveryArtifactExists,
                mediaPositionMilliseconds: 0
            ))
            let starts = await fixture.codec.startCount()
            let stops = await fixture.codec.stopCount()
            XCTAssertEqual(starts, stops)
        }

        do {
            let fixture = try ActualRecorderFixture()
            defer { fixture.cleanup() }
            let manager = fixture.manager()
            _ = try await manager.registerSelectedDirectory(fixture.rootA)
            let location = try await fixture.location(using: manager)
            let output = fixture.recoveryURL(for: location, root: fixture.rootA)
            let escapedOutput = fixture.outside.appendingPathComponent("escaped.mov")
            try FileManager.default.createSymbolicLink(
                at: output,
                withDestinationURL: escapedOutput
            )
            let recorder = AVFoundationAudioRecorder(roots: manager)
            let layoutCode = await recorderErrorCode {
                try await recorder.start(at: location, expectedCaptureGeneration: 1)
            }
            XCTAssertEqual(layoutCode, .unsafeSessionLayout)
            XCTAssertFalse(FileManager.default.fileExists(atPath: escapedOutput.path))
            XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: output.path))
            let starts = await fixture.codec.startCount()
            let stops = await fixture.codec.stopCount()
            XCTAssertEqual(starts, stops)
        }

        do {
            let fixture = try ActualRecorderFixture()
            defer { fixture.cleanup() }
            let manager = fixture.manager()
            _ = try await manager.registerSelectedDirectory(fixture.rootA)
            let location = try await fixture.location(using: manager)
            let recoveryDirectory = fixture.rootA
                .appendingPathComponent(location.folderName.rawValue)
                .appendingPathComponent("recovery")
            try FileManager.default.removeItem(at: recoveryDirectory)
            try FileManager.default.createSymbolicLink(
                at: recoveryDirectory,
                withDestinationURL: fixture.outside
            )
            let recorder = AVFoundationAudioRecorder(roots: manager)
            let layoutCode = await recorderErrorCode {
                try await recorder.start(at: location, expectedCaptureGeneration: 1)
            }
            XCTAssertEqual(layoutCode, .unsafeSessionLayout)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.outside.path), [])
            let starts = await fixture.codec.startCount()
            let stops = await fixture.codec.stopCount()
            XCTAssertEqual(starts, stops)
        }

        do {
            let fixture = try ActualRecorderFixture()
            defer { fixture.cleanup() }
            let manager = fixture.manager()
            _ = try await manager.registerSelectedDirectory(fixture.rootA)
            let locationA = try await fixture.location(using: manager)
            _ = try await manager.registerSelectedDirectory(fixture.rootB)
            let recorder = AVFoundationAudioRecorder(roots: manager)
            try await recorder.start(at: locationA, expectedCaptureGeneration: 1)
            let outputA = fixture.recoveryURL(for: locationA, root: fixture.rootA)
            let redirected = fixture.recoveryURL(for: locationA, root: fixture.rootB)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputA.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: redirected.path))
            let noSamplesCode = await recorderErrorCode { try await recorder.stop() }
            XCTAssertEqual(noSamplesCode, .noAudioSamples)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputA.path))
            let starts = await fixture.codec.startCount()
            let stops = await fixture.codec.stopCount()
            XCTAssertEqual(starts, stops)
        }
    }

    func testProductionConverterHandles441Mono48StereoOtherRateIrregularChunksAndMeaningfulDownmix() async throws {
        let formatCases: [(Double, Int)] = [(44_100, 1), (48_000, 2), (32_000, 1)]
        for (sampleRate, channels) in formatCases {
            let format = try PCMFormatDescription(sampleRate: sampleRate, channelCount: channels)
            let converter = try AVAudioPCMConverter(source: format)
            let totalFrames = Int(sampleRate)
            let pattern = [997, 2_301, 4_096, 811]
            var sourceFrame = 0
            var sequence: UInt64 = 0
            var outputCount = 0
            while sourceFrame < totalFrames {
                let frames = min(pattern[Int(sequence) % pattern.count], totalFrames - sourceFrame)
                let chunk = try syntheticChunk(
                    generation: 1,
                    sequence: sequence,
                    sampleRate: sampleRate,
                    channels: channels,
                    sourceFrame: sourceFrame,
                    frames: frames
                )
                outputCount += try await converter.convert(chunk).count
                sourceFrame += frames
                sequence += 1
            }
            outputCount += try await converter.drain().count
            XCTAssertEqual(outputCount, 48_000, accuracy: 96)
            let repeatedTail = try await converter.drain()
            XCTAssertTrue(repeatedTail.isEmpty)
        }

        let leftOnly = try await convertedStereoRMS(leftAmplitude: 0.3, rightAmplitude: 0)
        let rightOnly = try await convertedStereoRMS(leftAmplitude: 0, rightAmplitude: 0.3)
        let both = try await convertedStereoRMS(leftAmplitude: 0.3, rightAmplitude: 0.15)
        XCTAssertGreaterThan(leftOnly, 0.02)
        XCTAssertGreaterThan(rightOnly, 0.02)
        XCTAssertGreaterThan(both, 0.02)
    }

    private func convertedStereoRMS(leftAmplitude: Double, rightAmplitude: Double) async throws -> Double {
        let format = try PCMFormatDescription(sampleRate: 48_000, channelCount: 2)
        let converter = try AVAudioPCMConverter(source: format)
        var samples = [Float](repeating: 0, count: 4_800 * 2)
        for frame in 0..<4_800 {
            samples[frame * 2] = Float(sin(Double(frame) * 0.071) * leftAmplitude)
            samples[frame * 2 + 1] = Float(sin(Double(frame) * 0.043 + 0.7) * rightAmplitude)
        }
        let chunk = try PCMChunk(
            generation: 1,
            sequence: 0,
            format: format,
            frameCount: 4_800,
            sourceSampleTime: 0,
            samples: samples
        )
        let body = try await converter.convert(chunk)
        let tail = try await converter.drain()
        let converted = body + tail
        guard !converted.isEmpty else { return 0 }
        let meanSquare = converted.reduce(0.0) { $0 + Double($1 * $1) } / Double(converted.count)
        return sqrt(meanSquare)
    }
}

final class AudioRecorderFragmentedMOVIntegrationTests: XCTestCase {
    func testTwentyTwoSecondFragmentedMOVHasConfiguredIntervalsReadableActivePrefixAndDecodedEnds() async throws {
        let fixture = try ActualRecorderFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager()
        _ = try await manager.registerSelectedDirectory(fixture.rootA)
        let location = try await fixture.location(using: manager)
        let spyFactory = SpyAVAssetWriterFactory()
        let recorder = AVFoundationAudioRecorder(
            outputLeases: StorageRecoveryAudioOutputLeaseProvider(roots: manager),
            writerFactory: spyFactory,
            converterFactory: AVAudioPCMConverterFactory()
        )
        let output = fixture.recoveryURL(for: location, root: fixture.rootA)

        do {
            try await recorder.start(at: location, expectedCaptureGeneration: 77)
            let totalInputFrames = 44_100 * 22
            let pattern = [997, 2_301, 4_096, 811]
            var sourceFrame = 0
            var sequence: UInt64 = 0
            while sourceFrame < totalInputFrames {
                let frames = min(pattern[Int(sequence) % pattern.count], totalInputFrames - sourceFrame)
                try await recorder.append(try syntheticChunk(
                    generation: 77,
                    sequence: sequence,
                    sampleRate: 44_100,
                    channels: 2,
                    sourceFrame: sourceFrame,
                    frames: frames
                ))
                sourceFrame += frames
                sequence += 1
            }
            try await recorder.flush()

            let activeEvidence = try await waitForReadableActivePrefix(
                at: output,
                snapshotsDirectory: fixture.base
            )
            let activeState = await recorder.currentState()
            XCTAssertEqual(activeState, .recording)
            XCTAssertGreaterThanOrEqual(activeEvidence.moofCount, 2)
            XCTAssertGreaterThan(activeEvidence.decode.sampleBufferCount, 0)
            XCTAssertGreaterThan(activeEvidence.decode.totalDataBytes, 0)
            XCTAssertGreaterThan(activeEvidence.decode.durationSeconds, 10)

            let summary = try await recorder.stop()
            XCTAssertEqual(summary.artifact, .recoveryAudio)
            XCTAssertEqual(summary.outputFormat, .recoveryAAC)
            XCTAssertEqual(Double(summary.mediaDurationMilliseconds) / 1_000, 22, accuracy: 0.15)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootA
                .appendingPathComponent(location.folderName.rawValue)
                .appendingPathComponent("audio.m4a").path))

            XCTAssertEqual(spyFactory.configurations(), [.production])
            let completedData = try Data(contentsOf: output)
            let completedMoofCount = completedData.topLevelBoxCount(named: "moof")

            let asset = AVURLAsset(url: output)
            let tracks = try await asset.load(.tracks)
            let audioTracks = tracks.filter { $0.mediaType == .audio }
            XCTAssertEqual(audioTracks.count, 1)
            XCTAssertEqual(tracks.filter { $0.mediaType == .video }.count, 0)
            let descriptions = try await audioTracks[0].load(.formatDescriptions)
            let description = try XCTUnwrap(descriptions.first)
            let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
            XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC)
            XCTAssertEqual(asbd.mSampleRate, 48_000, accuracy: 0.1)
            XCTAssertEqual(asbd.mChannelsPerFrame, 1)
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            XCTAssertEqual(duration, 22, accuracy: 0.15)

            let completedDecode = try await decodeAsset(at: output)
            XCTAssertGreaterThan(completedDecode.sampleBufferCount, 1)
            XCTAssertGreaterThan(completedDecode.firstDataBytes, 0)
            XCTAssertGreaterThan(completedDecode.lastDataBytes, 0)
            XCTAssertGreaterThan(completedDecode.totalDataBytes, 0)
            XCTAssertEqual(completedDecode.durationSeconds, 22, accuracy: 0.15)
            print(
                "T06_MOV_EVIDENCE activeMoof=\(activeEvidence.moofCount) " +
                "activeSamples=\(activeEvidence.decode.sampleBufferCount) " +
                "activeDuration=\(activeEvidence.decode.durationSeconds) " +
                "completedMoof=\(completedMoofCount) " +
                "completedSamples=\(completedDecode.sampleBufferCount) " +
                "completedDuration=\(completedDecode.durationSeconds) " +
                "completedFirstBytes=\(completedDecode.firstDataBytes) " +
                "completedLastBytes=\(completedDecode.lastDataBytes)"
            )
            let starts = await fixture.codec.startCount()
            let stops = await fixture.codec.stopCount()
            XCTAssertEqual(starts, stops)
        } catch {
            _ = try? await recorder.stop()
            throw error
        }
    }
}

// MARK: - Deterministic fault seams

private enum WriterFault: Sendable {
    case create(AudioRecorderErrorCode)
    case configure(AudioRecorderErrorCode)
    case start(AudioRecorderErrorCode)
    case session(AudioRecorderErrorCode)
    case append(at: Int, code: AudioRecorderErrorCode)
    case flush(AudioRecorderErrorCode)
    case finish(AudioRecorderErrorCode)
}

private struct FakeWriterCounts: Sendable, Equatable {
    var start = 0
    var session = 0
    var append = 0
    var flush = 0
    var markFinished = 0
    var finish = 0
}

private struct FakeAppendRecord: Sendable, Equatable {
    let presentationFrame: UInt64
    let sampleCount: Int
}

private actor AsyncTestGate {
    private var isOpen = false
    private var entered = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered += 1
        let observers = enteredWaiters
        enteredWaiters.removeAll()
        observers.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard entered == 0 else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private final class FakeOutputLease: RecoveryAudioOutputLease, @unchecked Sendable {
    let outputURL: URL
    private let gate: AsyncTestGate?
    private let lock = NSLock()
    private var releases = 0

    init(outputURL: URL, releaseGate: AsyncTestGate?) {
        self.outputURL = outputURL
        gate = releaseGate
    }

    func release() async {
        lock.withLock { releases += 1 }
        if let gate { await gate.wait() }
    }

    func releaseCount() -> Int { lock.withLock { releases } }
}

private final class FakeOutputLeaseProvider: RecoveryAudioOutputLeaseProviding, @unchecked Sendable {
    private let base: URL
    private let error: StorageError?
    private let releaseGates: [AsyncTestGate?]
    private let lock = NSLock()
    private var leases: [FakeOutputLease] = []

    init(base: URL, error: StorageError? = nil, releaseGates: [AsyncTestGate?] = []) {
        self.base = base
        self.error = error
        self.releaseGates = releaseGates
    }

    func acquire(for location: SessionLocation) async throws -> any RecoveryAudioOutputLease {
        if let error { throw error }
        return lock.withLock {
            let index = leases.count
            let output = base.appendingPathComponent("fake-recovery-\(index).mov")
            let gate = index < releaseGates.count ? releaseGates[index] : nil
            let lease = FakeOutputLease(outputURL: output, releaseGate: gate)
            leases.append(lease)
            return lease
        }
    }

    func acquireCount() -> Int { lock.withLock { leases.count } }
    func allLeases() -> [FakeOutputLease] { lock.withLock { leases } }
}

private final class FakeWriterFactory: RecoveryAudioWriterBackendFactory, @unchecked Sendable {
    private let fault: WriterFault?
    private let startGate: AsyncTestGate?
    private let appendGate: AsyncTestGate?
    private let finishGate: AsyncTestGate?
    private let cleanupFinishError: AudioRecorderErrorCode?
    private let lock = NSLock()
    private var backends: [FakeWriterBackend] = []
    private var seenConfigurations: [RecoveryAudioWriterConfiguration] = []

    init(
        fault: WriterFault? = nil,
        startGate: AsyncTestGate? = nil,
        appendGate: AsyncTestGate? = nil,
        finishGate: AsyncTestGate? = nil,
        cleanupFinishError: AudioRecorderErrorCode? = nil
    ) {
        self.fault = fault
        self.startGate = startGate
        self.appendGate = appendGate
        self.finishGate = finishGate
        self.cleanupFinishError = cleanupFinishError
    }

    func makeWriter(
        outputURL: URL,
        configuration: RecoveryAudioWriterConfiguration
    ) throws -> any RecoveryAudioWriterBackend {
        lock.withLock { seenConfigurations.append(configuration) }
        try Data("partial-recovery".utf8).write(to: outputURL)
        switch fault {
        case let .create(code), let .configure(code):
            throw AudioRecorderError(code)
        default:
            break
        }
        let backend = FakeWriterBackend(
            fault: fault,
            startGate: startGate,
            appendGate: appendGate,
            finishGate: finishGate,
            cleanupFinishError: cleanupFinishError
        )
        lock.withLock { backends.append(backend) }
        return backend
    }

    func makeCount() -> Int { lock.withLock { seenConfigurations.count } }
    func allBackends() -> [FakeWriterBackend] { lock.withLock { backends } }
    func configurations() -> [RecoveryAudioWriterConfiguration] { lock.withLock { seenConfigurations } }
}

private actor FakeWriterBackend: RecoveryAudioWriterBackend {
    private let fault: WriterFault?
    private let startGate: AsyncTestGate?
    private let appendGate: AsyncTestGate?
    private let finishGate: AsyncTestGate?
    private let cleanupFinishError: AudioRecorderErrorCode?
    private var callCounts = FakeWriterCounts()
    private var records: [FakeAppendRecord] = []

    init(
        fault: WriterFault?,
        startGate: AsyncTestGate?,
        appendGate: AsyncTestGate?,
        finishGate: AsyncTestGate?,
        cleanupFinishError: AudioRecorderErrorCode?
    ) {
        self.fault = fault
        self.startGate = startGate
        self.appendGate = appendGate
        self.finishGate = finishGate
        self.cleanupFinishError = cleanupFinishError
    }

    func startWriting() async throws {
        callCounts.start += 1
        if let startGate { await startGate.wait() }
        try Task.checkCancellation()
        if case let .start(code) = fault { throw AudioRecorderError(code) }
    }

    func startSession() async throws {
        callCounts.session += 1
        if case let .session(code) = fault { throw AudioRecorderError(code) }
    }

    func append(samples: [Float], presentationFrame: UInt64) async throws {
        callCounts.append += 1
        if let appendGate { await appendGate.wait() }
        try Task.checkCancellation()
        if case let .append(index, code) = fault, index == callCounts.append {
            throw AudioRecorderError(code)
        }
        records.append(FakeAppendRecord(
            presentationFrame: presentationFrame,
            sampleCount: samples.count
        ))
    }

    func flushBarrier() async throws {
        callCounts.flush += 1
        if case let .flush(code) = fault { throw AudioRecorderError(code) }
    }

    func markInputFinished() async {
        callCounts.markFinished += 1
    }

    func finishWriting() async throws {
        callCounts.finish += 1
        if let finishGate { await finishGate.wait() }
        if let cleanupFinishError { throw AudioRecorderError(cleanupFinishError) }
        if case let .finish(code) = fault { throw AudioRecorderError(code) }
    }

    func counts() -> FakeWriterCounts { callCounts }
    func appendRecords() -> [FakeAppendRecord] { records }
}

private final class FakePCMConverterFactory: RecoveryAudioPCMConverterFactory, @unchecked Sendable {
    private let creationError: AudioRecorderError?
    private let builder: @Sendable () -> any RecoveryAudioPCMConverting
    private let lock = NSLock()
    private var converters: [any RecoveryAudioPCMConverting] = []

    init(
        creationError: AudioRecorderError? = nil,
        builder: @escaping @Sendable () -> any RecoveryAudioPCMConverting = { FakePCMConverter() }
    ) {
        self.creationError = creationError
        self.builder = builder
    }

    func makeConverter(source: PCMFormatDescription) throws -> any RecoveryAudioPCMConverting {
        if let creationError { throw creationError }
        let converter = builder()
        lock.withLock { converters.append(converter) }
        return converter
    }
}

private actor FakePCMConverter: RecoveryAudioPCMConverting {
    private let convertError: AudioRecorderError?
    private let drainError: AudioRecorderError?
    private let convertedSamples: [Float]?
    private let tail: [Float]
    private var drains = 0
    private var maximumInputFrames = 0

    init(
        convertError: AudioRecorderError? = nil,
        drainError: AudioRecorderError? = nil,
        convertedSamples: [Float]? = nil,
        tail: [Float] = []
    ) {
        self.convertError = convertError
        self.drainError = drainError
        self.convertedSamples = convertedSamples
        self.tail = tail
    }

    func convert(_ chunk: PCMChunk) throws -> [Float] {
        if let convertError { throw convertError }
        maximumInputFrames = max(maximumInputFrames, chunk.frameCount)
        if let convertedSamples { return convertedSamples }
        return (0..<chunk.frameCount).map { frame in
            chunk.samples[frame * chunk.format.channelCount]
        }
    }

    func drain() throws -> [Float] {
        drains += 1
        if let drainError { throw drainError }
        return tail
    }

    func drainCount() -> Int { drains }
    func maxInputFrames() -> Int { maximumInputFrames }
}

private final class FakeRecorderFixture {
    let base: URL
    let leases: FakeOutputLeaseProvider
    let writers: FakeWriterFactory
    let converters: FakePCMConverterFactory

    init(
        storageError: StorageError? = nil,
        writerFault: WriterFault? = nil,
        startGate: AsyncTestGate? = nil,
        appendGate: AsyncTestGate? = nil,
        finishGate: AsyncTestGate? = nil,
        cleanupFinishError: AudioRecorderErrorCode? = nil,
        releaseGates: [AsyncTestGate?] = [],
        converterFactory: FakePCMConverterFactory = FakePCMConverterFactory()
    ) throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalLectureSTT-Recorder-Fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        leases = FakeOutputLeaseProvider(base: base, error: storageError, releaseGates: releaseGates)
        writers = FakeWriterFactory(
            fault: writerFault,
            startGate: startGate,
            appendGate: appendGate,
            finishGate: finishGate,
            cleanupFinishError: cleanupFinishError
        )
        converters = converterFactory
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    func makeRecorder() -> AVFoundationAudioRecorder {
        AVFoundationAudioRecorder(
            outputLeases: leases,
            writerFactory: writers,
            converterFactory: converters
        )
    }

    func location() -> SessionLocation {
        let sessionID = SessionID()
        return SessionLocation(
            rootID: StorageRootID(),
            sessionID: sessionID,
            folderName: SessionFolderName(
                sessionID: sessionID,
                createdAt: AbsoluteTime(Date(timeIntervalSince1970: 1_700_000_000)),
                timeZone: .gmt
            )
        )
    }

    func chunk(
        generation: UInt64,
        sequence: UInt64,
        sampleRate: Double = 48_000,
        channels: Int = 1,
        frames: Int = 48
    ) throws -> PCMChunk {
        try syntheticChunk(
            generation: generation,
            sequence: sequence,
            sampleRate: sampleRate,
            channels: channels,
            sourceFrame: Int(sequence) * frames,
            frames: frames
        )
    }
}

// MARK: - Actual AVFoundation fixtures and evidence

private actor PathBookmarkCodec: SecurityScopedBookmarkCodec {
    private var starts = 0
    private var stops = 0

    func makeBookmark(for directory: URL) async throws -> Data {
        Data(directory.path.utf8)
    }

    func resolve(_ bookmark: Data) async throws -> ResolvedBookmark {
        ResolvedBookmark(
            url: URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)),
            isStale: false
        )
    }

    func startAccessing(_ url: URL) async -> Bool {
        starts += 1
        return true
    }

    func stopAccessing(_ url: URL) async {
        stops += 1
    }

    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
}

private final class ActualRecorderFixture {
    let base: URL
    let rootA: URL
    let rootB: URL
    let outside: URL
    let support: URL
    let codec = PathBookmarkCodec()

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalLectureSTT-Recorder-Actual-\(UUID().uuidString)", isDirectory: true)
        rootA = base.appendingPathComponent("root-a", isDirectory: true)
        rootB = base.appendingPathComponent("root-b", isDirectory: true)
        outside = base.appendingPathComponent("outside", isDirectory: true)
        support = base.appendingPathComponent("support", isDirectory: true)
        for directory in [rootA, rootB, outside, support] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    func manager() -> StorageRootManager {
        StorageRootManager(applicationSupportDirectory: support, bookmarkCodec: codec)
    }

    func location(using manager: StorageRootManager) async throws -> SessionLocation {
        let repository = FileSessionRepository(roots: manager)
        return try await repository.createSession(
            sessionID: SessionID(),
            createdAt: AbsoluteTime(Date()),
            timeZone: .gmt
        )
    }

    func recoveryURL(for location: SessionLocation, root: URL) -> URL {
        root
            .appendingPathComponent(location.folderName.rawValue)
            .appendingPathComponent(SessionArtifact.recoveryAudio.relativePath)
    }
}

private final class SpyAVAssetWriterFactory: RecoveryAudioWriterBackendFactory, @unchecked Sendable {
    private let live = AVAssetWriterBackendFactory()
    private let lock = NSLock()
    private var seen: [RecoveryAudioWriterConfiguration] = []

    func makeWriter(
        outputURL: URL,
        configuration: RecoveryAudioWriterConfiguration
    ) throws -> any RecoveryAudioWriterBackend {
        lock.withLock { seen.append(configuration) }
        return try live.makeWriter(outputURL: outputURL, configuration: configuration)
    }

    func configurations() -> [RecoveryAudioWriterConfiguration] {
        lock.withLock { seen }
    }
}

private struct AssetDecodeEvidence: Sendable {
    let sampleBufferCount: Int
    let firstDataBytes: Int
    let lastDataBytes: Int
    let totalDataBytes: Int
    let durationSeconds: Double
}

private struct ActivePrefixEvidence: Sendable {
    let moofCount: Int
    let decode: AssetDecodeEvidence
}

private func waitForReadableActivePrefix(
    at activeURL: URL,
    snapshotsDirectory: URL
) async throws -> ActivePrefixEvidence {
    var lastError: Error?
    for attempt in 0..<120 {
        do {
            let bytes = try Data(contentsOf: activeURL)
            let moofCount = bytes.topLevelBoxCount(named: "moof")
            if moofCount >= 2 {
                let snapshot = snapshotsDirectory.appendingPathComponent("active-prefix-\(attempt).mov")
                try bytes.write(to: snapshot, options: .withoutOverwriting)
                let decode = try await decodeAsset(at: snapshot)
                if decode.sampleBufferCount > 0,
                   decode.firstDataBytes > 0,
                   decode.lastDataBytes > 0 {
                    return ActivePrefixEvidence(moofCount: moofCount, decode: decode)
                }
            }
        } catch {
            lastError = error
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw lastError ?? AudioRecorderError(.writerReadinessFailed)
}

private func decodeAsset(at url: URL) async throws -> AssetDecodeEvidence {
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
    var firstBytes = 0
    var lastBytes = 0
    var totalBytes = 0
    var lastEnd = CMTime.zero
    while let sample = output.copyNextSampleBuffer() {
        let bytes = CMSampleBufferGetDataBuffer(sample).map(CMBlockBufferGetDataLength) ?? 0
        if count == 0 { firstBytes = bytes }
        lastBytes = bytes
        totalBytes += bytes
        count += 1
        let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
        let duration = CMSampleBufferGetDuration(sample)
        if duration.isValid, duration.isNumeric {
            lastEnd = CMTimeAdd(presentation, duration)
        } else {
            let samples = CMSampleBufferGetNumSamples(sample)
            lastEnd = CMTimeAdd(presentation, CMTime(value: CMTimeValue(samples), timescale: 48_000))
        }
    }
    guard reader.status == .completed else { throw AudioRecorderError(.writerFinishFailed) }
    return AssetDecodeEvidence(
        sampleBufferCount: count,
        firstDataBytes: firstBytes,
        lastDataBytes: lastBytes,
        totalDataBytes: totalBytes,
        durationSeconds: CMTimeGetSeconds(lastEnd)
    )
}

private func syntheticChunk(
    generation: UInt64,
    sequence: UInt64,
    sampleRate: Double,
    channels: Int,
    sourceFrame: Int,
    frames: Int
) throws -> PCMChunk {
    let format = try PCMFormatDescription(sampleRate: sampleRate, channelCount: channels)
    var samples = [Float](repeating: 0, count: frames * channels)
    for localFrame in 0..<frames {
        let frame = sourceFrame + localFrame
        let left = Float(sin(Double(frame) * 2 * .pi * 431 / sampleRate) * 0.24)
        let right = Float(sin(Double(frame) * 2 * .pi * 677 / sampleRate + 0.7) * 0.12)
        for channel in 0..<channels {
            let value: Float
            switch channel {
            case 0: value = left
            case 1: value = right
            default: value = (left + right) * 0.5
            }
            samples[localFrame * channels + channel] = value
        }
    }
    return try PCMChunk(
        generation: generation,
        sequence: sequence,
        format: format,
        frameCount: frames,
        sourceSampleTime: Int64(sourceFrame),
        samples: samples
    )
}

private func recorderErrorCode<T>(
    _ operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> AudioRecorderErrorCode? {
    do {
        _ = try await operation()
        XCTFail("Expected AudioRecorderError", file: file, line: line)
        return nil
    } catch let error as AudioRecorderError {
        return error.code
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
        return nil
    }
}

private func nextEvent(
    in stream: AsyncStream<AudioRecorderEvent>,
    timeout: Duration = .seconds(1)
) async -> AudioRecorderEvent? {
    await withTaskGroup(of: AudioRecorderEvent?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

private extension Data {
    func topLevelBoxCount(named target: String) -> Int {
        let targetBytes = Array(target.utf8)
        guard targetBytes.count == 4 else { return 0 }
        var offset = 0
        var count = 0

        while offset <= self.count - 8 {
            let size32 = readUInt32BE(at: offset)
            let type = Array(self[(offset + 4)..<(offset + 8)])
            var headerSize = 8
            let boxSize: UInt64
            if size32 == 1 {
                guard offset <= self.count - 16 else { break }
                headerSize = 16
                boxSize = readUInt64BE(at: offset + 8)
            } else if size32 == 0 {
                boxSize = UInt64(self.count - offset)
            } else {
                boxSize = UInt64(size32)
            }
            guard boxSize >= UInt64(headerSize),
                  boxSize <= UInt64(self.count - offset) else {
                break
            }
            if type == targetBytes { count += 1 }
            guard boxSize <= UInt64(Int.max) else { break }
            offset += Int(boxSize)
        }
        return count
    }

    private func readUInt32BE(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    private func readUInt64BE(at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { value, index in
            (value << 8) | UInt64(self[offset + index])
        }
    }
}
