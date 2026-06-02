import AppKit
import SwiftUI

/// Thin application coordinator. Owns the shared stores and wires together the
/// two domain collaborators — `OverlayWindowController` (window geometry) and
/// `PlaybackConnectionCoordinator` (transport lifecycle) — plus the system-wide
/// Now Playing bridge.
///
/// Why it owns the stores: `NSApplicationDelegateAdaptor` builds the delegate
/// without arguments, so this is the natural single owner that both AppKit and
/// SwiftUI (Settings scene, MenuBarExtra) can read from.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings: SettingsStore
    let player: PlayerStore
    let themes: ThemeRegistry
    let artworkProvider: ArtworkCacheProvider

    private let windowController: OverlayWindowController
    private let connection: PlaybackConnectionCoordinator
    private var mediaCenter: MediaCenterController?

    override init() {
        let settings = SettingsStore()
        let player = PlayerStore()
        let themes = ThemeRegistry()
        let artworkProvider = ArtworkCacheProvider()
        self.settings = settings
        self.player = player
        self.themes = themes
        self.artworkProvider = artworkProvider
        self.windowController = OverlayWindowController(
            settings: settings,
            player: player,
            themes: themes,
            artworkProvider: artworkProvider
        )
        self.connection = PlaybackConnectionCoordinator(
            settings: settings,
            player: player,
            artworkProvider: artworkProvider
        )
        super.init()
        // Tell macOS not to restore Settings between launches. Without this,
        // closing the Settings window during one session causes it to spring
        // back open the next time the app starts (SwiftUI's Settings scene
        // participates in the system-wide Resume mechanism).
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Window-visibility events (miniaturise / close / deminiaturise) and
        // the user reopening the overlay should pause or resume the feed.
        windowController.onPauseRequested = { [weak self] reason in
            self?.connection.pause(reason: reason)
        }
        windowController.onResumeRequested = { [weak self] reason in
            self?.connection.resume(reason: reason)
        }

        windowController.createWindow()
        connection.activate()
        windowController.startObserving()
        activateMediaCenter()
        windowController.closeRestoredScenesExceptOverlay()

        applyPresence(settings.appPresence)
        trackPresenceChanges()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showOverlay() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        connection.shutdown()
        windowController.shutdown()
    }

    /// Keep the process alive when the overlay window is closed; the user
    /// reopens it from the menu-bar item.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Public entry points

    func showOverlay() {
        windowController.showOverlay()
    }

    // MARK: - App presence

    private func applyPresence(_ presence: AppPresence) {
        NSApp.setActivationPolicy(presence.showsDock ? .regular : .accessory)
    }

    private func trackPresenceChanges() {
        withObservationTracking {
            _ = settings.appPresence
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyPresence(self.settings.appPresence)
                self.trackPresenceChanges()
            }
        }
    }

    // MARK: - Now Playing bridge

    private func activateMediaCenter() {
        let controller = MediaCenterController(player: player, artworkProvider: artworkProvider)
        controller.activate()
        mediaCenter = controller
    }
}
