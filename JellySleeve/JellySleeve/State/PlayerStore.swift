import Foundation
import Observation
import os

/// Single source of truth for the overlay UI. Lives on the main actor; the
/// `PlaybackPoller` actor pushes updates here via `apply(...)` after running
/// the active-session heuristic on raw `[Session]` from `JellyfinClient`.
@MainActor
@Observable
final class PlayerStore {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellysleeve",
        category: "state"
    )

    var connectionState: ConnectionState = .idle
    var currentTrack: TrackSnapshot? = nil
    var isPaused: Bool = false

    /// Manual override for the active-session heuristic (plan §4 point 2).
    /// Persisted across launches so a multi-device user keeps their pick.
    var selectedSessionId: String? {
        didSet {
            if selectedSessionId == nil {
                UserDefaults.standard.removeObject(forKey: Self.selectedSessionKey)
            } else {
                UserDefaults.standard.set(selectedSessionId, forKey: Self.selectedSessionKey)
            }
        }
    }

    /// All sessions belonging to the configured user, with or without a
    /// `NowPlayingItem`. The UI uses this for the device picker.
    var availableSessions: [SessionSummary] = []

    /// True while a playback command is in flight; consumed by `ControlsView`
    /// in Fase 5 to disable the buttons for a brief cooldown.
    var isCommandInFlight: Bool = false

    private static let selectedSessionKey = "playerStore.selectedSessionId"

    init() {
        self.selectedSessionId = UserDefaults.standard.string(forKey: Self.selectedSessionKey)
    }

    // MARK: Update entry points used by `PlaybackPoller`

    /// Apply a fresh poll result. `track == nil` means no active playback for
    /// this user; `connectionState` already reflects the connection lifecycle.
    func apply(
        connectionState: ConnectionState,
        track: TrackSnapshot?,
        isPaused: Bool,
        sessions: [SessionSummary]
    ) {
        self.connectionState = connectionState
        self.currentTrack = track
        self.isPaused = isPaused
        self.availableSessions = sessions

        // If the user picked a session that no longer exists, drop the manual
        // override so the heuristic gets a clean slate next tick.
        if let pick = selectedSessionId,
           !sessions.contains(where: { $0.id == pick }) {
            Self.logger.notice("Dropping stale selectedSessionId \(pick, privacy: .public).")
            selectedSessionId = nil
        }
    }

    /// Convenience for transient lifecycle states (connecting, errors) that
    /// do not carry a snapshot.
    func updateConnection(_ state: ConnectionState) {
        connectionState = state
        if case .error = state {
            currentTrack = nil
            isPaused = false
        }
    }
}
