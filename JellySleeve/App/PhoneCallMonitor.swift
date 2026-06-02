@preconcurrency import AppKit
import os

/// Pauses Jellyfin playback automatically when a call starts on this Mac.
///
/// macOS does not expose a public API for detecting incoming calls directly.
/// This monitor uses two complementary signals:
///
/// 1. **NSDistributedNotificationCenter** — observes telephony notifications
///    posted by the system's call services daemon (`callservicesd`), which
///    handles both iPhone cellular calls relayed via Continuity and FaceTime
///    audio/video calls.
///
/// 2. **NSWorkspace app-activation** — FaceTime.app is the macOS host for
///    all call UI. Becoming frontmost is a reliable "call in progress" signal
///    (the user answered or placed a call).
///
/// Only pauses if playback is already active; does not auto-resume when the
/// call ends (the user controls resumption).
@MainActor
final class PhoneCallMonitor {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellysleeve",
        category: "state"
    )

    private let player: PlayerStore
    private var observers: [NSObjectProtocol] = []

    // Bundle IDs of apps whose activation indicates an active call.
    private static let callingAppBundleIDs: Set<String> = [
        "com.apple.FaceTime",   // FaceTime + iPhone cellular relay (Continuity)
    ]

    // Distributed notification names posted by the system call-services daemon.
    // These are undocumented but stable across macOS releases.
    private static let callNotificationNames: [String] = [
        "com.apple.callkit.callservices.callStarted",
        "com.apple.telephonyutilities.phoneCall.started",
        "com.apple.TelephonyUtilities.phoneCallActive",
    ]

    init(player: PlayerStore) {
        self.player = player
        registerObservers()
    }

    // MARK: - Private

    private func registerObservers() {
        // 1. System distributed notifications from the call-services daemon.
        for name in Self.callNotificationNames {
            let o = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleCallStarted(source: name)
                }
            }
            observers.append(o)
        }

        // 2. FaceTime.app becoming frontmost (call answered / placed).
        let workspace = NSWorkspace.shared.notificationCenter
        let o = workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                let bundleID = app.bundleIdentifier,
                Self.callingAppBundleIDs.contains(bundleID)
            else { return }
            Task { @MainActor [weak self] in
                self?.handleCallStarted(source: bundleID)
            }
        }
        observers.append(o)
    }

    private func handleCallStarted(source: String) {
        guard !player.isPaused, player.currentTrack != nil else { return }
        Self.logger.notice("Call signal received (\(source, privacy: .public)) — pausing playback.")
        Task { @MainActor [weak self] in
            await self?.player.playPause()
        }
    }
}
