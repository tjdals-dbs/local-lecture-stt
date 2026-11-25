import SwiftUI

struct SessionDetailView: View {
    @ObservedObject var model: SessionDetailViewModel
    @State private var seekValue: Double = 0
    @State private var seeking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let item = model.item {
                HStack {
                    Text(model.document?.metadata?.title ?? item.title).font(.title2.bold()).lineLimit(2)
                    Spacer()
                    Button("제목 변경") { model.rename() }.disabled(!model.canEdit)
                    Button("휴지통으로 이동", role: .destructive) { model.requestDeletion() }
                        .disabled(model.busy || model.hasDraft).accessibilityIdentifier("session-trash")
                }
                HStack {
                    Text(item.createdAt.value, format: .dateTime.year().month().day().hour().minute())
                    Text(SessionListRow.status(model.document?.metadata?.status ?? item.displayStatus))
                    Spacer()
                    Button("다시 읽기") { Task { await model.refresh() } }.disabled(model.busy || model.hasDraft)
                }.font(.caption).foregroundStyle(.secondary)
                if model.document?.availableFiles.contains(.audio) == true { audioControls }
                HStack {
                    ForEach(SessionDetailFile.allCases, id: \.self) { file in
                        Button("\(file.rawValue) 위치") { Task { await model.reveal(file) } }
                            .disabled(model.busy || model.document?.availableFiles.contains(file) != true)
                    }
                    Button("문서 다시 생성") { Task { await model.regenerate() } }.disabled(!model.canEdit)
                }.font(.caption)
                if model.hasDraft { editor }
                if let document = model.document {
                    if !document.editable {
                        Text("마무리 완료와 파일 상태를 확인한 뒤 텍스트를 수정할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !document.issues.isEmpty {
                        DisclosureGroup("누락되거나 확인이 필요한 파일 \(document.issues.count)개") {
                            ForEach(Array(document.issues.enumerated()), id: \.offset) { _, issue in
                                Text("\(issue.artifact): \(issue.code)").font(.caption)
                                IssueNoticeView(issue: UserIssues.artifact(issue))
                            }
                        }.foregroundStyle(.orange)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(document.transcript?.segments ?? [], id: \.id) { segment in
                                HStack(alignment: .top, spacing: 12) {
                                    Button(TranscriptRenderer.timestamp(segment.startMs)) {
                                        Task { await model.seek(segment.startMs.rawValue) }
                                    }.monospacedDigit().buttonStyle(.link)
                                        .disabled(model.busy || !document.availableFiles.contains(.audio))
                                        .accessibilityLabel("\(TranscriptRenderer.timestamp(segment.startMs))로 이동")
                                    Text(segment.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    Button { model.edit(segment) } label: { Image(systemName: "pencil") }
                                        .disabled(!model.canEdit).accessibilityLabel("이 구간 텍스트 수정")
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.accessibilityIdentifier("session-transcript")
                }
            } else {
                Text("세션을 선택하세요.").font(.title2)
            }
            if model.busy { ProgressView("처리 중…") }
            if let message = model.message { Text(message).font(.callout).textSelection(.enabled) }
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("세션을 휴지통으로 이동할까요?", isPresented: Binding(get: { model.deletion != nil }, set: { if !$0 { model.deletion = nil } }), presenting: model.deletion) { location in
            Button("취소", role: .cancel) { model.deletion = nil }
            Button("휴지통으로 이동", role: .destructive) { Task { await model.confirmDeletion(location) } }
        } message: { _ in Text("이 세션의 오디오와 전사 파일을 함께 이동합니다. Finder 휴지통에서 복구할 수 있습니다.") }
        .onDisappear { Task { await model.stopPlayback() } }
        .accessibilityIdentifier("session-detail")
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.editingTitle ? "제목 수정" : "텍스트 수정 · 타임스탬프와 원문은 유지됩니다").font(.headline)
            TextEditor(text: $model.draft).frame(height: 100).disabled(model.busy)
                .accessibilityIdentifier("session-text-editor")
            HStack {
                Button("저장") { Task { await model.save() } }.disabled(model.busy)
                Button("취소") { Task { await model.cancelEdit() } }.disabled(model.busy)
                Text("앱 종료·잠자기 전에도 저장을 시도합니다.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var audioControls: some View {
        VStack(spacing: 6) {
            HStack {
                Button(model.playback.phase == .playing ? "일시정지" : "재생") { Task { await model.togglePlayback() } }
                    .disabled(model.busy).accessibilityIdentifier("session-audio-play")
                Button("정지") { Task { await model.stopPlayback() } }.disabled(model.busy || model.playback.phase == .idle)
                Text("\(SessionListRow.duration(model.playback.positionMilliseconds)) / \(SessionListRow.duration(model.playback.durationMilliseconds))").monospacedDigit()
                Spacer()
            }
            Slider(value: $seekValue, in: 0...Double(max(1, model.playback.durationMilliseconds)), onEditingChanged: { active in
                seeking = active
                if !active { Task { await model.seek(Int64(seekValue)) } }
            }).disabled(model.busy || model.playback.durationMilliseconds == 0)
                .accessibilityLabel("오디오 재생 위치")
        }
        .onReceive(model.$playback) { value in if !seeking { seekValue = Double(value.positionMilliseconds) } }
    }
}
