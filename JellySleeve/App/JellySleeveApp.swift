import AppKit
import SwiftUI

@main
struct JellySleeveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(appDelegate.settings)
                .environment(appDelegate.themes)
                .environment(appDelegate.player)
        }

        MenuBarExtra("JellySleeve", systemImage: "music.note") {
            Button(String(localized: "Open Overlay")) {
                appDelegate.showOverlay()
            }
            SettingsLink {
                Text(String(localized: "Settings…"))
            }
            .keyboardShortcut(",", modifiers: .command)
            Button(String(localized: "About JellySleeve")) {
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
