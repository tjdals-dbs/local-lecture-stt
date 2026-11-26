import XCTest
@testable import LocalLectureSTT

final class LiveSTTCoordinatorTests: XCTestCase {
    func testSuspendedPublicationCannotOvertakeTerminalFailure() async throws {
        let publicationGate = T14Gate()
        let cancelGate = T14Gate()
        let prematureFailure = expectation(description: "failure cannot overtake a suspended earlier publication")
        prematureFailure.isInverted = true
        let probe = T19PublicationProbe(gate: publicationGate, prematureFailure: prematureFailure)
        let f = try T19Fixture(cancelGate: cancelGate, publish: { await probe.append($0) })
        await f.start()
        try f.send(2_000)
        try await publicationGate.wait()
        _ = try await f.engine.request(0)
        try await f.engine.fail(0, .inferenceFailed)
        try await cancelGate.wait()
        let failed = await f.coordinator.currentSnapshot()
        XCTAssertEqual(failed.failure, .inferenceFailed)
        await fulfillment(of: [prematureFailure], timeout: 0.2)
        await probe.release()
        await cancelGate.release()
        await f.coordinator.waitUntilSettled()
        let delivered = await probe.values
        let firstFailure = try XCTUnwrap(delivered.firstIndex { $0.failure != nil })
        XCTAssertTrue(delivered[firstFailure...].allSatisfy { $0.failure == .inferenceFailed },
                      "a delayed healthy snapshot must never erase a terminal failure")
        XCTAssertEqual(delivered.last?.cleanupComplete, true)
        f.finish()
    }

    func testT24PauseSealsOpenSpeechWithoutWaitingForSlowInferenceAndSuppressesLatePartial() async throws {
        let f = try T19Fixture()
        await f.start(); try f.send(2_000)
        _ = try await f.engine.request(0)
        try await f.engine.respond(0, .partial, "멈추기 전 임시")
        _ = try await f.observed.wait { $0.partial != nil }
        f.pause()
        let paused = try await f.observed.wait { $0.inputPaused && $0.pendingFinals == 1 }
        XCTAssertNil(paused.partial)
        try await f.engine.respond(0, .final, "늦은 임시")
        let sealed = try await f.engine.request(1)
        XCTAssertEqual(sealed.audio.duration.rawValue, 2_000)
        let current = await f.coordinator.currentSnapshot(); XCTAssertNil(current.partial)
        try await f.engine.respond(1, .final, "정지 전 확정")
        _ = try await f.observed.wait { $0.finals.count == 1 }
        try f.send(400); f.pause()
        let resumed = try await f.engine.request(2)
        XCTAssertEqual(resumed.context.mediaStart.rawValue, 2_000)
        XCTAssertEqual(resumed.context.session, sealed.context.session)
        try await f.engine.respond(2, .final, "재개 후 확정")
        f.finish(); await f.coordinator.waitUntilSettled()
        let result = await f.coordinator.currentSnapshot()
        XCTAssertNil(result.failure); XCTAssertEqual(result.inputDiscontinuities, 0)
        XCTAssertEqual(result.finals.map(\.text), ["정지 전 확정", "재개 후 확정"])
        XCTAssertEqual(result.finals.map(\.startMs.rawValue), [0, 2_000])
        let counts = await f.engine.counts; XCTAssertEqual(counts, [1, 1, 0, 1])
    }

    func testT24LostPauseMarkerStillSeparatesSpeechThroughPCMGenerationEpoch() async throws {
        let f = try T19Fixture()
        await f.start(); try f.send(400)
        _ = try await f.observed.wait { $0.inputMilliseconds == 400 }
        f.pause(marker: false); try f.send(400)
        let old = try await f.engine.request(0)
        XCTAssertEqual(old.audio.duration.rawValue, 400)
        try await f.engine.respond(0, .final, "앞 문장")
        f.finish()
        let new = try await f.engine.request(1)
        XCTAssertEqual(new.context.mediaStart.rawValue, 400)
        XCTAssertEqual(new.audio.duration.rawValue, 400)
        try await f.engine.respond(1, .final, "뒤 문장")
        await f.coordinator.waitUntilSettled()
        let result = await f.coordinator.currentSnapshot()
        XCTAssertEqual(result.finals.map(\.text), ["앞 문장", "뒤 문장"])
        XCTAssertNil(result.failure)
    }

    func testT24EmptyPauseCyclesDoNotInventSpeechOrRestartEngine() async throws {
        let f = try T19Fixture()
        await f.start()
        for _ in 0..<10 { f.pause() }
        f.finish(); await f.coordinator.waitUntilSettled()
        let result = await f.coordinator.currentSnapshot()
        XCTAssertTrue(result.finals.isEmpty); XCTAssertNil(result.failure)
        let requests = await f.engine.requests; XCTAssertTrue(requests.isEmpty)
        let counts = await f.engine.counts; XCTAssertEqual(counts, [1, 1, 0, 1])
    }

    func testConverterTailAtStopGoesDirectlyToFinalInference() async throws {
        let f = try T19Fixture(converter: T19TailConverter())
        await f.start()
        try f.send(2_000)
        f.finish()
        let request = try await f.engine.request(0)
        XCTAssertEqual(request.audio.frameCount, 32_000)
        try await f.engine.respond(0, .final, "종료 직전 발화")
        await f.coordinator.waitUntilSettled()
        let value = await f.coordinator.currentSnapshot()
        XCTAssertEqual(value.finals.map(\.text), ["종료 직전 발화"])
        XCTAssertTrue(value.cleanupComplete)
        let count = await f.engine.requests.count
        XCTAssertEqual(count, 1)
    }

    func testEmptyAutomaticResultDoesNotInventLanguageOrDisableLaterSpeech() async throws {
        let f = try T19Fixture(mode: .automatic)
        await f.start()
        try f.send(400); try f.send(800, voice: false)
        _ = try await f.engine.request(0)
        try await f.engine.empty(0)
        try f.send(400); try f.send(800, voice: false)
        let next = try await f.engine.request(1)
        XCTAssertNil(next.decodingHints)
        try await f.engine.respond(1, .final, "한국어로 고정", language: "ko")
        f.finish()
        await f.coordinator.waitUntilSettled()
        let value = await f.coordinator.currentSnapshot()
        XCTAssertNil(value.failure)
        XCTAssertEqual(value.language?.rawValue, "ko")
        XCTAssertEqual(value.finals.map(\.text), ["한국어로 고정"])
    }

    func testForeignResponseIsRejectedWithoutJournalWrite() async throws {
        let f = try T19Fixture()
        await f.start()
        try f.send(400); try f.send(800, voice: false)
        _ = try await f.engine.request(0)
        try await f.engine.foreignResponse(0)
        await f.coordinator.waitUntilSettled()
        let value = await f.coordinator.currentSnapshot()
        XCTAssertEqual(value.failure, .invalidResponse)
        let records = await f.repository.records
        XCTAssertTrue(records.isEmpty)
        f.finish()
    }

    func testSourceTimeGapFlushesSeparateWindowsWithoutChangingClock() async throws {
        let f = try T19Fixture()
        await f.start()
        try f.send(400)
        try f.send(400, at: 32_000)
        let old = try await f.engine.request(0)
        XCTAssertEqual(old.context.mediaStart.rawValue, 0)
        XCTAssertEqual(old.audio.duration.rawValue, 400)
        try await f.engine.respond(0, .final, "앞")
        try f.send(800, voice: false)
        let next = try await f.engine.request(1)
        XCTAssertEqual(next.context.mediaStart.rawValue, 2_000)
        try await f.engine.respond(1, .final, "뒤")
        f.finish()
        await f.coordinator.waitUntilSettled()
        let value = await f.coordinator.currentSnapshot()
        XCTAssertEqual(value.inputDiscontinuities, 1)
        XCTAssertEqual(value.finals.map(\.startMs.rawValue), [0, 2_000])
    }

    func testProvisionalReplacementAndDurableImmutableFinal() async throws {
        let f = try T19Fixture()
        await f.start()
        try f.send(2_000)
        let first = try await f.engine.request(0)
        XCTAssertEqual(first.audio.format.sampleRate, 16_000)
        XCTAssertNil(first.decodingHints)
        try await f.engine.respond(0, .partial, "임시")
        _ = try await f.observed.wait { $0.partial == "임시" }
        try await f.engine.respond(0, .final, "아직 임시")
        _ = try await f.observed.wait { $0.partial == "아직 임시" }
        let before = await f.repository.records
        XCTAssertTrue(before.isEmpty)
        try f.send(800, voice: false)
        _ = try await f.engine.request(1)
        try await f.engine.respond(1, .final, "확정 문장")
        let committed = try await f.observed.wait { $0.finals.count == 1 }
        XCTAssertNil(committed.partial)
        XCTAssertEqual(committed.finals[0].text, "확정 문장")
        try f.send(1_000)
        f.finish()
        let second = try await f.engine.request(2)
        XCTAssertEqual(second.decodingHints?.promptText, "확정 문장")
        XCTAssertEqual(second.context.session, f.session)
        try await f.engine.respond(2, .final, "다음 문장")
        await f.coordinator.waitUntilSettled()
        let value = await f.coordinator.currentSnapshot()
        XCTAssertEqual(value.phase, .finished)
        XCTAssertEqual(value.finals.first, committed.finals.first)
        XCTAssertEqual(value.finals.map(\.sequence.rawValue), [0, 1])
        XCTAssertEqual(value.finals.map(\.text), ["확정 문장", "다음 문장"])
        let records = await f.repository.records
        XCTAssertEqual(records.map(\.segment), value.finals)
        let counts = await f.engine.counts
        XCTAssertEqual(counts, [1, 1, 0, 1])
    }

    func testBusyTicksAreDroppedAndStalePartialCannotReplaceSealedWindow() async throws {
        let f = try T19Fixture()
        await f.start()
        try f.send(2_000)
        _ = try await f.engine.request(0)
        try f.send(4_000)
        try f.send(800, voice: false)
        let pending = try await f.observed.wait { $0.pendingFinals == 1 }
        XCTAssertTrue(pending.degraded)
        let count = await f.engine.requests.count
        XCTAssertEqual(count, 1, "no partial backlog")
        try await f.engine.respond(0, .final, "stale")
        let finalRequest = try await f.engine.request(1)
        XCTAssertEqual(finalRequest.context.mediaStart.rawValue, 0)
        XCTAssertEqual(finalRequest.audio.duration.rawValue, 6_800)
        let current = await f.coordinator.currentSnapshot()
        XCTAssertNotEqual(current.partial, "stale")
        try await f.engine.respond(1, .final, "보존")
        f.finish()
        await f.coordinator.waitUntilSettled()
        let result = await f.coordinator.currentSnapshot()
        XCTAssertEqual(result.finals.map(\.text), ["보존"])
        let events = await f.repository.events
        XCTAssertEqual(events.filter { $0.kind == .sttBackpressureDegraded }.count, 1)
    }

    func testFinalQueueHasHardBoundAndReportsOverloadExactlyOnce() async throws {
        let f = try T19Fixture(capacity: 2)
        await f.start()
        try f.send(2_000)
        _ = try await f.engine.request(0)
        try f.send(800, voice: false)
        try f.send(400)
        try f.send(800, voice: false)
        _ = try await f.observed.wait { $0.pendingFinals == 2 }
        try f.send(400)
        try f.send(800, voice: false)
        await f.coordinator.waitUntilSettled()
        let value = await f.coordinator.currentSnapshot()
        XCTAssertEqual(value.failure, .backlogFull)
        XCTAssertEqual(value.phase, .failed)
        let counts = await f.engine.counts
        XCTAssertEqual(counts, [1, 0, 1, 1])
        let events = await f.repository.events
        XCTAssertEqual(events.filter { $0.kind == .sttError }.count, 1)
        f.finish()
    }

    func testOnlyLastConfirmedSegmentIsBoundedContext() async throws {
        let f = try T19Fixture()
        await f.start()
        try f.send(400); try f.send(800, voice: false)
        _ = try await f.engine.request(0)
        let text = String(repeating: "한국어 English ", count: 100)
        try await f.engine.respond(0, .final, text)
        _ = try await f.observed.wait { $0.finals.count == 1 }
        try f.send(400); try f.send(800, voice: false)
        let next = try await f.engine.request(1)
        let prompt = try XCTUnwrap(next.decodingHints?.promptText)
        XCTAssertLessThanOrEqual(prompt.utf8.count, LiveSTTCoordinator.contextUTF8Limit)
        XCTAssertTrue(text.trimmingCharacters(in: .whitespaces).hasSuffix(prompt))
        try await f.engine.respond(1, .final, "마지막 확정")
        _ = try await f.observed.wait { $0.finals.count == 2 }
        try f.send(400); try f.send(800, voice: false)
        let last = try await f.engine.request(2)
        XCTAssertEqual(last.decodingHints?.promptText, "마지막 확정")
        try await f.engine.respond(2, .final, "끝")
        f.finish()
        await f.coordinator.waitUntilSettled()
    }

    func testAutomaticLanguagePinsAndRejectsLaterLanguageChange() async throws {
        let f = try T19Fixture(mode: .automatic)
        await f.start()
        try f.send(400); try f.send(800, voice: false)
        _ = try await f.engine.request(0)
        try await f.engine.respond(0, .final, "English", language: "en")
        _ = try await f.observed.wait { $0.finals.count == 1 }
        try f.send(400); try f.send(800, voice: false)
        _ = try await f.engine.request(1)
        try await f.engine.respond(1, .final, "다른 언어", language: "ko")
        await f.coordinator.waitUntilSettled()
        let value = await f.coordinator.currentSnapshot()
        XCTAssertEqual(value.language?.rawValue, "en")
        XCTAssertEqual(value.failure, .invalidResponse)
        XCTAssertEqual(value.finals.map(\.text), ["English"])
        f.finish()
    }

    func testInferenceAndStartFailuresTerminateSpeechWithoutLosingDurableFinals() async throws {
        for code in [STTErrorCode.inferenceFailed, .startFailed] {
            let f = try T19Fixture(startFailure: code == .startFailed ? code : nil)
            await f.start()
            if code != .startFailed {
                try f.send(400); try f.send(800, voice: false)
                _ = try await f.engine.request(0)
                try await f.engine.respond(0, .final, "저장됨")
                _ = try await f.observed.wait { $0.finals.count == 1 }
                try f.send(400); try f.send(800, voice: false)
                _ = try await f.engine.request(1)
                try await f.engine.fail(1, code)
            }
            await f.coordinator.waitUntilSettled()
            let value = await f.coordinator.currentSnapshot()
            XCTAssertEqual(value.failure, code)
            XCTAssertEqual(value.finals.count, code == .startFailed ? 0 : 1)
            f.finish()
        }
    }

    func testAppendFailureNeverPublishesOrRetriesUndurableFinal() async throws {
        let f = try T19Fixture(journalFailure: true)
        await f.start()
        try f.send(400); try f.send(800, voice: false)
        _ = try await f.engine.request(0)
        try await f.engine.respond(0, .final, "disk full")
        await f.coordinator.waitUntilSettled()
        await f.coordinator.cancel()
        let value = await f.coordinator.currentSnapshot()
        XCTAssertTrue(value.finals.isEmpty)
        XCTAssertEqual(value.storageWarning, StorageErrorCode.jsonlAppendFailed.rawValue)
        let attempts = await f.repository.appendAttempts
        XCTAssertEqual(attempts, 1)
        f.finish()
    }

    func testCancelJoinsDurableAppendAndNativeCleanupBeforeUnload() async throws {
        let journalGate = T14Gate(), cancelGate = T14Gate()
        let f = try T19Fixture(journalGate: journalGate, cancelGate: cancelGate)
        await f.start()
        try f.send(400); try f.send(800, voice: false)
        _ = try await f.engine.request(0)
        try await f.engine.respond(0, .final, "저장 중")
        try await journalGate.wait()
        let cancellation = Task { await f.coordinator.cancel() }
        try await cancelGate.wait()
        let before = await f.engine.counts
        XCTAssertEqual(before[3], 0)
        await cancelGate.release()
        let stillHeld = await f.engine.counts
        XCTAssertEqual(stillHeld[3], 0)
        await journalGate.release()
        await cancellation.value
        await f.coordinator.cancel()
        let value = await f.coordinator.currentSnapshot()
        XCTAssertEqual(value.phase, .cancelled)
        XCTAssertEqual(value.finals.map(\.text), ["저장 중"])
        let counts = await f.engine.counts
        XCTAssertEqual(counts, [1, 0, 1, 1])
        f.finish()
    }

    func testCancelDuringEngineStartAndInferenceHasNoLateFinal() async throws {
        for duringStart in [true, false] {
            let gate = duringStart ? T14Gate() : nil
            let f = try T19Fixture(startGate: gate)
            await f.start()
            if let gate { try await gate.wait() }
            else { try f.send(2_000); _ = try await f.engine.request(0) }
            let cancellation = Task { await f.coordinator.cancel() }
            if let gate { await gate.release() }
            await cancellation.value
            let value = await f.coordinator.currentSnapshot()
            XCTAssertEqual(value.phase, .cancelled)
            XCTAssertTrue(value.finals.isEmpty)
            let counts = await f.engine.counts
            XCTAssertEqual(counts[3], 1)
            f.finish()
        }
    }

    func testEmptyCaptureFinishesWithoutInferenceAndInputGapsKeepMediaTime() async throws {
        let empty = try T19Fixture()
        await empty.start(); empty.finish()
        await empty.coordinator.waitUntilSettled()
        let requests = await empty.engine.requests
        XCTAssertTrue(requests.isEmpty)
        let f = try T19Fixture()
        await f.start()
        // First two chunks were dropped by speech fan-out, recording origin is 0.
        try f.send(400, at: 32_000, sequence: 2)
        try f.send(800, voice: false)
        let request = try await f.engine.request(0)
        XCTAssertEqual(request.context.mediaStart.rawValue, 2_000)
        try await f.engine.respond(0, .final, "2초부터")
        f.finish()
        await f.coordinator.waitUntilSettled()
        let value = await f.coordinator.currentSnapshot()
        XCTAssertEqual(value.inputDiscontinuities, 1)
        XCTAssertEqual(value.finals.first?.startMs.rawValue, 2_000)
    }

    func testRealConverterStereoRatesChunkBoundariesAndGap() async throws {
        for rate in [16_000.0, 44_100, 48_000] {
            let converter = SpeechPCMConverter()
            let format = try PCMFormatDescription(sampleRate: rate, channelCount: 2)
            var blocks: [SpeechAudioBlock] = []
            let count = Int(rate)
            for offset in stride(from: 0, to: count, by: 997) {
                let frames = min(997, count - offset)
                let samples: [Float] = (0..<frames).flatMap { i -> [Float] in
                    let v = Float(sin(Double(i + offset) * 2 * .pi * 220 / rate))
                    return [v * 0.1, v * 0.3]
                }
                let chunk = try PCMChunk(generation: 1, sequence: UInt64(offset), format: format,
                    frameCount: frames, sourceSampleTime: 90_000 + Int64(offset), samples: samples)
                blocks += try await converter.convert(chunk, origin: 90_000)
            }
            blocks += try await converter.drain()
            XCTAssertEqual(blocks.reduce(0) { $0 + $1.samples.count }, 16_000)
            XCTAssertEqual(blocks.first?.startFrame, 0)
            for (a,b) in zip(blocks, blocks.dropFirst()) {
                XCTAssertEqual(a.startFrame + Int64(a.samples.count), b.startFrame)
            }
            let joined = blocks.flatMap(\.samples)
            let rms = sqrt(joined.dropFirst(500).reduce(0.0) { $0 + Double($1 * $1) } / Double(joined.count - 500))
            XCTAssertEqual(rms, 0.2 / sqrt(2), accuracy: 0.003)
            let next = try PCMChunk(generation: 1, sequence: 99_999, format: format,
                frameCount: count, sourceSampleTime: 90_000 + Int64(count * 2),
                samples: Array(repeating: 0, count: count * 2))
            let later = try await converter.convert(next, origin: 90_000)
            XCTAssertEqual(later.first?.startFrame, 32_000)
            _ = try await converter.drain()
        }
    }
}

private struct T19Detector: VoiceActivityDetector {
    mutating func isSpeech(_ frame: [Float]) -> Bool { frame.contains { abs($0) > 0.1 } }
    mutating func reset() {}
}

private struct T19Passthrough: SpeechPCMConverting {
    func convert(_ chunk: PCMChunk, origin: Int64) async throws -> [SpeechAudioBlock] {
        [.init(samples: chunk.samples, startFrame: chunk.sourceSampleTime - origin)]
    }
    func drain() async throws -> [SpeechAudioBlock] { [] }
}

private actor T19TailConverter: SpeechPCMConverting {
    private var pending: [SpeechAudioBlock] = []
    func convert(_ chunk: PCMChunk, origin: Int64) async throws -> [SpeechAudioBlock] {
        pending.append(.init(samples: chunk.samples, startFrame: chunk.sourceSampleTime - origin))
        return []
    }
    func drain() async throws -> [SpeechAudioBlock] {
        let result = pending
        pending.removeAll()
        return result
    }
}

private final class T19Fixture: @unchecked Sendable {
    let engine: T19ControlledEngine
    let repository: T19Repository
    let observed = T19Observations()
    let session: STTSessionConfiguration
    let coordinator: LiveSTTCoordinator
    let handle: CaptureHandle
    let continuation: AsyncThrowingStream<CaptureSpeechInput, Error>.Continuation
    private var frame: Int64 = 0
    private var sequence: UInt64 = 0
    private var epoch: UInt64 = 0
    func pause(marker: Bool = true) {
        epoch += 1
        if marker { continuation.yield(.pause(.init(epoch: epoch, recordingChunkCount: sequence, mediaMilliseconds: UInt64(frame / 16)))) }
    }
    init(capacity: Int = 4, mode: LanguageMode = .korean, journalFailure: Bool = false,
         journalGate: T14Gate? = nil, cancelGate: T14Gate? = nil,
         startGate: T14Gate? = nil, startFailure: STTErrorCode? = nil,
         converter: any SpeechPCMConverting = T19Passthrough(),
         recovery: (any SpeechRecoveryRecording)? = nil, timeout: Duration = .seconds(60),
         publish: @escaping @Sendable (LiveSTTSnapshot) async -> Void = { _ in }) throws {
        session = try STTTestFixture.session(mode: mode)
        engine = try T19ControlledEngine(cancelGate: cancelGate, startGate: startGate, startFailure: startFailure)
        repository = T19Repository(failure: journalFailure, gate: journalGate)
        let location = SessionLocation(rootID: StorageRootID(), sessionID: session.sessionID,
            folderName: SessionFolderName(sessionID: session.sessionID, createdAt: AbsoluteTime(Date()), timeZone: .gmt))
        let observed = observed
        coordinator = LiveSTTCoordinator(engine: engine, session: session, repository: repository,
            location: location, converter: converter, detector: T19Detector(),
            maximumPendingFinals: capacity, recovery: recovery, requestTimeout: timeout, publish: { await publish($0); await observed.append($0) })
        let pair = AsyncThrowingStream<CaptureSpeechInput, Error>.makeStream()
        continuation = pair.continuation
        handle = CaptureHandle(generation: 1, device: .init(identity: "test", displayName: "test"),
            recordingPCM: .init { $0.finish() }, speechInputs: pair.stream,
            events: .init { $0.finish() }, inputSignalStates: .init { $0.finish() })
        handle.timeline.recordOrigin(0)
    }
    func start() async { await coordinator.start(handle) }
    func send(_ ms: Int, voice: Bool = true, at: Int64? = nil, sequence: UInt64? = nil) throws {
        frame = at ?? frame
        self.sequence = sequence ?? self.sequence
        continuation.yield(.pcm(try PCMChunk(generation: 1, sequence: self.sequence,
            format: PCMFormatDescription(sampleRate: 16_000, channelCount: 1), frameCount: ms * 16,
            sourceSampleTime: frame, samples: Array(repeating: voice ? 0.2 : 0, count: ms * 16), segmentEpoch: epoch)))
        frame += Int64(ms * 16); self.sequence += 1
    }
    func finish() { continuation.finish() }
}

private actor T19PublicationProbe {
    let gate: T14Gate
    let prematureFailure: XCTestExpectation
    private var held = false
    private var released = false
    var values: [LiveSTTSnapshot] = []
    init(gate: T14Gate, prematureFailure: XCTestExpectation) {
        self.gate = gate; self.prematureFailure = prematureFailure
    }
    func append(_ value: LiveSTTSnapshot) async {
        if !held, value.inputMilliseconds >= 2_000, value.failure == nil {
            held = true
            await gate.hold()
        }
        if value.failure != nil, !released { prematureFailure.fulfill() }
        values.append(value)
    }
    func release() async { released = true; await gate.release() }
}

private actor T19Observations {
    private var value = LiveSTTSnapshot.idle
    private var waiters: [(@Sendable (LiveSTTSnapshot) -> Bool, XCTestExpectation)] = []
    func append(_ snapshot: LiveSTTSnapshot) {
        value = snapshot
        waiters.removeAll { predicate, waiter in
            if predicate(value) { waiter.fulfill(); return true }
            return false
        }
    }
    func wait(_ predicate: @escaping @Sendable (LiveSTTSnapshot) -> Bool) async throws -> LiveSTTSnapshot {
        if predicate(value) { return value }
        let event = XCTestExpectation(description: "T19 snapshot boundary")
        waiters.append((predicate, event))
        guard await XCTWaiter.fulfillment(of: [event], timeout: 8) == .completed else {
            throw STTEngineError(.invalidLifecycle)
        }
        return value
    }
}

private actor T19ControlledEngine: STTEngine {
    nonisolated let capabilities: STTCapabilities
    var requests: [STTInferenceRequest] = []
    var loaded: [STTModelConfiguration] = []
    var sessions: [STTSessionConfiguration] = []
    var counts = [0, 0, 0, 0] // start, end, cancel, unload
    private var feeds: [STTEventFeed] = []
    private var revisions: [Int64] = []
    private var waiters: [(Int, XCTestExpectation)] = []
    private let cancelGate: T14Gate?
    private let startGate: T14Gate?
    private let startFailure: STTErrorCode?
    init(cancelGate: T14Gate?, startGate: T14Gate?, startFailure: STTErrorCode?) throws {
        capabilities = try STTTestFixture.capabilities()
        self.cancelGate = cancelGate; self.startGate = startGate; self.startFailure = startFailure
    }
    func load(_ model: STTModelConfiguration) async throws { loaded.append(model) }
    func start(_ session: STTSessionConfiguration) async throws {
        counts[0] += 1
        sessions.append(session)
        await startGate?.hold()
        if let startFailure { throw STTEngineError(startFailure) }
    }
    func infer(_ request: STTInferenceRequest) async throws -> STTEventFeed {
        let feed = STTEventFeed(withdraw: {})
        requests.append(request); feeds.append(feed); revisions.append(0)
        waiters.removeAll { index, event in
            if requests.count > index { event.fulfill(); return true }
            return false
        }
        return feed
    }
    func request(_ index: Int) async throws -> STTInferenceRequest {
        if requests.count <= index {
            let event = XCTestExpectation(description: "T19 request \(index)")
            waiters.append((index, event))
            guard await XCTWaiter.fulfillment(of: [event], timeout: 8) == .completed else {
                throw STTEngineError(.invalidLifecycle)
            }
        }
        return requests[index]
    }
    func respond(_ index: Int, _ kind: STTResponseKind, _ text: String, language: String? = nil) throws {
        let request = requests[index]
        revisions[index] += 1
        feeds[index].publish(try STTResponse(context: request.context, revision: revisions[index], kind: kind,
            segments: [STTHypothesisSegment(start: request.context.mediaStart, end: request.context.mediaEnd, text: text)],
            detectedLanguage: language.map { try! LanguageCode($0) }))
    }
    func fail(_ index: Int, _ code: STTErrorCode) throws {
        revisions[index] += 1
        feeds[index].publish(try STTResponse(context: requests[index].context, revision: revisions[index],
            kind: .failed, failure: STTEngineError(code)))
    }
    func empty(_ index: Int) throws {
        revisions[index] += 1
        feeds[index].publish(try STTResponse(context: requests[index].context, revision: revisions[index], kind: .final))
    }
    func foreignResponse(_ index: Int) throws {
        let wrong = try STTTestFixture.request(session: STTTestFixture.session(2), start: 0)
        feeds[index].publish(try STTResponse(context: wrong.context, revision: 1, kind: .final))
    }
    func end() async throws { counts[1] += 1 }
    func cancel() async throws {
        counts[2] += 1
        await cancelGate?.hold()
        for index in feeds.indices {
            revisions[index] += 1
            feeds[index].publish(try STTResponse(context: requests[index].context, revision: revisions[index],
                kind: .cancelled, failure: STTEngineError(.cancelled)))
        }
    }
    func unload() async { counts[3] += 1 }
}

private actor T19Repository: SessionRepository {
    var records: [TranscriptJournalRecord] = []
    var events: [SessionEventRecord] = []
    var appendAttempts = 0
    let failure: Bool
    let gate: T14Gate?
    init(failure: Bool, gate: T14Gate?) { self.failure = failure; self.gate = gate }
    func appendTranscriptJournal(_ record: TranscriptJournalRecord, at location: SessionLocation) async throws {
        appendAttempts += 1
        await gate?.hold()
        if failure { throw StorageError(.jsonlAppendFailed) }
        records.append(record)
    }
    func appendEvent(_ record: SessionEventRecord, at location: SessionLocation) async throws { events.append(record) }
    func createSession(sessionID: SessionID, createdAt: AbsoluteTime, timeZone: TimeZone) async throws -> SessionLocation { fatalError("unused") }
    func writeMetadata(_ document: SessionMetadataDocument, at location: SessionLocation) async throws { fatalError("unused") }
    func readMetadata(at location: SessionLocation) async throws -> SessionMetadataDocument { fatalError("unused") }
    func writeTranscript(_ document: TranscriptDocument, at location: SessionLocation) async throws { fatalError("unused") }
    func readTranscript(at location: SessionLocation) async throws -> TranscriptDocument { fatalError("unused") }
    func writeFinalizationCheckpoint(_ document: FinalizationCheckpointDocument, at location: SessionLocation) async throws { fatalError("unused") }
    func readFinalizationCheckpoint(at location: SessionLocation) async throws -> FinalizationCheckpointDocument { fatalError("unused") }
    nonisolated func artifactOwnership(_ artifact: SessionArtifact) -> SessionArtifactOwnership { artifact.ownership }
}

extension LiveSTTCoordinatorTests {
    func testT27FinalRetriesThenReloadsSameModelWithPinnedLanguageAndOneJournalCommit() async throws {
        let recovery = T27MemoryRecovery(), gate = T14Gate()
        let f = try T19Fixture(mode: .automatic, cancelGate: gate, recovery: recovery)
        await f.start(); try f.send(400); f.pause()
        _ = try await f.engine.request(0)
        try await f.engine.respond(0, .partial, "임시", language: "ko")
        try await f.engine.fail(0, .inferenceFailed)
        _ = try await f.engine.request(1)
        try await f.engine.fail(1, .invalidResponse)
        try await gate.wait()
        let before = await f.engine.requests.count; XCTAssertEqual(before, 2)
        let loading = await f.engine.loaded; XCTAssertTrue(loading.isEmpty)
        await gate.release()
        let restarted = try await f.engine.request(2)
        XCTAssertEqual(restarted.context.session.model, f.session.model)
        XCTAssertEqual(restarted.context.session.languageMode, .korean)
        XCTAssertNotEqual(restarted.context.session.operationID, f.session.operationID)
        try await f.engine.respond(2, .final, "복구된 문장", language: "ko")
        _ = try await f.observed.wait { $0.finals.count == 1 }
        f.finish(); await f.coordinator.waitUntilSettled()
        let result = await f.coordinator.currentSnapshot()
        XCTAssertEqual(result.phase, .finished); XCTAssertEqual(result.automaticRestarts, 1)
        XCTAssertEqual(result.recovery?.pending, 0)
        let records = await f.repository.records; XCTAssertEqual(records.count, 1)
        let model = await f.engine.loaded; XCTAssertEqual(model, [f.session.model])
        let ledger = await recovery.document; XCTAssertEqual(ledger?.language?.rawValue, "ko")
    }

    func testT27PartialFailureIsDiscardedAndSilentFinalIsDurableCoverage() async throws {
        let recovery = T27MemoryRecovery()
        let f = try T19Fixture(mode: .automatic, recovery: recovery)
        await f.start(); try f.send(2_000)
        _ = try await f.engine.request(0); try await f.engine.fail(0, .inferenceFailed)
        f.pause(); _ = try await f.engine.request(1); try await f.engine.empty(1)
        _ = try await f.observed.wait { $0.recovery?.pending == 0 }
        f.finish(); await f.coordinator.waitUntilSettled()
        let result = await f.coordinator.currentSnapshot()
        XCTAssertNil(result.failure); XCTAssertEqual(result.automaticRestarts, 0)
        let recorded = await recovery.value()
        let doc = try XCTUnwrap(recorded)
        XCTAssertEqual(doc.entries.count, 1); XCTAssertEqual(doc.entries[0].state, .complete)
        XCTAssertTrue(doc.entries[0].segments.isEmpty); XCTAssertNil(doc.language)
    }

    func testT27CircuitBreakerKeepsIngestingAndRecordsAllFailedWindows() async throws {
        let recovery = T27MemoryRecovery()
        let f = try T19Fixture(recovery: recovery)
        await f.start()
        var request = 0
        for window in 0..<3 {
            try f.send(400); f.pause()
            let attempts = window < 2 ? 3 : 2
            for _ in 0..<attempts {
                _ = try await f.engine.request(request)
                try await f.engine.fail(request, .inferenceFailed); request += 1
            }
            if window < 2 { _ = try await f.observed.wait { $0.phase == .listening && $0.pendingFinals == 0 } }
        }
        _ = try await f.observed.wait { $0.phase == .failed }
        try f.send(400); f.pause()
        _ = try await f.observed.wait { $0.inputMilliseconds == 1_600 && $0.recovery?.pending == 4 }
        f.finish(); await f.coordinator.waitUntilSettled()
        let state = await f.coordinator.currentSnapshot()
        XCTAssertEqual(state.automaticRestarts, 2); XCTAssertEqual(state.failure, .inferenceFailed)
        let count = await f.engine.requests.count; XCTAssertEqual(count, 8)
        XCTAssertTrue(state.cleanupComplete)
    }

    func testT27BackpressureDefersOldQueuedWindowButPreservesCurrentSpeech() async throws {
        let recovery = T27MemoryRecovery()
        let f = try T19Fixture(capacity: 1, recovery: recovery)
        await f.start(); try f.send(400); f.pause(); _ = try await f.engine.request(0)
        try f.send(400); f.pause(); try f.send(400); f.pause()
        _ = try await f.observed.wait { $0.recovery?.pending == 3 }
        try await f.engine.respond(0, .final, "처음")
        let current = try await f.engine.request(1)
        XCTAssertEqual(current.context.mediaStart.rawValue, 800)
        try await f.engine.respond(1, .final, "현재")
        _ = try await f.observed.wait { $0.finals.count == 2 }
        f.finish(); await f.coordinator.waitUntilSettled()
        let state = await f.coordinator.currentSnapshot()
        XCTAssertNil(state.failure); XCTAssertEqual(state.recovery?.pending, 1)
        let recorded = await recovery.value()
        let doc = try XCTUnwrap(recorded)
        XCTAssertEqual(doc.entries.filter { $0.state == .pending }.map(\.range.start), [400])
    }

    func testT27StorageFailureNeverRetriesAmbiguousJournalAppend() async throws {
        let recovery = T27MemoryRecovery()
        let f = try T19Fixture(journalFailure: true, recovery: recovery)
        await f.start(); try f.send(400); f.pause()
        _ = try await f.engine.request(0); try await f.engine.respond(0, .final, "저장할 문장")
        await f.coordinator.waitUntilSettled(); f.finish()
        let state = await f.coordinator.currentSnapshot()
        XCTAssertNotNil(state.storageWarning); XCTAssertEqual(state.automaticRestarts, 0)
        let attempts = await f.repository.appendAttempts; XCTAssertEqual(attempts, 1)
        let recorded = await recovery.value()
        let doc = try XCTUnwrap(recorded)
        XCTAssertEqual(doc.entries[0].state, .prepared)
        XCTAssertEqual(doc.entries[0].segments.map(\.text), ["저장할 문장"])
    }

    func testT27TimeoutWaitsForNativeCleanupAndIgnoresLateResult() async throws {
        let recovery = T27MemoryRecovery(), gate = T14Gate()
        let f = try T19Fixture(cancelGate: gate, recovery: recovery, timeout: .milliseconds(100))
        await f.start(); try f.send(400); f.pause(); _ = try await f.engine.request(0)
        try await gate.wait()
        try f.send(400); f.pause()
        _ = try await f.observed.wait { $0.inputMilliseconds == 800 }
        try await f.engine.respond(0, .final, "늦은 응답")
        f.finish()
        let before = await f.coordinator.currentSnapshot(); XCTAssertFalse(before.cleanupComplete)
        let loaded = await f.engine.loaded; XCTAssertTrue(loaded.isEmpty)
        await gate.release(); await f.coordinator.waitUntilSettled()
        let state = await f.coordinator.currentSnapshot()
        XCTAssertTrue(state.finals.isEmpty); XCTAssertEqual(state.recovery?.pending, 2)
        XCTAssertEqual(state.phase, .failed); XCTAssertTrue(state.cleanupComplete)
    }

    func testT27ExplicitCancellationLeavesPendingWithoutReload() async throws {
        let recovery = T27MemoryRecovery()
        let f = try T19Fixture(recovery: recovery)
        await f.start(); try f.send(400); f.pause(); _ = try await f.engine.request(0)
        await f.coordinator.cancel(); f.finish()
        let state = await f.coordinator.currentSnapshot()
        XCTAssertEqual(state.phase, .cancelled); XCTAssertEqual(state.recovery?.pending, 1)
        let count = await f.engine.requests.count; XCTAssertEqual(count, 1)
        XCTAssertEqual(state.automaticRestarts, 0)
    }
}

extension LiveSTTCoordinatorTests {
    func testT27SlowJournalAfterFinalIsNotMisclassifiedAsInferenceTimeout() async throws {
        let recovery = T27MemoryRecovery(), gate = T14Gate()
        let f = try T19Fixture(journalGate: gate, recovery: recovery, timeout: .milliseconds(100))
        await f.start(); try f.send(400); f.pause(); _ = try await f.engine.request(0)
        try await f.engine.respond(0, .final, "저장 대기")
        try await gate.wait(); try await Task.sleep(for: .milliseconds(180))
        let during = await f.coordinator.currentSnapshot(); XCTAssertNil(during.failure)
        let counts = await f.engine.counts; XCTAssertEqual(counts[2], 0)
        await gate.release()
        _ = try await f.observed.wait { $0.finals.count == 1 }
        f.finish(); await f.coordinator.waitUntilSettled()
        let done = await f.coordinator.currentSnapshot(); XCTAssertNil(done.failure)
    }

    func testT27DroppedInputIsPersistedSeparatelyFromSuccessfulWindow() async throws {
        let recovery = T27MemoryRecovery()
        let f = try T19Fixture(recovery: recovery)
        await f.start(); try f.send(400); f.pause(); _ = try await f.engine.request(0)
        try await f.engine.respond(0, .final, "앞")
        _ = try await f.observed.wait { $0.finals.count == 1 }
        try f.send(400, at: 16_000, sequence: 3); f.pause()
        _ = try await f.engine.request(1); try await f.engine.respond(1, .final, "뒤")
        _ = try await f.observed.wait { $0.finals.count == 2 }
        f.finish(); await f.coordinator.waitUntilSettled()
        let recorded = await recovery.value(), doc = try XCTUnwrap(recorded)
        XCTAssertEqual(doc.entries.filter { $0.state == .pending }.map(\.range), [try .init(400, 1_000)])
        XCTAssertEqual(doc.entries.filter { $0.state == .complete }.count, 2)
    }

    func testT27LedgerFailureStopsSpeechWithoutPublishingOrRetrying() async throws {
        let recovery = T27MemoryRecovery(failPrepare: true)
        let f = try T19Fixture(recovery: recovery)
        await f.start(); try f.send(400); f.pause(); _ = try await f.engine.request(0)
        try await f.engine.respond(0, .final, "보존해야 할 오디오")
        await f.coordinator.waitUntilSettled(); f.finish()
        let state = await f.coordinator.currentSnapshot()
        XCTAssertNotNil(state.storageWarning); XCTAssertTrue(state.finals.isEmpty)
        let records = await f.repository.records; XCTAssertTrue(records.isEmpty)
        let requests = await f.engine.requests; XCTAssertEqual(requests.count, 1)
    }
}

private actor T27MemoryRecovery: SpeechRecoveryRecording {
    let failPrepare: Bool
    init(failPrepare: Bool = false) { self.failPrepare = failPrepare }
    var document: SpeechRecoveryDocument?
    func value() -> SpeechRecoveryDocument? { document }
    func initialize(_ session: STTSessionConfiguration, at: SessionLocation) throws {
        document = SpeechRecoveryDocument(session: session, language: session.languageMode == .automatic ? nil : try .init(session.languageMode == .korean ? "ko" : "en"))
    }
    func observe(windows: [SpeechRecoveryRange], missing: [SpeechRecoveryRange], through: Int64, ended: Bool, at: SessionLocation) throws -> SpeechRecoverySummary {
        for range in windows { document!.register(range) }
        for range in missing { try document!.addMissing(range) }
        document!.scannedThrough = through
        return document!.summary
    }
    func pinLanguage(_ language: LanguageCode, at: SessionLocation) { document!.language = language }
    func prepare(_ segments: [TranscriptSegment], range: SpeechRecoveryRange, language: LanguageCode?, at: SessionLocation) throws {
        if failPrepare { throw StorageError(.jsonlAppendFailed) }
        let i = try XCTUnwrap(document!.entries.firstIndex { $0.range == range })
        document!.entries[i].segments = segments; document!.entries[i].state = .prepared
        if let language { document!.language = language }
    }
    func complete(_ range: SpeechRecoveryRange, at: SessionLocation) throws -> SpeechRecoverySummary {
        let i = try XCTUnwrap(document!.entries.firstIndex { $0.range == range })
        document!.entries[i].state = .complete
        return document!.summary
    }
}
