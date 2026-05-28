import SwiftUI

@main
struct JellySleeveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Settings scene wires up Cmd+, and the standard "Settings…" menu
        // entry under the app menu. Body filled in Fase 3.
        Settings {
            SettingsView()
        }

        // Menu-bar entry per plan §3.3. Provides a way to reopen the overlay
        // if the user dismisses it, plus the universal Settings / Quit items.
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
