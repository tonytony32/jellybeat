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
            ForEach(sourceOptions, id: \.self) { option in
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

    /// Menu options: Automatic, then one entry per registered source (Jellyfin +
    /// every loopback source), each pinned by id.
    private var sourceOptions: [SourceSelection] {
        [.auto] + appDelegate.registry.selectableIDs.map(SourceSelection.forced)
    }

    private func sourceLabel(for option: SourceSelection) -> String {
        guard option == .auto else {
            // A forced pick: the source's TRUSTED display name (manifest/built-in),
            // never the source-served `/health.sourceName`.
            if let id = option.forcedKind {
                return appDelegate.registry.displayName(for: id)
            }
            return String(localized: "Automatic")
        }
        guard appDelegate.settings.sourceSelection == .auto else {
            return String(localized: "Automatic")
        }
        // In auto, note which source is currently driving.
        let driving = appDelegate.registry.displayName(for: appDelegate.arbiter.activeKind)
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
