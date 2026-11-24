import SwiftUI

struct MainWindowView: View {
    @ObservedObject private var storageRoots: StorageRootViewModel
    @ObservedObject private var catalogStartup: CatalogStartupCoordinator
    @ObservedObject private var recording: RecordingSessionViewModel

    init(
        storageRoots: StorageRootViewModel = .preview,
        catalogStartup: CatalogStartupCoordinator = CatalogStartupCoordinator(catalog: UnavailableSessionCatalog(error: .openFailed)),
        recording: RecordingSessionViewModel = .preview
    ) {
        self.storageRoots = storageRoots
        self.catalogStartup = catalogStartup
        self.recording = recording
    }

    @State private var destination = "recording"
    @State private var selectedSession: SessionID?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List {
                    Button(recording.models?.recordingLocked == true ? "현재 녹음" : "새 녹음") {
                        destination = "recording"; selectedSession = nil
                        if recording.actions.canReset { Task { await recording.beginAnotherRecording() } }
                    }.accessibilityIdentifier("show-recording")
                    if recording.models?.recordingLocked != true, recording.models != nil {
                        Button("모델 관리") { destination = "models"; selectedSession = nil }
                            .accessibilityIdentifier("show-model-management")
                    }
                    Section("녹음 세션") {
                        if catalogStartup.items.isEmpty { Text("저장된 세션이 없습니다").foregroundStyle(.secondary) }
                        ForEach(catalogStartup.items) { item in
                            Button {
                                selectedSession = item.sessionID; destination = "session"
                            } label: { SessionListRow(item: item) }
                            .buttonStyle(.plain)
                            .listRowBackground(selectedSession == item.sessionID ? Color.accentColor.opacity(0.15) : Color.clear)
                        }
                    }
                }.listStyle(.sidebar)
                if case let .failed(code) = catalogStartup.state {
                    Text("세션 검색 실패: \(code.rawValue)").font(.caption).foregroundStyle(.orange)
                    Button("세션 다시 검색") { catalogStartup.start() }
                }
                if let code = catalogStartup.listFailure {
                    Text("목록 갱신 실패: \(code.rawValue)").font(.caption).foregroundStyle(.orange)
                }
                Button("목록 새로고침") { Task { await catalogStartup.refreshItems() } }
                    .padding(12)
                if let activity = recording.backgroundWorkText {
                    Button { destination = "activity"; selectedSession = nil } label: {
                        Label(activity, systemImage: "waveform.badge.magnifyingglass").font(.caption)
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                    .accessibilityIdentifier("background-work-status")
                }
            }.navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if let recovery = catalogStartup.recoverySnapshot {
                    ScrollView {
                        RecoveryStatusView(snapshot: recovery, retry: { catalogStartup.retryRecovery() },
                            historicalReauthorizationErrors: storageRoots.historicalReauthorizationErrors,
                            reauthorize: { rootID in await storageRoots.reauthorize(rootID: rootID) })
                    }.frame(maxHeight: 140)
                    Divider()
                }
                if recording.models?.recordingLocked == true {
                    // Root failures or navigation never hide the stop/save controls.
                    RecordingSessionView(viewModel: recording)
                } else if destination == "activity" {
                    // Background progress remains reachable even if the storage root needs reauthorization.
                    RecordingSessionView(viewModel: recording, activityOnly: true)
                } else if destination == "models", let models = recording.models {
                    ModelManagementView(models: models)
                } else if destination == "session", let item = catalogStartup.items.first(where: { $0.sessionID == selectedSession }) {
                    SessionSummaryView(item: item)
                } else {
                    recordingStart
                }
            }.frame(minWidth: 460, minHeight: 440)
        }
        .accessibilityIdentifier("initial-project-shell")
        .task {
            recording.startObserving()
            recording.models?.loadIfNeeded()
            await storageRoots.restore()
            await recording.refreshPermissionStatus()
            catalogStartup.start()
        }
        .onChange(of: recording.snapshot.phase) { _, _ in
            Task { await catalogStartup.refreshItems() }
        }
        .onChange(of: recording.finalizations) { _, values in
            if values.contains(where: { $0.result != nil }) { Task { await catalogStartup.refreshItems() } }
        }
    }

    @ViewBuilder private var recordingStart: some View {
        switch storageRoots.state {
        case .loading: ProgressView("저장 폴더 상태를 확인하는 중…")
        case .noRoot:
            ContentUnavailableView {
                Label("저장 폴더가 필요합니다", systemImage: "folder.badge.plus")
            } description: { Text("녹음과 기록을 보관할 폴더를 선택하세요. 모델은 모델 관리에서 준비할 수 있습니다.") }
              actions: { Button("저장 폴더 선택") { Task { await storageRoots.chooseActiveRoot() } } }
        case let .available(root, refreshed):
            VStack(spacing: 0) {
                HStack {
                    Label(root.displayName, systemImage: "folder.fill")
                    if refreshed { Text("접근 권한 갱신됨").font(.caption) }
                    Spacer()
                    Button("폴더 변경") { Task { await storageRoots.chooseActiveRoot() } }
                        .disabled(storageRoots.isSavingSelection || storageRoots.isPresentingPicker)
                }.padding(16)
                Divider()
                RecordingSessionView(viewModel: recording)
            }
        case .reauthorizationRequired:
            ContentUnavailableView {
                Label("저장 폴더 재승인이 필요합니다", systemImage: "folder.badge.questionmark")
            } description: { Text("저장 폴더를 다시 선택해 접근 권한을 허용하세요.") }
              actions: { Button("저장 폴더 재승인") { Task { await storageRoots.reauthorize() } } }
        case let .failed(code):
            ContentUnavailableView {
                Label("저장 폴더 오류", systemImage: "exclamationmark.triangle")
            } description: { Text("저장 폴더에 접근할 수 없습니다. (\(code.rawValue))") }
              actions: { Button("다시 선택") { Task { await storageRoots.chooseActiveRoot() } } }
        }
    }
}

struct SessionListRow: View {
    let item: SessionCatalogItem
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.title).font(.headline).lineLimit(2)
            Text(item.createdAt.value, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(Self.duration(item.activeDuration.rawValue)).monospacedDigit()
                Spacer()
                Text(Self.status(item.displayStatus))
            }.font(.caption)
        }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    static func duration(_ ms: Int64) -> String { RecordingSessionViewModel.formatElapsed(UInt64(max(0, ms))) }
    static func status(_ value: SessionStatus) -> String {
        switch value {
        case .preparing: "준비 중"
        case .recording: "녹음 중"
        case .paused: "일시정지"
        case .securing: "저장 중"
        case .finalizing: "마무리 중"
        case .completed: "완료"
        case .interrupted: "중단됨"
        case .error: "오류"
        case .missing: "파일 없음"
        }
    }
}

private struct SessionSummaryView: View {
    let item: SessionCatalogItem
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(item.title).font(.largeTitle.bold()).textSelection(.enabled)
            LabeledContent("녹음 날짜") { Text(item.createdAt.value, format: .dateTime.year().month().day().hour().minute()) }
            LabeledContent("길이", value: SessionListRow.duration(item.activeDuration.rawValue))
            LabeledContent("상태", value: SessionListRow.status(item.displayStatus))
            if item.presence != .present {
                Text("세션 파일을 읽을 수 없습니다. 저장 폴더의 연결과 접근 권한을 확인하세요.").foregroundStyle(.orange)
            }
            Spacer()
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct RecoveryStatusView: View {
    let snapshot: SessionRecoverySnapshot
    let retry: () -> Void
    let historicalReauthorizationErrors: [StorageRootID: StorageErrorCode]
    let reauthorize: @Sendable (StorageRootID) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch snapshot.phase {
            case .idle: EmptyView()
            case .discovering: Label("이전 세션을 확인하는 중…", systemImage: "magnifyingglass")
            case .recovering: Label("이전 녹음의 오디오를 복구하는 중…", systemImage: "waveform")
            case .cancelled: Label("세션 복구가 취소되었습니다", systemImage: "xmark.circle")
            case .ready: EmptyView()
            }
            if let report = snapshot.report {
                let presentation = RecoveryStatusPresentation.make(
                    report: report, historicalReauthorizationErrors: historicalReauthorizationErrors
                )
                Label(presentation.title, systemImage: presentation.items.isEmpty && presentation.rootNotices.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                Text(presentation.detail).font(.caption).foregroundStyle(.secondary)
                ForEach(presentation.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(item.issue.folderName ?? item.issue.rootID.rawValue.uuidString): \(item.title)")
                            .font(.caption).foregroundStyle(.secondary)
                        if let firstError = item.firstError { Text("최초 오류: \(firstError)").font(.caption2) }
                        if !item.warnings.isEmpty { Text("후속 경고: \(item.warnings.joined(separator: ", "))").font(.caption2) }
                        if let action = item.action {
                            switch action {
                            case .retry: Button("복구 다시 시도", action: retry)
                            case let .reauthorize(rootID): Button("이 폴더 재승인") { Task { await reauthorize(rootID) } }
                            }
                        }
                    }
                }
                ForEach(presentation.rootNotices) { notice in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(notice.rootID.rawValue.uuidString): 저장 폴더 재승인 실패")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("저장 폴더 오류: \(notice.error.rawValue)").font(.caption2)
                        Button("이 폴더 재승인") { Task { await reauthorize(notice.rootID) } }
                    }
                }
                if let catalogWarning = presentation.catalogWarning { Text("카탈로그 경고: \(catalogWarning.rawValue)").font(.caption) }
                if let discoveryWarning = presentation.discoveryWarning { Text("검색 경고: \(discoveryWarning)").font(.caption) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .accessibilityIdentifier("startup-recovery-status")
    }
}
