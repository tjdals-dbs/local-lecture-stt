import XCTest
@testable import LocalLectureSTT

final class LiveSTTCoordinatorTests: XCTestCase {
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
    let continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation
    private var frame: Int64 = 0
    private var sequence: UInt64 = 0
    init(capacity: Int = 4, mode: LanguageMode = .korean, journalFailure: Bool = false,
         journalGate: T14Gate? = nil, cancelGate: T14Gate? = nil,
         startGate: T14Gate? = nil, startFailure: STTErrorCode? = nil,
         converter: any SpeechPCMConverting = T19Passthrough()) throws {
        session = try STTTestFixture.session(mode: mode)
        engine = try T19ControlledEngine(cancelGate: cancelGate, startGate: startGate, startFailure: startFailure)
        repository = T19Repository(failure: journalFailure, gate: journalGate)
        let location = SessionLocation(rootID: StorageRootID(), sessionID: session.sessionID,
            folderName: SessionFolderName(sessionID: session.sessionID, createdAt: AbsoluteTime(Date()), timeZone: .gmt))
        let observed = observed
        coordinator = LiveSTTCoordinator(engine: engine, session: session, repository: repository,
            location: location, converter: converter, detector: T19Detector(),
            maximumPendingFinals: capacity, publish: { await observed.append($0) })
        let pair = AsyncThrowingStream<PCMChunk, Error>.makeStream()
        continuation = pair.continuation
        handle = CaptureHandle(generation: 1, device: .init(identity: "test", displayName: "test"),
            recordingPCM: .init { $0.finish() }, speechPCM: pair.stream,
            events: .init { $0.finish() }, inputSignalStates: .init { $0.finish() })
        handle.timeline.recordOrigin(0)
    }
    func start() async { await coordinator.start(handle) }
    func send(_ ms: Int, voice: Bool = true, at: Int64? = nil, sequence: UInt64? = nil) throws {
        frame = at ?? frame
        self.sequence = sequence ?? self.sequence
        continuation.yield(try PCMChunk(generation: 1, sequence: self.sequence,
            format: PCMFormatDescription(sampleRate: 16_000, channelCount: 1), frameCount: ms * 16,
            sourceSampleTime: frame, samples: Array(repeating: voice ? 0.2 : 0, count: ms * 16)))
        frame += Int64(ms * 16); self.sequence += 1
    }
    func finish() { continuation.finish() }
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
    func load(_ model: STTModelConfiguration) async throws {}
    func start(_ session: STTSessionConfiguration) async throws {
        counts[0] += 1
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
