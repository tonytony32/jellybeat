import AppKit
import SwiftUI

/// Radio-style "Source" picker shared by the menu-bar extra and the overlay's
/// right-click menu, so both stay in sync. Lists Automatic + every registered
/// source; in Automatic it also notes which source is currently driving the
/// overlay (`arbiter.activeKind`). Reads its collaborators from the environment.
struct SourceMenuSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(SourceRegistry.self) private var registry
    @Environment(SourceArbiter.self) private var arbiter

    var body: some View {
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
}

/// Right-click menu for the album artwork in every theme: pick the playback
/// source and open Settings, in place — without dismissing the overlay or
/// quitting the app. Built lazily as `.contextMenu` content, so it inherits the
/// overlay's environment (settings / registry / arbiter / openSettings).
struct ArtworkContextMenu: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        SourceMenuSection()
        Divider()
        Button {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Text(String(localized: "Settings…"))
        }
    }
}
