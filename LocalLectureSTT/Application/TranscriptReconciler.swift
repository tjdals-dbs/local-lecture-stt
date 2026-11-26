import CryptoKit
import Foundation

protocol TranscriptReconciling: Sendable {
    mutating func reconcile(_ response: STTResponse, for window: SpeechWindow,
                            language: LanguageCode) throws -> [TranscriptSegment]
}

/// Consumes closed windows in media order and returns only newly committed segments.
/// The caller owns the transcript. This value retains at most the previous engine snapshot.
struct TranscriptReconciler: TranscriptReconciling {
    private(set) var session: STTSessionConfiguration
    private var previousFrames: Range<Int64>?
    private var previousFinal: [STTHypothesisSegment] = []
    private var nextSequence: Int64 = 0

    init(session: STTSessionConfiguration) { self.session = session }

    mutating func rebind(to next: STTSessionConfiguration) throws {
        guard next.sessionID == session.sessionID, next.model == session.model else { throw STTEngineError(.sessionMismatch) }
        session = next
    }

    mutating func reconcile(_ response: STTResponse, for window: SpeechWindow,
                            language: LanguageCode) throws -> [TranscriptSegment] {
        guard response.context.session == session else { throw STTEngineError(.sessionMismatch) }
        guard window.boundary != .open, response.kind == .final,
              response.context.mediaStart == window.mediaStart,
              response.context.mediaEnd.rawValue - window.mediaStart.rawValue == window.audio.duration.rawValue,
              response.detectedLanguage == nil || response.detectedLanguage == language else {
            throw STTEngineError(.invalidResponse)
        }
        switch session.languageMode {
        case .korean where language.rawValue != "ko", .english where language.rawValue != "en":
            throw STTEngineError(.invalidResponse)
        default: break
        }

        let frames = window.startFrame..<window.endFrame
        if frames == previousFrames { return [] }
        if let previousFrames {
            guard frames.lowerBound > previousFrames.lowerBound, frames.upperBound > previousFrames.upperBound else {
                throw STTEngineError(.invalidResponse)
            }
        }

        var cuts: [Int: String.Index] = [:]
        if window.overlapFrames > 0, previousFrames?.upperBound == window.startFrame + Int64(window.overlapFrames) {
            let start = window.mediaStart.rawValue
            let overlap = start..<(start + Int64(window.overlapFrames / 16))
            cuts = Self.duplicateCuts(previousFinal, response.segments, in: overlap)
        }
        var additions: [TranscriptSegment] = []
        var sequence = nextSequence
        for (index, hypothesis) in response.segments.enumerated() {
            let start = cuts[index] ?? hypothesis.text.startIndex
            let text = hypothesis.text[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard sequence < Int64.max else { throw STTEngineError(.invalidResponse) }
            additions.append(try TranscriptSegment(
                id: Self.id(session: session.sessionID, sequence: sequence),
                sequence: TranscriptSegmentSequence(sequence), startMs: hypothesis.start, endMs: hypothesis.end,
                originalText: text, text: text, language: language))
            sequence += 1
        }
        previousFrames = frames
        previousFinal = response.segments
        nextSequence = sequence
        return additions
    }

    // RFC 9562 UUIDv5: namespace = session UUID, name = UTF-8 decimal display sequence.
    private static func id(session: SessionID, sequence: Int64) -> TranscriptSegmentID {
        var name = withUnsafeBytes(of: session.rawValue.uuid) { Data($0) }
        name.append(contentsOf: String(sequence).utf8)
        var bytes = Array(Insecure.SHA1.hash(data: name).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return TranscriptSegmentID(UUID(uuid: bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }))
    }

    private struct Unit {
        let key: String
        let segment: Int
        var wordEnd: String.Index
        let startsWord: Bool
        let endsWord: Bool
        var remainingInSegment = 0
    }

    private static let punctuation = CharacterSet(charactersIn: ".,!?;:…，。！？“”‘’\"()[]")
    private static let trailingMarks = CharacterSet(charactersIn: ".,!?;:…，。！？”’")
    private static let markOrWhitespace = trailingMarks.union(.whitespacesAndNewlines)

    private static func isDetachedMark(_ hypothesis: STTHypothesisSegment) -> Bool {
        let mark = hypothesis.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !mark.isEmpty && mark.unicodeScalars.allSatisfy(markOrWhitespace.contains)
    }

    private static func lexicalStart(in text: Substring) -> String.Index {
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            guard c.isWhitespace || c.unicodeScalars.allSatisfy(punctuation.contains) else { break }
            let next = text.index(after: i)
            // The dot in .NET or .5 belongs to the term, even inside quotes or after a comma.
            if c == ".", next < text.endIndex, text[next].isLetter || text[next].isNumber,
               i == text.startIndex || text[text.index(before: i)] != "." { break }
            i = next
        }
        return i
    }

    // Hangul syllables can acquire or lose spaces, even next to a Latin term.
    // Keep other runs intact so unrelated identifiers and partial words cannot match.
    private static func keys(for word: Substring) -> [String] {
        let start = lexicalStart(in: word)
        let lexical: Substring
        if let last = word.lastIndex(where: { !$0.unicodeScalars.allSatisfy(punctuation.contains) }), start <= last {
            lexical = word[start...last]
        } else {
            lexical = word
        }
        let text = lexical.precomposedStringWithCanonicalMapping.lowercased()
        var keys: [String] = []
        var runStart = text.startIndex
        for i in text.indices {
            let scalars = text[i].unicodeScalars
            guard scalars.count == 1, let scalar = scalars.first, (0xac00...0xd7a3).contains(scalar.value) else { continue }
            if runStart != i { keys.append(String(text[runStart..<i])) }
            keys.append(String(text[i]))
            runStart = text.index(after: i)
        }
        if runStart != text.endIndex { keys.append(String(text[runStart...])) }
        return keys
    }

    private static func units(_ segments: ArraySlice<STTHypothesisSegment>) -> [Unit] {
        var result: [Unit] = []
        for index in segments.indices {
            let firstUnit = result.count
            for word in segments[index].text.split(whereSeparator: \.isWhitespace) {
                if word.unicodeScalars.allSatisfy(trailingMarks.contains) {
                    // A mark contributes no word. After a word in this segment,
                    // carry its end into the original-text cut for that word.
                    if result.count > firstUnit { result[result.count - 1].wordEnd = word.endIndex }
                    continue
                }
                let keys = keys(for: word)
                for (i, key) in keys.enumerated() {
                    result.append(Unit(key: key, segment: index, wordEnd: word.endIndex,
                                       startsWord: i == 0, endsWord: i + 1 == keys.count))
                }
            }
            let end = result.count
            for i in firstUnit..<end { result[i].remainingInSegment = end - i }
        }
        return result
    }

    private static func duplicateCuts(_ old: [STTHypothesisSegment], _ new: [STTHypothesisSegment],
                                      in overlap: Range<Int64>) -> [Int: String.Index] {
        let tail = units(old.drop(while: { $0.end.rawValue < overlap.lowerBound }))
        let prefix = units(new.prefix(while: { $0.start.rawValue < overlap.upperBound }))
        var cuts: [Int: String.Index] = [:]
        var oldStart = 0, newStart = 0
        while oldStart < tail.count && newStart < prefix.count {
            let incoming = new[prefix[newStart].segment]
            while oldStart < tail.count && old[tail[oldStart].segment].end < incoming.start {
                oldStart += tail[oldStart].remainingInSegment
            }
            let match = longestMatch(tail[oldStart...], prefix[newStart...], old: old, new: new, overlap: overlap)
            if match.count == 0 {
                // This incoming segment is novel. A later segment may still match the same old audio.
                newStart += prefix[newStart].remainingInSegment
            } else {
                let last = newStart + match.count - 1
                let final = prefix[last]
                let firstOld = match.oldEnd - match.count
                if newStart == 0, prefix[0].segment > 0,
                   firstOld == 0 || tail[firstOld - 1].segment != tail[firstOld].segment {
                    cutInitialMarks(in: new, before: prefix[0].segment, old: old,
                                    oldWord: tail[firstOld].segment, overlap: overlap, cuts: &cuts)
                }
                // Every incoming segment between the first and last matched words
                // belongs to this match, including separately timestamped formatting.
                for i in prefix[newStart].segment..<final.segment { cuts[i] = new[i].text.endIndex }
                cuts[final.segment] = final.wordEnd
                if final.remainingInSegment == 1 {
                    let oldEnd = tail[match.oldEnd - 1].segment
                    cutTrailingMarks(after: final.segment, in: new, oldTail: old[(oldEnd + 1)...],
                                     overlap: overlap, cuts: &cuts)
                }
                newStart = last + final.remainingInSegment
                oldStart = match.oldEnd
            }
        }
        return cuts
    }

    // A detached mark before the first matched word has no matched word to its left.
    // Require the same leading symbols in the earlier decode before removing it.
    private static func cutInitialMarks(in new: [STTHypothesisSegment], before word: Int,
                                        old: [STTHypothesisSegment], oldWord: Int, overlap: Range<Int64>,
                                        cuts: inout [Int: String.Index]) {
        typealias Mark = (symbol: Character, row: Int?)
        func marks(in segments: [STTHypothesisSegment], before index: Int) -> [Mark] {
            var first = index
            while first > 0 {
                let row = segments[first - 1]
                guard overlap.contains(row.start.rawValue), row.text.unicodeScalars.allSatisfy(markOrWhitespace.contains)
                else { break }
                first -= 1
            }
            var marks: [Mark] = []
            for i in first..<index {
                marks += segments[i].text.filter { !$0.isWhitespace }.map { ($0, i) }
            }
            let text = segments[index].text
            marks += text[..<lexicalStart(in: text[...])].filter { !$0.isWhitespace }.map { ($0, nil) }
            return marks
        }
        let incoming = marks(in: new, before: word)
        let previous = marks(in: old, before: oldWord)
        guard incoming.count == previous.count else { return }
        for (a, b) in zip(incoming, previous) {
            guard a.symbol == b.symbol else { return }
            guard let i = a.row else { continue }
            if let j = b.row {
                guard new[i].start == old[j].start, new[i].end == old[j].end else { return }
            } else {
                // The old mark was attached to the word. Only a point in the
                // same gap can represent it without absorbing an earlier utterance.
                guard new[i].start == new[i].end, overlap.contains(old[oldWord].start.rawValue),
                      oldWord == 0 || old[oldWord - 1].end <= new[i].start else { return }
            }
        }
        for i in 0..<word { cuts[i] = new[i].text.endIndex }
    }

    private static func cutTrailingMarks(after index: Int, in new: [STTHypothesisSegment],
                                         oldTail: ArraySlice<STTHypothesisSegment>, overlap: Range<Int64>,
                                         cuts: inout [Int: String.Index]) {
        let oldMarks = oldTail.prefix { $0.text.unicodeScalars.allSatisfy(markOrWhitespace.contains) }
        var matchedEnd = new[index].end
        for i in (index + 1)..<new.count {
            let mark = new[i]
            guard overlap.contains(mark.start.rawValue), mark.end.rawValue <= overlap.upperBound else { break }
            if mark.text.allSatisfy(\.isWhitespace) { continue }
            // Whitespace adds no time. Across a gap, require the same mark at
            // the same media interval after the matched words in the old decode.
            guard isDetachedMark(mark) else { break }
            if mark.start != matchedEnd {
                let symbols = mark.text.filter { !$0.isWhitespace }
                guard oldMarks.contains(where: { old in
                    old.start == mark.start && old.end == mark.end && old.text.filter { !$0.isWhitespace } == symbols
                }) else { break }
            }
            cuts[i] = mark.text.endIndex
            matchedEnd = mark.end
        }
    }

    /// Measure only actual intersection inside the copied audio. Coincident
    /// point hypotheses are the one supported zero-duration case.
    private static func sharedDuration(_ a: STTHypothesisSegment, _ b: STTHypothesisSegment,
                                       in overlap: Range<Int64>) -> Int64? {
        let start = max(a.start.rawValue, b.start.rawValue, overlap.lowerBound)
        let end = min(a.end.rawValue, b.end.rawValue, overlap.upperBound)
        if a.start == a.end && a.start == b.start && a.end == b.end && overlap.contains(a.start.rawValue) {
            return 0
        }
        return end > start ? end - start : nil
    }

    /// KMP suffix/prefix search. Build the fallback table as input is read,
    /// including shorter alternatives for repeated words.
    private struct PrefixSearch {
        private let units: ArraySlice<Unit>
        private(set) var length = 0
        private var fallback = [0]

        init(_ units: ArraySlice<Unit>) { self.units = units }

        func shorter(than count: Int) -> Int { fallback[count - 1] }

        mutating func consume(_ key: String) {
            let start = units.startIndex
            while length > 0 && (length == units.count || key != units[start + length].key) {
                length = shorter(than: length)
            }
            guard key == units[start + length].key else { return }
            if length == fallback.count {
                var j = shorter(than: length)
                while j > 0 && key != units[start + j].key { j = shorter(than: j) }
                if key == units[start + j].key { j += 1 }
                fallback.append(j)
            }
            length += 1
        }
    }

    /// Try suffixes ending at each old segment boundary. A short intersection
    /// may contribute to a longer phrase. Only the matched spans decide coverage.
    private static func longestMatch(_ tail: ArraySlice<Unit>, _ prefix: ArraySlice<Unit>,
                                     old: [STTHypothesisSegment], new: [STTHypothesisSegment],
                                     overlap: Range<Int64>) -> (count: Int, oldEnd: Int) {
        let incoming = new[prefix[prefix.startIndex].segment]
        var startLimit = tail.startIndex
        while startLimit < tail.endIndex && old[tail[startLimit].segment].start <= incoming.end {
            startLimit += tail[startLimit].remainingInSegment
        }
        var search = PrefixSearch(prefix)
        var position = tail.startIndex
        var best = (count: 0, oldEnd: position)
        guard position < startLimit else { return best }
        while position < tail.endIndex {
            let next = position + tail[position].remainingInSegment
            for unit in tail[position..<next] { search.consume(unit.key) }
            var length = search.length
            while length > best.count && next - length < startLimit {
                let start = next - length
                let final = prefix[prefix.startIndex + length - 1]
                let whole = final.remainingInSegment == 1 &&
                    (start == tail.startIndex || tail[start - 1].segment != tail[start].segment)
                if tail[start].startsWord, final.endsWord,
                   hasTimingEvidence(tail[start..<next], prefix.prefix(length), whole: whole,
                                     old: old, new: new, overlap: overlap) {
                    best = (length, next)
                    break
                }
                length = search.shorter(than: length)
            }
            // All shorter alternatives start at or after the longest surviving suffix.
            if best.count == prefix.count || next - search.length >= startLimit { break }
            position = next
        }
        return best
    }

    /// Each segment that contributed matched units supplies its interval once.
    private static func matchedSegments(_ units: ArraySlice<Unit>, in segments: [STTHypothesisSegment]) -> [STTHypothesisSegment] {
        var result: [STTHypothesisSegment] = []
        var index = units.startIndex
        while index < units.endIndex {
            let unit = units[index]
            result.append(segments[unit.segment])
            index += unit.remainingInSegment
        }
        return result
    }

    /// Shared lexical boundaries divide a candidate into independently timed spans.
    /// Between those boundaries, compare actual audio coverage: the engine only
    /// supplies segment timestamps, so a moved word has no timestamp of its own.
    private static func hasTimingEvidence(_ tail: ArraySlice<Unit>, _ prefix: ArraySlice<Unit>, whole: Bool,
                                          old: [STTHypothesisSegment], new: [STTHypothesisSegment],
                                          overlap: Range<Int64>) -> Bool {
        if whole {
            let oldPhrase = matchedSegments(tail, in: old)
            let newPhrase = matchedSegments(prefix, in: new)
            // If both complete texts cover the same audio in both directions,
            // their internal cuts provide no evidence about individual word times.
            if covers(oldPhrase, newPhrase, in: overlap) && covers(newPhrase, oldPhrase, in: overlap) { return true }
        }
        var i = tail.startIndex, j = prefix.startIndex
        while i < tail.endIndex {
            let oldStart = i, newStart = j
            repeat {
                let oldRemaining = tail[i].remainingInSegment, newRemaining = prefix[j].remainingInSegment
                let step = min(oldRemaining, newRemaining, tail.endIndex - i)
                i += step
                j += step
                if oldRemaining == newRemaining { break }
            } while i < tail.endIndex
            let oldSpan = matchedSegments(tail[oldStart..<i], in: old)
            let newSpan = matchedSegments(prefix[newStart..<j], in: new)
            guard covers(oldSpan, newSpan, in: overlap) else { return false }
        }
        return true
    }

    private static func covers(_ old: [STTHypothesisSegment], _ new: [STTHypothesisSegment],
                               in overlap: Range<Int64>) -> Bool {
        var supported = Set<Int>()
        var firstOld = old.startIndex
        for incoming in new {
            while firstOld < old.endIndex && old[firstOld].end < incoming.start { firstOld += 1 }
            var covered: Int64 = 0, hasSharedAudio = false
            for i in firstOld..<old.endIndex {
                if old[i].start > incoming.end { break }
                if let duration = sharedDuration(old[i], incoming, in: overlap) {
                    supported.insert(i)
                    hasSharedAudio = true
                    covered += duration
                }
            }
            // Without word timestamps, the same standard applies to removing
            // a prefix as to removing all the text of the incoming hypothesis.
            guard hasSharedAudio, 2 * covered >= incoming.end.rawValue - incoming.start.rawValue else { return false }
        }
        return supported.count == old.count
    }
}
