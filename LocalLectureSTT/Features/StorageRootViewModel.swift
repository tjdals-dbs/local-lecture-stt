import AppKit
import SwiftUI

@MainActor
protocol DirectorySelecting {
    func chooseDirectory() -> URL?
}

@MainActor
struct OpenPanelDirectorySelector: DirectorySelecting {
    func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum StorageRootViewState: Equatable {
    case loading
    case noRoot
    case available(StorageRootSummary, refreshedBookmark: Bool)
    case reauthorizationRequired(StorageRootSummary?)
    case failed(StorageErrorCode)
}

@MainActor
final class StorageRootViewModel: ObservableObject {
    @Published private(set) var state: StorageRootViewState = .loading
    @Published private(set) var isPresentingPicker = false
    @Published private(set) var isSavingSelection = false

    private let controller: any StorageRootControlling
    private let directorySelector: any DirectorySelecting

    init(controller: any StorageRootControlling, directorySelector: any DirectorySelecting) {
        self.controller = controller
        self.directorySelector = directorySelector
    }

    static var preview: StorageRootViewModel {
        StorageRootViewModel(controller: PreviewStorageRootController(), directorySelector: PreviewDirectorySelector())
    }

    func restore() async {
        state = Self.viewState(from: await controller.availability())
    }

    func chooseActiveRoot() async {
        guard !isPresentingPicker, !isSavingSelection else { return }
        isPresentingPicker = true
        defer { isPresentingPicker = false }
        guard let url = directorySelector.chooseDirectory() else { return }
        isSavingSelection = true
        defer { isSavingSelection = false }
        do {
            let root = try await controller.registerSelectedDirectory(url)
            state = .available(root, refreshedBookmark: false)
        } catch let error as StorageError {
            state = .failed(error.code)
        } catch {
            state = .failed(.bookmarkCreateFailed)
        }
    }

    func reauthorize() async {
        guard case let .reauthorizationRequired(summary?) = state, !isPresentingPicker, !isSavingSelection else { return }
        isPresentingPicker = true
        defer { isPresentingPicker = false }
        guard let url = directorySelector.chooseDirectory() else { return }
        isSavingSelection = true
        defer { isSavingSelection = false }
        do {
            let root = try await controller.reauthorize(rootID: summary.id, with: url)
            state = .available(root, refreshedBookmark: false)
        } catch let error as StorageError {
            state = .failed(error.code)
        } catch {
            state = .failed(.bookmarkCreateFailed)
        }
    }

    private static func viewState(from availability: StorageRootAvailability) -> StorageRootViewState {
        switch availability {
        case .noRootSelected: .noRoot
        case let .available(summary, refreshed): .available(summary, refreshedBookmark: refreshed)
        case let .reauthorizationRequired(summary): .reauthorizationRequired(summary)
        case let .failed(code): .failed(code)
        }
    }
}

private actor PreviewStorageRootController: StorageRootControlling {
    func availability() async -> StorageRootAvailability { .noRootSelected }
    func storageRootCatalog() async throws -> StorageRootCatalog { StorageRootCatalog(activeRootID: nil, roots: []) }
    func registerSelectedDirectory(_ url: URL) async throws -> StorageRootSummary { throw StorageError(.bookmarkCreateFailed) }
    func reauthorize(rootID: StorageRootID, with url: URL) async throws -> StorageRootSummary { throw StorageError(.bookmarkCreateFailed) }
}

@MainActor
private struct PreviewDirectorySelector: DirectorySelecting {
    func chooseDirectory() -> URL? { nil }
}
