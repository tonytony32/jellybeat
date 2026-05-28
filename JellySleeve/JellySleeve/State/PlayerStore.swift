import Foundation
import Observation
import os

/// Single source of truth for the overlay UI. Lives on the main actor; the
/// `PlaybackPoller` actor pushes updates here via `apply(...)` after running
/// the active-session heuristic on raw `[Session]` from `JellyfinClient`.
///
/// Also owns the playback-command vocabulary (`playPause`, `nextTrack`,
/// `previousTrack`) so views call into one place. Commands respect a 300 ms
/// cooldown (plan §5.5) and surface failures through a transient toast.
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

    /// True while a playback command is in flight or its cooldown is active.
    /// `ControlsView` reads this to disable buttons.
    var isCommandInFlight: Bool = false

    /// Short user-facing message rendered as an overlay toast for ~2 s.
    var transientMessage: String? = nil

    // MARK: - Wired in by AppDelegate

    private var client: JellyfinClient?
    private var poller: PlaybackPoller?

    // MARK: - Internals

    private var transientTask: Task<Void, Never>?
    private var clearTrackTask: Task<Void, Never>?
    /// How long to wait before clearing `currentTrack` when a poll reports no
    /// active track. Smooths over the brief gap between songs while the web
    /// player loads the next one.
    private static let trackClearDebounce: UInt64 = 1_500_000_000
    private static let selectedSessionKey = "playerStore.selectedSessionId"

    init() {
        self.selectedSessionId = UserDefaults.standard.string(forKey: Self.selectedSessionKey)
    }

    // MARK: Configuration

    /// Called by `AppDelegate` whenever the polling stack is (re)built. Pass
    /// `nil` for both to detach when the user clears the configuration.
    func configure(client: JellyfinClient?, poller: PlaybackPoller?) {
        self.client = client
        self.poller = poller
    }

    // MARK: Polling updates

    /// Apply a fresh poll result. `track == nil` means no active playback for
    /// this user; `connectionState` already reflects the connection lifecycle.
    func apply(
        connectionState: ConnectionState,
        track: TrackSnapshot?,
        isPaused: Bool,
        sessions: [SessionSummary]
    ) {
        self.connectionState = connectionState
        self.isPaused = isPaused
        self.availableSessions = sessions

        // Track transition smoothing: a new track cancels any pending clear
        // so we go straight from A to B (fade through ArtworkView). A nil
        // track only takes effect after `trackClearDebounce` to absorb the
        // gap during which the web player has unloaded A and not yet
        // started B.
        if let track {
            clearTrackTask?.cancel()
            clearTrackTask = nil
            currentTrack = track
        } else if currentTrack != nil {
            clearTrackTask?.cancel()
            clearTrackTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.trackClearDebounce)
                guard !Task.isCancelled else { return }
                self?.currentTrack = nil
            }
        }

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

    // MARK: Commands

    func playPause() async {
        await sendCommand(name: "play/pause") { client, sessionId in
            try await client.playPause(sessionId: sessionId)
        }
    }

    func nextTrack() async {
        await sendCommand(name: "next") { client, sessionId in
            try await client.nextTrack(sessionId: sessionId)
        }
    }

    func previousTrack() async {
        await sendCommand(name: "previous") { client, sessionId in
            try await client.previousTrack(sessionId: sessionId)
        }
    }

    // MARK: Toast

    func showTransient(_ message: String) {
        transientMessage = message
        transientTask?.cancel()
        transientTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.transientMessage = nil
        }
    }

    // MARK: Internals

    /// Common command path: marks `isCommandInFlight`, fires the request,
    /// asks the poller for an immediate refresh, and ensures the in-flight
    /// flag stays true for at least 300 ms (plan §5.5).
    private func sendCommand(
        name: String,
        _ work: @Sendable (JellyfinClient, String) async throws -> Void
    ) async {
        guard !isCommandInFlight else { return }
        guard let client else {
            Self.logger.error("Command \(name, privacy: .public) ignored: no client")
            return
        }
        guard let sessionId = currentTrack?.sessionId else {
            Self.logger.error("Command \(name, privacy: .public) ignored: no current session")
            return
        }

        isCommandInFlight = true
        let startNanos = DispatchTime.now().uptimeNanoseconds

        do {
            try await work(client, sessionId)
            await poller?.forceRefresh()
            Self.logger.notice("Command \(name, privacy: .public) OK")
        } catch let error as NetworkError {
            Self.logger.error("Command \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            showTransient(error.errorDescription ?? "Command failed.")
        } catch {
            Self.logger.error("Command \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            showTransient(error.localizedDescription)
        }

        // Keep the cooldown at >= 300 ms from the original press, even if the
        // command was faster, so double-taps are absorbed.
        let elapsed = DispatchTime.now().uptimeNanoseconds - startNanos
        let target: UInt64 = 300_000_000
        if elapsed < target {
            try? await Task.sleep(nanoseconds: target - elapsed)
        }
        isCommandInFlight = false
    }
}
