import Foundation

@MainActor
final class CatalogStartupCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case ready(CatalogReconciliationReport)
        case failed(CatalogErrorCode)
    }

    @Published private(set) var state: State = .idle
    private let catalog: any SessionCataloging
    private var startupTask: Task<Void, Never>?
    private var refreshPending = false

    init(catalog: any SessionCataloging) { self.catalog = catalog }

    func start() {
        if startupTask != nil { return }
        state = .starting
        startupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await self.catalog.reconcile()
                self.state = .ready(report)
            } catch let error as CatalogError {
                self.state = .failed(error.code)
            } catch {
                self.state = .failed(.filesystemScanFailed)
            }
            self.startupTask = nil
            if self.refreshPending {
                self.refreshPending = false
                self.start()
            }
        }
    }

    func refreshAfterRootChange() {
        if startupTask != nil { refreshPending = true }
        else { start() }
    }
}
