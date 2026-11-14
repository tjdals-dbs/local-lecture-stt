import Foundation
import XCTest
@testable import LocalLectureSTT

private actor T14Gate {
    let entered = XCTestExpectation(description: "backend acknowledged boundary")
    private var held = true
    private var arrived = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        if !arrived { arrived = true; entered.fulfill() }
        if held { await withCheckedContinuation { waiters.append($0) } }
    }
    func wait() async throws {
        guard await XCTWaiter.fulfillment(of: [entered], timeout: 5) == .completed else { throw STTEngineError(.inferenceFailed) }
    }
    func release() { held = false; let joined = waiters; waiters = []; joined.forEach { $0.resume() } }
}
private actor T14Backend: WhisperKitBackend {
    let loadGate: T14Gate?
    let decodeGates: [T14Gate]
    let unloadGate: T14Gate?
    var outputs: [WhisperSnapshot]
    var loadError: STTEngineError?
    var unloadError: STTEngineError?
    var counts = [0, 0, 0]
    var settings: [WhisperDecodeSettings] = []
    let cancellation = XCTestExpectation(description: "SDK task cancellation acknowledged")
    var callbacks: [@Sendable (WhisperSnapshot) async -> Void] = []
    init(loadGate: T14Gate? = nil, decodeGates: [T14Gate] = [], unloadGate: T14Gate? = nil,
         outputs: [WhisperSnapshot] = [], loadError: STTEngineError? = nil, unloadError: STTEngineError? = nil) {
        self.loadGate = loadGate; self.decodeGates = decodeGates; self.unloadGate = unloadGate
        self.outputs = outputs; self.loadError = loadError; self.unloadError = unloadError
    }
    func load(_ lease: ModelUseLease) async throws {
        counts[0] += 1; await loadGate?.hold()
        if let loadError { throw loadError }; try Task.checkCancellation(); try lease.check()
    }
    func decode(_ audio: STTInferenceAudio, settings value: WhisperDecodeSettings,
                partial: @escaping @Sendable (WhisperSnapshot) async -> Void) async throws -> WhisperSnapshot {
        let index = counts[1]; counts[1] += 1; settings.append(value); callbacks.append(partial)
        if index < decodeGates.count {
            await withTaskCancellationHandler { await decodeGates[index].hold() }
            onCancel: { cancellation.fulfill() }
        }
        try Task.checkCancellation()
        return index < outputs.count ? outputs[index] : .init(text: "hello", intervals: [], language: "en")
    }
    func waitForCancellation() async throws {
        guard await XCTWaiter.fulfillment(of: [cancellation], timeout: 5) == .completed else { throw STTEngineError(.inferenceFailed) }
    }
    func emit(_ value: WhisperSnapshot, at index: Int = 0) async { await callbacks[index](value) }
    func unload() async throws {
        counts[2] += 1; await unloadGate?.hold()
        if let unloadError { throw unloadError }
    }
    func releaseAll() async {
        await loadGate?.release(); for gate in decodeGates { await gate.release() }; await unloadGate?.release()
    }
}
private struct T14FixtureValidator: OfflineModelFormatValidating {
    func validate(_ descriptor: ModelPackageDescriptor, directory: ModelPackageDirectory) async throws {
        guard try directory.readMetadata("test.bin") == Data("synthetic".utf8) else { throw ModelRepositoryCode.incompatible }
    }
}
private struct T14References: ModelReferenceChecking {
    func references(to descriptor: ModelPackageDescriptor) async -> ModelReferenceReport { .init(sessions: [], warnings: []) }
}
private final class T14Fixture: @unchecked Sendable {
    let root = URL(fileURLWithPath: "/private/tmp/stt-t14-test-" + UUID().uuidString)
    let sources = ModelImportSources()
    let descriptor: ModelPackageDescriptor
    let repository: FileModelRepository
    init() throws {
        let root = self.root
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let data = Data("synthetic".utf8); try data.write(to: source.appendingPathComponent("test.bin"))
        descriptor = try .init(engine: WhisperKitSTTEngine.identity, modelID: ModelID("test-large"), revision: "fixture-v1",
            format: "whisperkit-coreml-v1", variant: "large-v3", quantization: "none", compute: WhisperKitSTTEngine.compute,
            licenseIdentifier: "LicenseRef-Test", licenseTextOrReference: "Generated test data", licenseProvenance: "this test",
            files: [ModelPayloadFile(path: "test.bin", byteCount: Int64(data.count), sha256: ModelPackageRules.sha256(data))])
        repository = FileModelRepository(storeURL: { root.appendingPathComponent("store") }, sources: sources,
            validator: T14FixtureValidator(), references: T14References())
    }
    func install() async throws {
        let source = await sources.register(root.appendingPathComponent("source"), start: { true }, stop: {})
        _ = try await repository.importPackage(from: source, descriptor: descriptor, origin: .suppliedLocal)
    }
    func engine(_ backend: T14Backend, capacity: Int = 2,
                cleanupJoinAcknowledged: @escaping @Sendable () -> Void = {}) throws -> WhisperKitSTTEngine {
        try .init(capacity: capacity, resolve: { [repository] in try await repository.acquireUseLease($0) },
                  cleanupJoinAcknowledged: cleanupJoinAcknowledged, makeBackend: { backend })
    }
    func model(partials: Bool = true, timestamps: Bool = true, compute: String = "default") throws -> STTModelConfiguration {
        try .init(engine: descriptor.engine, model: descriptor.model,
                  options: STTInferenceOptions(partialResults: partials, timestamps: timestamps, computeMode: compute))
    }
    func session(_ model: STTModelConfiguration, language: LanguageMode = .english) -> STTSessionConfiguration {
        .init(sessionID: SessionID(), operationID: STTOperationID(UUID()), model: model, languageMode: language)
    }
    func installed() -> URL { FileModelRepository.namespace(descriptor.key).reduce(root.appendingPathComponent("store")) { $0.appendingPathComponent($1) } }
    deinit { try? FileManager.default.removeItem(at: root) }
}

private func checkEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual, expected, file: file, line: line)
}

final class WhisperKitSTTEngineTests: XCTestCase {
    private func setup(_ backend: T14Backend = .init(), partials: Bool = true, language: LanguageMode = .english,
                       capacity: Int = 2) async throws -> (T14Fixture, WhisperKitSTTEngine, STTSessionConfiguration) {
        let fixture = try T14Fixture(); try await fixture.install()
        let engine = try fixture.engine(backend, capacity: capacity)
        addTeardownBlock { await backend.releaseAll(); await engine.unload(); _ = fixture.root }
        let model = try fixture.model(partials: partials); try await engine.load(model)
        let session = fixture.session(model, language: language); try await engine.start(session)
        return (fixture, engine, session)
    }
    private func request(_ session: STTSessionConfiguration, sequence: Int64 = 0, start: Int64 = 5000,
                         hints: STTDecodingHints? = nil) throws -> STTInferenceRequest {
        try .init(session: session, requestID: STTRequestID(UUID()), sequence: sequence, mediaStart: MediaMilliseconds(start),
                  audio: STTInferenceAudio(format: STTInputFormat(), frameCount: 16000, samples: [Float](repeating: 0.1, count: 16000)), decodingHints: hints)
    }
    private func terminal(_ feed: STTEventFeed) async throws -> STTResponse {
        var last: STTResponse?
        for await response in try feed.events() { last = response }
        return try XCTUnwrap(last)
    }
    private func expect(_ code: STTErrorCode, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(code)") }
        catch let value as STTEngineError { checkEqual(value.code, code) }
        catch { XCTFail("Unexpected \(error)") }
    }
    func testLegacyHintsAbsentRoundTripAndInitDecodeBounds() throws {
        let f = try T14Fixture(); let session = f.session(try f.model())
        let plain = try request(session)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        object.removeValue(forKey: "decodingHints")
        let decoded = try JSONDecoder().decode(STTInferenceRequest.self, from: JSONSerialization.data(withJSONObject: object))
        checkEqual(decoded, plain)
        let hinted = try request(session, hints: .init(promptText: "Core ML 한국어"))
        checkEqual(try JSONDecoder().decode(STTInferenceRequest.self, from: JSONEncoder().encode(hinted)), hinted)
        XCTAssertThrowsError(try STTDecodingHints(promptText: String(repeating: "가", count: 1366)))
        XCTAssertThrowsError(try STTDecodingHints(promptText: "a\0b"))
        XCTAssertNoThrow(try STTDecodingHints(promptText: String(repeating: "x", count: 4096)))
        XCTAssertThrowsError(try JSONDecoder().decode(STTDecodingHints.self, from: Data("{\"promptText\":\"\(String(repeating: "x", count: 4097))\"}".utf8)))
    }
    func testNonzeroOffsetCheckedRoundingAndWholeWindowRepresentation() throws {
        let f = try T14Fixture(); let req = try request(f.session(try f.model()))
        let valid = WhisperSnapshot(text: "ab", intervals: [.init(start: -0.0005, end: 0.4, text: "a"), .init(start: 0.4, end: 1.0005, text: "b")], language: "en")
        let segments = try WhisperKitSTTEngine.segments(valid, request: req)
        checkEqual(segments.map { $0.start.rawValue }, [5000, 5400]); checkEqual(segments.last?.end.rawValue, 6000)
        let whole = try WhisperKitSTTEngine.segments(.init(text: "partial", intervals: [], language: nil), request: req)
        checkEqual(whole.first?.start, req.context.mediaStart); checkEqual(whole.first?.end, req.context.mediaEnd)
        checkEqual(try WhisperKitSTTEngine.segments(.init(text: "", intervals: [], language: nil), request: req), [])
    }
    func testInvalidTimesOverlapMissingTextAndOutputBoundsFailTruthfully() throws {
        let f = try T14Fixture(); let req = try request(f.session(try f.model()))
        for pair in [(Double.nan,1.0), (0,Double.infinity),(-0.002,0.5),(0,1.002),(0.8,0.2)] {
            XCTAssertThrowsError(try WhisperKitSTTEngine.segments(.init(text: "a", intervals: [.init(start: pair.0, end: pair.1, text: "a")], language: nil), request: req))
        }
        XCTAssertThrowsError(try WhisperKitSTTEngine.segments(.init(text: "ab", intervals: [.init(start: 0, end: 0.8, text: "a"), .init(start: 0.7, end: 1, text: "b")], language: nil), request: req))
        XCTAssertThrowsError(try WhisperKitSTTEngine.segments(.init(text: "lost", intervals: [.init(start: 0, end: 1, text: "a")], language: nil), request: req))
        XCTAssertThrowsError(try WhisperKitSTTEngine.segments(.init(text: String(repeating: "x", count: 65537), intervals: [], language: nil), request: req))
        XCTAssertThrowsError(try WhisperKitSTTEngine.segments(.init(text: "a", intervals: Array(repeating: .init(start: 0, end: 0, text: "a"), count: 129), language: nil), request: req))
    }
    func testDisabledTimestampsPreserveWholeWindowText() throws {
        let f = try T14Fixture(); let req = try request(f.session(try f.model(timestamps: false)))
        let result = try WhisperKitSTTEngine.segments(.init(text: "speech", intervals: [.init(start: 0.1, end: 0.5, text: "speech")], language: nil), request: req)
        checkEqual(result.count, 1); checkEqual(result[0].start.rawValue, 5000); checkEqual(result[0].end.rawValue, 6000)
    }
    func testLoadStartInferenceEndReloadAndRetainedTerminal() async throws {
        let (f, engine, session) = try await setup()
        let feed = try await engine.infer(request(session)); try await engine.end()
        let final = try await terminal(feed); checkEqual(final.kind, .final); checkEqual(final.context.session, session)
        XCTAssertThrowsError(try feed.events())
        checkEqual(feed.observation().terminals, 1)
        await engine.unload(); try await engine.load(f.model()); try await engine.start(f.session(try f.model()))
    }
    func testModelAndComputeMismatchRejectBeforeBackendConstruction() async throws {
        let f = try T14Fixture(); try await f.install(); let backend = T14Backend(); let engine = try f.engine(backend)
        await expect(.unsupportedCapability) { try await engine.load(f.model(compute: "unknown")) }
        let bad = try STTModelConfiguration(engine: EngineIdentity(id: EngineID("other"), version: "v1"), model: f.descriptor.model, options: STTInferenceOptions())
        await expect(.unsupportedModel) { try await engine.load(bad) }
        checkEqual(await backend.counts, [0,0,0]); await engine.unload()
    }
    func testLeaseBlocksValidationDeletionAndReplacementUntilUnload() async throws {
        let (f, engine, _) = try await setup()
        do { _ = try await f.repository.prepareDeletion(f.descriptor.key); XCTFail() }
        catch let error as ModelOperationFailure { checkEqual(error.cause, .busy) }
        do { _ = try await f.repository.validate(f.descriptor.key); XCTFail() }
        catch let error as ModelOperationFailure { checkEqual(error.cause, .busy) }
        let source = await f.sources.register(f.root.appendingPathComponent("source"), start: { true }, stop: {})
        do { _ = try await f.repository.importPackage(from: source, descriptor: f.descriptor, origin: .suppliedLocal); XCTFail() }
        catch let error as ModelOperationFailure { checkEqual(error.cause, .busy) }
        await engine.unload()
        let entry = try await f.repository.validate(f.descriptor.key); checkEqual(entry.state, .usable)
    }
    func testLoadCallerCancellationJoinsBackendAndCleanupBeforeReuse() async throws {
        let f = try T14Fixture(); try await f.install(); let loadGate = T14Gate(), unloadGate = T14Gate()
        let backend = T14Backend(loadGate: loadGate, unloadGate: unloadGate); let engine = try f.engine(backend)
        addTeardownBlock { await backend.releaseAll(); await engine.unload() }
        let loading = Task { try await engine.load(f.model()) }
        do { try await loadGate.wait(); loading.cancel(); await loadGate.release(); try await unloadGate.wait()
            await expect(.busy) { try await engine.load(f.model()) }
            await unloadGate.release(); await expect(.cancelled) { try await loading.value }
            try await engine.load(f.model()); await engine.unload()
            checkEqual(await backend.counts, [2,0,2])
        } catch { await backend.releaseAll(); loading.cancel(); _ = try? await loading.value; throw error }
    }
    func testRootMutationDuringLoadCannotBecomeTrusted() async throws {
        let f = try T14Fixture(); try await f.install(); let gate = T14Gate()
        let backend = T14Backend(loadGate: gate); let engine = try f.engine(backend)
        addTeardownBlock { await backend.releaseAll(); await engine.unload() }
        let loading = Task { try await engine.load(f.model()) }
        do {
            try await gate.wait()
            try Data("changed".utf8).write(to: f.installed().appendingPathComponent("test.bin"))
            await gate.release(); await expect(.loadFailed) { try await loading.value }
            checkEqual(await backend.counts, [1,0,1])
        } catch { await gate.release(); loading.cancel(); _ = try? await loading.value; throw error }
    }
    func testFirstLoadErrorSurvivesConcurrentUnloadAndCleanupDiagnostic() async throws {
        let f = try T14Fixture(); try await f.install(); let gate = T14Gate()
        let backend = T14Backend(loadGate: gate, loadError: STTEngineError(.unsupportedModel), unloadError: STTEngineError(.cleanupFailed))
        let engine = try f.engine(backend); addTeardownBlock { await backend.releaseAll(); await engine.unload() }
        let loading = Task { try await engine.load(f.model()) }
        do {
            try await gate.wait(); let unloading = Task { await engine.unload() }
            await gate.release(); await expect(.unsupportedModel) { try await loading.value }; await unloading.value
            checkEqual(await engine.cleanupDiagnostics, [STTEngineError(.cleanupFailed)])
            checkEqual(await backend.counts, [1,0,1])
        } catch { await gate.release(); loading.cancel(); _ = try? await loading.value; throw error }
    }
    func testFIFOBacklogQueuedWithdrawalAndNoSequenceConsumptionOnReject() async throws {
        let first = T14Gate(), second = T14Gate(); let backend = T14Backend(decodeGates: [first, second])
        let (_, engine, session) = try await setup(backend, capacity: 1)
        let a = try await engine.infer(request(session)); try await first.wait()
        let b = try await engine.infer(request(session, sequence: 1))
        await expect(.backlogFull) { _ = try await engine.infer(self.request(session, sequence: 2)) }
        await b.withdraw(); checkEqual(try await terminal(b).kind, .cancelled)
        let c = try await engine.infer(request(session, sequence: 2)); await first.release(); try await second.wait()
        let aResult = try await terminal(a); checkEqual(aResult.kind, .final)
        await second.release(); checkEqual(try await terminal(c).kind, .final)
        checkEqual(await backend.counts, [1,2,0])
    }
    func testWrongSessionSequenceAndFormatRejectWithoutWork() async throws {
        let (f, engine, session) = try await setup()
        await expect(.sessionMismatch) { _ = try await engine.infer(self.request(f.session(try f.model()))) }
        let req = try request(session)
        let format = try STTInputFormat(sampleRate: 48000)
        let audio = try STTInferenceAudio(format: format, frameCount: 48000, samples: [Float](repeating: 0, count: 48000))
        await expect(.unsupportedCapability) { _ = try await engine.infer(STTInferenceRequest(context: req.context, audio: audio)) }
        let feed = try await engine.infer(req); _ = try await terminal(feed)
        await expect(.invalidInput) { _ = try await engine.infer(req) }
    }
    func testAutomaticLanguagePinsWithDisabledPartialsAndResetsSession() async throws {
        let gate = T14Gate(); let backend = T14Backend(decodeGates: [gate], outputs: [.init(text: "안녕", intervals: [], language: "ko"), .init(text: "다음", intervals: [], language: "ko"), .init(text: "hello", intervals: [], language: "en")])
        let (f, engine, session) = try await setup(backend, partials: false, language: .automatic)
        let a = try await engine.infer(request(session)); try await gate.wait()
        await backend.emit(.init(text: "안", intervals: [], language: "ko")); checkEqual(a.observation().published, 0)
        await gate.release(); let result = try await terminal(a); checkEqual(result.detectedLanguage?.rawValue, "ko"); checkEqual(result.revision, 1)
        let b = try await engine.infer(request(session, sequence: 1)); _ = try await terminal(b)
        try await engine.end(); try await engine.start(f.session(try f.model(partials: false), language: .automatic))
        let nextSession = f.session(try f.model(partials: false), language: .automatic)
        try await engine.end(); try await engine.start(nextSession)
        let c = try await engine.infer(request(nextSession)); _ = try await terminal(c)
        let settings = await backend.settings
        XCTAssertTrue(settings[0].detectLanguage); checkEqual(settings[1].language, "ko"); XCTAssertFalse(settings[1].detectLanguage)
        XCTAssertNil(settings[2].language); XCTAssertTrue(settings[2].detectLanguage)
    }
    func testUnsupportedAndContradictoryLanguagesFailWithoutInventedSilenceLanguage() async throws {
        for value in ["fr", "ko"] {
            let backend = T14Backend(outputs: [.init(text: "speech", intervals: [], language: value)])
            let (_, engine, session) = try await setup(backend)
            let feed = try await engine.infer(request(session)); let result = try await terminal(feed)
            checkEqual(result.failure?.code, .invalidResponse); await engine.unload()
        }
        let backend = T14Backend(outputs: [.init(text: "", intervals: [], language: nil)])
        let (_, engine, session) = try await setup(backend, language: .automatic)
        let feed = try await engine.infer(request(session)); let result = try await terminal(feed)
        XCTAssertNil(result.detectedLanguage); checkEqual(result.segments, []); checkEqual(result.kind, .final)
    }
    func testHintsOptionsAndNilResetReachProductionBackendSeam() async throws {
        let backend = T14Backend(); let (_, engine, session) = try await setup(backend)
        let a = try await engine.infer(request(session, hints: .init(promptText: "Korean terms"))); _ = try await terminal(a)
        let b = try await engine.infer(request(session, sequence: 1)); _ = try await terminal(b)
        let settings = await backend.settings
        checkEqual(settings[0].promptText, "Korean terms"); XCTAssertNil(settings[1].promptText)
        checkEqual(settings[0].language, "en"); XCTAssertFalse(settings[0].detectLanguage)
        XCTAssertTrue(settings[0].timestamps); checkEqual(settings[0].temperature, 0)
    }
    func testActiveWithdrawalWaitsForDecodeReturnAndPreservesNextFIFO() async throws {
        let first = T14Gate(), second = T14Gate(); let backend = T14Backend(decodeGates: [first, second])
        let (_, engine, session) = try await setup(backend)
        let a = try await engine.infer(request(session)); try await first.wait()
        let b = try await engine.infer(request(session, sequence: 1))
        let withdrawal = Task { await a.withdraw() }
        // Cancellation acknowledgement comes from the owning engine through a barrier callback.
        try await backend.waitForCancellation()
        checkEqual(a.observation().terminals, 0)
        await first.release(); await withdrawal.value; try await second.wait()
        checkEqual(try await terminal(a).kind, .cancelled)
        await second.release(); checkEqual(try await terminal(b).kind, .final)
    }
    func testLateDuplicateCallbacksCannotPublishIntoNextRequestOrSession() async throws {
        let gate = T14Gate(); let backend = T14Backend(decodeGates: [gate])
        let (f, engine, session) = try await setup(backend)
        let feed = try await engine.infer(request(session)); try await gate.wait()
        await backend.emit(.init(text: "one", intervals: [], language: "en"))
        await backend.emit(.init(text: "two", intervals: [], language: "en"))
        checkEqual(feed.observation().published, 2)
        await gate.release(); _ = try await terminal(feed); try await engine.end()
        let fresh = f.session(try f.model()); try await engine.start(fresh)
        await backend.emit(.init(text: "stale", intervals: [], language: "ko"))
        checkEqual(feed.observation().terminals, 1)
        let next = try await engine.infer(request(fresh)); checkEqual(try await terminal(next).kind, .final)
    }
    func testRealFormatValidatorRejectsSyntheticPackageAndMissingAssets() async throws {
        let f = try T14Fixture()
        do { try await WhisperKitModelValidator().validate(f.descriptor, directory: ModelPackageDirectory(url: f.root.appendingPathComponent("source"))); XCTFail() }
        catch let error as ModelRepositoryCode { checkEqual(error, .incompatible) }
    }
    func testBenchmarkSchemaRTFWarmupAndUnavailableMetrics() throws {
        let f = try T14Fixture(); let req = try request(f.session(try f.model()))
        let input = try STTBenchmarkInput(caseID: "fixture", provenance: "synthetic", sourceSHA256: String(repeating: "a", count: 64), pcmSHA256: STTBenchmarkInput.pcmDigest(req.audio.samples), audio: req.audio, mediaStart: req.context.mediaStart)
        checkEqual(try JSONDecoder().decode(STTBenchmarkInput.self, from: JSONEncoder().encode(input)), input)
        checkEqual(STTBenchmarkMeasurement.rtf(processing: 2, audio: 4), 0.5)
        XCTAssertNil(STTBenchmarkMeasurement.rtf(processing: nil, audio: 4)); XCTAssertNil(STTBenchmarkMeasurement.rtf(processing: 1, audio: 0))
        XCTAssertNil(STTBenchmarkMeasurement.rtf(processing: .nan, audio: 4))
    }
    func testConstructionCatalogAndCapabilityReadsNeverConstructBackend() async throws {
        let f = try T14Fixture(); let count = T14CounterClock()
        let engine = try WhisperKitSTTEngine(resolve: { _ in XCTFail("No load was requested"); throw STTEngineError(.loadFailed) },
            makeBackend: { _ = count.next(); return T14Backend() })
        checkEqual(engine.capabilities.inputFormats.count, 1)
        checkEqual(try await f.repository.catalog().entries, [])
        checkEqual(try await f.repository.inventory(), [])
        await engine.unload(); checkEqual(count.next(), 0)
    }
    func testBenchmarkCallerCancellationJoinsDecodeUnloadAndSampler() async throws {
        let f = try T14Fixture(); try await f.install(); let gate = T14Gate(); let backend = T14Backend(decodeGates: [gate])
        let engine = try f.engine(backend); addTeardownBlock { await backend.releaseAll(); await engine.unload() }
        let session = f.session(try f.model()); let req = try request(session)
        let input = try STTBenchmarkInput(caseID: "cancel", provenance: "synthetic", sourceSHA256: String(repeating: "a", count: 64), pcmSHA256: STTBenchmarkInput.pcmDigest(req.audio.samples), audio: req.audio, mediaStart: req.context.mediaStart)
        let memory = T14Memory(baseline: 10, peak: 20)
        let measuring = Task { await STTBenchmarkRunner().measure(engine: engine, input: input, session: session,
            repetition: 1, warmup: false, memory: memory, observe: { (.init(prewarmSeconds: nil, modelSeconds: nil), await engine.lastRequestTiming) }) }
        do {
            try await gate.wait(); measuring.cancel(); try await backend.waitForCancellation()
            checkEqual(memory.stops, 0); await gate.release()
            let result = await measuring.value; checkEqual(result.failure?.code, .cancelled)
            checkEqual(result.terminal?.kind, .cancelled); checkEqual(memory.stops, 1)
            checkEqual(await engine.phase, .unloaded)
        } catch { await backend.releaseAll(); measuring.cancel(); _ = await measuring.value; throw error }
    }

    func testReplacedInstallCannotRedirectInferenceOrCleanup() async throws {
        let gate = T14Gate(); let backend = T14Backend(decodeGates: [gate]); let (f, engine, session) = try await setup(backend)
        let feed = try await engine.infer(request(session)); try await gate.wait()
        let path = f.installed(), saved = f.root.appendingPathComponent("saved-model")
        try FileManager.default.moveItem(at: path, to: saved)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let marker = path.appendingPathComponent("unrelated.txt"); try Data("preserve".utf8).write(to: marker)
        await gate.release(); let result = try await terminal(feed); checkEqual(result.failure?.code, .inferenceFailed)
        try await engine.end(); await expect(.startFailed) { try await engine.start(session) }
        await engine.unload(); checkEqual(try String(contentsOf: marker, encoding: .utf8), "preserve")
        checkEqual(try Data(contentsOf: saved.appendingPathComponent("test.bin")), Data("synthetic".utf8))
    }
    func testBenchmarkInputRejectsTamperingAndOutputNeverOverwrites() throws {
        let f = try T14Fixture(); let session = f.session(try f.model()); let req = try request(session)
        let input = try STTBenchmarkInput(caseID: "io", provenance: "synthetic", sourceSHA256: String(repeating: "a", count: 64),
            pcmSHA256: STTBenchmarkInput.pcmDigest(req.audio.samples), audio: req.audio, mediaStart: req.context.mediaStart)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        object["pcmSHA256"] = String(repeating: "c", count: 64)
        XCTAssertThrowsError(try JSONDecoder().decode(STTBenchmarkInput.self, from: JSONSerialization.data(withJSONObject: object)))
        object["schemaVersion"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(STTBenchmarkInput.self, from: JSONSerialization.data(withJSONObject: object)))
        let report = STTBenchmarkReport(schemaVersion: 1, appVersion: "test", os: "test", hardware: "test", model: f.descriptor,
            input: input, settings: session, policy: "warmup excluded", memoryMethod: "unavailable", measurements: [], success: false)
        let output = try STTBenchmarkOutput(f.root.appendingPathComponent("output")); try output.write(report)
        let before = try Data(contentsOf: output.directory.appendingPathComponent("report.json"))
        XCTAssertThrowsError(try output.write(report)); XCTAssertThrowsError(try STTBenchmarkOutput(output.directory))
        checkEqual(try Data(contentsOf: output.directory.appendingPathComponent("report.json")), before)
        XCTAssertThrowsError(try STTBenchmarkOutput(f.root.appendingPathComponent("missing/child")))
    }

    func testOldLeaseReleaseCannotReleaseLaterClaim() async throws {
        let f = try T14Fixture(); try await f.install()
        let old = try await f.repository.acquireUseLease(f.descriptor.key); old.release()
        XCTAssertThrowsError(try old.check())
        let fresh = try await f.repository.acquireUseLease(f.descriptor.key)
        old.release(); try fresh.check()
        do { _ = try await f.repository.validate(f.descriptor.key); XCTFail() }
        catch let error as ModelOperationFailure { checkEqual(error.cause, .busy) }
        fresh.release(); checkEqual(try await f.repository.validate(f.descriptor.key).state, .usable)
    }

    func testReviewEndAndCancelledCancelJoinHeldUnloadCleanup() async throws {
        let fixture = try T14Fixture(); try await fixture.install()
        let cleanup = T14Gate(); let backend = T14Backend(unloadGate: cleanup)
        let joins = XCTestExpectation(description: "both control calls captured cleanup task")
        joins.expectedFulfillmentCount = 2
        let engine = try fixture.engine(backend, cleanupJoinAcknowledged: { joins.fulfill() })
        try await engine.load(fixture.model()); try await engine.start(fixture.session(try fixture.model()))
        let unloading = Task { await engine.unload() }
        var ending: Task<Void, Error>?, cancelling: Task<Void, Error>?
        do {
            try await cleanup.wait()
            ending = Task { try await engine.end() }
            cancelling = Task { try await engine.cancel() }
            cancelling?.cancel()
            guard await XCTWaiter.fulfillment(of: [joins], timeout: 5) == .completed else {
                throw STTEngineError(.cleanupFailed)
            }
            // The counters are actor-owned. Omitting the await decrements them before
            // this actor read can execute, so a premature return fails deterministically.
            checkEqual(await engine.cleanupJoiners, 2)
            checkEqual(await engine.phase, .unloading)
            checkEqual(await backend.counts, [1,0,1])
            do { _ = try await fixture.repository.validate(fixture.descriptor.key); XCTFail() }
            catch let error as ModelOperationFailure { checkEqual(error.cause, .busy) }
            await cleanup.release()
            try await ending?.value; try await cancelling?.value; await unloading.value
            checkEqual(await engine.cleanupJoiners, 0); checkEqual(await engine.phase, .unloaded)
            await engine.unload(); checkEqual(await backend.counts, [1,0,1])
            try await engine.load(fixture.model()); await engine.unload()
            checkEqual(await backend.counts, [2,0,2])
        } catch {
            await backend.releaseAll(); await unloading.value
            _ = try? await ending?.value; _ = try? await cancelling?.value
            await engine.unload(); throw error
        }
    }

    func testPromptTokenBudgetNilEmptyAndNoTruncation() throws {
        checkEqual(try SDKWhisperKitBackend.promptTokens(nil, encode: { _ in XCTFail(); return [] }), nil)
        checkEqual(try SDKWhisperKitBackend.promptTokens("", encode: { _ in XCTFail(); return [] }), nil)
        checkEqual(try SDKWhisperKitBackend.promptTokens("text", encode: { _ in [1,2] }), [1,2])
        checkEqual(try SDKWhisperKitBackend.promptTokens("text", encode: { _ in Array(repeating: 1, count: 111) })?.count, 111)
        XCTAssertThrowsError(try SDKWhisperKitBackend.promptTokens("text", encode: { _ in Array(repeating: 1, count: 112) }))
    }
    func testKoreanTemperatureAndTimestampOptionsAreFrozenAndNewSessionResetsHints() async throws {
        let f = try T14Fixture(); try await f.install(); let backend = T14Backend(outputs: [.init(text: "한국어 Core ML", intervals: [], language: "ko")])
        let engine = try f.engine(backend); addTeardownBlock { await backend.releaseAll(); await engine.unload() }
        let model = STTModelConfiguration(engine: f.descriptor.engine, model: f.descriptor.model,
            options: try STTInferenceOptions(partialResults: false, timestamps: false, temperature: 0.75))
        try await engine.load(model); let session = f.session(model, language: .korean); try await engine.start(session)
        await expect(.busy) { try await engine.load(f.model()) }
        await expect(.busy) { try await engine.start(session) }
        let feed = try await engine.infer(request(session)); checkEqual(try await terminal(feed).kind, .final)
        let settings = await backend.settings
        checkEqual(settings[0].language, "ko"); checkEqual(settings[0].temperature, 0.75)
        XCTAssertFalse(settings[0].timestamps); XCTAssertFalse(settings[0].detectLanguage)
    }
    func testUnloadDuringLoadJoinsExactlyOnceAndRejectsConcurrentPreparation() async throws {
        let f = try T14Fixture(); try await f.install(); let gate = T14Gate(), cleanup = T14Gate()
        let backend = T14Backend(loadGate: gate, unloadGate: cleanup); let engine = try f.engine(backend)
        addTeardownBlock { await backend.releaseAll(); await engine.unload() }
        let loading = Task { try await engine.load(f.model()) }
        do {
            try await gate.wait(); await expect(.busy) { try await engine.load(f.model()) }
            let unloading = Task { await engine.unload() }
            // Load worker only returns after its explicit acknowledged barrier is released.
            loading.cancel(); await gate.release(); try await cleanup.wait()
            let secondUnload = Task { await engine.unload() }; secondUnload.cancel()
            await expect(.busy) { try await engine.load(f.model()) }
            await cleanup.release(); _ = try? await loading.value; await unloading.value; await secondUnload.value
            checkEqual(await backend.counts, [1,0,1]); checkEqual(await engine.phase, .unloaded)
            try await engine.load(f.model())
        } catch { await backend.releaseAll(); loading.cancel(); _ = try? await loading.value; throw error }
    }
    func testCancelledControlCallerStillDrainsAcceptedWorkAndReleasesLeaseAfterUnload() async throws {
        let gate = T14Gate(), cleanup = T14Gate(); let backend = T14Backend(decodeGates: [gate], unloadGate: cleanup)
        let (f, engine, session) = try await setup(backend)
        let a = try await engine.infer(request(session)); try await gate.wait()
        let b = try await engine.infer(request(session, sequence: 1))
        let ending = Task { try await engine.end() }; ending.cancel()
        let cancelling = Task { try await engine.cancel() }; cancelling.cancel()
        try await backend.waitForCancellation()
        await backend.emit(.init(text: "late", intervals: [], language: "ko"))
        checkEqual(a.observation().published, 0)
        let unloading = Task { await engine.unload() }; unloading.cancel()
        await gate.release(); try await cleanup.wait()
        await expect(.busy) { try await engine.load(f.model()) }
        checkEqual(try await terminal(a).kind, .cancelled); checkEqual(try await terminal(b).kind, .cancelled)
        await cleanup.release(); try await ending.value; try await cancelling.value; await unloading.value
        checkEqual(await backend.counts, [1,1,1]); checkEqual(await engine.phase, .unloaded)
        let entry = try await f.repository.validate(f.descriptor.key); checkEqual(entry.state, .usable)
    }
    func testInvalidPartialStopsPublicationButJoinsActualWorkerAndAllowsReuse() async throws {
        let gate = T14Gate(); let backend = T14Backend(decodeGates: [gate])
        let (f, engine, session) = try await setup(backend)
        let feed = try await engine.infer(request(session)); try await gate.wait()
        await backend.emit(.init(text: "invalid language", intervals: [], language: "ko"))
        try await backend.waitForCancellation(); checkEqual(feed.observation().terminals, 0)
        await gate.release(); let response = try await terminal(feed)
        checkEqual(response.failure?.code, .invalidResponse); checkEqual(feed.observation().terminals, 1)
        try await engine.end(); try await engine.start(f.session(try f.model()))
    }
    func testPartialPublicationIsBoundedAndTerminalRetainedOnOverflow() async throws {
        let gate = T14Gate(); let backend = T14Backend(decodeGates: [gate]); let (_, engine, session) = try await setup(backend)
        let feed = try await engine.infer(request(session)); try await gate.wait()
        for _ in 0...256 { await backend.emit(.init(text: "snapshot", intervals: [], language: "en")) }
        try await backend.waitForCancellation(); await gate.release()
        let response = try await terminal(feed); checkEqual(response.failure?.code, .invalidResponse)
        checkEqual(feed.observation().published, 257); checkEqual(feed.observation().terminals, 1)
    }
    func testBenchmarkRunnerInjectedClockSamplerAndFailureCleanup() async throws {
        let f = try T14Fixture(); try await f.install(); let backend = T14Backend(); let engine = try f.engine(backend)
        let session = f.session(try f.model()); let req = try request(session)
        let input = try STTBenchmarkInput(caseID: "tiny", provenance: "synthetic", sourceSHA256: String(repeating: "a", count: 64),
            pcmSHA256: STTBenchmarkInput.pcmDigest(req.audio.samples), audio: req.audio, mediaStart: req.context.mediaStart)
        let clock = T14CounterClock(); let memory = T14Memory(baseline: 100, peak: 200)
        let measurement = await STTBenchmarkRunner(now: { clock.next() }).measure(engine: engine, input: input,
            session: session, repetition: 1, warmup: false, memory: memory,
            observe: { (.init(prewarmSeconds: 0.25, modelSeconds: 0.5), .init(sequence: 0, queueSeconds: 0.2, inferenceSeconds: 0.5)) })
        checkEqual(measurement.loadSeconds, 1); checkEqual(measurement.finalSeconds, 1); checkEqual(measurement.rtf, 0.5)
        checkEqual(measurement.queueSeconds, 0.2); checkEqual(measurement.prewarmSeconds, 0.25)
        checkEqual(measurement.baselinePhysicalFootprint, 100); checkEqual(measurement.peakPhysicalFootprint, 200)
        XCTAssertNil(measurement.firstPartialSeconds); XCTAssertNil(measurement.failure); checkEqual(memory.stops, 1)
        checkEqual(await engine.phase, .unloaded)
        let badBackend = T14Backend(loadError: STTEngineError(.loadFailed)); let bad = try f.engine(badBackend)
        let missingMemory = T14Memory(baseline: nil, peak: nil)
        let failed = await STTBenchmarkRunner(now: { clock.next() }).measure(engine: bad, input: input,
            session: session, repetition: 0, warmup: true, memory: missingMemory,
            observe: { (.init(prewarmSeconds: nil, modelSeconds: nil), nil) })
        checkEqual(failed.failure?.code, .loadFailed); XCTAssertNil(failed.terminal); XCTAssertNil(failed.rtf)
        XCTAssertNil(failed.finalSeconds); XCTAssertNil(failed.peakPhysicalFootprint); checkEqual(missingMemory.stops, 1)
        checkEqual(failed.warnings, ["Physical footprint unavailable"]); checkEqual(await bad.phase, .unloaded)
        let report = STTBenchmarkReport(schemaVersion: 1, appVersion: "test", os: "test", hardware: "test", model: f.descriptor,
            input: input, settings: session, policy: "one warmup excluded", memoryMethod: "injected", measurements: [measurement, failed], success: false)
        checkEqual(try JSONDecoder().decode(STTBenchmarkReport.self, from: JSONEncoder().encode(report)), report)
    }

}

private final class T14CounterClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    func next() -> Double { lock.withLock { defer { value += 1 }; return value } }
}
private final class T14Memory: STTBenchmarkMemoryProbe, @unchecked Sendable {
    let baseline: UInt64?
    let peak: UInt64?
    private let lock = NSLock()
    private var count = 0
    init(baseline: UInt64?, peak: UInt64?) { self.baseline = baseline; self.peak = peak }
    var stops: Int { lock.withLock { count } }
    func stop() -> UInt64? { lock.withLock { count += 1; return peak } }
}
