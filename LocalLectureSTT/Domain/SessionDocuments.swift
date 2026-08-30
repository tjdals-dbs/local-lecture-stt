import Foundation

struct AudioDescription: Codable, Sendable, Equatable {
    let format: String
    let sampleRate: Int
    let channels: Int
    let bitRate: Int

    init(format: String, sampleRate: Int, channels: Int, bitRate: Int) throws {
        guard !format.isEmpty, sampleRate > 0, channels > 0, bitRate > 0 else {
            throw DomainValidationError.invalidAudioDescription
        }
        self.format = format
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitRate = bitRate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            format: container.decode(String.self, forKey: .format),
            sampleRate: container.decode(Int.self, forKey: .sampleRate),
            channels: container.decode(Int.self, forKey: .channels),
            bitRate: container.decode(Int.self, forKey: .bitRate)
        )
    }
}

struct TranscriptSummary: Codable, Sendable, Equatable {
    let segmentCount: TranscriptSegmentCount
}

struct SessionMetadataDocument: Codable, Sendable, Equatable {
    let schemaVersion: SchemaVersion
    let sessionId: SessionID
    let title: String
    let status: SessionStatus
    let captureOutcome: CaptureOutcome
    let createdAt: AbsoluteTime
    let recordingStartedAt: AbsoluteTime?
    let recordingEndedAt: AbsoluteTime?
    let activeDurationMs: MediaMilliseconds
    let languageMode: LanguageMode
    let detectedLanguage: LanguageCode?
    let engine: EngineIdentity?
    let model: ModelIdentity?
    let audio: AudioDescription?
    let transcript: TranscriptSummary
    let appVersion: String
    let osVersion: String
    let lastUpdatedAt: AbsoluteTime

    init(
        schemaVersion: SchemaVersion = .current,
        sessionId: SessionID,
        title: String,
        status: SessionStatus,
        captureOutcome: CaptureOutcome,
        createdAt: AbsoluteTime,
        recordingStartedAt: AbsoluteTime? = nil,
        recordingEndedAt: AbsoluteTime? = nil,
        activeDurationMs: MediaMilliseconds,
        languageMode: LanguageMode,
        detectedLanguage: LanguageCode? = nil,
        engine: EngineIdentity? = nil,
        model: ModelIdentity? = nil,
        audio: AudioDescription? = nil,
        transcript: TranscriptSummary,
        appVersion: String,
        osVersion: String,
        lastUpdatedAt: AbsoluteTime
    ) throws {
        try SchemaVersionPolicy.validate(schemaVersion)
        _ = try SessionLifecycle(status: status, captureOutcome: captureOutcome)
        try DomainValidation.requireNonEmpty(title, field: "title")
        try DomainValidation.requireNonEmpty(appVersion, field: "app version")
        try DomainValidation.requireNonEmpty(osVersion, field: "os version")
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.title = title
        self.status = status
        self.captureOutcome = captureOutcome
        self.createdAt = createdAt
        self.recordingStartedAt = recordingStartedAt
        self.recordingEndedAt = recordingEndedAt
        self.activeDurationMs = activeDurationMs
        self.languageMode = languageMode
        self.detectedLanguage = detectedLanguage
        self.engine = engine
        self.model = model
        self.audio = audio
        self.transcript = transcript
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.lastUpdatedAt = lastUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(SchemaVersion.self, forKey: .schemaVersion),
            sessionId: container.decode(SessionID.self, forKey: .sessionId),
            title: container.decode(String.self, forKey: .title),
            status: container.decode(SessionStatus.self, forKey: .status),
            captureOutcome: container.decode(CaptureOutcome.self, forKey: .captureOutcome),
            createdAt: container.decode(AbsoluteTime.self, forKey: .createdAt),
            recordingStartedAt: container.decodeIfPresent(AbsoluteTime.self, forKey: .recordingStartedAt),
            recordingEndedAt: container.decodeIfPresent(AbsoluteTime.self, forKey: .recordingEndedAt),
            activeDurationMs: container.decode(MediaMilliseconds.self, forKey: .activeDurationMs),
            languageMode: container.decode(LanguageMode.self, forKey: .languageMode),
            detectedLanguage: container.decodeIfPresent(LanguageCode.self, forKey: .detectedLanguage),
            engine: container.decodeIfPresent(EngineIdentity.self, forKey: .engine),
            model: container.decodeIfPresent(ModelIdentity.self, forKey: .model),
            audio: container.decodeIfPresent(AudioDescription.self, forKey: .audio),
            transcript: container.decode(TranscriptSummary.self, forKey: .transcript),
            appVersion: container.decode(String.self, forKey: .appVersion),
            osVersion: container.decode(String.self, forKey: .osVersion),
            lastUpdatedAt: container.decode(AbsoluteTime.self, forKey: .lastUpdatedAt)
        )
    }
}

struct TranscriptSegment: Codable, Sendable, Equatable {
    let id: TranscriptSegmentID
    let sequence: TranscriptSegmentSequence
    let startMs: MediaMilliseconds
    let endMs: MediaMilliseconds
    let originalText: String
    var text: String
    let language: LanguageCode

    init(
        id: TranscriptSegmentID,
        sequence: TranscriptSegmentSequence,
        startMs: MediaMilliseconds,
        endMs: MediaMilliseconds,
        originalText: String,
        text: String,
        language: LanguageCode
    ) throws {
        guard startMs <= endMs else {
            throw DomainValidationError.invalidSegmentBounds(start: startMs.rawValue, end: endMs.rawValue)
        }
        self.id = id
        self.sequence = sequence
        self.startMs = startMs
        self.endMs = endMs
        self.originalText = originalText
        self.text = text
        self.language = language
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(TranscriptSegmentID.self, forKey: .id),
            sequence: container.decode(TranscriptSegmentSequence.self, forKey: .sequence),
            startMs: container.decode(MediaMilliseconds.self, forKey: .startMs),
            endMs: container.decode(MediaMilliseconds.self, forKey: .endMs),
            originalText: container.decode(String.self, forKey: .originalText),
            text: container.decode(String.self, forKey: .text),
            language: container.decode(LanguageCode.self, forKey: .language)
        )
    }
}

struct TranscriptDocument: Codable, Sendable, Equatable {
    let schemaVersion: SchemaVersion
    let sessionId: SessionID
    let segments: [TranscriptSegment]

    init(schemaVersion: SchemaVersion = .current, sessionId: SessionID, segments: [TranscriptSegment]) throws {
        try SchemaVersionPolicy.validate(schemaVersion)
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.segments = segments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(SchemaVersion.self, forKey: .schemaVersion),
            sessionId: container.decode(SessionID.self, forKey: .sessionId),
            segments: container.decode([TranscriptSegment].self, forKey: .segments)
        )
    }
}

/// One independently persisted line in recovery/transcript.journal.jsonl.
struct TranscriptJournalRecord: Codable, Sendable, Equatable {
    let schemaVersion: SchemaVersion
    let sessionId: SessionID
    let segment: TranscriptSegment

    init(
        schemaVersion: SchemaVersion = .current,
        sessionId: SessionID,
        segment: TranscriptSegment
    ) throws {
        try SchemaVersionPolicy.validate(schemaVersion)
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.segment = segment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(SchemaVersion.self, forKey: .schemaVersion),
            sessionId: container.decode(SessionID.self, forKey: .sessionId),
            segment: container.decode(TranscriptSegment.self, forKey: .segment)
        )
    }
}
