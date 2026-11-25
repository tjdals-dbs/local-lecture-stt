import SwiftUI

struct IssueNoticeView: View {
    let issue: UserIssue
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(issue.title, systemImage: "exclamationmark.triangle")
            Text("원인: \(issue.cause)")
            Text("조치: \(issue.action)")
            Text(issue.recovery.label).foregroundStyle(.secondary)
        }
        .font(.caption).fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("issue-\(issue.code.rawValue)")
    }
}

@MainActor
final class DiagnosticSettingsViewModel: ObservableObject, LifecycleAuxiliaryWorking {
    @Published private(set) var summary: DiagnosticSummary?
    @Published private(set) var busy = false
    @Published private(set) var issue: UserIssue?
    @Published private(set) var message: String?
    private let manager: any DiagnosticManaging
    private let openLogs: @MainActor () async throws -> Void
    private let exportLogs: @MainActor (DiagnosticCancellation) async throws -> Bool
    private let authority: LifecycleWorkAuthority?
    private var operation: Task<Void, Never>?
    private var cancellation: DiagnosticCancellation?
    private var quiescing = false
    private var attention = false
    private var lease: UUID?
    private var observers: [UUID: AsyncStream<LifecycleAuxiliarySnapshot>.Continuation] = [:]

    init(manager: any DiagnosticManaging, authority: LifecycleWorkAuthority? = nil,
         openLogs: @escaping @MainActor () async throws -> Void = {},
         exportLogs: @escaping @MainActor (DiagnosticCancellation) async throws -> Bool = { _ in false }) {
        self.manager = manager; self.authority = authority
        self.openLogs = openLogs; self.exportLogs = exportLogs
    }
    func refresh() async { await perform { _ in } }
    func open() async { await perform { _ in try await self.openLogs() } }
    func clear() async {
        await perform { control in
            try control.check(); try await self.manager.clear()
            self.message = "앱 진단 로그를 삭제했습니다. 녹음·전사·세션 사건 기록은 유지됩니다."
        }
    }
    func export() async {
        await perform(export: true) { control in
            if try await self.exportLogs(control) { self.message = "진단 로그를 내보냈습니다." }
        }
    }
    private func perform(export: Bool = false, _ body: @escaping @MainActor (DiagnosticCancellation) async throws -> Void) async {
        guard !busy, !quiescing else { return }
        busy = true; issue = nil; message = nil; attention = false
        let control = DiagnosticCancellation(); cancellation = control; publish()
        let task = Task { @MainActor in
            do {
                try await body(control); try control.check()
                self.summary = try await self.manager.summary()
                if self.summary?.lastFailure != nil {
                    self.issue = .init(code: .diagnosticStorage); self.attention = !self.quiescing
                }
            } catch {
                if (error as? DiagnosticFailure) != .cancelled && !(error is CancellationError) {
                    self.issue = .init(code: export ? .diagnosticExport : .diagnosticStorage)
                    self.attention = !self.quiescing
                }
            }
            self.busy = false; self.operation = nil; self.cancellation = nil; self.publish()
        }
        operation = task; await task.value
    }
    func quiesce() async {
        quiescing = true; attention = false; cancellation?.cancel(); publish()
        await operation?.value
        quiescing = false; publish()
    }
    func currentWork() -> LifecycleAuxiliarySnapshot {
        .init(active: busy || quiescing, requiresAttention: attention)
    }
    func workSnapshots() -> AsyncStream<LifecycleAuxiliarySnapshot> {
        let id = UUID(); let pair = AsyncStream<LifecycleAuxiliarySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = pair.continuation; pair.continuation.yield(currentWork())
        pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.observers[id] = nil } }
        return pair.stream
    }
    private func publish() {
        let work = currentWork()
        if work.active, lease == nil { lease = authority?.admit() }
        if !work.active, let lease { authority?.release(lease); self.lease = nil }
        observers.values.forEach { $0.yield(work) }
    }
}

struct DiagnosticSettingsSection: View {
    @ObservedObject var model: DiagnosticSettingsViewModel
    @State private var confirmClear = false
    var body: some View {
        Section("로컬 진단 로그") {
            Text("앱 진단 정보만 이 Mac에 보관합니다. 전사 본문·오디오를 기록하거나 자동 전송하지 않습니다.")
                .font(.caption)
            Text("최근 30일 · 최대 100MB").font(.caption).foregroundStyle(.secondary)
            if let value = model.summary {
                Text("\(value.fileCount)개 파일 · \(ByteCountFormatter.string(fromByteCount: value.bytes, countStyle: .decimal))")
                if value.droppedEntries > 0 {
                    Text("진단 처리 실패·지연으로 \(value.droppedEntries)건을 생략했습니다. 녹음 저장에는 영향을 주지 않습니다.").font(.caption)
                }
            }
            if let issue = model.issue { IssueNoticeView(issue: issue) }
            if let message = model.message { Text(message).font(.caption) }
            HStack {
                Button("로그 폴더 열기") { Task { await model.open() } }
                Button("로그 내보내기…") { Task { await model.export() } }
                Button("로그 삭제…") { confirmClear = true }
                if model.busy { ProgressView().controlSize(.small) }
            }.disabled(model.busy)
        }
        .task { await model.refresh() }
        .alert("앱 진단 로그를 삭제할까요?", isPresented: $confirmClear) {
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) { Task { await model.clear() } }
        } message: { Text("녹음·전사·각 세션의 사건 기록은 삭제하지 않습니다.") }
    }
}
