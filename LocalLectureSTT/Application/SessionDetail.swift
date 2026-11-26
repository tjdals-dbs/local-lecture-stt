import Foundation

enum SessionDetailFile: String, Codable, Sendable, CaseIterable {
    case audio = "audio.m4a", transcript = "transcript.json", markdown = "transcript.md"
}
struct SessionDetailIssue: Codable, Sendable, Equatable {
    let artifact: String
    let code: String
}
struct SessionDetailDocument: Codable, Sendable, Equatable {
    let location: SessionLocation
    let metadata: SessionMetadataDocument?
    let transcript: TranscriptDocument?
    let availableFiles: [SessionDetailFile]
    let editable: Bool
    let issues: [SessionDetailIssue]
    var speechRecovery: SpeechRecoverySummary? = nil
}
enum SessionDetailFailure: String, Error, Codable, Sendable {
    case busy, unavailable, invalidAudio, invalidSeek, identityChanged, notFinalized, conflict, cancelled
}
struct SessionTrashResult: Codable, Sendable, Equatable {
    let catalogWarning: Bool
}
protocol SessionDetailStoring: Sendable {
    func load(_ location: SessionLocation) async throws -> SessionDetailDocument
    func updateText(_ location: SessionLocation, segment: TranscriptSegmentID, expected: String, text: String) async throws
    func updateTitle(_ location: SessionLocation, expected: String, title: String) async throws
    func regenerate(_ location: SessionLocation) async throws
    func reveal(_ file: SessionDetailFile, at location: SessionLocation) async throws
    func trash(_ location: SessionLocation) async throws -> SessionTrashResult
}
enum SessionPlaybackPhase: String, Codable, Sendable { case idle, loading, paused, playing, failed }
struct SessionPlaybackSnapshot: Codable, Sendable, Equatable {
    var phase: SessionPlaybackPhase = .idle
    var positionMilliseconds: Int64 = 0
    var durationMilliseconds: Int64 = 0
    var failure: SessionDetailFailure?
}
@MainActor
protocol SessionPlaybackControlling: AnyObject, Sendable {
    func snapshots() -> AsyncStream<SessionPlaybackSnapshot>
    func open(_ location: SessionLocation) async throws
    func play() async throws
    func pause()
    func seek(to milliseconds: Int64) async throws
    func close() async
}

enum SessionDetailDiagnostics {
    static func code(_ error: Error) -> String {
        if let e = error as? TranscriptFailure { return e.code.rawValue }
        if let e = error as? StorageError { return e.code.rawValue }
        if let e = error as? AudioFinalizationCode { return e.rawValue }
        if let e = error as? SessionDetailFailure { return e.rawValue }
        return "unavailable"
    }
}
