import AppKit
import SwiftUI

/// The app's menu content — Source picker, Settings, About, Quit — shared
/// between the menu-bar `MenuBarExtra` and the cover art's right-click
/// context menu so both present the identical menu.
struct AppMenuContent: View {
    let settings: SettingsStore
    let registry: SourceRegistry
    let arbiter: SourceArbiter

    var body: some View {
        sourceSection
        Divider()
        SettingsLink {
            Text(String(localized: "Settings…"))
        }
        .keyboardShortcut(",", modifiers: .command)
        Button(String(localized: "About JellyBeat")) {
            Self.showAboutPanel()
        }
        Divider()
        Button(String(localized: "Quit")) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    /// "Source" picker: Automatic / Jellyfin / YouTube, radio-style (✓ on the
    /// chosen one). In Automatic mode the label also notes which source is
    /// currently driving the overlay (`arbiter.activeKind`).
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
            get: { settings.sourceSelection },
            set: { settings.sourceSelection = $0 }
        )
    }

    /// Menu options: Automatic, then one entry per registered source (Jellyfin +
    /// every loopback source), each pinned by id.
    private var sourceOptions: [SourceSelection] {
        [.auto] + registry.selectableIDs.map(SourceSelection.forced)
    }

    private func sourceLabel(for option: SourceSelection) -> String {
        guard option == .auto else {
            // A forced pick: the source's TRUSTED display name (manifest/built-in),
            // never the source-served `/health.sourceName`.
            if let id = option.forcedKind {
                return registry.displayName(for: id)
            }
            return String(localized: "Automatic")
        }
        guard settings.sourceSelection == .auto else {
            return String(localized: "Automatic")
        }
        // In auto, note which source is currently driving.
        let driving = registry.displayName(for: arbiter.activeKind)
        return String(localized: "Automatic (\(driving))")
    }

    static func showAboutPanel() {
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
