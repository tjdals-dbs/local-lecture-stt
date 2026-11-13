import Foundation

enum STTErrorCode: String, Codable, Sendable, CaseIterable {
    case invalidLifecycle, invalidConfiguration, invalidInput, invalidResponse
    case unsupportedCapability, unsupportedModel, busy, sessionMismatch, backlogFull
    case loadFailed, startFailed, inferenceFailed, cancelled, cleanupFailed, consumerAlreadyClaimed
}

struct STTEngineError: Error, Codable, Sendable, Equatable {
    let code: STTErrorCode
    init(_ code: STTErrorCode) { self.code = code }
}

struct STTRequestID: Codable, Sendable, Hashable {
    let rawValue: UUID
    init(_ rawValue: UUID) { self.rawValue = rawValue }
}

struct STTOperationID: Codable, Sendable, Hashable {
    let rawValue: UUID
    init(_ rawValue: UUID) { self.rawValue = rawValue }
}

enum STTAudioLayout: String, Codable, Sendable { case float32Interleaved }

struct STTInputFormat: Codable, Sendable, Equatable {
    let sampleRate: Double
    let channelCount: Int
    let layout: STTAudioLayout

    init(sampleRate: Double = 16_000, channelCount: Int = 1, layout: STTAudioLayout = .float32Interleaved) throws {
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= 384_000,
              channelCount > 0, channelCount <= 32 else { throw STTEngineError(.invalidInput) }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.layout = layout
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sampleRate: c.decode(Double.self, forKey: .sampleRate),
                      channelCount: c.decode(Int.self, forKey: .channelCount),
                      layout: c.decode(STTAudioLayout.self, forKey: .layout))
    }
}

struct STTCapabilities: Codable, Sendable, Equatable {
    let inputFormats: [STTInputFormat]
    let languageModes: [LanguageMode]
    let languages: [LanguageCode]
    let partialResults: Bool
    let timestamps: Bool

    init(inputFormats: [STTInputFormat], languageModes: [LanguageMode], languages: [LanguageCode],
         partialResults: Bool, timestamps: Bool) throws {
        guard !inputFormats.isEmpty, inputFormats.count <= 16, !languageModes.isEmpty,
              languageModes.count <= 3, !languages.isEmpty, languages.count <= 256 else {
            throw STTEngineError(.invalidConfiguration)
        }
        self.inputFormats = inputFormats
        self.languageModes = languageModes
        self.languages = languages
        self.partialResults = partialResults
        self.timestamps = timestamps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(inputFormats: c.decode([STTInputFormat].self, forKey: .inputFormats),
                      languageModes: c.decode([LanguageMode].self, forKey: .languageModes),
                      languages: c.decode([LanguageCode].self, forKey: .languages),
                      partialResults: c.decode(Bool.self, forKey: .partialResults),
                      timestamps: c.decode(Bool.self, forKey: .timestamps))
    }
}

struct STTInferenceOptions: Codable, Sendable, Equatable {
    let partialResults: Bool
    let timestamps: Bool
    let temperature: Double
    let computeMode: String

    init(partialResults: Bool = true, timestamps: Bool = true, temperature: Double = 0,
         computeMode: String = "default") throws {
        guard temperature.isFinite, (0...1).contains(temperature), !computeMode.isEmpty,
              computeMode.utf8.count <= 128 else { throw STTEngineError(.invalidConfiguration) }
        self.partialResults = partialResults
        self.timestamps = timestamps
        self.temperature = temperature
        self.computeMode = computeMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(partialResults: c.decode(Bool.self, forKey: .partialResults),
                      timestamps: c.decode(Bool.self, forKey: .timestamps),
                      temperature: c.decode(Double.self, forKey: .temperature),
                      computeMode: c.decode(String.self, forKey: .computeMode))
    }
}

struct STTModelConfiguration: Codable, Sendable, Equatable {
    let engine: EngineIdentity
    let model: ModelIdentity
    let options: STTInferenceOptions
}

struct STTSessionConfiguration: Codable, Sendable, Equatable {
    let sessionID: SessionID
    let operationID: STTOperationID
    let model: STTModelConfiguration
    let languageMode: LanguageMode
}

/// Owned frame-major Float32 data. A request is at most 30 seconds and 960,000 samples.
struct STTInferenceAudio: Codable, Sendable, Equatable {
    let format: STTInputFormat
    let frameCount: Int
    let samples: [Float]
    let duration: MediaMilliseconds

    init(format: STTInputFormat, frameCount: Int, samples: [Float]) throws {
        let count = frameCount.multipliedReportingOverflow(by: format.channelCount)
        let ms = (Double(frameCount) / format.sampleRate * 1_000).rounded()
        guard frameCount > 0, !count.overflow, count.partialValue == samples.count,
              samples.count <= 960_000, samples.allSatisfy(\.isFinite),
              ms.isFinite, ms >= 1, ms <= 30_000, Double(frameCount) <= format.sampleRate * 30 else { throw STTEngineError(.invalidInput) }
        self.format = format
        self.frameCount = frameCount
        self.samples = samples
        self.duration = try MediaMilliseconds(Int64(ms))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(format: c.decode(STTInputFormat.self, forKey: .format),
                      frameCount: c.decode(Int.self, forKey: .frameCount),
                      samples: c.decode([Float].self, forKey: .samples))
        guard try c.decode(MediaMilliseconds.self, forKey: .duration) == duration else {
            throw STTEngineError(.invalidInput)
        }
    }
}

struct STTRequestContext: Codable, Sendable, Equatable {
    let session: STTSessionConfiguration
    let requestID: STTRequestID
    let sequence: Int64
    let mediaStart: MediaMilliseconds
    let mediaEnd: MediaMilliseconds

    init(session: STTSessionConfiguration, requestID: STTRequestID, sequence: Int64,
         mediaStart: MediaMilliseconds, mediaEnd: MediaMilliseconds) throws {
        guard sequence >= 0, mediaEnd > mediaStart,
              mediaEnd.rawValue - mediaStart.rawValue <= 30_000 else { throw STTEngineError(.invalidInput) }
        self.session = session
        self.requestID = requestID
        self.sequence = sequence
        self.mediaStart = mediaStart
        self.mediaEnd = mediaEnd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(session: c.decode(STTSessionConfiguration.self, forKey: .session),
                      requestID: c.decode(STTRequestID.self, forKey: .requestID),
                      sequence: c.decode(Int64.self, forKey: .sequence),
                      mediaStart: c.decode(MediaMilliseconds.self, forKey: .mediaStart),
                      mediaEnd: c.decode(MediaMilliseconds.self, forKey: .mediaEnd))
    }
}

struct STTInferenceRequest: Codable, Sendable, Equatable {
    let context: STTRequestContext
    let audio: STTInferenceAudio

    init(session: STTSessionConfiguration, requestID: STTRequestID, sequence: Int64,
         mediaStart: MediaMilliseconds, audio: STTInferenceAudio) throws {
        let end = mediaStart.rawValue.addingReportingOverflow(audio.duration.rawValue)
        guard !end.overflow else { throw STTEngineError(.invalidInput) }
        try self.init(context: STTRequestContext(session: session, requestID: requestID, sequence: sequence,
                                               mediaStart: mediaStart, mediaEnd: MediaMilliseconds(end.partialValue)), audio: audio)
    }

    init(context: STTRequestContext, audio: STTInferenceAudio) throws {
        guard context.mediaEnd.rawValue - context.mediaStart.rawValue == audio.duration.rawValue else {
            throw STTEngineError(.invalidInput)
        }
        self.context = context
        self.audio = audio
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(context: c.decode(STTRequestContext.self, forKey: .context),
                      audio: c.decode(STTInferenceAudio.self, forKey: .audio))
    }
}

/// Engine hypotheses are full replacement snapshots, not canonical TranscriptSegments.
struct STTHypothesisSegment: Codable, Sendable, Equatable {
    let start: MediaMilliseconds
    let end: MediaMilliseconds
    let text: String

    init(start: MediaMilliseconds, end: MediaMilliseconds, text: String) throws {
        guard end >= start, text.utf8.count <= 16_384 else { throw STTEngineError(.invalidResponse) }
        self.start = start
        self.end = end
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(start: c.decode(MediaMilliseconds.self, forKey: .start),
                      end: c.decode(MediaMilliseconds.self, forKey: .end), text: c.decode(String.self, forKey: .text))
    }
}

enum STTResponseKind: String, Codable, Sendable { case partial, final, failed, cancelled }

struct STTResponse: Codable, Sendable, Equatable {
    let context: STTRequestContext
    let revision: Int64
    let kind: STTResponseKind
    let segments: [STTHypothesisSegment]
    let detectedLanguage: LanguageCode?
    let failure: STTEngineError?
    var isTerminal: Bool { kind != .partial }

    init(context: STTRequestContext, revision: Int64, kind: STTResponseKind,
         segments: [STTHypothesisSegment] = [], detectedLanguage: LanguageCode? = nil,
         failure: STTEngineError? = nil) throws {
        guard revision > 0, revision < Int64.max, segments.count <= 128,
              segments.reduce(0, { $0 + $1.text.utf8.count }) <= 65_536 else {
            throw STTEngineError(.invalidResponse)
        }
        switch kind {
        case .partial, .final:
            guard failure == nil else { throw STTEngineError(.invalidResponse) }
        case .failed:
            guard let failure, failure.code != .cancelled, segments.isEmpty else { throw STTEngineError(.invalidResponse) }
        case .cancelled:
            guard failure == STTEngineError(.cancelled), segments.isEmpty else { throw STTEngineError(.invalidResponse) }
        }
        guard kind != .partial || context.session.model.options.partialResults else { throw STTEngineError(.invalidResponse) }
        if let detectedLanguage {
            let expected: String? = switch context.session.languageMode {
            case .korean: "ko"
            case .english: "en"
            case .automatic: nil
            }
            guard expected == nil || detectedLanguage.rawValue == expected else { throw STTEngineError(.invalidResponse) }
        }
        var previous = context.mediaStart
        for segment in segments {
            guard segment.start >= previous, segment.end <= context.mediaEnd else { throw STTEngineError(.invalidResponse) }
            previous = segment.end
        }
        self.context = context
        self.revision = revision
        self.kind = kind
        self.segments = segments
        self.detectedLanguage = detectedLanguage
        self.failure = failure
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(context: c.decode(STTRequestContext.self, forKey: .context),
                      revision: c.decode(Int64.self, forKey: .revision), kind: c.decode(STTResponseKind.self, forKey: .kind),
                      segments: c.decode([STTHypothesisSegment].self, forKey: .segments),
                      detectedLanguage: c.decodeIfPresent(LanguageCode.self, forKey: .detectedLanguage),
                      failure: c.decodeIfPresent(STTEngineError.self, forKey: .failure))
    }
}
