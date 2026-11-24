import Combine
import Foundation

/// LiveSTTCoordinator only appends durable finals within a session. The UI consumes
/// that suffix once; meter/partial updates never compare or republish the history.
@MainActor
final class LiveTranscriptPresentation: ObservableObject {
    static let pageSize = 64
    @Published private(set) var pages: [TranscriptPage] = []
    let partial = PartialTranscriptPresentation()
    let notices = SpeechNoticePresentation()
    let contentChanges = PassthroughSubject<ContentChange, Never>()
    enum ContentChange { case reset, appended }
    private(set) var sessionID: SessionID?
    private(set) var finalCount = 0

    func update(sessionID: SessionID?, speech: LiveSTTSnapshot) {
        let reset = self.sessionID != sessionID || speech.finals.count < finalCount
        if reset {
            self.sessionID = sessionID
            pages = []
            finalCount = 0
        }
        let appended = speech.finals.count > finalCount
        while finalCount < speech.finals.count {
            let page: TranscriptPage
            if let last = pages.last, last.segments.count < Self.pageSize { page = last }
            else {
                page = TranscriptPage()
                pages.append(page)
            }
            let end = min(speech.finals.count, finalCount + Self.pageSize - page.segments.count)
            page.append(contentsOf: speech.finals[finalCount..<end])
            finalCount = end
        }
        let changedPartial = partial.update(speech.partial)
        notices.update(speech)
        if reset { contentChanges.send(.reset) }
        else if appended || changedPartial { contentChanges.send(.appended) }
    }
}

@MainActor
final class TranscriptPage: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var segments: [TranscriptSegment] = []
    fileprivate func append(contentsOf segments: ArraySlice<TranscriptSegment>) {
        self.segments.append(contentsOf: segments)
    }
}

@MainActor
final class PartialTranscriptPresentation: ObservableObject {
    @Published private(set) var text: String?
    @discardableResult fileprivate func update(_ value: String?) -> Bool {
        let value = value?.isEmpty == true ? nil : value
        guard text != value else { return false }
        text = value
        return true
    }
}

struct SpeechNoticeState: Equatable {
    var phase: LiveSTTPhase = .idle
    var failure: STTErrorCode?
    var storageWarning: String?
    var degraded = false
    var pendingFinals = 0
    var inputDiscontinuities = 0
}

@MainActor
final class SpeechNoticePresentation: ObservableObject {
    @Published private(set) var state = SpeechNoticeState()
    fileprivate func update(_ speech: LiveSTTSnapshot) {
        let next = SpeechNoticeState(phase: speech.phase, failure: speech.failure,
            storageWarning: speech.storageWarning, degraded: speech.degraded,
            pendingFinals: speech.pendingFinals, inputDiscontinuities: speech.inputDiscontinuities)
        if state != next { state = next }
    }
}

/// Layout growth is never interpreted as user intent. Only a user scroll ending
/// at the bottom, or the explicit Latest button, re-enables following.
struct TranscriptScrollFollowing: Equatable {
    private(set) var followsLatest = true
    private(set) var userScrolling = false
    var shouldScroll: Bool { followsLatest && !userScrolling }
    mutating func userBeganScrolling() { userScrolling = true; followsLatest = false }
    mutating func userEndedScrolling(atBottom: Bool) { userScrolling = false; followsLatest = atBottom }
    mutating func showLatest() { followsLatest = true; userScrolling = false }
    mutating func reset() { self = Self() }
}
