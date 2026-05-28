import AppKit
import SwiftUI

/// Owns the borderless floating overlay `NSWindow` and ties its lifecycle to
/// system events.
///
/// Phase 1 only handles window creation and the menu-bar "Open Overlay" action.
/// Phase 4 adds:
///  - `NSWorkspace.willSleepNotification` / `didWakeNotification` observers to
///    pause/resume `PlaybackPoller` (plan §5.3).
///  - Window visibility observers to pause polling when the overlay is hidden
///    (plan §5.4).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        createOverlayWindow()
    }

    /// Keep the process alive when the overlay window is closed; the user
    /// reopens it from the menu-bar item.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Bring the overlay back to the front, recreating it if it was released.
    func showOverlay() {
        if overlayWindow == nil {
            createOverlayWindow()
            return
        }
        overlayWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createOverlayWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 300, height: 380)
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
        // Always-visible across spaces; .fullScreenAuxiliary keeps it above
        // apps in fullscreen mode (plan Fase 1 criterion 3).
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: OverlayView())
        hosting.frame = contentRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting

        window.center()
        window.makeKeyAndOrderFront(nil)
        overlayWindow = window
    }
}
