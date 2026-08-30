import SwiftUI

@main
struct LocalLectureSTTApp: App {
    @StateObject private var storageRoots: StorageRootViewModel

    init() {
        _storageRoots = StateObject(wrappedValue: StorageRootViewModel(
            controller: StorageRootManager.live(),
            directorySelector: OpenPanelDirectorySelector()
        ))
    }

    var body: some Scene {
        Window("Local Lecture STT", id: "main") {
            MainWindowView(storageRoots: storageRoots)
        }
        .defaultSize(width: 720, height: 480)

        Settings {
            SettingsView(storageRoots: storageRoots)
        }
    }
}
