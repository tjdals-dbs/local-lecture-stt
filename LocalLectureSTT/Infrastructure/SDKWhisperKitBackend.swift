import CoreML
import Foundation
@preconcurrency import WhisperKit

/// Only the owning engine worker calls this instance. Unload is joined after decode/load.
final class SDKWhisperKitBackend: WhisperIntervalBackend, @unchecked Sendable {
    private var sdk: WhisperKit?
    private var decodingClient: (any WhisperKitDecodingClient)?
    private var modelLease: ModelUseLease?
    init() {}
    /// Narrow SDK-call seam for model-free deterministic boundary tests.
    init(decodingClient: any WhisperKitDecodingClient) { self.decodingClient = decodingClient }

    // At this pin SDK prefill uses (maxTokenContext / 2) - 1, not 128.
    static let maximumPromptTokens = (Constants.maxTokenContext / 2) - 1
    private static let specialTokenBegin = 50_257 // exact pinned large-v3 tokenizer
    private var timing = STTBenchmarkLoadTiming(prewarmSeconds: nil, modelSeconds: nil)
    func loadTiming() async -> STTBenchmarkLoadTiming { timing }
    func load(_ lease: ModelUseLease) async throws {
        modelLease = lease
        try lease.check()
        let tokenizer = try await LocalWhisperTokenizer.load(lease.directory)
        try lease.check(); try Task.checkCancellation()
        let config = WhisperKitConfig(modelFolder: lease.directory.url.path,
            tokenizerFolder: lease.directory.url,
            computeOptions: ModelComputeOptions(melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine),
            verbose: false, prewarm: false, load: false, download: false, useBackgroundDownloadSession: false)
        let instance = try await WhisperKit(config); sdk = instance
        // Inject before any model load: upstream's fallback-capable tokenizer loader exits immediately.
        instance.tokenizer = tokenizer
        instance.textDecoder.isModelMultilingual = true
        try lease.check(); try Task.checkCancellation()
        let prewarmStart = ProcessInfo.processInfo.systemUptime
        try await instance.prewarmModels()
        let prewarmSeconds = ProcessInfo.processInfo.systemUptime - prewarmStart
        try lease.check(); try Task.checkCancellation()
        let modelStart = ProcessInfo.processInfo.systemUptime
        try await instance.loadModels()
        timing = .init(prewarmSeconds: prewarmSeconds, modelSeconds: ProcessInfo.processInfo.systemUptime - modelStart)
        try lease.check(); try Task.checkCancellation()
        guard instance.textDecoder.logitsSize == 51866, instance.audioEncoder.embedSize == 1280 else {
            throw STTEngineError(.unsupportedModel)
        }
        decodingClient = LocalWhisperKitDecodingClient(instance)
    }
    func decode(_ audio: STTInferenceAudio, settings: WhisperDecodeSettings,
                partial: @escaping @Sendable (WhisperSnapshot) async -> Void) async throws -> WhisperSnapshot {
        guard let decodingClient else { throw STTEngineError(.invalidLifecycle) }
        do {
            try modelLease?.check(); try Task.checkCancellation()
            let language: String
            if let selected = settings.language {
                guard !settings.detectLanguage, ["ko", "en"].contains(selected) else {
                    throw STTEngineError(.invalidConfiguration)
                }
                language = selected
            } else {
                guard settings.detectLanguage else { throw STTEngineError(.invalidConfiguration) }
                // Explicit detector failure must propagate. transcribe() otherwise swallows
                // detection errors and can manufacture a successful default-English result.
                let evidence = try await decodingClient.detectLanguage(audio)
                try modelLease?.check(); try Task.checkCancellation()
                language = try Self.validatedLanguage(evidence)
            }
            let options = try Self.decodingOptions(settings, resolvedLanguage: language) {
                try decodingClient.tokenize($0)
            }
            let value = try await decodingClient.transcribe(audio, options: options) { value in
                let nonempty = !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                await partial(.init(text: value.text, intervals: value.intervals,
                    language: value.language ?? (nonempty ? language : nil)))
            }
            try modelLease?.check(); try Task.checkCancellation()
            let nonempty = !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // The SDK can label a no-window/empty result with its default language.
            // No transcript means no detected-language publication or contradiction.
            guard !nonempty || value.language == nil || value.language == language else { throw STTEngineError(.invalidResponse) }
            return .init(text: value.text, intervals: value.intervals,
                language: nonempty ? language : nil)
        } catch { throw WhisperKitSTTEngine.error(error, fallback: .inferenceFailed) }
    }
    static func validatedLanguage(_ evidence: WhisperLanguageDetection) throws -> String {
        guard ["ko", "en"].contains(evidence.language), (1...256).contains(evidence.scores.count),
              evidence.scores[evidence.language] != nil, evidence.scores.values.allSatisfy(\.isFinite) else {
            throw STTEngineError(.invalidResponse)
        }
        return evidence.language
    }
    static func decodingOptions(_ settings: WhisperDecodeSettings, resolvedLanguage: String,
                                tokenize: (String) throws -> [Int]) throws -> DecodingOptions {
        guard ["ko", "en"].contains(resolvedLanguage), settings.language == nil || settings.language == resolvedLanguage,
              settings.temperature.isFinite, (0...1).contains(settings.temperature) else {
            throw STTEngineError(.invalidConfiguration)
        }
        let tokens = try promptTokens(settings.promptText, encode: tokenize)
        return DecodingOptions(verbose: false, task: .transcribe, language: resolvedLanguage,
            temperature: Float(settings.temperature), temperatureIncrementOnFallback: 0,
            temperatureFallbackCount: 0, sampleLength: 224, topK: 5, usePrefillPrompt: true,
            detectLanguage: false, skipSpecialTokens: true,
            withoutTimestamps: !settings.timestamps, wordTimestamps: false,
            clipTimestamps: [], windowClipTime: 0, promptTokens: tokens, prefixTokens: nil,
            suppressBlank: true, suppressTokens: [], concurrentWorkerCount: 1, chunkingStrategy: nil)
    }
    static func promptTokens(_ text: String?, encode: (String) throws -> [Int]) throws -> [Int]? {
        guard let text, !text.isEmpty else { return nil }
        guard text.utf8.count <= STTDecodingHints.maximumUTF8Bytes, !text.contains("\0") else {
            throw STTEngineError(.invalidInput)
        }
        let tokens = try encode(text)
        // SDK prefill also filters special tokens. Reject rather than silently losing text.
        guard tokens.count <= maximumPromptTokens,
              tokens.allSatisfy({ $0 >= 0 && $0 < specialTokenBegin }) else { throw STTEngineError(.invalidInput) }
        return tokens
    }
    func unload() async {
        if let sdk { await sdk.unloadModels(); sdk.tokenizer = nil }
        decodingClient = nil; sdk = nil; modelLease = nil
    }
}

struct WhisperLanguageDetection: Codable, Sendable, Equatable {
    let language: String
    /// Pinned SDK returns language log probabilities, not normalized [0,1] probabilities.
    let scores: [String: Double]
}

/// SDK-only seam; vendor options stay inside Infrastructure, behind WhisperIntervalBackend.
protocol WhisperKitDecodingClient: Sendable {
    func tokenize(_ text: String) throws -> [Int]
    func detectLanguage(_ audio: STTInferenceAudio) async throws -> WhisperLanguageDetection
    func transcribe(_ audio: STTInferenceAudio, options: DecodingOptions,
                    partial: @escaping @Sendable (WhisperSnapshot) async -> Void) async throws -> WhisperSnapshot
}

/// Owned by the engine's one decode worker; unload joins that worker before releasing SDK state.
final class LocalWhisperKitDecodingClient: WhisperKitDecodingClient, @unchecked Sendable {
    let sdk: WhisperKit
    init(_ sdk: WhisperKit) { self.sdk = sdk }
    func tokenize(_ text: String) throws -> [Int] {
        guard let tokenizer = sdk.tokenizer else { throw STTEngineError(.invalidLifecycle) }
        return tokenizer.encode(text: text)
    }
    func detectLanguage(_ audio: STTInferenceAudio) async throws -> WhisperLanguageDetection {
        let result = try await sdk.detectLangauge(audioArray: audio.samples)
        return .init(language: result.language, scores: result.langProbs.mapValues(Double.init))
    }
    func transcribe(_ audio: STTInferenceAudio, options: DecodingOptions,
                    partial: @escaping @Sendable (WhisperSnapshot) async -> Void) async throws -> WhisperSnapshot {
        guard let tokenizer = sdk.tokenizer as? LocalWhisperTokenizer else { throw STTEngineError(.invalidLifecycle) }
        let control = WhisperDecodeControl()
        let pair = AsyncStream<WhisperSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { for await value in pair.stream { await partial(value) } }
        do {
            let results = try await withTaskCancellationHandler {
                try await sdk.transcribe(audioArray: audio.samples, decodeOptions: options) { progress in
                    // SDK progress.text includes prompt context, and is window-local.
                    // Publish only real output from the first SDK window; the terminal
                    // contains all windows. No synthetic concatenation or fine timing.
                    if progress.windowId == 0, !control.isCancelled {
                        guard let value = Self.partialSnapshot(tokens: progress.tokens, tokenizer: tokenizer) else {
                            control.rejectInvalidResponse(); return false
                        }
                        if !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            control.publishPartial(tokenCount: progress.tokens.count) {
                                pair.continuation.yield(value)
                            }
                        }
                    }
                    return !control.isCancelled
                }
            } onCancel: { control.cancel() }
            pair.continuation.finish(); await consumer.value
            if let failure = control.failure { throw failure }
            try Task.checkCancellation()
            let segments = results.flatMap(\.segments)
            guard results.allSatisfy({ $0.language == results.first?.language }) else { throw STTEngineError(.invalidResponse) }
            return .init(text: segments.map(\.text).joined(),
                intervals: options.withoutTimestamps ? [] : segments.map { .init(start: Double($0.start), end: Double($0.end), text: $0.text) },
                language: results.first?.language)
        } catch {
            pair.continuation.finish(); await consumer.value
            throw error
        }
    }
    static func partialSnapshot(tokens: [Int], tokenizer: any WhisperTokenizer) -> WhisperSnapshot? {
        guard let start = tokens.firstIndex(of: tokenizer.specialTokens.startOfTranscriptToken) else { return nil }
        let output = tokens.dropFirst(start + 1).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return .init(text: tokenizer.decode(tokens: Array(output)), intervals: [], language: nil)
    }
}

/// Local-only factory bypasses ModelUtilities.loadTokenizer's remote fallback entirely.
/// The SDK wrapper's initializer is internal at this pin, so this small protocol bridge is owned here.
// All stored fields are immutable and the pinned TokenizerWrapper is Sendable.
final class LocalWhisperTokenizer: WhisperTokenizer, @unchecked Sendable {
    let wrapped: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>
    init(_ wrapped: TokenizerWrapper) throws {
        self.wrapped = wrapped
        func id(_ text: String) throws -> Int {
            guard let value = wrapped.convertTokenToId(text) else { throw ModelRepositoryCode.incompatible }
            return value
        }
        specialTokens = try SpecialTokens(endToken: id("<|endoftext|>"), englishToken: id("<|en|>"),
            noSpeechToken: id("<|nospeech|>"), noTimestampsToken: id("<|notimestamps|>"),
            specialTokenBegin: id("<|endoftext|>"), startOfPreviousToken: id("<|startofprev|>"),
            startOfTranscriptToken: id("<|startoftranscript|>"), timeTokenBegin: id("<|0.00|>"),
            transcribeToken: id("<|transcribe|>"), translateToken: id("<|translate|>"), whitespaceToken: 220)
        allLanguageTokens = Set(Constants.languages.values.compactMap { wrapped.convertTokenToId("<|\($0)|>") })
        guard try id("<|ko|>") == 50264, specialTokens.timeTokenBegin == 50365 else { throw ModelRepositoryCode.incompatible }
    }
    static func load(_ directory: ModelPackageDirectory) async throws -> LocalWhisperTokenizer {
        // Read through pinned no-follow descriptors first; factory uses the same root and is checked after await.
        for name in ["tokenizer.json", "tokenizer_config.json"] {
            let (fd, _) = try directory.regularFD(name); Darwin.close(fd)
        }
        let before = try directory.treeStamps()
        let wrapped = try await AutoTokenizerWrapper.from(modelFolder: directory.url)
        try directory.check()
        guard try directory.treeStamps() == before else { throw ModelRepositoryCode.identityChanged }
        return try LocalWhisperTokenizer(wrapped)
    }
    func encode(text: String) -> [Int] { wrapped.encode(text: text, addSpecialTokens: false) }
    func decode(tokens: [Int]) -> String { wrapped.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { wrapped.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { wrapped.convertIdToToken(id) }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        // Word timestamps are disabled. Preserve Unicode bytes if the SDK asks for a split.
        var words: [String] = [], groups: [[Int]] = [], pending: [Int] = []
        for id in tokenIds {
            pending.append(id)
            let text = decode(tokens: pending)
            if !text.contains("\u{fffd}") { words.append(text); groups.append(pending); pending = [] }
        }
        if !pending.isEmpty { words.append(decode(tokens: pending)); groups.append(pending) }
        return (words, groups)
    }
}

/// Detached SDK token callbacks cannot use their own Task.isCancelled to inspect the decode task.
private final class WhisperDecodeControl: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var firstFailure: STTEngineError?
    private var lastPartialTokenCount = 0
    var isCancelled: Bool { lock.withLock { value } }
    var failure: STTEngineError? { lock.withLock { firstFailure } }
    func cancel() { lock.withLock { value = true } }
    func rejectInvalidResponse() {
        lock.withLock { if firstFailure == nil { firstFailure = STTEngineError(.invalidResponse) }; value = true }
    }
    func publishPartial(tokenCount: Int, _ publish: () -> Void) {
        lock.withLock {
            guard !value, tokenCount > lastPartialTokenCount else { return }
            lastPartialTokenCount = tokenCount
            // Keep acceptance and synchronous stream publication ordered together.
            publish()
        }
    }
}
