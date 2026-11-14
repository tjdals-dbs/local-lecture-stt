import CoreML
import Foundation
@preconcurrency import WhisperKit
import XCTest
@testable import LocalLectureSTT

/// Only tokenizer protocol values: actual pinned SDK prefill runs without weights.
private final class BoundaryTokenizer: WhisperTokenizer {
    let specialTokens = SpecialTokens(endToken: 50257, englishToken: 50259, noSpeechToken: 50363,
        noTimestampsToken: 50364, specialTokenBegin: 50257, startOfPreviousToken: 50362,
        startOfTranscriptToken: 50258, timeTokenBegin: 50365, transcribeToken: 50360,
        translateToken: 50359, whitespaceToken: 220)
    let allLanguageTokens: Set<Int> = [50259, 50264]
    func encode(text: String) -> [Int] { text.utf8.map(Int.init) }
    func decode(tokens: [Int]) -> String { String(decoding: tokens.compactMap(UInt8.init(exactly:)), as: UTF8.self) }
    func convertTokenToId(_ token: String) -> Int? {
        ["<|en|>": 50259, "<|ko|>": 50264, "<|transcribe|>": 50360][token]
    }
    func convertIdToToken(_ id: Int) -> String? { nil }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) { ([], []) }
}
private actor BoundaryGate {
    let entered = XCTestExpectation(description: "explicit detector entered")
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async { entered.fulfill(); if !released { await withCheckedContinuation { waiter = $0 } } }
    func wait() async throws {
        guard await XCTWaiter.fulfillment(of: [entered], timeout: 5) == .completed else { throw STTEngineError(.inferenceFailed) }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
private final class BoundaryClient: WhisperKitDecodingClient, @unchecked Sendable {
    let detection: Result<WhisperLanguageDetection, STTEngineError>
    let transcript: WhisperSnapshot
    let partialSnapshot: WhisperSnapshot?
    let gate: BoundaryGate?
    private let lock = NSLock()
    private var detectionCount = 0
    private var tokenizeCount = 0
    private var options: [DecodingOptions] = []
    init(detection: Result<WhisperLanguageDetection, STTEngineError> = .success(.init(language: "en", scores: ["en": -0.1])),
         transcript: WhisperSnapshot = .init(text: "speech", intervals: [], language: "en"),
         partial: WhisperSnapshot? = nil, gate: BoundaryGate? = nil) {
        self.detection = detection; self.transcript = transcript; partialSnapshot = partial; self.gate = gate
    }
    func tokenize(_ text: String) throws -> [Int] { lock.withLock { tokenizeCount += 1 }; return text.utf8.map(Int.init) }
    func detectLanguage(_ audio: STTInferenceAudio) async throws -> WhisperLanguageDetection {
        lock.withLock { detectionCount += 1 }; await gate?.hold(); try Task.checkCancellation()
        return try detection.get()
    }
    func transcribe(_ audio: STTInferenceAudio, options value: DecodingOptions,
                    partial: @escaping @Sendable (WhisperSnapshot) async -> Void) async throws -> WhisperSnapshot {
        lock.withLock { options.append(value) }
        if let partialSnapshot { await partial(partialSnapshot) }
        return transcript
    }
    func snapshot() -> (detections: Int, tokenizations: Int, options: [DecodingOptions]) {
        lock.withLock { (detectionCount, tokenizeCount, options) }
    }
}
private actor BoundaryPartials {
    var values: [WhisperSnapshot] = []
    func append(_ value: WhisperSnapshot) { values.append(value) }
}

final class WhisperKitSDKBoundaryTests: XCTestCase {
    private func audio() throws -> STTInferenceAudio {
        try .init(format: STTInputFormat(), frameCount: 160, samples: Array(repeating: 0.1, count: 160))
    }
    private func settings(language: String? = nil, detect: Bool = true, prompt: String? = nil,
                          timestamps: Bool = true, temperature: Double = 0) -> WhisperDecodeSettings {
        .init(language: language, detectLanguage: detect, temperature: temperature, timestamps: timestamps, promptText: prompt)
    }
    private func expect(_ code: STTErrorCode, _ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected \(code)") }
        catch let value as STTEngineError { XCTAssertEqual(value.code, code) }
        catch { XCTFail("Unexpected \(error)") }
    }
    func testReviewAcceptedPromptSurvivesActualPinnedSDKPrefill() async throws {
        XCTAssertEqual(SDKWhisperKitBackend.maximumPromptTokens, 111)
        let tokenizer = BoundaryTokenizer(), decoder = TextDecoder()
        decoder.tokenizer = tokenizer; decoder.isModelMultilingual = true
        let one = try MLMultiArray(shape: [1], dataType: .int32)
        let input = DecodingInputs(initialPrompt: [50258], inputIds: one, cacheLength: one,
            keyCache: one, valueCache: one, alignmentWeights: one, kvCacheUpdateMask: one, decoderKeyPaddingMask: one)
        let options = try SDKWhisperKitBackend.decodingOptions(settings(prompt: String(repeating: "x", count: 111)),
            resolvedLanguage: "ko", tokenize: tokenizer.encode)
        let output = try await decoder.prefillDecoderInputs(input, withOptions: options)
        XCTAssertEqual(Array(output.initialPrompt.dropFirst().dropLast(4)), options.promptTokens)
        XCTAssertEqual(options.language, "ko"); XCTAssertFalse(options.detectLanguage)
        for count in [112, 120, 128] {
            XCTAssertThrowsError(try SDKWhisperKitBackend.decodingOptions(settings(prompt: String(repeating: "x", count: count)),
                resolvedLanguage: "ko", tokenize: tokenizer.encode)) { error in
                XCTAssertEqual(error as? STTEngineError, STTEngineError(.invalidInput))
            }
        }
        let reset = try SDKWhisperKitBackend.decodingOptions(settings(prompt: nil), resolvedLanguage: "en", tokenize: tokenizer.encode)
        let resetOutput = try await decoder.prefillDecoderInputs(input, withOptions: reset)
        XCTAssertNil(reset.promptTokens); XCTAssertEqual(resetOutput.initialPrompt, [50258, 50259, 50360, 50365])
        let empty = try SDKWhisperKitBackend.decodingOptions(settings(prompt: ""), resolvedLanguage: "en", tokenize: tokenizer.encode)
        XCTAssertNil(empty.promptTokens)
    }
    func testPromptSpecialTokenFilteringCannotSilentlyLoseText() throws {
        for tokens in [[-1], [50257], [50365]] {
            XCTAssertThrowsError(try SDKWhisperKitBackend.promptTokens("text", encode: { _ in tokens }))
        }
        XCTAssertEqual(try SDKWhisperKitBackend.promptTokens("text", encode: { _ in [0, 50256] }), [0, 50256])
    }
    func testSDKTokenProgressExcludesContextAndControlTokens() {
        let tokenizer = BoundaryTokenizer()
        let prefix = [50362] + tokenizer.encode(text: "hint") + [50258, 50259, 50360, 50365]
        let prefill = LocalWhisperKitDecodingClient.partialSnapshot(tokens: prefix, tokenizer: tokenizer)
        XCTAssertEqual(prefill?.text, "")
        let output = LocalWhisperKitDecodingClient.partialSnapshot(tokens: prefix + tokenizer.encode(text: "speech") + [50257], tokenizer: tokenizer)
        XCTAssertEqual(output?.text, "speech"); XCTAssertEqual(output?.intervals, [])
        XCTAssertNil(LocalWhisperKitDecodingClient.partialSnapshot(tokens: tokenizer.encode(text: "missing SOT"), tokenizer: tokenizer))
    }
    func testOverBudgetPromptFailsBeforeAnySDKTranscription() async throws {
        let client = BoundaryClient(); let backend = SDKWhisperKitBackend(decodingClient: client)
        await expect(.invalidInput) {
            _ = try await backend.decode(self.audio(), settings: self.settings(language: "en", detect: false, prompt: String(repeating: "x", count: 112)), partial: { _ in })
        }
        XCTAssertEqual(client.snapshot().options.count, 0); XCTAssertEqual(client.snapshot().detections, 0)
        await backend.unload()
    }
    func testReviewDetectionFailureNeverBecomesEnglishSuccessAndReuseWorks() async throws {
        let client = BoundaryClient(detection: .failure(STTEngineError(.inferenceFailed)))
        let backend = SDKWhisperKitBackend(decodingClient: client)
        await expect(.inferenceFailed) { _ = try await backend.decode(self.audio(), settings: self.settings(), partial: { _ in }) }
        XCTAssertEqual(client.snapshot().detections, 1); XCTAssertEqual(client.snapshot().options.count, 0)
        let fresh = try await backend.decode(audio(), settings: settings(language: "en", detect: false), partial: { _ in })
        XCTAssertEqual(fresh.language, "en"); XCTAssertEqual(client.snapshot().detections, 1)
        XCTAssertEqual(client.snapshot().options.count, 1); await backend.unload()
    }
    func testMissingContradictoryUnsupportedAndNonfiniteDetectionEvidenceFails() async throws {
        let invalid: [WhisperLanguageDetection] = [.init(language: "en", scores: [:]), .init(language: "en", scores: ["ko": -0.1]),
            .init(language: "fr", scores: ["fr": -0.1]), .init(language: "en", scores: ["en": .nan]), .init(language: "en", scores: ["en": .infinity])]
        for evidence in invalid {
            let client = BoundaryClient(detection: .success(evidence)); let backend = SDKWhisperKitBackend(decodingClient: client)
            await expect(.invalidResponse) { _ = try await backend.decode(self.audio(), settings: self.settings(), partial: { _ in }) }
            XCTAssertEqual(client.snapshot().options.count, 0); await backend.unload()
        }
    }
    func testExplicitDetectionPinsSDKOptionsPartialsAndResetsPrompt() async throws {
        let client = BoundaryClient(detection: .success(.init(language: "ko", scores: ["ko": -0.2])),
            transcript: .init(text: "한국어 Core ML", intervals: [], language: "ko"), partial: .init(text: "한국어", intervals: [], language: nil))
        let backend = SDKWhisperKitBackend(decodingClient: client); let partials = BoundaryPartials()
        let result = try await backend.decode(audio(), settings: settings(prompt: "term", timestamps: false, temperature: 0.75)) { await partials.append($0) }
        XCTAssertEqual(result.language, "ko")
        let observed = await partials.values; XCTAssertEqual(observed.first?.language, "ko")
        _ = try await backend.decode(audio(), settings: settings(language: "ko", detect: false), partial: { _ in })
        let state = client.snapshot(); XCTAssertEqual(state.detections, 1); XCTAssertEqual(state.options.count, 2)
        XCTAssertEqual(state.options[0].language, "ko"); XCTAssertFalse(state.options[0].detectLanguage)
        XCTAssertEqual(state.options[0].task, .transcribe); XCTAssertTrue(state.options[0].withoutTimestamps)
        XCTAssertEqual(state.options[0].temperature, 0.75); XCTAssertEqual(state.options[0].promptTokens, [116,101,114,109])
        XCTAssertNil(state.options[1].promptTokens); await backend.unload()
    }
    func testEmptyTranscriptDoesNotInventLanguageAndContradictoryResultFails() async throws {
        let silent = SDKWhisperKitBackend(decodingClient: BoundaryClient(transcript: .init(text: "", intervals: [], language: nil)))
        let result = try await silent.decode(audio(), settings: settings(), partial: { _ in })
        XCTAssertNil(result.language); XCTAssertEqual(result.text, ""); await silent.unload()
        let emptyDefault = SDKWhisperKitBackend(decodingClient: BoundaryClient(
            detection: .success(.init(language: "ko", scores: ["ko": -0.1])),
            transcript: .init(text: "", intervals: [], language: "en")))
        let undecided = try await emptyDefault.decode(audio(), settings: settings(), partial: { _ in })
        XCTAssertNil(undecided.language); await emptyDefault.unload()
        let contradiction = SDKWhisperKitBackend(decodingClient: BoundaryClient(transcript: .init(text: "speech", intervals: [], language: "ko")))
        await expect(.invalidResponse) { _ = try await contradiction.decode(self.audio(), settings: self.settings(), partial: { _ in }) }
        await contradiction.unload()
    }
    func testCancellationDuringExplicitDetectionJoinsBeforeTranscription() async throws {
        let gate = BoundaryGate(); let client = BoundaryClient(gate: gate); let backend = SDKWhisperKitBackend(decodingClient: client)
        let input = try audio(); let options = settings()
        let task = Task { try await backend.decode(input, settings: options, partial: { _ in }) }
        do {
            try await gate.wait(); task.cancel(); XCTAssertEqual(client.snapshot().options.count, 0)
            await gate.release(); await expect(.cancelled) { _ = try await task.value }
            XCTAssertEqual(client.snapshot().options.count, 0); await backend.unload()
        } catch { await gate.release(); task.cancel(); _ = try? await task.value; await backend.unload(); throw error }
    }
    func testActualSDKDetectorErrorCannotFallThroughToTranscribe() async throws {
        let decoder = BoundaryFailingDecoder()
        let sdk = try await BoundarySDK(WhisperKitConfig(modelFolder: "/private/tmp/not-a-model",
            featureExtractor: BoundaryFeatures(), audioEncoder: BoundaryEncoder(), textDecoder: decoder,
            verbose: false, prewarm: false, load: false, download: false))
        sdk.tokenizer = BoundaryTokenizer(); sdk.textDecoder.tokenizer = sdk.tokenizer
        let backend = SDKWhisperKitBackend(decodingClient: LocalWhisperKitDecodingClient(sdk))
        await expect(.inferenceFailed) { _ = try await backend.decode(self.audio(), settings: self.settings(), partial: { _ in }) }
        XCTAssertEqual(decoder.failures, 1); XCTAssertEqual(sdk.transcriptions, 0)
        await backend.unload(); await sdk.unloadModels(); sdk.tokenizer = nil
    }
}

// The pinned SDK's actual detectLangauge helper executes. Only expensive tensors and
// model loading are synthetic; no fallback model/tokenizer/network call can occur.
private final class BoundarySDK: WhisperKit {
    var transcriptions = 0
    override func loadModels(prewarmMode: Bool = false) async throws {}
    override func transcribe(audioArray: [Float], decodeOptions: DecodingOptions? = nil,
        callback: TranscriptionCallback? = nil, segmentCallback: SegmentDiscoveryCallback? = nil) async throws -> [TranscriptionResult] {
        transcriptions += 1; return []
    }
}
private struct BoundaryFeatures: FeatureExtracting {
    let melCount: Int? = 128
    let windowSamples: Int? = 160
    func logMelSpectrogram(fromAudio inputAudio: any AudioProcessorOutputType) async throws -> (any FeatureExtractorOutputType)? {
        try MLMultiArray(shape: [1], dataType: .float32)
    }
}
private struct BoundaryEncoder: AudioEncoding {
    let embedSize: Int? = 1
    func encodeFeatures(_ features: any FeatureExtractorOutputType) async throws -> (any AudioEncoderOutputType)? {
        try MLMultiArray(shape: [1], dataType: .float32)
    }
}
private final class BoundaryFailingDecoder: TextDecoding {
    var tokenizer: WhisperTokenizer?
    var isModelMultilingual = true
    var logitsFilters: [any LogitsFiltering]?
    let supportsWordTimestamps = false
    let logitsSize: Int? = 51866
    let kvCacheEmbedDim: Int? = 1
    let kvCacheMaxSequenceLength: Int? = 1
    let windowSize: Int? = 1
    let embedSize: Int? = 1
    var failures = 0
    func predictLogits(_ inputs: any TextDecoderInputType) async throws -> (any TextDecoderOutputType)? { throw STTEngineError(.inferenceFailed) }
    func decodeText(from encoderOutput: any AudioEncoderOutputType, using decoderInputs: any DecodingInputsType,
        sampler tokenSampler: any TokenSampling, options decoderOptions: DecodingOptions,
        callback: TranscriptionCallback?) async throws -> DecodingResult { throw STTEngineError(.inferenceFailed) }
    func detectLanguage(from encoderOutput: any AudioEncoderOutputType, using decoderInputs: any DecodingInputsType,
        sampler tokenSampler: any TokenSampling, options: DecodingOptions, temperature: FloatType) async throws -> DecodingResult {
        failures += 1; throw STTEngineError(.inferenceFailed)
    }
}
