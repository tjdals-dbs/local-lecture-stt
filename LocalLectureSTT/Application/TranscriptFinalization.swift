import Foundation

enum TranscriptFailureCode: String, Codable, Sendable {
    case invalidJournal, unsupportedSchema, sessionMismatch, duplicateConflict, invalidOrder
    case invalidTime, canonicalConflict, missingCanonical, notFinalized, editConflict, segmentMissing
    case busy, storage, catalog, repairRequired, speechIncomplete
}

struct TranscriptFailure: Error, Codable, Sendable, Equatable {
    let code: TranscriptFailureCode
    var line: Int? = nil
}

protocol TranscriptFinalizing: Sendable {
    func finalize(at location: SessionLocation, audio: AudioFinalizationResult,
                  control: AudioFinalizationControl) async throws -> [FinalizationStep]
}

protocol TranscriptEditing: Sendable {
    func updateText(at location: SessionLocation, segmentID: TranscriptSegmentID,
                    expectedText: String, text: String) async throws -> TranscriptDocument
    func regenerate(at location: SessionLocation) async throws -> TranscriptDocument
}

/// Strict replay. A repeated identical durable record is idempotent; ambiguous
/// identities, reordered sequences and torn lines are errors, never repairs.
struct TranscriptJournalReplay {
    let sessionID: SessionID
    private(set) var segments: [TranscriptSegment] = []
    private var identities: [TranscriptSegmentID: TranscriptSegment] = [:]
    private var line = 0

    init(sessionID: SessionID) { self.sessionID = sessionID }

    mutating func append(_ bytes: Data) throws {
        line += 1
        guard String(data: bytes, encoding: .utf8) != nil, !bytes.contains(0) else {
            throw TranscriptFailure(code: .invalidJournal, line: line)
        }
        let record: TranscriptJournalRecord
        do { record = try JSONDecoder().decode(TranscriptJournalRecord.self, from: bytes) }
        catch DomainValidationError.unsupportedSchemaVersion {
            throw TranscriptFailure(code: .unsupportedSchema, line: line)
        } catch { throw TranscriptFailure(code: .invalidJournal, line: line) }
        guard record.sessionId == sessionID else { throw TranscriptFailure(code: .sessionMismatch, line: line) }
        let segment = record.segment
        guard segment.text == segment.originalText else { throw TranscriptFailure(code: .invalidJournal, line: line) }
        if let previous = identities[segment.id] {
            guard previous == segment else { throw TranscriptFailure(code: .duplicateConflict, line: line) }
            return
        }
        guard segment.sequence.rawValue == Int64(segments.count) else {
            throw TranscriptFailure(code: .invalidOrder, line: line)
        }
        identities[segment.id] = segment
        segments.append(segment)
    }
}

enum TranscriptCanonical {
    static func validate(_ document: TranscriptDocument, sessionID: SessionID,
                         duration: MediaMilliseconds) throws {
        guard document.sessionId == sessionID else { throw TranscriptFailure(code: .sessionMismatch) }
        var ids = Set<TranscriptSegmentID>()
        for (index, segment) in document.segments.enumerated() {
            guard ids.insert(segment.id).inserted else { throw TranscriptFailure(code: .duplicateConflict) }
            guard segment.sequence.rawValue == Int64(index) else { throw TranscriptFailure(code: .invalidOrder) }
            // Sequence owns display order. Independent overlap windows can
            // produce earlier starts after reconciliation; preserve the exact
            // T18 timestamps. The domain already enforces 0 <= start <= end.
            guard segment.endMs <= duration else {
                throw TranscriptFailure(code: .invalidTime)
            }
        }
    }

    static func compact(sessionID: SessionID, journal: [TranscriptSegment],
                        existing: TranscriptDocument?, duration: MediaMilliseconds) throws -> TranscriptDocument {
        let replayed = try TranscriptDocument(sessionId: sessionID, segments: journal)
        try validate(replayed, sessionID: sessionID, duration: duration)
        guard let existing else { return replayed }
        try validate(existing, sessionID: sessionID, duration: duration)
        // Canonical JSON owns edits. Journal replay may extend a prefix but
        // never replaces edited text or changes immutable identity/time fields.
        var merged = existing.segments
        for (index, incoming) in journal.enumerated() {
            if index < merged.count {
                var expected = incoming
                expected.text = merged[index].text
                guard expected == merged[index] else { throw TranscriptFailure(code: .canonicalConflict) }
            } else { merged.append(incoming) }
        }
        return try TranscriptDocument(sessionId: sessionID, segments: merged)
    }
}

struct TranscriptRenderedFiles: Sendable, Equatable {
    let text: Data
    let markdown: Data
}

enum TranscriptRenderer {
    static func timestamp(_ milliseconds: MediaMilliseconds) -> String {
        let seconds = milliseconds.rawValue / 1_000
        return String(format: "%02lld:%02lld:%02lld", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }

    static func render(_ document: TranscriptDocument, metadata: SessionMetadataDocument) throws -> TranscriptRenderedFiles {
        try TranscriptCanonical.validate(document, sessionID: metadata.sessionId, duration: metadata.activeDurationMs)
        // JSON quoted scalars are also YAML 1.2 scalars. This safely represents
        // colons, quotes, newlines, YAML-looking titles and Unicode without a
        // locale-dependent emitter or an external YAML dependency.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func scalar<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        var headerLines = try [
            "---", "sessionId: \(scalar(metadata.sessionId))", "title: \(scalar(metadata.title))",
            "createdAt: \(scalar(metadata.createdAt))", "durationMs: \(metadata.activeDurationMs.rawValue)",
            "languageMode: \(scalar(metadata.languageMode))", "detectedLanguage: \(scalar(metadata.detectedLanguage))",
            "engine: \(scalar(metadata.engine))", "model: \(scalar(metadata.model))", "---", ""
        ]
        if let recovery = metadata.transcript.recovery {
            headerLines.insert("transcriptionPendingRanges: \(recovery.pending)", at: headerLines.count - 2)
            headerLines.insert("transcriptionUnresolvedRanges: \(recovery.unresolved)", at: headerLines.count - 2)
        }
        let header = headerLines.joined(separator: "\n")
        let body = document.segments.map { "[\(timestamp($0.startMs))] \($0.text)" }.joined(separator: "\n")
        let notice = metadata.transcript.recovery.map { $0.pending + $0.unresolved > 0
            ? "[전사 미완료: 복구 대기 \($0.pending)구간, 미복구 \($0.unresolved)구간]\n" : "" } ?? ""
        let text = notice + (body.isEmpty ? "" : body + "\n")
        return .init(text: Data(text.utf8), markdown: Data((header + "\n" + text).utf8))
    }
}
