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
