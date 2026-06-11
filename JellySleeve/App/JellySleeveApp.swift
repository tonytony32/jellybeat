import AppKit
import SwiftUI

@main
struct JellySleeveApp: App {
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

        MenuBarExtra("JellySleeve", systemImage: "music.note", isInserted: Binding(
            get: { menuBarIsInserted },
            set: { _ in }
        )) {
            Button(String(localized: "Open Overlay")) {
                appDelegate.showOverlay()
            }
            Divider()
            sourceSection
            Divider()
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

    /// "Source" picker in the menu: Automatic / Jellyfin / YouTube, radio-style
    /// (✓ on the chosen one). In Automatic mode the label also notes which
    /// source is currently driving the overlay (`arbiter.activeKind`).
    @ViewBuilder
    private var sourceSection: some View {
        Picker(selection: sourceBinding) {
            ForEach(SourceSelection.allCases) { option in
                Text(sourceLabel(for: option)).tag(option)
            }
        } label: {
            Text(String(localized: "Source"))
        }
        .pickerStyle(.inline)
    }

    private var sourceBinding: Binding<SourceSelection> {
        Binding(
            get: { appDelegate.settings.sourceSelection },
            set: { appDelegate.settings.sourceSelection = $0 }
        )
    }

    private func sourceLabel(for option: SourceSelection) -> String {
        guard option == .auto,
              appDelegate.settings.sourceSelection == .auto else {
            return option.displayName
        }
        let driving = appDelegate.arbiter.activeKind == .youtube
            ? String(localized: "YouTube")
            : String(localized: "Jellyfin")
        return String(localized: "Automatic (\(driving))")
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
