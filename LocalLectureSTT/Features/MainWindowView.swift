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

    var body: some View {
        Group {
            switch storageRoots.state {
            case .loading:
                ProgressView("저장 폴더 상태를 확인하는 중…")
            case .noRoot:
                ContentUnavailableView {
                    Label("저장 폴더가 필요합니다", systemImage: "folder.badge.plus")
                } description: {
                    Text("세션 파일을 저장할 폴더를 선택하세요.")
                } actions: {
                    Button("저장 폴더 선택") { Task { await storageRoots.chooseActiveRoot() } }
                }
            case let .available(root, refreshedBookmark):
                VStack(spacing: 0) {
                    HStack {
                        Label(root.displayName, systemImage: "folder.fill")
                        Spacer()
                        if refreshedBookmark { Text("접근 권한 갱신됨").foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    Divider()
                    if let recovery = catalogStartup.recoverySnapshot {
                        RecoveryStatusView(snapshot: recovery, retry: { catalogStartup.retryRecovery() },
                                           historicalReauthorizationErrors: storageRoots.historicalReauthorizationErrors,
                                           reauthorize: { rootID in await storageRoots.reauthorize(rootID: rootID) })
                        Divider()
                    }
                    RecordingSessionView(viewModel: recording)
                }
            case .reauthorizationRequired:
                ContentUnavailableView {
                    Label("재승인이 필요합니다", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("저장 폴더에 다시 접근할 수 있도록 선택하세요.")
                } actions: {
                    Button("저장 폴더 재승인") { Task { await storageRoots.reauthorize() } }
                }
            case let .failed(code):
                ContentUnavailableView {
                    Label("저장 폴더 오류", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(code.rawValue)
                } actions: {
                    Button("다시 선택") { Task { await storageRoots.chooseActiveRoot() } }
                }
            }
        }
        .accessibilityIdentifier("initial-project-shell")
        .task {
            recording.startObserving()
            await storageRoots.restore()
            await recording.refreshPermissionStatus()
            catalogStartup.start()
        }
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
