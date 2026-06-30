import AppKit
import SwiftUI

@main
struct JellyBeatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Mirrors settings.appPresence in UserDefaults so the App body reacts when
    // the user changes it from the Settings window (which lives in a different
    // SwiftUI subtree). @AppStorage watches the same key SettingsStore writes.
    @AppStorage("settings.appPresence") private var appPresence: String = AppPresence.dockAndMenuBar.rawValue

    private var menuBarIsInserted: Bool {
        AppPresence(rawValue: appPresence)?.showsMenuBar ?? true
    }

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(appDelegate.settings)
                .environment(appDelegate.themes)
                .environment(appDelegate.player)
        }

        MenuBarExtra("JellyBeat", systemImage: "music.note", isInserted: Binding(
            get: { menuBarIsInserted },
            set: { _ in }
        )) {
            SourceMenuSection()
                .environment(appDelegate.settings)
                .environment(appDelegate.registry)
                .environment(appDelegate.arbiter)
            Divider()
            SettingsLink {
                Text(String(localized: "Settings…"))
            }
            .keyboardShortcut(",", modifiers: .command)
            Button(String(localized: "About JellyBeat")) {
                showAboutPanel()
            }
            Divider()
            Button(String(localized: "Quit")) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func showAboutPanel() {
        let credits = NSAttributedString(
            string: "Built independently for Jellyfin.\nVisual inspiration from Sleeve by Replay.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            NSApplication.AboutPanelOptionKey.credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
