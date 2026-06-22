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
    /// True between the start of a user drag and ~200 ms after it settles.
    /// While set, `applyWindowSizeForCurrentState` leaves the window alone so a
    /// background poll can't reposition (and fight) the window mid-drag.
    private var isUserDragging: Bool = false
    /// Fires once window movement stops, to snap + persist. Debounced so we
    /// never call `setFrameOrigin` mid-drag (which jitters), and so the snap
    /// runs cleanly on release.
    private var dragSettleTask: Task<Void, Never>?
    /// Last ambient state pushed through `applyWindowSizeForCurrentState`, so
    /// the per-poll `currentTrack` churn doesn't re-run the geometry pass when
    /// only the playback position changed.
    private var lastAppliedAmbient: Bool?
    /// The play-queue side panel (a borderless child window beside the overlay)
    /// and its click-outside dismissal monitors. Shown while
    /// `player.isQueuePopoverOpen` is true.
    private var queuePanel: NSPanel?
    private var queueDismissMonitors: [Any] = []
    /// Polls the cursor against the Minim strip to drive its hover-expand.
    /// Active only while the Minim theme is showing.
    private var minimHoverTimer: Timer?
    /// Beak direction + position for the panel, so its tail points back at the
    /// overlay. Updated each time the panel is positioned.
    private let queueChrome = QueuePanelChrome()
    /// Published snap alignment — the corner or edge the window is currently
    /// pinned to, or `.center` when free-floating. Read by `NothingPlayingView`
    /// to align the idle Jellyfin logo toward the same anchor.
    let snapState = WindowSnapState()

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
        watchMinimHover()
        watchQueuePanel()
        watchQueuePanelSize()
    }

    func shutdown() {
        for observer in windowVisibilityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowVisibilityObservers.removeAll()
        removeMinimHoverMonitor()
        dismissQueuePanel()
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
        // stationary: pinned like a desktop widget — Mission Control and
        // "Show Desktop" leave it in place instead of sweeping it off-screen,
        // in every window level (always-on-top / normal / behind).
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false

        let hosting = ClickableHostingView(
            rootView: OverlayView()
                .environment(settings)
                .environment(player)
                .environment(themes)
                .environment(artworkProvider)
                .environment(snapState)
                .environment(queueChrome)
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
        refreshSnapState()
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
            // Space change with no other windows on top) JellyBeat is
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
            // The Minim strip expands on hover; tear the hover monitor up/down
            // with the theme so it only runs while Minim is showing, and clear a
            // stale hover flag when leaving so we don't re-open expanded.
            if self.themes.current.id == "minim" {
                self.installMinimHoverMonitor()
            } else {
                self.removeMinimHoverMonitor()
                self.player.minimHovered = false
            }
            self.applyWindowSizeForCurrentState()
            self.scheduleThemeReevaluation()
        }
        watcher()
    }

    private func watchMinimHover() {
        withObservationTracking {
            _ = player.minimHovered
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyWindowSizeForCurrentState()
                self?.watchMinimHover()
            }
        }
    }

    /// Hover detection for the Minim strip. Both an `NSTrackingArea` and
    /// `.mouseMoved` event monitors proved unreliable: the tracking area's
    /// mouse-exit could fail to fire across the hover-resize, and the event
    /// monitors stop firing for moves over the desktop once JellyBeat itself is
    /// the active app (a local monitor needs the event delivered to us; a global
    /// one only sees other apps' events). Both left the strip stuck open. A
    /// small timer that polls the cursor against the strip's footprint is immune
    /// to all of that — it doesn't depend on event delivery or active-app state.
    private func installMinimHoverMonitor() {
        guard minimHoverTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMinimHoverFromMouse() }
        }
        // .common so it keeps firing during window resize / event tracking.
        RunLoop.main.add(timer, forMode: .common)
        minimHoverTimer = timer
        updateMinimHoverFromMouse()
    }

    private func removeMinimHoverMonitor() {
        minimHoverTimer?.invalidate()
        minimHoverTimer = nil
    }

    /// Set `minimHovered` from the live cursor position. The hover zone is the
    /// strip's footprint *plus the space it unfolds into* — a rectangle anchored
    /// at the (bottom-pinned) bottom edge, `expandedHeight` tall. Because that
    /// rectangle is identical whether the strip is collapsed or expanded, moving
    /// between the strip and the revealed info never thrashes the state, and
    /// there's no race against the in-flight resize.
    private func updateMinimHoverFromMouse() {
        guard let window = overlayWindow, themes.current.id == "minim" else { return }
        // Use the live window rect as the hover zone, which gives natural
        // hysteresis and can't oscillate:
        //  - Collapsed, the rect is just the strip, so it only expands when the
        //    cursor is actually over the strip — never over the empty space the
        //    info would unfold into (the old expanded-height zone did, which made
        //    it flip open/closed unpredictably).
        //  - Expanded, the rect is the whole card, so it stays open until the
        //    cursor leaves all of it.
        // Expand-zone ⊂ stay-zone, so there's no boundary where it flickers.
        // Forced off while dragging so the strip stays collapsed during a move.
        let inside = !isUserDragging && window.frame.contains(NSEvent.mouseLocation)
        if player.minimHovered != inside {
            player.minimHovered = inside
        }
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
    ///
    /// We track `currentTrack` (the observation framework can't observe the
    /// derived `isInAmbientMode` without reading its inputs), but only act when
    /// the ambient condition actually flips. The transport updates
    /// `currentTrack` on every poll because `TrackSnapshot.position` advances;
    /// without this gate the window would re-run its resize/snap pass ~every
    /// 2 s, which fights an in-progress drag and re-clamps the window. Window
    /// size depends only on ambient-vs-full, not on which track or how far in.
    private func watchPlayerForAmbientMode() {
        withObservationTracking {
            _ = player.connectionState
            _ = player.currentTrack
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ambient = self.isInAmbientMode
                if ambient != self.lastAppliedAmbient {
                    self.lastAppliedAmbient = ambient
                    self.applyWindowSizeForCurrentState()
                }
                self.watchPlayerForAmbientMode()
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
        // Never reposition while the user is dragging — a background poll firing
        // mid-drag would yank the window out from under the cursor (and fight
        // AppKit's own drag tracking).
        guard !isUserDragging else { return }

        // The window's own drop-shadow looks like a frame around the cover
        // when the theme has no glass background (Aero). Suppress it there
        // and let the artwork's own shadow do the work.
        window.hasShadow = theme.behavior.hasGlassBackground

        // Decide next size.
        let nextSize: CGSize
        if targetAmbient, let art = theme.artworkFrame {
            nextSize = art.size
        } else if theme.id == "minim" && player.minimHovered {
            nextSize = CGSize(width: theme.layout.windowSize.width, height: MinimTheme.expandedHeight)
        } else {
            nextSize = theme.layout.windowSize
        }

        // Decide next origin.
        var nextOrigin: CGPoint
        let snap = currentSnapEdges(window: window)
        if theme.id == "minim" && !targetAmbient {
            // The strip's rect must never move on hover — only the space it
            // unfolds into is added. Recover the strip's resting bottom edge from
            // the current frame using the active grow direction (its anchored
            // edge is stable across the collapse/expand cycle).
            let stripBottom = player.minimGrowsUpward
                ? window.frame.minY
                : window.frame.maxY - MinimTheme.barHeight
            // Unfold upward by default; unfold downward only when the expanded
            // height wouldn't fit above the strip — i.e. it's parked near the top
            // (against the menu bar). Decided from the resting position, so it
            // only flips when the strip is actually moved, never mid-hover.
            if let screen = window.screen ?? NSScreen.main {
                let area = snapFrame(for: screen)
                player.minimGrowsUpward =
                    stripBottom + MinimTheme.expandedHeight <= area.maxY
            }
            let x = window.frame.minX
            if player.minimHovered && player.minimGrowsUpward {
                nextOrigin = CGPoint(x: x, y: stripBottom)                  // grow up: bottom pinned
            } else if player.minimHovered {
                // grow down: top pinned at the strip's top edge
                nextOrigin = CGPoint(x: x, y: stripBottom + MinimTheme.barHeight - MinimTheme.expandedHeight)
            } else {
                nextOrigin = CGPoint(x: x, y: stripBottom)                  // collapsed: the strip itself
            }
        } else if snap.isSnapped,
           let screen = window.screen ?? NSScreen.main {
            // Preserve the snapped edge(s) across resizes — including plain
            // edge snaps (e.g. bottom-centred), not just the four corners.
            nextOrigin = origin(for: snap, oldFrame: window.frame, size: nextSize, on: screen)
        } else {
            // Not snapped: keep the window centred on the same screen point so
            // a resize (full ⇄ ambient, theme change) shrinks or grows in
            // place instead of flinging the window up toward the artwork's old
            // position.
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            nextOrigin = CGPoint(
                x: center.x - nextSize.width / 2,
                y: center.y - nextSize.height / 2
            )
        }

        // Clamp inside the snap frame (physical screen, minus the menu bar) so
        // we never end up off-screen — but without lifting the window above the
        // Dock.
        if let screen = window.screen ?? NSScreen.main {
            let area = snapFrame(for: screen)
            nextOrigin.x = min(max(area.minX, nextOrigin.x),
                               area.maxX - nextSize.width)
            if theme.id == "minim" && !targetAmbient {
                // The strip's bottom edge is sacred: it must stay exactly where
                // the user parked it across the hover-expand. The generic upper
                // clamp (`area.maxY - height`) would drag the bottom edge *down*
                // whenever the expanded height doesn't fit above a strip resting
                // near the top — which both jumps the strip on hover and makes
                // it drift down a little each cycle. So clamp only the lower
                // bound; if the unfolded info overruns the top, it tucks under
                // the menu bar (rare — the strip lives near the bottom) rather
                // than moving the strip.
                nextOrigin.y = max(area.minY, nextOrigin.y)
            } else {
                nextOrigin.y = min(max(area.minY, nextOrigin.y),
                                   area.maxY - nextSize.height)
            }
        }

        // Skip the move entirely if nothing changed. `applyWindowSizeForCurrentState`
        // runs on every poll (the watched `currentTrack` changes as playback
        // progresses), so without this guard we'd call `setFrame` ~every 2 s
        // for no reason.
        let nextFrame = NSRect(origin: nextOrigin, size: nextSize)
        guard nextFrame != window.frame else {
            windowIsAmbient = targetAmbient
            return
        }
        suppressMoveCallback = true
        if theme.id == "minim" {
            // Animate the window with the exact same duration/curve as the
            // Minim content's SwiftUI animation (0.16s ease-out) so the glass
            // and the unfolding info move in lockstep. AppKit's default
            // `animate: true` uses its own timing, and that mismatch was the
            // small tug on unfold/fold.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(nextFrame, display: true)
            }
        } else {
            window.setFrame(nextFrame, display: true, animate: true)
        }
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
        // Clamp against the snap frame in case the screen layout changed since
        // the saved position was written.
        let size = window.frame.size
        let area = snapFrame(for: screen)
        let clampedX = min(max(area.minX, saved.x), area.maxX - size.width)
        let clampedY = min(max(area.minY, saved.y), area.maxY - size.height)
        suppressMoveCallback = true
        window.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        suppressMoveCallback = false
    }

    private func refreshSnapState() {
        guard let window = overlayWindow else { return }
        let e = currentSnapEdges(window: window)
        let alignment: Alignment
        switch (e.left, e.right, e.top, e.bottom) {
        case (true, _, true, _): alignment = .topLeading
        case (_, true, true, _): alignment = .topTrailing
        case (true, _, _, true): alignment = .bottomLeading
        case (_, true, _, true): alignment = .bottomTrailing
        case (true, _, _, _): alignment = .leading
        case (_, true, _, _): alignment = .trailing
        case (_, _, true, _): alignment = .top
        case (_, _, _, true): alignment = .bottom
        default: alignment = .center
        }
        snapState.alignment = alignment
    }

    private static func displayID(of screen: NSScreen) -> UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    // MARK: - Snap edge detection

    /// The region the overlay snaps and clamps to: the *physical* screen edges
    /// (`screen.frame`) so the window can reach the true bottom/left/right
    /// corners regardless of the Dock — i.e. it behaves the same whether the
    /// Dock is hidden or always-visible. The only inset is the menu bar at the
    /// top (`visibleFrame.maxY`), which a window can't sit under anyway.
    ///
    /// Snapping/clamping to `visibleFrame` instead is what made the window jump
    /// *up* above the Dock when dropped near the bottom — the user wants it to
    /// reach the screen edge, like it does with the Dock hidden.
    private func snapFrame(for screen: NSScreen) -> NSRect {
        let full = screen.frame
        let topInset = full.maxY - screen.visibleFrame.maxY
        return NSRect(x: full.minX, y: full.minY,
                      width: full.width, height: full.height - topInset)
    }

    /// Which edges of the snap frame the window is currently pinned against.
    /// Captures plain edge snaps (e.g. the window resting on the bottom edge
    /// while horizontally centred), not just the four corners — `snapToEdgesIfClose`
    /// snaps each axis independently, so an edge-only snap is a real state we
    /// have to preserve across resizes.
    private struct SnapEdges {
        var left = false
        var right = false
        var bottom = false
        var top = false
        var isSnapped: Bool { left || right || bottom || top }
    }

    /// Returns the edges the window is currently pinned against, if any.
    /// Tolerates up to 6 pt drift so that a snap performed during a drag
    /// (which uses the 40 pt threshold but does not produce sub-pixel
    /// precision) still counts as snapped.
    private func currentSnapEdges(window: NSWindow) -> SnapEdges {
        guard let screen = window.screen ?? NSScreen.main else { return SnapEdges() }
        let area = snapFrame(for: screen)
        let frame = window.frame
        let threshold: CGFloat = 6

        return SnapEdges(
            left: abs(frame.minX - area.minX) <= threshold,
            right: abs(frame.maxX - area.maxX) <= threshold,
            bottom: abs(frame.minY - area.minY) <= threshold,
            top: abs(frame.maxY - area.maxY) <= threshold
        )
    }

    /// Origin that keeps every snapped edge pinned after a resize. Axes with
    /// no snap preserve the previous window centre on that axis, so an
    /// edge-snapped window stays glued to its edge while staying put along the
    /// free axis (e.g. bottom-centred stays bottom-centred).
    private func origin(for snap: SnapEdges, oldFrame: NSRect, size: CGSize, on screen: NSScreen) -> CGPoint {
        let area = snapFrame(for: screen)
        let x: CGFloat
        if snap.left {
            x = area.minX
        } else if snap.right {
            x = area.maxX - size.width
        } else {
            x = oldFrame.midX - size.width / 2
        }
        let y: CGFloat
        if snap.bottom {
            y = area.minY
        } else if snap.top {
            y = area.maxY - size.height
        } else {
            y = oldFrame.midY - size.height / 2
        }
        return CGPoint(x: x, y: y)
    }

    /// Snap to corners and edges within 40pt of the current screen's
    /// `visibleFrame`. Called from `windowDidMove`; the resulting
    /// `setFrameOrigin` does not retrigger `windowDidMove` so there is no
    /// loop.
    private func snapToEdgesIfClose(_ window: NSWindow) {
        guard let screen = window.screen else { return }
        let area = snapFrame(for: screen)
        let threshold: CGFloat = 40
        var origin = window.frame.origin
        let size = window.frame.size

        // Snap when the window is within `threshold` of a screen edge *or past
        // it* (dragged off-screen). One-sided so a window shoved past an edge is
        // pulled flush to that edge. `area` uses the physical screen frame, so
        // the bottom edge is the true screen bottom (y = 0) — not above the
        // Dock — which is what stops the "jumps up above the Dock" behaviour.
        if origin.x < area.minX + threshold {
            origin.x = area.minX
        } else if origin.x + size.width > area.maxX - threshold {
            origin.x = area.maxX - size.width
        }

        if origin.y < area.minY + threshold {
            origin.y = area.minY
        } else if origin.y + size.height > area.maxY - threshold {
            origin.y = area.maxY - size.height
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
        // Only react to genuine user drags (primary mouse button held). AppKit
        // also fires windowDidMove for moves *it* makes — notably nudging the
        // window up so a popover (the queue list) fits on screen above the
        // Dock. Treating those as a drag would snap + persist a position the
        // user never chose, so the window would creep up when opening the list.
        guard NSEvent.pressedMouseButtons & 0x1 != 0 else { return }
        // A user drag is in progress. Block poll-driven repositioning, and
        // debounce the snap so it runs once movement stops (i.e. on release),
        // never mid-drag. Close the queue panel so it doesn't trail the drag.
        player.isQueuePopoverOpen = false
        let startingDrag = !isUserDragging
        isUserDragging = true
        // At the start of a Minim drag, collapse to the compact strip so the
        // user repositions the strip itself — and can snap it flush against the
        // menu bar — rather than the tall expanded card. Keep the strip's edge
        // pinned (so it doesn't jump) and skip the synchronous redisplay so this
        // doesn't fight AppKit's in-progress drag.
        if startingDrag, themes.current.id == "minim", player.minimHovered {
            let f = window.frame
            let stripBottom = player.minimGrowsUpward ? f.minY : f.maxY - MinimTheme.barHeight
            player.minimHovered = false
            suppressMoveCallback = true
            window.setFrame(
                NSRect(x: f.minX, y: stripBottom, width: f.width, height: MinimTheme.barHeight),
                display: false
            )
            suppressMoveCallback = false
        }
        dragSettleTask?.cancel()
        dragSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self else { return }
            self.isUserDragging = false
            self.handleDragEnded()
        }
    }

    /// Called once window movement settles. Snaps to nearby/overrun edges and
    /// persists the resulting position.
    func handleDragEnded() {
        guard let window = overlayWindow else { return }
        snapToEdgesIfClose(window)
        refreshSnapState()
        // Re-decide the Minim unfold direction from where the strip came to rest:
        // downward when it's parked near the top (no room above for the info).
        if themes.current.id == "minim", let screen = window.screen {
            let area = snapFrame(for: screen)
            player.minimGrowsUpward =
                window.frame.minY + MinimTheme.expandedHeight <= area.maxY
        }
        if let screen = window.screen,
           let displayID = Self.displayID(of: screen) {
            settings.setOverlayPosition(window.frame.origin, forDisplay: displayID)
        }
    }
}

// MARK: - Queue side panel

extension OverlayWindowController {
    /// Bind the queue side panel to `player.isQueuePopoverOpen`. Presenting the
    /// queue as our own borderless child window — rather than a SwiftUI
    /// `.popover` — lets us place it beside the overlay so it never covers the
    /// now-playing frame and, crucially, never nudges the overlay off its spot
    /// (the popover did, to fit itself above the Dock).
    private func watchQueuePanel() {
        withObservationTracking {
            _ = player.isQueuePopoverOpen
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncQueuePanel()
                self?.watchQueuePanel()
            }
        }
    }

    private func syncQueuePanel() {
        if player.isQueuePopoverOpen {
            presentQueuePanel()
        } else {
            dismissQueuePanel()
        }
    }

    /// Re-fit and reposition the panel when its content height changes (the user
    /// switched tabs, the Instant Mix list arrived, the queue grew). The panel
    /// is a fixed-size AppKit window, so SwiftUI can't grow it from inside;
    /// `QueuePopover` bumps `queueChrome.contentRevision` and we react here.
    private func watchQueuePanelSize() {
        withObservationTracking {
            _ = queueChrome.contentRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refitQueuePanel()
                self?.watchQueuePanelSize()
            }
        }
    }

    private func refitQueuePanel() {
        guard player.isQueuePopoverOpen,
              let panel = queuePanel,
              let overlay = overlayWindow else { return }
        fitQueuePanelHeight(panel)
        positionQueuePanel(panel, relativeTo: overlay)
    }

    /// Size the panel to its current SwiftUI content, capped at 380 pt (the
    /// ScrollView handles overflow beyond that).
    private func fitQueuePanelHeight(_ panel: NSPanel) {
        guard let hosting = panel.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        let height = fit.height > 1 ? min(fit.height, 380) : 380
        panel.setContentSize(NSSize(width: 300 + QueuePanelBeak.width, height: height))
    }

    private func presentQueuePanel() {
        guard let overlay = overlayWindow else { return }

        let panel: NSPanel
        if let existing = queuePanel {
            panel = existing
        } else {
            panel = QueuePanelWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300 + QueuePanelBeak.width, height: 380),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            // No window shadow: on a borderless, transparent, non-rectangular
            // window AppKit derives the shadow from the content's alpha and
            // renders it as a hard dark contour hugging the card *and the beak* —
            // the "ugly black frame line". The panel's own bright glass rim
            // (drawn in `QueuePopover`) defines its edge instead, exactly like
            // the Classic overlay, which also runs shadowless.
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.contentView = NSHostingView(
                rootView: QueuePanelView()
                    .environment(player)
                    .environment(artworkProvider)
                    .environment(queueChrome)
            )
            queuePanel = panel
        }

        // Match the overlay's window level so it floats with it, and size to the
        // current content (short queue → short panel) up to the 380 pt cap.
        panel.level = overlay.level
        fitQueuePanelHeight(panel)
        positionQueuePanel(panel, relativeTo: overlay)
        if panel.parent == nil {
            overlay.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        installQueueDismissMonitors()
    }

    /// Place the panel just beyond the overlay — to its right by default,
    /// flipping to the left when there's no room — bottom-aligned with it, and
    /// aim the panel's beak back at the overlay's center so it reads as having
    /// sprung from it. Clamped to the physical screen (minus the menu bar) so it
    /// can sit over the Dock just like the overlay. Only the panel moves — the
    /// overlay is never touched.
    private func positionQueuePanel(_ panel: NSPanel, relativeTo overlay: NSWindow) {
        guard let screen = overlay.screen ?? NSScreen.main else { return }
        // Clamp to the physical screen (minus the menu bar), NOT the visible
        // frame — i.e. ignore the Dock, exactly like the overlay does. Clamping
        // to `visibleFrame` is what pushed the panel up by the Dock's height
        // when it was shown, so it behaved differently than with the Dock
        // hidden.
        let area = snapFrame(for: screen)
        let size = panel.frame.size
        let o = overlay.frame
        let tipGap = QueuePanelBeak.tipGap

        // Prefer the panel to the right of the overlay with the beak pointing
        // left back at it; flip to the left (beak pointing right) when there's
        // no room. Only the beak's tip reaches toward the overlay — the card
        // keeps its gap.
        var edge: QueuePanelBeakEdge = .leading
        var x = o.maxX + tipGap
        if x + size.width > area.maxX {
            edge = .trailing
            x = o.minX - tipGap - size.width
        }
        x = min(max(area.minX, x), area.maxX - size.width)

        // Bottom-align with the overlay so the panel stays anchored to it (it
        // may sit over the Dock, just as the overlay can); only the menu bar at
        // the top is kept clear.
        var y = o.minY
        y = min(max(area.minY, y), area.maxY - size.height)

        panel.setFrameOrigin(NSPoint(x: x, y: y))

        // Aim the beak at the queue button it sprang from — the button sits low
        // in the controls row, well below the overlay's center, so pointing at
        // the center left the beak floating above the button. `ControlsView`
        // publishes the button's center as points from the overlay's top; fall
        // back to the overlay center until that's been laid out. Expressed in
        // panel-local points (y grows downward) and kept clear of the corners.
        let halfBase = QueuePanelBeak.height / 2
        let minCenter = QueuePanelBeak.cornerRadius + halfBase + 4
        let maxCenter = max(minCenter, size.height - minCenter)
        let targetScreenY: CGFloat
        if let buttonFromTop = queueChrome.queueButtonCenterFromOverlayTop {
            targetScreenY = o.maxY - buttonFromTop
        } else {
            targetScreenY = o.midY
        }
        let centerFromTop = (y + size.height) - targetScreenY
        queueChrome.beakEdge = edge
        queueChrome.beakCenterFromTop = min(max(minCenter, centerFromTop), maxCenter)
    }

    private func dismissQueuePanel() {
        removeQueueDismissMonitors()
        guard let panel = queuePanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func installQueueDismissMonitors() {
        removeQueueDismissMonitors()
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in self?.dismissQueueIfClickOutside() }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.player.isQueuePopoverOpen = false }
        }
        queueDismissMonitors = [local, global].compactMap { $0 }
    }

    private func removeQueueDismissMonitors() {
        for monitor in queueDismissMonitors {
            NSEvent.removeMonitor(monitor)
        }
        queueDismissMonitors.removeAll()
    }

    /// Close the panel on a click that's neither inside it nor on the overlay.
    /// Clicks on the overlay are spared so the list button can toggle the panel
    /// (and dragging the overlay is handled separately).
    private func dismissQueueIfClickOutside() {
        guard let panel = queuePanel, let overlay = overlayWindow else { return }
        let point = NSEvent.mouseLocation
        if panel.frame.contains(point) || overlay.frame.contains(point) { return }
        player.isQueuePopoverOpen = false
    }
}

/// Nonactivating borderless panel for the queue list. Overrides `canBecomeKey`
/// so the SwiftUI row buttons receive clicks, while staying nonactivating so
/// showing it never activates the app or disturbs the overlay's position.
final class QueuePanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
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
            // Higher = slower: more scroll distance is needed per 1% of volume.
            let pointsPerStep: CGFloat = 12
            let steps = (scrollAccumulator / pointsPerStep).rounded(.towardZero)
            guard steps != 0 else { return }
            scrollAccumulator -= steps * pointsPerStep
            amount = -Int(steps)
        } else {
            // Legacy mouse wheel: each event is one discrete notch → 1%.
            amount = deltaY > 0 ? -1 : 1
        }
        onScrollVolume(amount)
    }
}

/// Publishes the screen corner or edge the overlay is currently snapped to.
/// `.center` means the window is free-floating (not against any edge).
/// Read by `NothingPlayingView` to anchor the idle Jellyfin logo toward the
/// same snap corner so the icon feels glued to the screen edge.
@MainActor
@Observable
final class WindowSnapState {
    var alignment: Alignment = .center
}
