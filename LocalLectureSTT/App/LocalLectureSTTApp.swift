import SwiftUI

@main
struct LocalLectureSTTApp: App {
    var body: some Scene {
        Window("Local Lecture STT", id: "main") {
            MainWindowView()
        }
        .defaultSize(width: 720, height: 480)

        Settings {
            SettingsView()
        }
    }
}
