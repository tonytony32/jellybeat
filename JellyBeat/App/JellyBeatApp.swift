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
            AppMenuContent(
                settings: appDelegate.settings,
                registry: appDelegate.registry,
                arbiter: appDelegate.arbiter
            )
        }
    }
}
