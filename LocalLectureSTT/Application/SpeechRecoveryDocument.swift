import Foundation

enum SpeechRecoveryState: String, Codable, Sendable { case pending, prepared, complete, exhausted }
struct SpeechRecoveryEntry: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let range: SpeechRecoveryRange
    var state: SpeechRecoveryState = .pending
    var attempts = 0
    var segments: [TranscriptSegment] = []
    var recovered = false
    var failure: STTErrorCode?
}

/// Atomic intent/result ledger. Only unmarked sessions may omit this file;
/// missing or unreadable marked ledgers never mean empty success.
struct SpeechRecoveryDocument: Codable, Sendable, Equatable {
    static let path = "recovery/speech-recovery.json"
    var schemaVersion = 1
    let session: STTSessionConfiguration
    var language: LanguageCode?
    var scannedThrough: Int64 = 0
    var captureEnded = false
    var entries: [SpeechRecoveryEntry] = []

    var summary: SpeechRecoverySummary {
        .init(pending: entries.filter { $0.state == .pending || $0.state == .prepared }.count,
              unresolved: entries.filter { $0.state == .exhausted }.count,
              recovered: entries.filter { $0.state == .complete && $0.recovered }.count,
              pendingRanges: entries.filter { $0.state == .pending || $0.state == .prepared }.map(\.range),
              unresolvedRanges: entries.filter { $0.state == .exhausted }.map(\.range))
    }
    func validate(sessionID: SessionID) throws {
        guard schemaVersion == 1, session.sessionID == sessionID, scannedThrough >= 0,
              entries.count <= 50_000, Set(entries.map(\.id)).count == entries.count,
              Set(entries.map(\.range)).count == entries.count,
              language == nil || ["ko", "en"].contains(language!.rawValue),
              session.languageMode == .automatic || language?.rawValue == (session.languageMode == .korean ? "ko" : "en"),
              try JSONEncoder().encode(self).count <= 16 * 1024 * 1024 else {
            throw TranscriptFailure(code: .canonicalConflict)
        }
        var ids = Set<TranscriptSegmentID>()
        for entry in entries {
            guard (0...2).contains(entry.attempts), entry.range.start >= 0, entry.range.end > entry.range.start,
                  entry.state == .complete || entry.state == .prepared || entry.segments.isEmpty,
                  entry.state != .exhausted || entry.attempts == 2,
                  !entry.recovered || entry.state == .complete else {
                throw TranscriptFailure(code: .canonicalConflict)
            }
            for segment in entry.segments {
                guard ids.insert(segment.id).inserted,
                      segment.startMs.rawValue >= entry.range.start, segment.endMs.rawValue <= entry.range.end,
                      segment.text == segment.originalText, segment.language == language else { throw TranscriptFailure(code: .canonicalConflict) }
            }
        }
    }

    func validate(metadata: SessionMetadataDocument) throws {
        try validate(sessionID: metadata.sessionId)
        guard metadata.engine == session.model.engine, metadata.model == session.model.model,
              metadata.modelSettings?.inference == session.model.options,
              metadata.languageMode == session.languageMode,
              metadata.detectedLanguage == nil || language == metadata.detectedLanguage else {
            throw TranscriptFailure(code: .canonicalConflict)
        }
    }

    @discardableResult mutating func register(_ range: SpeechRecoveryRange) -> UUID {
        if let old = entries.first(where: { $0.range == range }) { return old.id }
        let entry = SpeechRecoveryEntry(id: UUID(), range: range)
        entries.append(entry)
        return entry.id
    }

    /// Cut a missing interval around already-owned windows, including silence
    /// windows with an explicitly committed empty result. Text times are not coverage.
    mutating func addMissing(_ range: SpeechRecoveryRange) throws {
        var remaining = [range]
        for existing in entries {
            remaining = try remaining.flatMap { span -> [SpeechRecoveryRange] in
                let lo = max(span.start, existing.range.start), hi = min(span.end, existing.range.end)
                guard lo < hi else { return [span] }
                var parts: [SpeechRecoveryRange] = []
                if span.start < lo { parts.append(try .init(span.start, lo)) }
                if hi < span.end { parts.append(try .init(hi, span.end)) }
                return parts
            }
        }
        for span in remaining {
            var start = span.start
            while start < span.end {
                guard entries.count < 50_000 else { throw TranscriptFailure(code: .canonicalConflict) }
                let end = start + min(20_000, span.end - start)
                register(try .init(start, end)); start = end
            }
        }
    }

    func canonical(existing: TranscriptDocument?, journal: [TranscriptSegment], duration: MediaMilliseconds) throws -> TranscriptDocument {
        try validate(sessionID: session.sessionID)
        guard captureEnded else { throw TranscriptFailure(code: .notFinalized) }
        let all = entries.filter { $0.state == .complete || $0.state == .prepared }
            .sorted { $0.range.start == $1.range.start ? $0.range.end < $1.range.end : $0.range.start < $1.range.start }
            .flatMap(\.segments)
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        for old in journal {
            guard byID[old.id] == old else { throw TranscriptFailure(code: .canonicalConflict) }
        }
        var edits: [TranscriptSegmentID: String] = [:]
        if let existing {
            try TranscriptCanonical.validate(existing, sessionID: session.sessionID, duration: duration)
            for old in existing.segments {
                guard let source = byID[old.id], source.startMs == old.startMs, source.endMs == old.endMs,
                      source.originalText == old.originalText, source.language == old.language else {
                    throw TranscriptFailure(code: .canonicalConflict)
                }
                edits[old.id] = old.text
            }
            let oldIDs = Set(existing.segments.map(\.id))
            guard all.filter({ oldIDs.contains($0.id) }).map(\.id) == existing.segments.map(\.id) else {
                throw TranscriptFailure(code: .canonicalConflict)
            }
        }
        let segments = try all.enumerated().map { index, value in
            try TranscriptSegment(id: value.id, sequence: .init(Int64(index)), startMs: value.startMs, endMs: value.endMs,
                originalText: value.originalText, text: edits[value.id] ?? value.text, language: value.language)
        }
        let result = try TranscriptDocument(sessionId: session.sessionID, segments: segments)
        try TranscriptCanonical.validate(result, sessionID: session.sessionID, duration: duration)
        return result
    }
}
