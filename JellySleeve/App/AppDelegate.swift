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
    private var socketClient: JellyfinSocketClient?
    private var socketStateTask: Task<Void, Never>?
    private var socketFailureStreak: Int = 0
    private var currentClient: JellyfinClient?
    private var mediaCenter: MediaCenterController?
    /// Once we've fallen back to polling we stop trying to revive the socket
    /// for this configuration. A reconfigure (new baseURL / user / key) or a
    /// relaunch resets it.
    private static let socketMaxConsecutiveFailures = 3

    private var overlayWindow: NSWindow?
    private var sleepWakeObservers: [NSObjectProtocol] = []
    private var windowVisibilityObservers: [NSObjectProtocol] = []
    private var settingsObservation: NSObjectProtocol?
    private var debouncedReconfigure: Task<Void, Never>?
    /// True while we are programmatically moving the window (theme resize,
    /// snap apply, restore on launch). Used to suppress feedback into
    /// `windowDidMove` so we don't try to snap something we just snapped.
    private var suppressMoveCallback: Bool = false
    /// Tracks whether the window currently shows the ambient (artwork-sized)
    /// or the full-layout footprint. Lets us compute the correct screen
    /// origin when transitioning between the two modes.
    private var windowIsAmbient: Bool = false

    override init() {
        self.settings = SettingsStore()
        self.player = PlayerStore()
        self.themes = ThemeRegistry()
        self.artworkProvider = ArtworkCacheProvider()
        super.init()
        // Tell macOS not to restore Settings between launches. Without this,
        // closing the Settings window during one session causes it to spring
        // back open the next time the app starts (SwiftUI's Settings scene
        // participates in the system-wide Resume mechanism).
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        createOverlayWindow()
        observeSleepWake()
        startPollingIfPossible()
        watchSettingsForReconfiguration()
        watchThemeForWindowResize()
        watchAppearanceSettings()
        watchPlayerForAmbientMode()
        activateMediaCenter()
        // Close anything macOS Resume restored except the overlay AND the
        // MenuBarExtra's internal NSStatusBarWindow (`StatusBar`/`Popover`
        // class names) so we don't lose the menu-bar item.
        closeRestoredScenesExceptOverlay()
    }

    private func closeRestoredScenesExceptOverlay() {
        for window in NSApp.windows where window !== overlayWindow {
            let cls = String(describing: type(of: window))
            if cls.contains("StatusBar") || cls.contains("Popover") || cls.contains("MenuBar") {
                continue
            }
            window.close()
        }
    }

    private func activateMediaCenter() {
        let controller = MediaCenterController(player: player, artworkProvider: artworkProvider)
        controller.activate()
        mediaCenter = controller
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

    /// Reconfigure the playback feed (WebSocket preferred, polling fallback)
    /// from the current settings. Safe to call repeatedly; tears down any
    /// previous stack first.
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
        let socket = JellyfinSocketClient(
            configuration: config,
            deviceId: settings.deviceId,
            userId: config.userId,
            store: player
        )

        self.currentClient = client
        self.artworkProvider.cache = cache
        self.poller = poller
        self.socketClient = socket
        self.socketFailureStreak = 0
        player.configure(client: client, poller: poller)
        player.connectionMode = .unknown
        player.updateConnection(.connecting)

        // Drive the swap-to-polling decision off the socket's state stream.
        socketStateTask?.cancel()
        socketStateTask = Task { [weak self] in
            await self?.observeSocketStates(socket)
        }

        Task {
            await socket.start()
        }
    }

    func stopPolling() {
        let oldPoller = poller
        let oldSocket = socketClient
        poller = nil
        socketClient = nil
        currentClient = nil
        artworkProvider.cache = nil
        socketStateTask?.cancel()
        socketStateTask = nil
        player.configure(client: nil, poller: nil)
        player.connectionMode = .unknown
        if let oldPoller {
            Task { await oldPoller.stop() }
        }
        if let oldSocket {
            Task { await oldSocket.stop() }
        }
    }

    /// Reacts to socket state transitions:
    ///  - `.connected` → make sure the poller is stopped (server is pushing).
    ///  - `.failed`    → increment the streak; if we hit the cap, hand over
    ///                   to the polling poller permanently for this config.
    private func observeSocketStates(_ socket: JellyfinSocketClient) async {
        for await state in socket.stateStream {
            guard !Task.isCancelled else { return }
            switch state {
            case .connecting, .idle:
                continue
            case .connected:
                socketFailureStreak = 0
                player.connectionMode = .webSocket
                if let poller {
                    Self.logger.notice("WebSocket up; pausing polling fallback.")
                    Task { await poller.stop() }
                }
            case .failed(let message):
                socketFailureStreak += 1
                Self.logger.error("WebSocket failed (\(self.socketFailureStreak, privacy: .public)/\(Self.socketMaxConsecutiveFailures, privacy: .public)): \(message, privacy: .public)")
                if socketFailureStreak >= Self.socketMaxConsecutiveFailures {
                    Self.logger.notice("WebSocket gave up after \(self.socketFailureStreak, privacy: .public) failures; switching to polling.")
                    startPollerFallback()
                    // Don't return — keep the loop alive so a successful
                    // reconnect can flip us back to WebSocket mode. Schedule
                    // a reconnect attempt after a 60 s backoff.
                    scheduleWebSocketReconnect(socket: socket)
                } else {
                    // Retry the socket with a short backoff before giving up.
                    Task { [weak self, socket] in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard !Task.isCancelled, let self else { return }
                        if self.socketClient === socket {
                            await socket.start()
                        }
                    }
                }
            }
        }
    }

    private func startPollerFallback() {
        guard let client = currentClient,
              let config = settings.jellyfinConfiguration,
              let poller else { return }
        // Idempotent: skip if the poller is already the active transport.
        // Called repeatedly during WebSocket reconnect cycles — only the
        // first call (or a call after a brief WebSocket reconnect) needs
        // to actually start the poller.
        guard player.connectionMode != .polling else { return }
        player.connectionMode = .polling
        Task { [poller, settings] in
            await poller.start(
                client: client,
                userId: config.userId,
                baseDelay: settings.refreshRate
            )
        }
    }

    /// Schedule a WebSocket reconnect attempt after a 60 s backoff. Called
    /// after the socket has permanently failed and the poller has taken over.
    /// If the reconnect succeeds, `observeSocketStates` receives `.connected`
    /// and stops the poller; if it fails again, the cycle repeats.
    private func scheduleWebSocketReconnect(socket: JellyfinSocketClient) {
        Task { [weak self, socket] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, self.socketClient === socket else { return }
            Self.logger.notice("Retrying WebSocket after polling fallback.")
            // Reset streak so the socket gets a fresh set of attempts.
            self.socketFailureStreak = 0
            await socket.start()
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
        // Apply cheap window-level/opacity changes immediately — they don't
        // need a poller restart.
        applyWindowSettings()

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

    /// Apply user-configurable window placement (level, opacity). Called both
    /// after window creation and on every settings change.
    private func applyWindowSettings() {
        guard let window = overlayWindow else { return }
        switch settings.windowLevel {
        case .alwaysOnTop:
            window.level = .floating
        case .normal:
            window.level = .normal
        case .behind:
            // One step below Normal — other apps cover us, but as soon as
            // the foreground window goes away (Cmd+Tab elsewhere, app hide,
            // Space change with no other windows on top) JellySleeve is
            // clickable again. The previous desktopIconWindow level was too
            // low — macOS routes clicks there to Finder.
            window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        }
        window.alphaValue = CGFloat(settings.windowOpacity)
    }

    private func watchThemeForWindowResize() {
        // Use the Observation framework's withObservationTracking to bind
        // window size to themes.current.layout.windowSize.
        let watcher: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.applyWindowSizeForCurrentState()
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

    /// Shrink the overlay to artwork-size when the server is reachable but
    /// nothing is playing, so the floating window stays out of the way until
    /// the user wants it. Restores full layout once a track starts.
    private func watchPlayerForAmbientMode() {
        withObservationTracking {
            _ = player.connectionState
            _ = player.currentTrack
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyWindowSizeForCurrentState()
                self?.watchPlayerForAmbientMode()
            }
        }
    }

    private var isInAmbientMode: Bool {
        if case .connected = player.connectionState, player.currentTrack == nil {
            return true
        }
        return false
    }

    /// Resize and reposition the overlay across transitions (theme change,
    /// full → ambient, ambient → full).
    ///
    /// Two anchoring strategies:
    ///  - If the window is currently snapped to one of the four corners of
    ///    the screen's visibleFrame, keep it pinned to that same corner with
    ///    the new size. This trumps the artwork anchor below.
    ///  - Otherwise, line the new window up so the artwork rectangle lands
    ///    on the exact same screen pixels as before. Minim (no artwork)
    ///    falls back to centring at the previous window centre.
    private func applyWindowSizeForCurrentState() {
        guard let window = overlayWindow else { return }
        let theme = themes.current
        let targetAmbient = isInAmbientMode && theme.artworkFrame != nil

        // The window's own drop-shadow looks like a frame around the cover
        // when the theme has no glass background (Aero). Suppress it there
        // and let the artwork's own shadow do the work.
        window.hasShadow = theme.behavior.hasGlassBackground

        // Decide next size.
        let nextSize: CGSize
        if targetAmbient, let art = theme.artworkFrame {
            nextSize = art.size
        } else {
            nextSize = theme.layout.windowSize
        }

        // Decide next origin.
        var nextOrigin: CGPoint
        if let corner = currentSnapCorner(window: window),
           let screen = window.screen ?? NSScreen.main {
            // Preserve the snapped corner across resizes.
            nextOrigin = origin(for: corner, size: nextSize, on: screen)
        } else {
            // Artwork-anchored repositioning.
            let artworkScreenOrigin: CGPoint = {
                if windowIsAmbient {
                    return window.frame.origin
                } else if let art = theme.artworkFrame {
                    return CGPoint(
                        x: window.frame.origin.x + art.minX,
                        y: window.frame.origin.y + art.minY
                    )
                } else {
                    return CGPoint(x: window.frame.midX, y: window.frame.midY)
                }
            }()

            if targetAmbient {
                nextOrigin = artworkScreenOrigin
            } else if let art = theme.artworkFrame {
                nextOrigin = CGPoint(
                    x: artworkScreenOrigin.x - art.minX,
                    y: artworkScreenOrigin.y - art.minY
                )
            } else {
                nextOrigin = CGPoint(
                    x: artworkScreenOrigin.x - nextSize.width / 2,
                    y: artworkScreenOrigin.y - nextSize.height / 2
                )
            }
        }

        // Clamp inside the visibleFrame so we never end up off-screen.
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            nextOrigin.x = min(max(visible.minX, nextOrigin.x),
                               visible.maxX - nextSize.width)
            nextOrigin.y = min(max(visible.minY, nextOrigin.y),
                               visible.maxY - nextSize.height)
        }

        suppressMoveCallback = true
        window.setFrame(NSRect(origin: nextOrigin, size: nextSize),
                        display: true,
                        animate: true)
        suppressMoveCallback = false
        windowIsAmbient = targetAmbient
    }

    private func resizeOverlayWindow(to size: CGSize) {
        guard let window = overlayWindow else { return }
        let current = window.frame
        var newOrigin = NSPoint(
            x: current.midX - size.width / 2,
            y: current.midY - size.height / 2
        )
        let proposedFrame = NSRect(origin: newOrigin, size: size)
        // Clamp inside the screen's visibleFrame so the new layout never lands
        // partially off-screen. Plan §6 Fase 6 / risk table.
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            newOrigin.x = min(max(visible.minX, newOrigin.x),
                              visible.maxX - size.width)
            newOrigin.y = min(max(visible.minY, newOrigin.y),
                              visible.maxY - size.height)
        }
        let clamped = NSRect(origin: newOrigin, size: proposedFrame.size)
        suppressMoveCallback = true
        window.setFrame(clamped, display: true, animate: true)
        suppressMoveCallback = false
    }

    /// Observe the appearance-related properties on `SettingsStore` directly
    /// (without going through the debounced UserDefaults notification) so
    /// dragging the opacity slider updates the window in real time.
    private func watchAppearanceSettings() {
        withObservationTracking {
            _ = settings.windowOpacity
            _ = settings.windowLevel
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyWindowSettings()
                self?.watchAppearanceSettings()
            }
        }
    }

    // MARK: - Poller helpers

    private func pausePoller(reason: String) {
        if let poller {
            Self.logger.notice("Pause poller (\(reason, privacy: .public))")
            Task { await poller.pause() }
        }
        if let socket = socketClient {
            Self.logger.notice("Stop socket (\(reason, privacy: .public))")
            Task { await socket.stop() }
        }
    }

    private func resumePollerIfPaused(reason: String) {
        if let poller {
            Self.logger.notice("Resume poller (\(reason, privacy: .public))")
            Task { await poller.resume() }
        }
        if let socket = socketClient {
            Self.logger.notice("Reconnect socket (\(reason, privacy: .public))")
            Task { await socket.start() }
        }
    }

    // MARK: - Window setup

    private func createOverlayWindow() {
        let windowSize = themes.current.layout.windowSize
        let contentRect = NSRect(
            x: 0, y: 0,
            width: windowSize.width, height: windowSize.height
        )
        let window = ClickableBorderlessWindow(
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
        // canJoinAllSpaces: visible in every Space.
        // fullScreenAuxiliary: stays above apps in fullscreen.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let hosting = ClickableHostingView(
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
        window.delegate = self
        observeWindowVisibility(window)
        overlayWindow = window
        applyWindowSettings()
        restoreSavedPosition(for: window)
    }

    // MARK: - Position persistence + edge snap

    private func restoreSavedPosition(for window: NSWindow) {
        guard let screen = window.screen,
              let displayID = Self.displayID(of: screen),
              let saved = settings.overlayPosition(forDisplay: displayID) else {
            return
        }
        // Clamp against the current visibleFrame in case the screen layout
        // changed since the saved position was written.
        let size = window.frame.size
        let visible = screen.visibleFrame
        let clampedX = min(max(visible.minX, saved.x), visible.maxX - size.width)
        let clampedY = min(max(visible.minY, saved.y), visible.maxY - size.height)
        suppressMoveCallback = true
        window.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        suppressMoveCallback = false
    }

    private static func displayID(of screen: NSScreen) -> UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    // MARK: - Snap corner detection

    private enum SnapCorner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// Returns the corner the window is currently pinned against, if any.
    /// Tolerates up to 6 pt drift so that a snap performed during a drag
    /// (which uses the 40 pt threshold but does not produce sub-pixel
    /// precision) still counts as snapped.
    private func currentSnapCorner(window: NSWindow) -> SnapCorner? {
        guard let screen = window.screen ?? NSScreen.main else { return nil }
        let visible = screen.visibleFrame
        let frame = window.frame
        let threshold: CGFloat = 6

        let onLeft = abs(frame.minX - visible.minX) <= threshold
        let onRight = abs(frame.maxX - visible.maxX) <= threshold
        let onBottom = abs(frame.minY - visible.minY) <= threshold
        let onTop = abs(frame.maxY - visible.maxY) <= threshold

        switch (onTop, onBottom, onLeft, onRight) {
        case (true, _, true, _):   return .topLeft
        case (true, _, _, true):   return .topRight
        case (_, true, true, _):   return .bottomLeft
        case (_, true, _, true):   return .bottomRight
        default:                   return nil
        }
    }

    private func origin(for corner: SnapCorner, size: CGSize, on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        switch corner {
        case .topLeft:
            return CGPoint(x: visible.minX, y: visible.maxY - size.height)
        case .topRight:
            return CGPoint(x: visible.maxX - size.width, y: visible.maxY - size.height)
        case .bottomLeft:
            return CGPoint(x: visible.minX, y: visible.minY)
        case .bottomRight:
            return CGPoint(x: visible.maxX - size.width, y: visible.minY)
        }
    }

    /// Snap to corners and edges within 40pt of the current screen's
    /// `visibleFrame`. Called from `windowDidMove`; the resulting
    /// `setFrameOrigin` does not retrigger `windowDidMove` so there is no
    /// loop.
    private func snapToEdgesIfClose(_ window: NSWindow) {
        guard let screen = window.screen else { return }
        let visible = screen.visibleFrame
        let threshold: CGFloat = 40
        var origin = window.frame.origin
        let size = window.frame.size

        if abs(origin.x - visible.minX) < threshold {
            origin.x = visible.minX
        } else if abs(visible.maxX - (origin.x + size.width)) < threshold {
            origin.x = visible.maxX - size.width
        }

        if abs(origin.y - visible.minY) < threshold {
            origin.y = visible.minY
        } else if abs(visible.maxY - (origin.y + size.height)) < threshold {
            origin.y = visible.maxY - size.height
        }

        if origin != window.frame.origin {
            suppressMoveCallback = true
            window.setFrameOrigin(origin)
            suppressMoveCallback = false
        }
    }
}

/// Borderless NSWindow that overrides `canBecomeKey` so SwiftUI buttons
/// still receive mouse events after the user swipes to another Space and
/// back. Without this override, macOS sometimes leaves the borderless
/// window's hit-testing in a state where clicks no longer register until
/// the window is focused again — which never happens for a `.floating`
/// window that can't become key.
///
/// `sendEvent` intercepts every mouse-down before it reaches any subview,
/// so clicking on static text or any non-interactive area restores focus
/// just as reliably as clicking on the artwork or the progress bar.
final class ClickableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            NSApp.activate(ignoringOtherApps: true)
            makeKey()
        }
        super.sendEvent(event)
    }
}

/// NSHostingView subclass that prevents click-through in the transparent
/// gaps between overlay UI elements (track info, progress bar, controls).
///
/// For an NSWindow with `isOpaque = false`, AppKit passes mouse events to
/// the window below whenever the content view's `hitTest` returns nil —
/// which NSHostingView does for any SwiftUI area that has no interactive
/// content. This subclass intercepts that nil return and falls back to
/// `self`, so the overlay catches every click within its bounds. Interactive
/// SwiftUI content (buttons, gestures) is unaffected because NSHostingView's
/// own hit-test path returns a non-nil view for those areas and our fallback
/// is never reached. `mouseDownCanMoveWindow` stays true (NSView default),
/// so dragging the overlay by its gaps still repositions the window.
final class ClickableHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? (bounds.contains(point) ? self : nil)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard !suppressMoveCallback,
              let window = notification.object as? NSWindow,
              window == overlayWindow else { return }
        snapToEdgesIfClose(window)
        if let screen = window.screen,
           let displayID = Self.displayID(of: screen) {
            settings.setOverlayPosition(window.frame.origin, forDisplay: displayID)
        }
    }
}
