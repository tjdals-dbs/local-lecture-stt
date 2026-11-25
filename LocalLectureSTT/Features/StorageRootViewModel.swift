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
    @Published private(set) var state: StorageRootViewState = .loading {
        didSet {
            guard state != oldValue else { return }
            switch state {
            case let .failed(code): diagnostics.issue(UserIssues.storage(code), source: .storage)
            case .reauthorizationRequired: diagnostics.issue(.init(code: .storagePermission), source: .storage)
            default: break
            }
        }
    }
    /// A recovery action may target a historical root while `state` continues
    /// to describe the active root that is powering a live recording.  Keep
    /// that per-root failure available to the recovery UI instead of turning
    /// the entire root selector into `.failed`.
    @Published private(set) var historicalReauthorizationErrors: [StorageRootID: StorageErrorCode] = [:]
    @Published private(set) var isPresentingPicker = false
    @Published private(set) var isSavingSelection = false

    private let controller: any StorageRootControlling
    private let directorySelector: any DirectorySelecting
    private let onRootChanged: @MainActor @Sendable () -> Void
    private let diagnostics: any DiagnosticRecording

    init(controller: any StorageRootControlling, directorySelector: any DirectorySelecting, onRootChanged: @escaping @MainActor @Sendable () -> Void = {},
         diagnostics: any DiagnosticRecording = NoopDiagnosticRecorder()) {
        self.controller = controller
        self.directorySelector = directorySelector
        self.onRootChanged = onRootChanged
        self.diagnostics = diagnostics
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
            onRootChanged()
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
            onRootChanged()
        } catch let error as StorageError {
            state = .failed(error.code)
        } catch {
            state = .failed(.bookmarkCreateFailed)
        }
    }

    /// Recovery can identify an unavailable historical root while another root
    /// remains active.  Reauthorize that exact root rather than silently using
    /// the active-root bookmark.
    func reauthorize(rootID: StorageRootID) async {
        guard !isPresentingPicker, !isSavingSelection else { return }
        // This action can target a historical root reported by recovery while
        // the active root is driving a live recording.  A failed picker or
        // bookmark update must not replace that active-root UI with a global
        // failure state.
        let stateBeforeHistoricalAttempt = state
        isPresentingPicker = true
        defer { isPresentingPicker = false }
        guard let url = directorySelector.chooseDirectory() else { return }
        isSavingSelection = true
        defer { isSavingSelection = false }
        do {
            _ = try await controller.reauthorize(rootID: rootID, with: url)
            historicalReauthorizationErrors[rootID] = nil
            state = Self.viewState(from: await controller.availability())
            onRootChanged()
        } catch let error as StorageError {
            historicalReauthorizationErrors[rootID] = error.code
            diagnostics.issue(UserIssues.storage(error.code), source: .storage)
            state = stateBeforeHistoricalAttempt
        } catch {
            historicalReauthorizationErrors[rootID] = .bookmarkCreateFailed
            diagnostics.issue(.init(code: .storagePermission), source: .storage)
            state = stateBeforeHistoricalAttempt
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
