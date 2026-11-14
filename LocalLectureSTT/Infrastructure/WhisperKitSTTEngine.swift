import Foundation

// Only value types cross the internal backend seam; no SDK errors/tokens escape it.
struct WhisperInterval: Codable, Sendable, Equatable { let start: Double; let end: Double; let text: String }
struct WhisperSnapshot: Codable, Sendable, Equatable {
    let text: String
    let intervals: [WhisperInterval]
    let language: String?
}
struct WhisperDecodeSettings: Codable, Sendable, Equatable {
    let language: String?
    let detectLanguage: Bool
    let temperature: Double
    let timestamps: Bool
    let promptText: String?
}
protocol WhisperKitBackend: Sendable {
    func load(_ lease: ModelUseLease) async throws
    func decode(_ audio: STTInferenceAudio, settings: WhisperDecodeSettings,
                partial: @escaping @Sendable (WhisperSnapshot) async -> Void) async throws -> WhisperSnapshot
    func unload() async throws
    func loadTiming() async -> STTBenchmarkLoadTiming
}
extension WhisperKitBackend {
    func loadTiming() async -> STTBenchmarkLoadTiming { .init(prewarmSeconds: nil, modelSeconds: nil) }
}

actor WhisperKitSTTEngine: STTEngine {
    static let revision = "1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4"
    static let identity = try! EngineIdentity(id: EngineID("whisperkit"), version: revision)
    static let compute = "cpuAndGPU+cpuAndNeuralEngine;prewarm=true"
    nonisolated let capabilities = try! STTCapabilities(inputFormats: [STTInputFormat()],
        languageModes: [.korean, .english, .automatic], languages: [LanguageCode("ko"), LanguageCode("en")],
        partialResults: true, timestamps: true)
    enum Phase: String, Sendable { case unloaded, loading, ready, running, draining, cancelling, unloading }
    private(set) var phase: Phase = .unloaded
    private(set) var cleanupDiagnostics: [STTEngineError] = []
    private let resolve: @Sendable (InstalledModelKey) async throws -> ModelUseLease
    private let makeBackend: @Sendable () -> any WhisperKitBackend
    private let capacity: Int
    private let now: @Sendable () -> Double
    private let cleanupJoinAcknowledged: @Sendable () -> Void
    private(set) var cleanupJoiners = 0
    private(set) var lastRequestTiming: STTBenchmarkRequestTiming?
    func loadTiming() async -> STTBenchmarkLoadTiming { await backend?.loadTiming() ?? .init(prewarmSeconds: nil, modelSeconds: nil) }
    private var backend: (any WhisperKitBackend)?
    private var lease: ModelUseLease?
    private var model: STTModelConfiguration?
    private var session: STTSessionConfiguration?
    private var language: String?
    private var sequence: Int64 = -1
    private var generation = UUID()
    private var preparation: Task<Void, Error>?
    private var cleanup: Task<Void, Never>?
    private struct Work {
        let id: UUID
        let request: STTInferenceRequest
        let feed: STTEventFeed
        let admitted: Double
        var revision: Int64 = 0
        var cause: STTEngineError?
    }
    private var active: Work?
    private var queue: [Work] = []
    private var worker: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var requestWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    init(repository: FileModelRepository, capacity: Int = 2) throws {
        guard (1...16).contains(capacity) else { throw STTEngineError(.invalidConfiguration) }
        self.capacity = capacity; now = { ProcessInfo.processInfo.systemUptime }
        cleanupJoinAcknowledged = {}
        resolve = { try await repository.acquireUseLease($0) }
        makeBackend = { SDKWhisperKitBackend() }
    }
    init(capacity: Int = 2, resolve: @escaping @Sendable (InstalledModelKey) async throws -> ModelUseLease,
         now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         cleanupJoinAcknowledged: @escaping @Sendable () -> Void = {},
         makeBackend: @escaping @Sendable () -> any WhisperKitBackend) throws {
        guard (1...16).contains(capacity) else { throw STTEngineError(.invalidConfiguration) }
        self.capacity = capacity; self.now = now; self.resolve = resolve; self.makeBackend = makeBackend
        self.cleanupJoinAcknowledged = cleanupJoinAcknowledged
    }
    func load(_ configuration: STTModelConfiguration) async throws {
        guard phase == .unloaded else {
            if phase == .ready, configuration == model { return }
            throw STTEngineError(.busy)
        }
        guard configuration.engine == Self.identity else { throw STTEngineError(.unsupportedModel) }
        guard configuration.options.computeMode == "default" || configuration.options.computeMode == Self.compute else {
            throw STTEngineError(.unsupportedCapability)
        }
        try Self.checkCancellation()
        phase = .loading; generation = UUID(); cleanupDiagnostics = []; lastRequestTiming = nil
        let token = generation
        let task = Task { try await self.prepare(configuration, token: token) }
        preparation = task
        try await withTaskCancellationHandler { try await task.value }
        onCancel: { task.cancel() }
    }
    private func prepare(_ configuration: STTModelConfiguration, token: UUID) async throws {
        do {
            let key = try InstalledModelKey(engineID: configuration.engine.id, modelID: configuration.model.id,
                                            revision: configuration.model.revision)
            let acquired = try await resolve(key); lease = acquired
            try Self.checkCancellation()
            guard acquired.descriptor.engine == configuration.engine, acquired.descriptor.model == configuration.model,
                  acquired.descriptor.format == "whisperkit-coreml-v1", acquired.descriptor.variant == "large-v3",
                  acquired.descriptor.quantization == "none", acquired.descriptor.compute == Self.compute else {
                throw STTEngineError(.unsupportedModel)
            }
            try acquired.check()
            let instance = makeBackend(); backend = instance
            try await instance.load(acquired)
            try Self.checkCancellation(); try acquired.check()
            guard generation == token, phase == .loading else { throw STTEngineError(.cancelled) }
            model = configuration; phase = .ready; preparation = nil
        } catch {
            let cause = Self.error(error, fallback: .loadFailed)
            await releaseBackend()
            model = nil; preparation = nil
            if phase != .unloading { phase = .unloaded }
            throw cause
        }
    }
    func start(_ configuration: STTSessionConfiguration) throws {
        guard phase == .ready else { throw STTEngineError(phase == .unloaded ? .invalidLifecycle : .busy) }
        guard configuration.model == model else { throw STTEngineError(.invalidConfiguration) }
        try Self.checkCancellation()
        do { try lease?.check() } catch { throw STTEngineError(.startFailed) }
        session = configuration; generation = UUID(); sequence = -1; lastRequestTiming = nil
        language = switch configuration.languageMode { case .korean: "ko"; case .english: "en"; case .automatic: nil }
        phase = .running
    }
    func infer(_ request: STTInferenceRequest) throws -> STTEventFeed {
        guard phase == .running, let session else { throw STTEngineError(.invalidLifecycle) }
        guard request.context.session == session else { throw STTEngineError(.sessionMismatch) }
        guard request.context.sequence > sequence else { throw STTEngineError(.invalidInput) }
        guard capabilities.inputFormats.contains(request.audio.format) else { throw STTEngineError(.unsupportedCapability) }
        guard active == nil || queue.count < capacity else { throw STTEngineError(.backlogFull) }
        try Self.checkCancellation()
        let id = UUID()
        let feed = STTEventFeed { [weak self] in await self?.withdraw(id) }
        queue.append(Work(id: id, request: request, feed: feed, admitted: now())); sequence = request.context.sequence
        drive(); return feed
    }
    private func drive() {
        if active == nil, !queue.isEmpty, phase == .running || phase == .draining {
            let work = queue.removeFirst(); active = work
            let token = generation
            worker = Task { await self.run(work, token: token) }
        }
        if active == nil, queue.isEmpty {
            if phase == .draining || phase == .cancelling {
                session = nil; language = nil; phase = .ready
            }
            let joined = idleWaiters; idleWaiters.removeAll(); joined.forEach { $0.resume() }
        }
    }
    private func run(_ work: Work, token: UUID) async {
        let began = now()
        var result: Result<WhisperSnapshot, STTEngineError>
        do {
            guard let backend, let lease else { throw STTEngineError(.invalidLifecycle) }
            try lease.check(); try Self.checkCancellation()
            let options = work.request.context.session.model.options
            let hints = work.request.decodingHints?.promptText
            let settings = WhisperDecodeSettings(language: language, detectLanguage: language == nil,
                temperature: options.temperature, timestamps: options.timestamps,
                promptText: hints?.isEmpty == false ? hints : nil)
            let snapshot = try await backend.decode(work.request.audio, settings: settings) { [weak self] value in
                await self?.publishPartial(value, id: work.id, token: token)
            }
            try lease.check(); try Self.checkCancellation()
            result = .success(snapshot)
        } catch { result = .failure(Self.error(error, fallback: .inferenceFailed)) }
        guard let owned = active, owned.id == work.id, generation == token else { return }
        lastRequestTiming = .init(sequence: owned.request.context.sequence, queueSeconds: max(0, began - owned.admitted), inferenceSeconds: max(0, now() - began))
        if let cause = owned.cause { result = .failure(cause) }
        do {
            switch result {
            case .success(let value):
                let response = try convert(value, work: owned, kind: .final)
                owned.feed.publish(response)
            case .failure(let cause): publishFailure(owned, cause)
            }
        } catch { publishFailure(owned, Self.error(error, fallback: .invalidResponse)) }
        // Only actual decode return permits promotion/reuse and waiter settlement.
        active = nil; worker = nil
        requestWaiters.removeValue(forKey: owned.id)?.forEach { $0.resume() }
        drive()
    }
    private func publishPartial(_ value: WhisperSnapshot, id: UUID, token: UUID) {
        guard var work = active, work.id == id, generation == token, work.cause == nil else { return }
        do {
            try acceptLanguage(value.language)
            guard work.request.context.session.model.options.partialResults else { return }
            // Bound publication even if a hostile backend emits unlimited callbacks.
            guard work.revision < 256 else { throw STTEngineError(.invalidResponse) }
            let response = try convert(value, work: work, kind: .partial)
            work.revision += 1; active = work; work.feed.publish(response)
        } catch {
            active?.cause = Self.error(error, fallback: .invalidResponse); worker?.cancel()
        }
    }
    private func acceptLanguage(_ value: String?) throws {
        guard let value else { return }
        guard ["ko", "en"].contains(value), language == nil || language == value else { throw STTEngineError(.invalidResponse) }
        language = value
    }
    private func convert(_ value: WhisperSnapshot, work: Work, kind: STTResponseKind) throws -> STTResponse {
        try acceptLanguage(value.language)
        let segments = try Self.segments(value, request: work.request)
        return try STTResponse(context: work.request.context, revision: work.revision + 1, kind: kind,
                               segments: segments, detectedLanguage: language.map { try! LanguageCode($0) })
    }
    static func segments(_ value: WhisperSnapshot, request: STTInferenceRequest) throws -> [STTHypothesisSegment] {
        guard value.text.utf8.count <= 65_536, value.intervals.count <= 128 else { throw STTEngineError(.invalidResponse) }
        let context = request.context
        if !context.session.model.options.timestamps || value.intervals.isEmpty {
            guard value.intervals.isEmpty || value.intervals.map(\.text).joined() == value.text else { throw STTEngineError(.invalidResponse) }
            return value.text.isEmpty ? [] : [try STTHypothesisSegment(start: context.mediaStart, end: context.mediaEnd, text: value.text)]
        }
        guard value.intervals.map(\.text).joined() == value.text else { throw STTEngineError(.invalidResponse) }
        let duration = Double(request.audio.duration.rawValue)
        func time(_ seconds: Double) throws -> MediaMilliseconds {
            let ms = seconds * 1000
            // At most 1 ms rounding tolerance, never a whole padded SDK window.
            guard ms.isFinite, ms >= -1, ms <= duration + 1 else { throw STTEngineError(.invalidResponse) }
            return try MediaMilliseconds(context.mediaStart.rawValue + Int64(min(duration, max(0, ms.rounded()))))
        }
        var previous = context.mediaStart
        return try value.intervals.map {
            guard $0.end >= $0.start else { throw STTEngineError(.invalidResponse) }
            let start = try time($0.start), end = try time($0.end)
            guard start >= previous, end >= start else { throw STTEngineError(.invalidResponse) }
            previous = end
            return try STTHypothesisSegment(start: start, end: end, text: $0.text)
        }
    }
    private func publishFailure(_ work: Work, _ cause: STTEngineError) {
        let response = try! STTResponse(context: work.request.context, revision: work.revision + 1,
            kind: cause.code == .cancelled ? .cancelled : .failed, failure: cause)
        work.feed.publish(response)
    }
    private func withdraw(_ id: UUID) async {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            publishFailure(queue.remove(at: index), STTEngineError(.cancelled)); return
        }
        guard active?.id == id else { return }
        if active?.cause == nil { active?.cause = STTEngineError(.cancelled) }
        worker?.cancel()
        await withCheckedContinuation { requestWaiters[id, default: []].append($0) }
    }
    func end() async throws {
        guard session != nil else { throw STTEngineError(.invalidLifecycle) }
        if phase == .running { phase = .draining }
        drive(); await joinSessionSettlement()
    }
    func cancel() async throws {
        guard session != nil else { throw STTEngineError(.invalidLifecycle) }
        cancelWork(); await joinSessionSettlement()
    }
    private func cancelWork() {
        if phase != .unloading { phase = .cancelling }
        let pending = queue; queue.removeAll()
        pending.forEach { publishFailure($0, STTEngineError(.cancelled)) }
        if active?.cause == nil { active?.cause = STTEngineError(.cancelled) }
        worker?.cancel(); drive()
    }
    private func waitIdle() async {
        if active == nil, queue.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }
    private func joinSessionSettlement() async {
        await waitIdle()
        // A concurrent unload may have entered while the accepted decode drained.
        // Capture that owning task; the unload worker itself waits only for idle work.
        if let cleanup {
            cleanupJoiners += 1
            cleanupJoinAcknowledged()
            await cleanup.value
            cleanupJoiners -= 1
        }
    }
    func unload() async {
        if let cleanup { await cleanup.value; return }
        if phase == .unloaded { return }
        phase = .unloading
        let prep = preparation; prep?.cancel(); cancelWork()
        let task = Task {
            _ = try? await prep?.value
            await self.waitIdle()
            await self.releaseBackend()
            self.finishUnload()
        }
        cleanup = task; await task.value
    }
    private func releaseBackend() async {
        if let backend {
            do { try await backend.unload() }
            catch { cleanupDiagnostics.append(Self.error(error, fallback: .cleanupFailed)) }
        }
        backend = nil; lease?.release(); lease = nil
    }
    private func finishUnload() {
        model = nil; session = nil; language = nil; preparation = nil
        phase = .unloaded; cleanup = nil; generation = UUID()
    }
    static func error(_ error: any Error, fallback: STTErrorCode) -> STTEngineError {
        if let value = error as? STTEngineError { return value }
        if error is CancellationError { return STTEngineError(.cancelled) }
        if let value = error as? ModelOperationFailure, value.cause == .busy { return STTEngineError(.busy) }
        return STTEngineError(fallback)
    }
    static func checkCancellation() throws { if Task.isCancelled { throw STTEngineError(.cancelled) } }
}
