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
        case .finalizationCheckpoint: "recovery/finalization.checkpoint.json"
        }
    }

    var ownership: SessionArtifactOwnership {
        switch self {
        case .transcriptText, .transcriptMarkdown: .derived
        case .metadata, .finalAudio, .transcript, .events, .recoveryAudio, .transcriptJournal, .finalizationCheckpoint:
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
}
