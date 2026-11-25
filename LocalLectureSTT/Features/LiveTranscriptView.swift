import SwiftUI

/// Identity equality isolates this subtree from the parent's meter/time snapshots.
struct LiveTranscriptView: View, Equatable {
    let presentation: LiveTranscriptPresentation
    @State private var following = TranscriptScrollFollowing()
    @State private var scrollRequest = 0
    private static let bottomID = "transcript-bottom"

    nonisolated private let identity: ObjectIdentifier
    init(presentation: LiveTranscriptPresentation) {
        self.presentation = presentation
        identity = ObjectIdentifier(presentation)
    }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("실시간 전사").font(.headline)
                Text("읽기 전용").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !following.followsLatest {
                    Button("최신 내용으로") {
                        following.showLatest()
                        scrollRequest += 1
                    }.accessibilityIdentifier("transcript-follow-latest")
                }
            }
            SpeechNoticesView(presentation: presentation.notices).equatable()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        TranscriptPagesView(presentation: presentation).equatable()
                        PartialTranscriptView(presentation: presentation.partial).equatable()
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                }
                .accessibilityIdentifier("transcript-scroll")
                .onScrollPhaseChange { _, phase, context in
                    switch phase {
                    case .tracking, .interacting, .decelerating, .animating:
                        // Our automatic jumps are unanimated. Animated keyboard /
                        // accessibility scrolling is user intent as well.
                        following.userBeganScrolling()
                    case .idle where following.userScrolling:
                        let geometry = context.geometry
                        following.userEndedScrolling(atBottom:
                            geometry.visibleRect.maxY >= geometry.contentSize.height - 24)
                    default: break
                    }
                }
                .task(id: scrollRequest) {
                    // Coalesce updates and let new rows/partial text enter the layout.
                    await Task.yield()
                    guard !Task.isCancelled, following.shouldScroll else { return }
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
        }
        .onReceive(presentation.contentChanges) { change in
            if case .reset = change { following.reset() }
            if following.shouldScroll { scrollRequest += 1 }
        }
        .frame(minHeight: 120, maxHeight: .infinity)
        .accessibilityIdentifier("live-transcript")
    }
}

private struct TranscriptPagesView: View, Equatable {
    @ObservedObject var presentation: LiveTranscriptPresentation
    nonisolated private let identity: ObjectIdentifier
    init(presentation: LiveTranscriptPresentation) {
        self.presentation = presentation
        identity = ObjectIdentifier(presentation)
    }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    var body: some View {
        ForEach(presentation.pages) { page in TranscriptPageView(page: page).equatable() }
    }
}

private struct TranscriptPageView: View, Equatable {
    @ObservedObject var page: TranscriptPage
    nonisolated private let identity: ObjectIdentifier
    init(page: TranscriptPage) {
        self.page = page
        identity = ObjectIdentifier(page)
    }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    var body: some View {
        // The outer lazy stack realizes pages; only this bounded final page changes.
        VStack(alignment: .leading, spacing: 12) {
            ForEach(page.segments, id: \.id) { segment in TranscriptSegmentRow(segment: segment).equatable() }
        }
    }
}

private struct TranscriptSegmentRow: View, Equatable {
    nonisolated let segment: TranscriptSegment
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.segment == rhs.segment }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading) {
                Text(RecordingSessionViewModel.formatElapsed(UInt64(segment.startMs.rawValue)))
                    .monospacedDigit()
                Text("확정").font(.caption2)
            }.font(.caption).foregroundStyle(.secondary)
            Text(segment.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transcript-final-\(segment.id.rawValue)")
    }
}

private struct PartialTranscriptView: View, Equatable {
    @ObservedObject var presentation: PartialTranscriptPresentation
    nonisolated private let identity: ObjectIdentifier
    init(presentation: PartialTranscriptPresentation) {
        self.presentation = presentation
        identity = ObjectIdentifier(presentation)
    }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    var body: some View {
        if let text = presentation.text {
            VStack(alignment: .leading, spacing: 4) {
                Text("임시 · 인식 중인 내용은 바뀔 수 있습니다").font(.caption)
                Text(text).italic().textSelection(.enabled)
            }
            .foregroundStyle(.secondary).padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("transcript-partial")
        }
    }
}

private struct SpeechNoticesView: View, Equatable {
    @ObservedObject var presentation: SpeechNoticePresentation
    nonisolated private let identity: ObjectIdentifier
    init(presentation: SpeechNoticePresentation) {
        self.presentation = presentation
        identity = ObjectIdentifier(presentation)
    }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    var body: some View {
        let state = presentation.state
        VStack(alignment: .leading, spacing: 4) {
            if state.phase == .finishing { ProgressView("남은 발화를 전사하는 중…") }
            if let code = state.failure {
                IssueNoticeView(issue: UserIssues.speech(code)).accessibilityIdentifier("transcript-failure")
            }
            if state.storageWarning != nil {
                IssueNoticeView(issue: .init(code: .transcriptStorage))
            }
            if state.degraded {
                IssueNoticeView(issue: .init(code: .speechDelayed))
                Text("대기 \(state.pendingFinals)구간").foregroundStyle(.secondary)
            }
            if state.inputDiscontinuities > 0 {
                Text("일부 전사 입력이 누락되었습니다. 녹음 파일은 별도로 저장됩니다.").foregroundStyle(.orange)
            }
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }
}
