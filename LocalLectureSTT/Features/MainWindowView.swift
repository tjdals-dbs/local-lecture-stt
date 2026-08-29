import SwiftUI

struct MainWindowView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Local Lecture STT", systemImage: "waveform")
        } description: {
            Text(AppShellInfo.statusMessage)
        }
        .accessibilityIdentifier("initial-project-shell")
    }
}
