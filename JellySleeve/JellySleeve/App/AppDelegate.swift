import AppKit
import Combine
import SwiftUI
import os

/// Owns the borderless overlay window, the shared stores, the artwork cache,
/// and the polling lifecycle.
///
/// Why all of it lives here: `NSApplicationDelegateAdaptor` builds the delegate
/// without arguments, so this is the natural single owner that both AppKit
/// (window, NSWorkspace observers) and SwiftUI (Settings scene, MenuBarExtra)
/// can read from.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellysleeve",
        category: "state"
    )

    let settings: SettingsStore
    let player: PlayerStore
    let themes: ThemeRegistry
    let artworkProvider: ArtworkCacheProvider

    private var poller: PlaybackPoller?
    private var currentClient: JellyfinClient?

    private var overlayWindow: NSWindow?
    private var sleepWakeObservers: [NSObjectProtocol] = []
    private var windowVisibilityObservers: [NSObjectProtocol] = []
    private var settingsObservation: NSObjectProtocol?
    private var debouncedReconfigure: Task<Void, Never>?

    override init() {
        self.settings = SettingsStore()
        self.player = PlayerStore()
        self.themes = ThemeRegistry()
        self.artworkProvider = ArtworkCacheProvider()
        super.init()
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        createOverlayWindow()
        observeSleepWake()
        startPollingIfPossible()
        watchSettingsForReconfiguration()
        watchThemeForWindowResize()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopPolling()
        for observer in sleepWakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for observer in windowVisibilityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Keep the process alive when the overlay window is closed; the user
    /// reopens it from the menu-bar item.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Public entry points

    func showOverlay() {
        if overlayWindow == nil {
            createOverlayWindow()
            return
        }
        overlayWindow?.makeKeyAndOrderFront(nil)
        resumePollerIfPaused(reason: "overlay shown")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reconfigure the polling stack from current settings. Safe to call
    /// repeatedly; tears down the previous client/cache/poller if any.
    func startPollingIfPossible() {
        stopPolling()
        guard let config = settings.jellyfinConfiguration else {
            Self.logger.notice("Configuration incomplete; staying in .idle.")
            player.updateConnection(.idle)
            return
        }
        let client = JellyfinClient(configuration: config)
        let cache = ArtworkCache(client: client)
        let poller = PlaybackPoller(store: player)
        self.currentClient = client
        self.artworkProvider.cache = cache
        self.poller = poller

        Task { [poller, settings] in
            await poller.start(
                client: client,
                userId: config.userId,
                baseDelay: settings.refreshRate
            )
        }
    }

    func stopPolling() {
        let oldPoller = poller
        poller = nil
        currentClient = nil
        artworkProvider.cache = nil
        if let oldPoller {
            Task { await oldPoller.stop() }
        }
    }

    // MARK: - Lifecycle observers

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        let sleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pausePoller(reason: "system will sleep")
            }
        }
        let wake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.resumePollerIfPaused(reason: "system woke")
                if let poller = self.poller {
                    Task { await poller.forceRefresh() }
                }
            }
        }
        sleepWakeObservers = [sleep, wake]
    }

    private func observeWindowVisibility(_ window: NSWindow) {
        let center = NotificationCenter.default
        let hide = center.addObserver(
            forName: NSWindow.didMiniaturizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pausePoller(reason: "window miniaturised")
            }
        }
        let show = center.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resumePollerIfPaused(reason: "window deminiaturised")
            }
        }
        let willClose = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pausePoller(reason: "window closed")
            }
        }
        windowVisibilityObservers.append(contentsOf: [hide, show, willClose])
    }

    private func watchSettingsForReconfiguration() {
        // Re-evaluate the polling stack whenever the user changes baseURL,
        // apiKey, userId, allowSelfSigned, or refreshRate. UserDefaults
        // notifications fire on every keystroke in a SecureField, so we
        // debounce 500 ms before tearing down and restarting the poller.
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDebouncedReconfigure()
            }
        }
        settingsObservation = observer
    }

    private func scheduleDebouncedReconfigure() {
        debouncedReconfigure?.cancel()
        debouncedReconfigure = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.reconfigureFromSettings()
        }
    }

    private func reconfigureFromSettings() {
        // Coalesce bursts. Capture the new desired config and compare with the
        // one currently in flight.
        guard let desired = settings.jellyfinConfiguration else {
            if poller != nil {
                stopPolling()
                player.updateConnection(.idle)
            }
            return
        }
        if currentClient?.configuration == desired,
           poller != nil {
            return
        }
        startPollingIfPossible()
    }

    private func watchThemeForWindowResize() {
        // Use the Observation framework's withObservationTracking to bind
        // window size to themes.current.layout.windowSize.
        let watcher: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let size = self.themes.current.layout.windowSize
            self.resizeOverlayWindow(to: size)
            self.scheduleThemeReevaluation()
        }
        watcher()
    }

    private func scheduleThemeReevaluation() {
        withObservationTracking {
            _ = themes.current.id
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.watchThemeForWindowResize()
            }
        }
    }

    private func resizeOverlayWindow(to size: CGSize) {
        guard let window = overlayWindow else { return }
        let current = window.frame
        let newOrigin = NSPoint(
            x: current.midX - size.width / 2,
            y: current.midY - size.height / 2
        )
        let newFrame = NSRect(origin: newOrigin, size: size)
        window.setFrame(newFrame, display: true, animate: true)
    }

    // MARK: - Poller helpers

    private func pausePoller(reason: String) {
        guard let poller else { return }
        Self.logger.notice("Pause poller (\(reason, privacy: .public))")
        Task { await poller.pause() }
    }

    private func resumePollerIfPaused(reason: String) {
        guard let poller else { return }
        Self.logger.notice("Resume poller (\(reason, privacy: .public))")
        Task { await poller.resume() }
    }

    // MARK: - Window setup

    private func createOverlayWindow() {
        let windowSize = themes.current.layout.windowSize
        let contentRect = NSRect(
            x: 0, y: 0,
            width: windowSize.width, height: windowSize.height
        )
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let hosting = NSHostingView(
            rootView: OverlayView()
                .environment(settings)
                .environment(player)
                .environment(themes)
                .environment(artworkProvider)
        )
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = contentRect
        window.contentView = hosting

        window.center()
        window.makeKeyAndOrderFront(nil)
        observeWindowVisibility(window)
        overlayWindow = window
    }
}
