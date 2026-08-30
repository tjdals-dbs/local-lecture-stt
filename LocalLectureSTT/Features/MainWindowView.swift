import SwiftUI

struct MainWindowView: View {
    @ObservedObject private var storageRoots: StorageRootViewModel

    init(storageRoots: StorageRootViewModel = .preview) {
        self.storageRoots = storageRoots
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
                ContentUnavailableView {
                    Label("저장 폴더 사용 가능", systemImage: "folder.fill")
                } description: {
                    Text(refreshedBookmark ? "\(root.displayName) — 접근 권한을 갱신했습니다." : root.displayPath)
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
        .task { await storageRoots.restore() }
    }
}
