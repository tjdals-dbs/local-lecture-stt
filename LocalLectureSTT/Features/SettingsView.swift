import SwiftUI

struct SettingsView: View {
    @ObservedObject private var storageRoots: StorageRootViewModel
    private let diagnostics: DiagnosticSettingsViewModel?

    init(storageRoots: StorageRootViewModel = .preview, diagnostics: DiagnosticSettingsViewModel? = nil) {
        self.storageRoots = storageRoots
        self.diagnostics = diagnostics
    }

    var body: some View {
        Form {
            Section("저장 폴더") {
                switch storageRoots.state {
                case let .available(root, _):
                    Text(root.displayPath)
                    Button("저장 폴더 변경") { Task { await storageRoots.chooseActiveRoot() } }
                case .reauthorizationRequired:
                    IssueNoticeView(issue: .init(code: .storagePermission))
                    Button("저장 폴더 재승인") { Task { await storageRoots.reauthorize() } }
                case .loading:
                    ProgressView()
                case .noRoot:
                    Button("저장 폴더 선택") { Task { await storageRoots.chooseActiveRoot() } }
                case let .failed(code):
                    IssueNoticeView(issue: UserIssues.storage(code))
                    Button("저장 폴더 다시 선택") { Task { await storageRoots.chooseActiveRoot() } }
                }
            }
            if let diagnostics { DiagnosticSettingsSection(model: diagnostics) }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 320)
        .task { await storageRoots.restore() }
    }
}
