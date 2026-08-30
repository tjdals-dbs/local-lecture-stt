import SwiftUI

struct SettingsView: View {
    @ObservedObject private var storageRoots: StorageRootViewModel

    init(storageRoots: StorageRootViewModel = .preview) {
        self.storageRoots = storageRoots
    }

    var body: some View {
        Form {
            Section("저장 폴더") {
                switch storageRoots.state {
                case let .available(root, _):
                    Text(root.displayPath)
                    Button("저장 폴더 변경") { Task { await storageRoots.chooseActiveRoot() } }
                case .reauthorizationRequired:
                    Text("재승인이 필요합니다.")
                    Button("저장 폴더 재승인") { Task { await storageRoots.reauthorize() } }
                case .loading:
                    ProgressView()
                case .noRoot, .failed:
                    Button("저장 폴더 선택") { Task { await storageRoots.chooseActiveRoot() } }
                }
            }
        }
        .padding()
        .frame(minWidth: 360, minHeight: 160)
        .task { await storageRoots.restore() }
    }
}
