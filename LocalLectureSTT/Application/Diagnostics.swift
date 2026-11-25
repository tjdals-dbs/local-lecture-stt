import Foundation

enum DiagnosticSource: String, Codable, Sendable {
    case app, recording, speech, finalization, recovery, storage, models, catalog, sessionDetail
}
enum DiagnosticSignal: Codable, Sendable, Equatable {
    case appStarted
    case issue(UserIssueCode)
    case sessionEvent(SessionEventKind)
}
/// A closed vocabulary: there is deliberately no free-form string, Error,
/// transcript, title, prompt, audio, path or URL field in an app-log record.
struct DiagnosticEntry: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let occurredAt: Date
    let source: DiagnosticSource
    let signal: DiagnosticSignal
    let sessionID: UUID?
    init(source: DiagnosticSource, signal: DiagnosticSignal, sessionID: UUID? = nil, occurredAt: Date = Date()) {
        schemaVersion = 1; self.source = source; self.signal = signal
        self.sessionID = sessionID; self.occurredAt = occurredAt
    }
}
protocol DiagnosticRecording: Sendable {
    /// Bounded synchronous admission only; never wait for disk on the audio path.
    func record(_ entry: DiagnosticEntry)
}
struct NoopDiagnosticRecorder: DiagnosticRecording { func record(_ entry: DiagnosticEntry) {} }
extension DiagnosticRecording {
    func issue(_ value: UserIssue, source: DiagnosticSource, sessionID: SessionID? = nil) {
        record(.init(source: source, signal: .issue(value.code), sessionID: sessionID?.rawValue))
    }
    func sessionEvent(_ event: SessionEventRecord) {
        record(.init(source: .recording, signal: .sessionEvent(event.kind),
                     sessionID: event.sessionId.rawValue, occurredAt: event.occurredAt.value))
    }
}
enum DiagnosticFailure: String, Error, Codable, Sendable {
    case storage, unsafeLayout, corruptLog, destinationExists, exportFailed, cancelled, invalidPolicy
}
struct DiagnosticSummary: Sendable, Equatable {
    let fileCount: Int
    let bytes: Int64
    let droppedEntries: UInt64
    let lastFailure: DiagnosticFailure?
}
protocol DiagnosticManaging: Sendable {
    func summary() async throws -> DiagnosticSummary
    func clear() async throws
}
final class DiagnosticCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { try lock.withLock { if cancelled { throw DiagnosticFailure.cancelled } } }
}

/// Deduplicates unchanged error snapshots, while allowing a new episode after
/// the issue clears. The owner keeps this value on its existing serial executor.
struct DiagnosticIssueTracker {
    private var previous: Set<UserIssueCode> = []
    mutating func update(_ issues: [UserIssue], source: DiagnosticSource, sessionID: SessionID? = nil,
                         recorder: any DiagnosticRecording) {
        let next = Set(issues.map(\.code))
        for code in next.subtracting(previous).sorted(by: { $0.rawValue < $1.rawValue }) {
            recorder.issue(.init(code: code), source: source, sessionID: sessionID)
        }
        previous = next
    }
}
