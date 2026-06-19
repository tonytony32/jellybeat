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
    /// Decides which source (Jellyfin / a loopback source) drives the overlay.
    /// Exposed so the menu-bar "Source" section can mark the active one.
    let arbiter: SourceArbiter
    /// All known playback sources — the built-in Jellyfin + YouTube, plus any
    /// third-party loopback sources discovered from `*.jellysource` manifests.
    /// The menu's "Source" picker lists these.
    let registry: SourceRegistry

    private let windowController: OverlayWindowController
    private let connection: PlaybackConnectionCoordinator
    private var mediaCenter: MediaCenterController?
    private var phoneCallMonitor: PhoneCallMonitor?

    override init() {
        // The hosted unit-test runner launches this app as its test host, so
        // `init` runs once per `xcodebuild test`. Keep every launch-time side
        // effect OFF the user's real domains: skip the identity migration and
        // back the stores with a throwaway UserDefaults suite + in-memory
        // Keychain. `applicationDidFinishLaunching` likewise early-returns.
        let underTests = Self.isRunningUnitTests

        // Migrate any pre-rename (JellySleeve) login/settings into the new
        // bundle-id identity BEFORE the stores below read UserDefaults/Keychain.
        // If a store ran first it would see the empty new domain and persist
        // logged-out/default state. Idempotent; see `IdentityMigrator`.
        if !underTests {
            IdentityMigrator.runIfNeeded()
        }
        let defaults: UserDefaults = underTests
            ? (UserDefaults(suiteName: Self.testHostSuiteName) ?? .standard)
            : .standard
        let keychain: any APIKeyKeychain = underTests ? InMemoryKeychain() : SystemKeychain()
        let settings = SettingsStore(defaults: defaults, keychain: keychain)
        let player = PlayerStore(defaults: defaults)
        let themes = ThemeRegistry(defaults: defaults)
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
        let connection = PlaybackConnectionCoordinator(
            settings: settings,
            player: player,
            artworkProvider: artworkProvider
        )
        self.connection = connection
        // Discover playback sources: the built-in YouTube loopback bridge plus
        // any third-party `*.jellysource` manifests. The arbiter weighs them
        // against Jellyfin (the privileged non-loopback built-in).
        let registry = SourceRegistry.loadingFromDisk()
        self.registry = registry
        self.arbiter = SourceArbiter(
            settings: settings,
            player: player,
            coordinator: connection,
            registry: registry
        )
        super.init()
        // Tell macOS not to restore Settings between launches. Without this,
        // closing the Settings window during one session causes it to spring
        // back open the next time the app starts (SwiftUI's Settings scene
        // participates in the system-wide Resume mechanism). Skipped under the
        // test host so it never writes to the user's real domain.
        if !underTests {
            UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        }
    }

    /// Throwaway UserDefaults suite used only when running under the unit-test
    /// host, so store construction never touches the user's real `.standard`
    /// domain. A fixed name (not per-launch) avoids accumulating stray plists.
    private static let testHostSuiteName = "software.trypwood.jellybeat.test-host"

    /// True when this process is the host for an `xcodebuild test` run. The test
    /// runner sets these environment variables / loads XCTest before `init`, so
    /// the check is reliable this early. Covers both XCTest- and Swift
    /// Testing-based bundles (both inject through the XCTest host machinery).
    private static var isRunningUnitTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Under the unit-test host, skip all launch-time side effects (window
        // creation, network auto-connect via the arbiter, the Now Playing
        // bridge). Tests drive the units they need directly.
        guard !Self.isRunningUnitTests else { return }

        // Window-visibility events (miniaturise / close / deminiaturise) and
        // the user reopening the overlay should pause or resume both feeds via
        // the arbiter, so the YouTube poll stops alongside the Jellyfin transport.
        windowController.onPauseRequested = { [weak self] reason in
            self?.arbiter.pause(reason: reason)
        }
        windowController.onResumeRequested = { [weak self] reason in
            self?.arbiter.resume(reason: reason)
        }

        windowController.createWindow()
        arbiter.activate()
        windowController.startObserving()
        activateMediaCenter()
        windowController.closeRestoredScenesExceptOverlay()

        phoneCallMonitor = PhoneCallMonitor(player: player)

        applyPresence(settings.appPresence)
        trackPresenceChanges()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showOverlay() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        arbiter.shutdown()
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
