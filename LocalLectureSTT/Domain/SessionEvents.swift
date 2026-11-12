import Foundation

enum SessionEventKind: String, Codable, Sendable, CaseIterable {
    case recordingStarted
    case recordingEnded
    case recordingPaused
    case recordingResumed
    case systemSleep
    case systemWake
    case applicationTermination
    case microphoneDisconnected
    case noInputWarning
    case sttError
    case sttBackpressureDegraded
    case fileWriteError
    case storageAccessError
    case recoveryStarted
    case recoveryCompleted
    case finalizationStepTransition
}

struct SessionEventDetail: Codable, Sendable, Equatable {
    let code: String
    let message: String?

    init(code: String, message: String? = nil) throws {
        try DomainValidation.requireNonEmpty(code, field: "event detail code")
        self.code = code
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            code: container.decode(String.self, forKey: .code),
            message: container.decodeIfPresent(String.self, forKey: .message)
        )
    }
}

struct SessionEventRecord: Codable, Sendable, Equatable {
    let schemaVersion: SchemaVersion
    let sessionId: SessionID
    let eventId: SessionEventID
    let occurredAt: AbsoluteTime
    let kind: SessionEventKind
    let mediaPositionMs: MediaMilliseconds?
    let detail: SessionEventDetail?

    init(
        schemaVersion: SchemaVersion = .current,
        sessionId: SessionID,
        eventId: SessionEventID,
        occurredAt: AbsoluteTime,
        kind: SessionEventKind,
        mediaPositionMs: MediaMilliseconds? = nil,
        detail: SessionEventDetail? = nil
    ) throws {
        try SchemaVersionPolicy.validate(schemaVersion)
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.eventId = eventId
        self.occurredAt = occurredAt
        self.kind = kind
        self.mediaPositionMs = mediaPositionMs
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(SchemaVersion.self, forKey: .schemaVersion),
            sessionId: container.decode(SessionID.self, forKey: .sessionId),
            eventId: container.decode(SessionEventID.self, forKey: .eventId),
            occurredAt: container.decode(AbsoluteTime.self, forKey: .occurredAt),
            kind: container.decode(SessionEventKind.self, forKey: .kind),
            mediaPositionMs: container.decodeIfPresent(MediaMilliseconds.self, forKey: .mediaPositionMs),
            detail: container.decodeIfPresent(SessionEventDetail.self, forKey: .detail)
        )
    }
}
