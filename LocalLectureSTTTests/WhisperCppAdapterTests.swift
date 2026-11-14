import Foundation
import whisper
import XCTest
@testable import LocalLectureSTT

final class WhisperCppAdapterTests: XCTestCase {
    private func settings(_ text: String? = nil, temperature: Double = 0, timestamps: Bool = true) -> WhisperDecodeSettings {
        .init(language: "ko", detectLanguage: false, temperature: temperature, timestamps: timestamps, promptText: text)
    }

    func testLinkedVersionParametersAndCallbackPolarity() throws {
        XCTAssertEqual(String(cString: whisper_version()), "1.9.5-dev")
        let entered = expectation(description: "encoder begin"), aborted = expectation(description: "one observed abort")
        let control = NativeDecodeControl(entered: { entered.fulfill() }, observed: { aborted.fulfill() })
        let p = try NativeWhisperBackend.parameters(settings(temperature: 0.25, timestamps: false), control: control)
        XCTAssertEqual(p.strategy, WHISPER_SAMPLING_GREEDY)
        XCTAssertEqual(p.n_threads, 4); XCTAssertEqual(p.temperature, 0.25); XCTAssertEqual(p.temperature_inc, 0)
        XCTAssertEqual(p.greedy.best_of, 1); XCTAssertTrue(p.no_timestamps); XCTAssertFalse(p.token_timestamps)
        XCTAssertFalse(p.translate); XCTAssertFalse(p.detect_language); XCTAssertTrue(p.no_context); XCTAssertTrue(p.carry_initial_prompt)
        XCTAssertNotNil(p.new_segment_callback); XCTAssertEqual(p.new_segment_callback_user_data, p.abort_callback_user_data)
        XCTAssertEqual(p.encoder_begin_callback_user_data, p.abort_callback_user_data)
        XCTAssertEqual(p.encoder_begin_callback?(nil, nil, p.encoder_begin_callback_user_data), true)
        XCTAssertEqual(p.abort_callback?(p.abort_callback_user_data), false)
        control.fail(.invalidResponse); control.fail(.cancelled)
        XCTAssertEqual(p.abort_callback?(p.abort_callback_user_data), true)
        XCTAssertEqual(p.abort_callback?(p.abort_callback_user_data), true)
        XCTAssertThrowsError(try control.check()) { XCTAssertEqual($0 as? STTEngineError, .init(.invalidResponse)) }
        wait(for: [entered, aborted], timeout: 1)
        XCTAssertThrowsError(try NativeWhisperBackend.parameters(settings(temperature: .nan), control: control))
    }

    func testCheckedDetectorStatusAndSupportedNativeIDs() throws {
        for name in ["en", "ko"] {
            XCTAssertEqual(try NativeWhisperBackend.detectedLanguage(status: 0, id: whisper_lang_id(name)), name)
        }
        for pair: (Int32, Int32) in [(-3, 0), (0, -1), (0, .max), (0, whisper_lang_id("fr"))] {
            XCTAssertThrowsError(try NativeWhisperBackend.detectedLanguage(status: pair.0, id: pair.1))
        }
    }

    /// A locally generated vocabulary-only model uses the upstream n_loaded == 0
    /// test convention. No weights, encoder state, network or model fixture required.
    private static func vocabularyContext() throws -> OpaquePointer {
        var data = Data()
        func append(_ word: UInt32) { withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) } }
        for word: UInt32 in [0x67676d6c, 51866, 16, 32, 1, 4, 448, 32, 1, 4, 128, 1, 128, 201] { append(word) }
        data.append(Data(count: 128 * 201 * 4))
        let vocabulary = [" x", "테", "스트", "!"]
        append(UInt32(vocabulary.count))
        for word in vocabulary { append(UInt32(word.utf8.count)); data.append(contentsOf: word.utf8) }
        var options = whisper_context_default_params()
        options.use_gpu = false
        return try data.withUnsafeMutableBytes { bytes in
            try XCTUnwrap(whisper_init_from_buffer_with_params_no_state(bytes.baseAddress, bytes.count, options))
        }
    }

    func testLinkedNativeTokenizerMultibyteBoundaryResetAndNoByteLoss() throws {
        let ctx = try Self.vocabularyContext()
        defer { whisper_free(ctx) }
        XCTAssertEqual(try NativeWhisperBackend.promptTokens(ctx, settings: settings("테스트!")), [1, 2, 3])
        XCTAssertEqual(try NativeWhisperBackend.promptTokens(ctx, settings: settings(String(repeating: " x", count: 223))), Array(repeating: 0, count: 223))
        for bad in [String(repeating: " x", count: 224), "테스트?", "테\0스트"] {
            XCTAssertThrowsError(try NativeWhisperBackend.promptTokens(ctx, settings: settings(bad)))
        }
        XCTAssertThrowsError(try NativeWhisperBackend.promptTokens(ctx, settings: settings(" x", temperature: 0.5)))
        for absent: String? in [nil, ""] {
            XCTAssertEqual(try NativeWhisperBackend.promptTokens(ctx, settings: settings(absent)), [])
        }
    }

    func testBoundedCallbackConsumerJoinsBeforeReturningFirstNativeFailure() async throws {
        let first = T14Gate()
        let published = expectation(description: "native returned after publishing replacement snapshots")
        let allowed = DispatchSemaphore(value: 0)
        let native = NativeWhisperBackend()
        let recorder = SnapshotRecorder()
        let decode = Task {
            try await native.withNativeCallbacks(partial: { value in
                await recorder.append(value.text)
                if value.text == "one" { await first.hold() }
            }) { control in
                control.publish(.init(text: "one", intervals: [], language: "en"))
                guard allowed.wait(timeout: .now() + 30) == .success else { throw STTEngineError(.inferenceFailed) }
                control.publish(.init(text: "one two", intervals: [], language: "en"))
                control.publish(.init(text: "one two three", intervals: [], language: "en"))
                published.fulfill()
                throw STTEngineError(.invalidResponse)
            }
        }
        addTeardownBlock { allowed.signal(); await first.release(); _ = await decode.result }
        try await first.wait(); allowed.signal()
        await fulfillment(of: [published], timeout: 5)
        let held = await recorder.values
        XCTAssertEqual(held, ["one"])
        decode.cancel()
        await first.release()
        do { _ = try await decode.value; XCTFail() }
        catch let error as STTEngineError { XCTAssertEqual(error.code, .invalidResponse) }
        let values = await recorder.values
        XCTAssertEqual(values, ["one", "one two three"])
    }

    func testTimestampTickBoundsOverflowAndSessionOffset() throws {
        let f = try IntervalFixture<WhisperCppProfile>()
        let session = f.session(try f.model())
        let request = try STTInferenceRequest(session: session, requestID: STTRequestID(UUID()), sequence: 0,
            mediaStart: MediaMilliseconds(5000), audio: .init(format: STTInputFormat(), frameCount: 1600, samples: Array(repeating: 0, count: 1600)))
        func seconds(_ ticks: Int64) throws -> Double { try NativeDecodeControl.seconds(ticks: ticks, duration: 100) }
        let interval = try WhisperInterval(start: seconds(1), end: seconds(10), text: "a")
        let segments = try WhisperCppSTTEngine.segments(.init(text: "a", intervals: [interval], language: "en"), request: request)
        XCTAssertEqual(segments.first?.start.rawValue, 5010); XCTAssertEqual(segments.first?.end.rawValue, 5100)
        XCTAssertEqual(try seconds(0), 0)
        for value: Int64 in [-1, 11, .max, .min] { XCTAssertThrowsError(try seconds(value)) }
        XCTAssertThrowsError(try WhisperCppSTTEngine.segments(.init(text: "aa", intervals: [interval, interval], language: nil), request: request))
    }

    func testHeaderRequiresArchitecturePrecisionVocabularyAndExactSize() throws {
        let file = tmpfile()!
        defer { fclose(file) }
        let fd = fileno(file)
        var words: [UInt32] = [0x67676d6c, 51866, 1500, 1280, 20, 32, 448, 1280, 20, 32, 128, 1, 128, 201]
        var vocab: UInt32 = 50257
        XCTAssertEqual(pwrite(fd, &words, 56, 0), 56)
        XCTAssertThrowsError(try WhisperCppModelValidator.checkHeader(fd, size: WhisperCppModelValidator.size))
        XCTAssertEqual(pwrite(fd, &vocab, 4, 56 + 128 * 201 * 4), 4)
        XCTAssertThrowsError(try WhisperCppModelValidator.checkHeader(fd, size: 56))
        try WhisperCppModelValidator.checkHeader(fd, size: WhisperCppModelValidator.size)
        for i in [0, 1, 4, 6, 10, 11, 12] {
            var bad = words
            bad[i] = 7
            XCTAssertEqual(pwrite(fd, &bad, 56, 0), 56)
            XCTAssertThrowsError(try WhisperCppModelValidator.checkHeader(fd, size: WhisperCppModelValidator.size))
        }
    }

    func testNativeLoadCancellationJoinsLateAllocationAndExactlyOneFree() async throws {
        let f = try IntervalFixture<WhisperCppProfile>()
        try await f.install()
        let entered = expectation(description: "native context allocated")
        let release = DispatchSemaphore(value: 0)
        let freed = expectation(description: "exactly one free")
        let calls = NativeWhisperCalls(create: { _, _ in
            let ctx = try Self.vocabularyContext()
            entered.fulfill()
            guard release.wait(timeout: .now() + 30) == .success else {
                whisper_free(ctx); throw STTEngineError(.loadFailed)
            }
            return ctx
        }, free: { ctx in whisper_free(ctx); freed.fulfill() })
        let engine = try WhisperCppSTTEngine(resolve: { try await f.repository.acquireUseLease($0) }) {
            NativeWhisperBackend(calls: calls)
        }
        let model = try f.model()
        let load = Task { try await engine.load(model) }
        await fulfillment(of: [entered], timeout: 10)
        load.cancel()
        do { _ = try await f.repository.prepareDeletion(f.descriptor.key); XCTFail("load still owns its claim") }
        catch let error as ModelOperationFailure { XCTAssertEqual(error.cause, .busy) }
        release.signal()
        do { try await load.value; XCTFail() }
        catch let error as STTEngineError { XCTAssertEqual(error.code, .cancelled) }
        await engine.unload()
        await fulfillment(of: [freed], timeout: 5)
        let entry = try await f.repository.validate(f.descriptor.key)
        XCTAssertEqual(entry.state, .usable)
    }

    func testNativeCallRetainsPCMUTF8PromptAndControlUntilActualReturn() async throws {
        let f = try IntervalFixture<WhisperCppProfile>()
        try await f.install()
        let entered = expectation(description: "full entered"), abort = expectation(description: "foreign hook observed cancel")
        let release = DispatchSemaphore(value: 0)
        let cancelFlag = expectation(description: "operation cancellation flag set")
        let calls = NativeWhisperCalls(create: { _, _ in try Self.vocabularyContext() }, full: { _, p, pcm, count in
            entered.fulfill()
            guard release.wait(timeout: .now() + 30) == .success else { return -9 }
            XCTAssertEqual(count, 1600); XCTAssertEqual(pcm?[1599], 0.125)
            XCTAssertEqual(String(cString: p.language), "ko")
            XCTAssertEqual(p.prompt_n_tokens, 3)
            XCTAssertEqual(Array(UnsafeBufferPointer(start: p.prompt_tokens, count: 3)), [1,2,3])
            XCTAssertFalse(p.detect_language); XCTAssertFalse(p.translate); XCTAssertTrue(p.no_timestamps)
            XCTAssertEqual(p.abort_callback?(p.abort_callback_user_data), true)
            return 0  // native encoder veto can break the loop and return zero
        })
        let engine = try WhisperCppSTTEngine(resolve: { try await f.repository.acquireUseLease($0) }) {
            NativeWhisperBackend(calls: calls, cancellationRequested: { cancelFlag.fulfill() }, abortObserved: { abort.fulfill() })
        }
        let model = try f.model(partials: false, timestamps: false)
        try await engine.load(model)
        let session = f.session(model, language: .korean)
        try await engine.start(session)
        let feed = try await engine.infer(.init(session: session, requestID: STTRequestID(UUID()), sequence: 0,
            mediaStart: MediaMilliseconds(5000), audio: .init(format: STTInputFormat(), frameCount: 1600,
                samples: Array(repeating: 0.125, count: 1600)), decodingHints: .init(promptText: "테스트!")))
        await fulfillment(of: [entered], timeout: 10)
        // end/cancel are asynchronous; wait for the operation's flag before
        // letting the synchronous call inspect its borrowed buffers and return.
        let cancelling = Task { await feed.withdraw() }
        await fulfillment(of: [cancelFlag], timeout: 5)
        XCTAssertEqual(feed.observation().terminals, 0)
        do { _ = try await f.repository.prepareDeletion(f.descriptor.key); XCTFail() }
        catch let error as ModelOperationFailure { XCTAssertEqual(error.cause, .busy) }
        release.signal()
        await cancelling.value
        await fulfillment(of: [abort], timeout: 5)
        XCTAssertEqual(feed.observation().latest?.kind, .cancelled)
        XCTAssertEqual(feed.observation().terminals, 1)
        try await engine.end(); await engine.unload()
    }

    func testCancelledControlsJoinHeldCleanupAndModelClaim() async throws {
        let fixture = try IntervalFixture<WhisperCppProfile>()
        try await fixture.install()
        let gate = T14Gate(), backend = T14Backend(unloadGate: gate)
        let joins = expectation(description: "both callers joined actual cleanup")
        joins.expectedFulfillmentCount = 2
        let engine = try fixture.engine(backend, cleanupJoinAcknowledged: { joins.fulfill() })
        let model = try fixture.model()
        try await engine.load(model); try await engine.start(fixture.session(model))
        let unloading = Task { await engine.unload() }
        addTeardownBlock { await gate.release(); await unloading.value }
        try await gate.wait()
        let end = Task { try await engine.end() }, cancel = Task { try await engine.cancel() }
        end.cancel(); cancel.cancel()
        await fulfillment(of: [joins], timeout: 5)
        let count = await engine.cleanupJoiners
        XCTAssertEqual(count, 2)
        do { _ = try await fixture.repository.prepareDeletion(fixture.descriptor.key); XCTFail("Claim released during cleanup") }
        catch let error as ModelOperationFailure { XCTAssertEqual(error.cause, .busy) }
        await gate.release(); try await end.value; try await cancel.value; await unloading.value
        try await engine.load(model); await engine.unload()
        let calls = await backend.counts
        XCTAssertEqual(calls, [2, 0, 2])
    }
}

private actor SnapshotRecorder {
    private(set) var values = [String]()
    func append(_ text: String) { values.append(text) }
}
