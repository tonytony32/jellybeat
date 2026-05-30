import AppKit
import SwiftUI

/// Owns the borderless overlay window and everything about its placement:
/// creation, the level/opacity application, the theme- and player-driven
/// resize (full ⇄ ambient), edge/corner snapping, and per-display position
/// persistence.
///
/// Split out of `AppDelegate` so the window-geometry logic is isolated from
/// the playback-transport state machine. Window-visibility events that should
/// pause or resume the feed are surfaced through `onPauseRequested` /
/// `onResumeRequested`, which the owner wires to the connection coordinator.
@MainActor
final class OverlayWindowController: NSObject {
    private let settings: SettingsStore
    private let player: PlayerStore
    private let themes: ThemeRegistry
    private let artworkProvider: ArtworkCacheProvider

    /// Invoked when a window event implies the feed should pause (miniaturise,
    /// close). The string is a human-readable reason for logging.
    var onPauseRequested: ((String) -> Void)?
    /// Invoked when a window event implies the feed should resume (overlay
    /// shown, deminiaturise).
    var onResumeRequested: ((String) -> Void)?

    private var overlayWindow: NSWindow?
    private var windowVisibilityObservers: [NSObjectProtocol] = []
    /// True while we are programmatically moving the window (theme resize,
    /// snap apply, restore on launch). Used to suppress feedback into
    /// `windowDidMove` so we don't try to snap something we just snapped.
    private var suppressMoveCallback: Bool = false
    /// Tracks whether the window currently shows the ambient (artwork-sized)
    /// or the full-layout footprint. Lets us compute the correct screen
    /// origin when transitioning between the two modes.
    private var windowIsAmbient: Bool = false

    init(
        settings: SettingsStore,
        player: PlayerStore,
        themes: ThemeRegistry,
        artworkProvider: ArtworkCacheProvider
    ) {
        self.settings = settings
        self.player = player
        self.themes = themes
        self.artworkProvider = artworkProvider
        super.init()
    }

    // MARK: - Lifecycle

    /// Start the Observation-framework watchers that bind window geometry and
    /// chrome to theme / player / appearance changes. Call once after
    /// `createWindow()`.
    func startObserving() {
        watchThemeForWindowResize()
        watchAppearanceSettings()
        watchPlayerForAmbientMode()
    }

    func shutdown() {
        for observer in windowVisibilityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowVisibilityObservers.removeAll()
    }

    // MARK: - Public entry points

    func showOverlay() {
        if overlayWindow == nil {
            createWindow()
            return
        }
        overlayWindow?.makeKeyAndOrderFront(nil)
        onResumeRequested?("overlay shown")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Close anything macOS Resume restored except the overlay AND the
    /// MenuBarExtra's internal NSStatusBarWindow (`StatusBar`/`Popover`
    /// class names) so we don't lose the menu-bar item.
    func closeRestoredScenesExceptOverlay() {
        for window in NSApp.windows where window !== overlayWindow {
            let cls = String(describing: type(of: window))
            if cls.contains("StatusBar") || cls.contains("Popover") || cls.contains("MenuBar") {
                continue
            }
            window.close()
        }
    }

    // MARK: - Window setup

    func createWindow() {
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
        hosting.onScrollVolume = { [weak player] delta in
            player?.nudgeVolume(by: delta)
        }
        window.contentView = hosting

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.delegate = self
        observeWindowVisibility(window)
        overlayWindow = window
        applyWindowSettings()
        restoreSavedPosition(for: window)
    }

    private func observeWindowVisibility(_ window: NSWindow) {
        let center = NotificationCenter.default
        let hide = center.addObserver(
            forName: NSWindow.didMiniaturizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onPauseRequested?("window miniaturised")
            }
        }
        let show = center.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onResumeRequested?("window deminiaturised")
            }
        }
        let willClose = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onPauseRequested?("window closed")
            }
        }
        windowVisibilityObservers.append(contentsOf: [hide, show, willClose])
    }

    // MARK: - Window level / opacity

    /// Apply user-configurable window placement (level, opacity). Called both
    /// after window creation and on every appearance-settings change.
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

    // MARK: - Theme / ambient resize

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

// MARK: - NSWindowDelegate

extension OverlayWindowController: NSWindowDelegate {
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

// MARK: - Borderless window + hosting view

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
    /// Invoked with a signed volume delta (percentage points) when the user
    /// scrolls over the overlay. Wired up by `OverlayWindowController` to
    /// `PlayerStore.nudgeVolume`. Scroll-up is positive (louder).
    var onScrollVolume: (@MainActor (Int) -> Void)?

    /// Leftover precise-scroll distance (trackpad) not yet worth a whole step.
    private var scrollAccumulator: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? (bounds.contains(point) ? self : nil)
    }

    /// Map vertical scrolling over the overlay to volume changes. Scroll events
    /// only reach this view while the cursor is over the window, so this is
    /// implicitly "scroll while hovering". Mouse-wheel notches move in fixed
    /// steps; precise (trackpad) deltas accumulate so a longer swipe moves more.
    /// Direction is inverted: scroll *down* raises the volume, *up* lowers it.
    override func scrollWheel(with event: NSEvent) {
        guard let onScrollVolume else {
            super.scrollWheel(with: event)
            return
        }
        let deltaY = event.scrollingDeltaY
        guard deltaY != 0 else { return }

        let amount: Int
        if event.hasPreciseScrollingDeltas {
            // Reset leftover distance at the start of a fresh gesture so an old
            // partial step doesn't bleed into the new one.
            if event.phase.contains(.began) { scrollAccumulator = 0 }
            scrollAccumulator += deltaY
            let pointsPerStep: CGFloat = 5
            let steps = (scrollAccumulator / pointsPerStep).rounded(.towardZero)
            guard steps != 0 else { return }
            scrollAccumulator -= steps * pointsPerStep
            amount = -Int(steps)
        } else {
            // Legacy mouse wheel: each event is one discrete notch.
            amount = deltaY > 0 ? -3 : 3
        }
        onScrollVolume(amount)
    }
}
