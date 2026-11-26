import Foundation

enum SessionArtifact: String, CaseIterable, Codable, Sendable {
    case metadata
    case finalAudio
    case transcript
    case transcriptText
    case transcriptMarkdown
    case events
    case recoveryAudio
    case transcriptJournal
    case finalizationCheckpoint
    case speechRecovery

    var relativePath: String {
        switch self {
        case .metadata: "metadata.json"
        case .finalAudio: "audio.m4a"
        case .transcript: "transcript.json"
        case .transcriptText: "transcript.txt"
        case .transcriptMarkdown: "transcript.md"
        case .events: "events.jsonl"
        case .recoveryAudio: "recovery/audio.recovery.mov"
        case .transcriptJournal: "recovery/transcript.journal.jsonl"
        case .speechRecovery: "recovery/speech-recovery.json"
        case .finalizationCheckpoint: "recovery/finalization.checkpoint.json"
        }
    }

    var ownership: SessionArtifactOwnership {
        switch self {
        case .transcriptText, .transcriptMarkdown: .derived
        case .metadata, .finalAudio, .transcript, .events, .recoveryAudio, .transcriptJournal, .finalizationCheckpoint, .speechRecovery:
            .authoritativeOrRecovery
        }
    }
}

enum SessionArtifactOwnership: String, Codable, Sendable {
    case authoritativeOrRecovery
    case derived
}

struct SessionFolderName: Codable, Sendable, Equatable, Hashable {
    let rawValue: String

    init(sessionID: SessionID, createdAt: AbsoluteTime, timeZone: TimeZone) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let compactID = sessionID.rawValue.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        self.rawValue = "\(formatter.string(from: createdAt.value))_\(compactID.prefix(8))"
    }

    init(validating rawValue: String) throws {
        let bytes = Array(rawValue.utf8)
        guard bytes.count == 24, bytes[8] == 45, bytes[15] == 95 else {
            throw DomainValidationError.invalidSessionFolderName
        }
        for index in 0..<15 where index != 8 {
            guard bytes[index] >= 48, bytes[index] <= 57 else { throw DomainValidationError.invalidSessionFolderName }
        }
        for index in 16..<24 {
            let byte = bytes[index]
            guard (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102) else {
                throw DomainValidationError.invalidSessionFolderName
            }
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = String(rawValue.prefix(15))
        guard let parsed = formatter.date(from: timestamp), formatter.string(from: parsed) == timestamp else {
            throw DomainValidationError.invalidSessionFolderName
        }
        self.rawValue = rawValue
    }

    func matches(_ sessionID: SessionID) -> Bool {
        let compactID = sessionID.rawValue.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return rawValue.suffix(8) == compactID.prefix(8)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(validating: container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
