import SwiftUI

@main
struct JellySleeveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(appDelegate.settings)
        }

        MenuBarExtra("JellySleeve", systemImage: "music.note") {
            Button("Open Overlay") {
                appDelegate.showOverlay()
            }
            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
