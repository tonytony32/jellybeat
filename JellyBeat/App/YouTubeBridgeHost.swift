import AppKit
import os

/// Owns the lifecycle of the **YTBridge** host app (`com.trypwood.ytbridge`), which hosts the
/// loopback socket for the built-in YouTube (Safari) source at `127.0.0.1:8976`.
///
/// The bridge only matters while JellyBeat is running, so JellyBeat — the sole consumer —
/// drives its lifecycle: launch it on our launch (when the source is enabled), terminate it on
/// our quit. That way the bridge runs *exactly* while JellyBeat does — no login item, no
/// resident background process. (The host also watches us and self-quits if we vanish, so a
/// JellyBeat crash never orphans it.)
///
/// All calls are best-effort: if YTBridge isn't installed, the YouTube source simply stays
/// unreachable (`LoopbackSourceClient` already treats connection-refused as idle).
@MainActor
enum YouTubeBridgeHost {
    /// Bundle id of the YTBridge container app (the yt-safari-bridge repo).
    static let bundleID = "com.trypwood.ytbridge"

    private static let logger = Logger(
        subsystem: "software.trypwood.jellybeat",
        category: "state"
    )

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Launch the host if it isn't already running. No-op (logged) when YTBridge isn't
    /// installed. Launched in the background — YTBridge is an LSUIElement agent, so this
    /// never shows a window or steals focus.
    static func start() {
        guard !isRunning else { return }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            logger.notice("YTBridge not installed — YouTube (Safari) source unavailable")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = false
        logger.notice("Launching YTBridge host")
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error {
                Self.logger.error("Failed to launch YTBridge: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Terminate any running host instances. The host also self-quits when JellyBeat exits, so
    /// this is just the prompt path on a clean quit or a toggle-off.
    static func stop() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            logger.notice("Terminating YTBridge host")
            app.terminate()
        }
    }
}
