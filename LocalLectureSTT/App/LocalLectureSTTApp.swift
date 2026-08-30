import SwiftUI

@main
struct LocalLectureSTTApp: App {
    @StateObject private var storageRoots: StorageRootViewModel
    @StateObject private var catalogStartup: CatalogStartupCoordinator

    init() {
        let roots = StorageRootManager.live()
        let catalog: any SessionCataloging
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: support)
            catalog = SessionCatalogReconciler(scanner: SessionFileScanner(roots: roots), store: store)
        } catch let error as CatalogError {
            catalog = UnavailableSessionCatalog(error: error.code)
        } catch {
            catalog = UnavailableSessionCatalog(error: .openFailed)
        }
        let coordinator = CatalogStartupCoordinator(catalog: catalog)
        _catalogStartup = StateObject(wrappedValue: coordinator)
        _storageRoots = StateObject(wrappedValue: StorageRootViewModel(
            controller: roots,
            directorySelector: OpenPanelDirectorySelector(),
            onRootChanged: { coordinator.refreshAfterRootChange() }
        ))
    }

    var body: some Scene {
        Window("Local Lecture STT", id: "main") {
            MainWindowView(storageRoots: storageRoots, catalogStartup: catalogStartup)
        }
        .defaultSize(width: 720, height: 480)

        Settings {
            SettingsView(storageRoots: storageRoots)
        }
    }
}
