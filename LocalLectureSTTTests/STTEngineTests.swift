import XCTest
@testable import LocalLectureSTT

/// Synthetic, explicit identities and sample data only; shared by both contract/fake suites.
enum STTTestFixture {
    static func uuid(_ value: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))! }
    static func model(_ revision: String = "r1", options: STTInferenceOptions? = nil) throws -> STTModelConfiguration {
        try .init(engine: EngineIdentity(id: EngineID("fake"), version: "1.0"),
                  model: ModelIdentity(id: ModelID("synthetic"), revision: revision, checksum: "sha256-\(revision)"),
                  options: options ?? STTInferenceOptions())
    }
    static func session(_ id: Int = 1, model: STTModelConfiguration? = nil,
                        mode: LanguageMode = .korean) throws -> STTSessionConfiguration {
        try .init(sessionID: SessionID(uuid(id)), operationID: STTOperationID(uuid(id + 100)),
                  model: model ?? self.model(), languageMode: mode)
    }
    static func audio(format: STTInputFormat? = nil) throws -> STTInferenceAudio {
        try .init(format: format ?? STTInputFormat(), frameCount: 160, samples: Array(repeating: 0.125, count: 160))
    }
    static func request(_ sequence: Int64 = 0, session: STTSessionConfiguration? = nil,
                        start: Int64 = 5_000) throws -> STTInferenceRequest {
        try .init(session: session ?? self.session(), requestID: STTRequestID(uuid(Int(sequence) + 200)),
                  sequence: sequence, mediaStart: MediaMilliseconds(start), audio: audio())
    }
    static func capabilities(modes: [LanguageMode] = LanguageMode.allCases,
                             partials: Bool = true, timestamps: Bool = true) throws -> STTCapabilities {
        try .init(inputFormats: [STTInputFormat()], languageModes: modes,
                  languages: [LanguageCode("ko"), LanguageCode("en")], partialResults: partials, timestamps: timestamps)
    }
    static func fake(_ scenario: FakeSTTScenario = .init(), capacity: Int = 2,
                     capabilities: STTCapabilities? = nil) throws -> FakeSTTEngine {
        try FakeSTTEngine(engine: model().engine, capabilities: capabilities ?? self.capabilities(),
                          pendingCapacity: capacity, scenario: scenario)
    }
    static func final(_ text: String = "한국어와 Swift concurrency", at delay: Int64 = 0) -> [FakeSTTStep] {
        [.init(after: delay, kind: .final, text: text)]
    }
    static func ready(_ fake: FakeSTTEngine, session: STTSessionConfiguration? = nil) async throws {
        let engine: any STTEngine = fake
        let config = try session ?? self.session()
        try await engine.load(config.model)
        try await engine.start(config)
    }
    static func collect(_ feed: STTEventFeed) async throws -> [STTResponse] {
        var result: [STTResponse] = []
        for await event in try feed.events() { result.append(event) }
        return result
    }
}

final class STTEngineTests: XCTestCase {
    override func setUp() { super.setUp(); executionTimeAllowance = 20 }

    private func roundTrip<T: Codable & Sendable & Equatable>(_ value: T) throws {
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)), value)
    }
    private func malformed<T: Codable>(_ value: T, _ change: (inout [String: Any]) -> Void) throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        change(&json)
        XCTAssertThrowsError(try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testEveryBoundaryPayloadIsCodableSendableEquatableAndPreservesProvenance() throws {
        let config = try STTTestFixture.session(mode: .automatic)
        let request = try STTTestFixture.request(session: config)
        let segment = try STTHypothesisSegment(start: request.context.mediaStart, end: request.context.mediaEnd,
                                               text: "한국어 Swift concurrency")
        try roundTrip(STTTestFixture.capabilities())
        try roundTrip(request.audio.format)
        try roundTrip(request.audio)
        try roundTrip(config.model.options)
        try roundTrip(config.model)
        try roundTrip(config)
        try roundTrip(request.context)
        try roundTrip(request)
        try roundTrip(segment)
        try roundTrip(config.operationID)
        try roundTrip(request.context.requestID)
        for code in STTErrorCode.allCases { try roundTrip(STTEngineError(code)) }
        for kind in [STTResponseKind.partial, .final, .failed, .cancelled] {
            let response = try STTResponse(context: request.context, revision: 1, kind: kind,
                                           segments: kind == .partial || kind == .final ? [segment] : [],
                                           detectedLanguage: kind == .partial ? nil : LanguageCode("ko"),
                                           failure: kind == .failed ? STTEngineError(.inferenceFailed)
                                           : kind == .cancelled ? STTEngineError(.cancelled) : nil)
            try roundTrip(response)
            XCTAssertEqual(response.context.session.model.engine.version, "1.0")
            XCTAssertEqual(response.context.session.model.model.revision, "r1")
            XCTAssertEqual(response.context.session.model.model.checksum, "sha256-r1")
        }
    }

    func testInvalidConfigurationAndMalformedDecodedValuesAreRejected() throws {
        for temperature in [Double.nan, .infinity, -0.1, 1.1] {
            XCTAssertThrowsError(try STTInferenceOptions(temperature: temperature))
        }
        XCTAssertThrowsError(try STTInferenceOptions(computeMode: ""))
        try malformed(STTInferenceOptions()) { $0["temperature"] = -1 }
        try malformed(STTInferenceOptions()) { $0["computeMode"] = "" }
        try malformed(STTTestFixture.capabilities()) { $0["inputFormats"] = [] }
        try malformed(STTTestFixture.capabilities()) { $0["languageModes"] = [] }
        try malformed(STTTestFixture.model()) { object in
            var engine = object["engine"] as! [String: Any]; engine["version"] = ""; object["engine"] = engine
        }
        try malformed(STTTestFixture.model()) { object in
            var model = object["model"] as! [String: Any]; model["checksum"] = ""; object["model"] = model
        }
        XCTAssertThrowsError(try STTCapabilities(inputFormats: [], languageModes: [.korean], languages: [LanguageCode("ko")],
                                                partialResults: true, timestamps: true))
    }

    func testInvalidAudioTimeOverflowAndMalformedDecodedAudioAreRejected() throws {
        for rate in [Double.nan, .infinity, 0, -1] { XCTAssertThrowsError(try STTInputFormat(sampleRate: rate)) }
        XCTAssertThrowsError(try STTInputFormat(channelCount: 0))
        let format = try STTInputFormat()
        for samples in [[Float.nan], [Float.infinity], [0, 1]] {
            XCTAssertThrowsError(try STTInferenceAudio(format: format, frameCount: 1, samples: samples))
        }
        XCTAssertThrowsError(try STTInferenceAudio(format: format, frameCount: Int.max, samples: []))
        XCTAssertThrowsError(try STTInferenceAudio(format: STTInputFormat(channelCount: 32), frameCount: Int.max, samples: []))
        XCTAssertThrowsError(try STTInferenceAudio(format: format, frameCount: 480_001, samples: Array(repeating: 0, count: 480_001)))
        let audio = try STTTestFixture.audio()
        try malformed(format) { $0["sampleRate"] = -1 }
        try malformed(format) { $0["channelCount"] = 0 }
        try malformed(audio) { $0["frameCount"] = -1 }
        try malformed(audio) { $0["samples"] = [] }
        try malformed(audio) { $0["duration"] = 11 }
        let request = try STTTestFixture.request()
        try malformed(request.context) { $0["sequence"] = -1 }
        try malformed(request.context) { $0["mediaStart"] = -1 }
        try malformed(request.context) { $0["mediaEnd"] = 4_999 }
        try malformed(request) { object in
            var context = object["context"] as! [String: Any]; context["mediaEnd"] = 5_011; object["context"] = context
        }
        XCTAssertThrowsError(try STTInferenceRequest(session: STTTestFixture.session(), requestID: request.context.requestID,
                                                    sequence: 0, mediaStart: MediaMilliseconds(Int64.max), audio: audio))
        let rounded = try STTInferenceAudio(format: format, frameCount: 24, samples: Array(repeating: 0, count: 24))
        XCTAssertEqual(rounded.duration.rawValue, 2) // 1.5 ms rounds to 2 ms.
    }

    func testConfiguredNonfiniteDecodingStillUsesValidatedInitializers() throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let cases: [(String, Data)] = [
            ("format", Data(#"{"sampleRate":"NaN","channelCount":1,"layout":"float32Interleaved"}"#.utf8)),
            ("options", Data(#"{"partialResults":true,"timestamps":true,"temperature":"Infinity","computeMode":"default"}"#.utf8))
        ]
        XCTAssertThrowsError(try decoder.decode(STTInputFormat.self, from: cases[0].1))
        XCTAssertThrowsError(try decoder.decode(STTInferenceOptions.self, from: cases[1].1))
        var audio = try JSONSerialization.jsonObject(with: JSONEncoder().encode(STTTestFixture.audio())) as! [String: Any]
        audio["samples"] = Array(repeating: "NaN", count: 160)
        XCTAssertThrowsError(try decoder.decode(STTInferenceAudio.self, from: JSONSerialization.data(withJSONObject: audio)))
    }

    func testInvalidResponseBoundsRevisionOrderAndDecodedResponsesAreRejected() throws {
        let context = try STTTestFixture.request().context
        let segment = try STTHypothesisSegment(start: MediaMilliseconds(5_000), end: MediaMilliseconds(5_010), text: "테스트")
        XCTAssertThrowsError(try STTHypothesisSegment(start: MediaMilliseconds(5_010), end: MediaMilliseconds(5_000), text: ""))
        let response = try STTResponse(context: context, revision: 1, kind: .final, segments: [segment])
        for revision in [Int64(0), -1, .max] {
            XCTAssertThrowsError(try STTResponse(context: context, revision: revision, kind: .final))
        }
        let outside = try STTHypothesisSegment(start: MediaMilliseconds(0), end: MediaMilliseconds(10), text: "offset missing")
        XCTAssertThrowsError(try STTResponse(context: context, revision: 1, kind: .final, segments: [outside]))
        XCTAssertThrowsError(try STTResponse(context: context, revision: 1, kind: .final, segments: [segment, segment]))
        XCTAssertThrowsError(try STTResponse(context: context, revision: 1, kind: .failed))
        XCTAssertThrowsError(try STTResponse(context: context, revision: 1, kind: .cancelled))
        XCTAssertThrowsError(try STTResponse(context: context, revision: 1, kind: .final, detectedLanguage: LanguageCode("en")))
        try malformed(segment) { $0["end"] = 4_999 }
        try malformed(response) { $0["revision"] = 0 }
        try malformed(response) { $0["kind"] = "failed" }
        try malformed(response) { object in
            var segments = object["segments"] as! [[String: Any]]; segments[0]["end"] = 5_011; object["segments"] = segments
        }
    }
}
