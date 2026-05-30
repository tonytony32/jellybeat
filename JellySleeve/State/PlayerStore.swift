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

    enum ConnectionMode: Equatable, Sendable {
        case unknown
        case webSocket
        case polling
    }

    var connectionState: ConnectionState = .idle
    var connectionMode: ConnectionMode = .unknown
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

    /// Raised when the user clicks the ambient overlay to launch their
    /// Jellyfin client. Keeps the overlay chrome visible (no auto-fade back
    /// to invisible) while we wait for a track to start, since that latency
    /// can be a few seconds. Auto-clears after 30 s or when a track lands.
    var anticipating: Bool = false

    /// Set briefly after a control action so the overlay can flash a large
    /// SF Symbol confirming the dispatch — useful when the user pressed a
    /// media key (F7/F8/F9) and the artwork/title hasn't updated yet.
    var commandFeedback: PlaybackAction? = nil

    // MARK: - Wired in by AppDelegate

    private var client: JellyfinClient?
    private var poller: PlaybackPoller?

    // MARK: - Internals

    private var transientTask: Task<Void, Never>?
    private var clearTrackTask: Task<Void, Never>?
    private var anticipatingTask: Task<Void, Never>?
    private var commandFeedbackTask: Task<Void, Never>?
    /// Timestamp of the last command we issued. Used to suppress poll-driven
    /// `isPaused` updates briefly so an optimistic toggle doesn't snap back
    /// before the server's round-trip with the client has completed.
    private var lastCommandAt: Date?
    /// Window during which we ignore the poll's `isPaused` value because the
    /// user just clicked play/pause and our optimistic flip is what they
    /// actually want to see (vs the stale value the server has not yet been
    /// notified of by the client). 1.5 s matches the worst-case round trip
    /// for the web client to receive the WebSocket push, apply it, and report
    /// the new state back to the server in time for the next `/Sessions`
    /// reply.
    private static let optimisticPlayPauseWindow: TimeInterval = 1.5
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
        if self.connectionState != connectionState { self.connectionState = connectionState }
        // Optimistic-update protection: if a command was issued in the last
        // 1.5 s, ignore the poll's `isPaused` so the local optimistic toggle
        // stays put until the server has confirmed.
        if let lastCommandAt,
           Date().timeIntervalSince(lastCommandAt) < Self.optimisticPlayPauseWindow {
            // skip
        } else if self.isPaused != isPaused {
            self.isPaused = isPaused
        }
        if self.availableSessions != sessions { self.availableSessions = sessions }

        // Track transition smoothing: a new track cancels any pending clear
        // so we go straight from A to B (fade through ArtworkView). A nil
        // track only takes effect after `trackClearDebounce` to absorb the
        // gap during which the web player has unloaded A and not yet
        // started B.
        if let track {
            clearTrackTask?.cancel()
            clearTrackTask = nil
            currentTrack = track
            // Music arrived — drop the "expecting music" hint.
            anticipating = false
            anticipatingTask?.cancel()
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

    /// Apply a fresh `[Session]` from any source (polling or WebSocket).
    /// Encapsulates the active-session heuristic from plan §4 (points 1-4)
    /// plus snapshot building so consumers don't duplicate it.
    func ingest(sessions: [Session], userId: String) {
        // Filter for the user's sessions that look genuinely active.
        //
        // Jellyfin keeps a session record around for a while after the
        // client disconnects — a Safari "Add to Dock" web app, in
        // particular, doesn't gracefully tear down on close. The session
        // keeps reporting the last `NowPlayingItem` until the server's own
        // timeout fires (minutes). We approximate "still there" by checking
        // `LastActivityDate`: an active web player checks in regularly, so
        // anything older than ~10 s belongs to a disconnected client.
        let now = Date()
        // Jellyfin's web player sends `LastActivityDate` heartbeats every
        // ~10 s while *playing* but stops the moment it's paused — and a
        // minimized/background browser tab is throttled harder still. So a
        // stale heartbeat means two very different things depending on the
        // play state, and we can't use one threshold for both:
        //
        //  - Playing but silent > 60 s: the client genuinely vanished
        //    (tab closed mid-track). Drop it so the overlay clears.
        //  - Paused and silent: this is *expected* — a paused web player
        //    legitimately stops heartbeating, and minimizing it stops it
        //    sooner. Dropping it after 60 s is the bug that flips the
        //    overlay to ambient mode while the user's track is merely
        //    paused. Give paused sessions a generous window so they survive
        //    being parked & minimized, while still self-healing eventually
        //    if the tab was actually closed while paused.
        let playingRecency: TimeInterval = 60
        let pausedRecency: TimeInterval = 15 * 60
        let mine = sessions.filter { session in
            guard session.userId == userId, session.nowPlayingItem != nil else {
                return false
            }
            if let last = session.lastActivityDate {
                let threshold = (session.playState?.isPaused ?? false)
                    ? pausedRecency
                    : playingRecency
                if now.timeIntervalSince(last) > threshold {
                    return false
                }
            }
            return true
        }

        let pick: Session?
        if let manual = selectedSessionId,
           let match = mine.first(where: { $0.id == manual }) {
            pick = match
        } else {
            pick = mine.max(by: { lhs, rhs in
                (lhs.lastActivityDate ?? .distantPast) < (rhs.lastActivityDate ?? .distantPast)
            })
        }

        let snapshot = pick.flatMap { Self.makeSnapshot(from: $0) }
        let pausedFromServer = pick?.playState?.isPaused ?? false
        let summaries = Self.summaries(of: sessions, userId: userId)

        apply(
            connectionState: .connected,
            track: snapshot,
            isPaused: pausedFromServer,
            sessions: summaries
        )
    }

    private static func makeSnapshot(from session: Session) -> TrackSnapshot? {
        guard let item = session.nowPlayingItem else { return nil }
        let artist = item.albumArtist
            ?? item.artists?.joined(separator: ", ")
            ?? "Unknown artist"
        let runtimeSeconds = Double(item.runTimeTicks ?? 0) / 10_000_000
        let positionSeconds = Double(session.playState?.positionTicks ?? 0) / 10_000_000
        return TrackSnapshot(
            itemId: item.id,
            imageTag: item.imageTags?.primary,
            title: item.name,
            artist: artist,
            album: item.album ?? "",
            runtime: .seconds(runtimeSeconds),
            position: .seconds(positionSeconds),
            sessionId: session.id
        )
    }

    private static func summaries(of sessions: [Session], userId: String) -> [SessionSummary] {
        sessions
            .filter { $0.userId == userId }
            .map {
                SessionSummary(
                    id: $0.id,
                    client: $0.client,
                    deviceName: $0.deviceName,
                    lastActivity: $0.lastActivityDate,
                    hasNowPlaying: $0.nowPlayingItem != nil
                )
            }
            .sorted(by: { lhs, rhs in
                if lhs.hasNowPlaying != rhs.hasNowPlaying { return lhs.hasNowPlaying }
                return (lhs.lastActivity ?? .distantPast) > (rhs.lastActivity ?? .distantPast)
            })
    }

    // MARK: Commands

    func playPause() async {
        // Optimistic UI: flip the icon at the press so latency is hidden.
        // The server's eventual confirmation through the poll either ratifies
        // (no visible change) or, if the command failed silently somewhere,
        // the apply() guard expires after 1.5 s and the poll's value wins.
        let expectedPaused = !isPaused
        isPaused.toggle()
        flashFeedback(.playPause)
        await sendCommand(name: "play/pause") { client, sessionId in
            try await client.playPause(sessionId: sessionId)
        }
        // Capture the timestamp set by sendCommand so we can detect whether a
        // newer command has been issued by the time the deferred check runs.
        let thisCommandAt = lastCommandAt
        // Deferred check: after the optimistic window expires, verify the web
        // player actually honoured the command. If isPaused snapped back, the
        // Jellyfin web client likely didn't receive the WebSocket push (e.g.
        // the browser tab was throttled in the background by Safari).
        Task { @MainActor [weak self] in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(thisCommandAt ?? .distantPast)
            let remaining = max(0, Self.optimisticPlayPauseWindow - elapsed)
            try? await Task.sleep(for: .seconds(remaining + 1.0))
            guard self.currentTrack != nil,
                  self.lastCommandAt == thisCommandAt else { return }
            if self.isPaused != expectedPaused {
                self.showTransient("Player didn't respond — bring Jellyfin to the foreground.")
            }
        }
    }

    func nextTrack() async {
        flashFeedback(.next)
        await sendCommand(name: "next") { client, sessionId in
            try await client.nextTrack(sessionId: sessionId)
        }
    }

    func previousTrack() async {
        flashFeedback(.previous)
        await sendCommand(name: "previous") { client, sessionId in
            try await client.previousTrack(sessionId: sessionId)
        }
    }

    /// Seek the currently playing track to an absolute `seconds` value.
    /// Updates the local snapshot optimistically so the progress bar moves
    /// before the WebSocket pushes the new state back from the server.
    func seek(toSeconds seconds: Double) async {
        guard let client else { return }
        guard let current = currentTrack else { return }
        let target = max(0, seconds)
        let ticks = Int64(target * 10_000_000)

        // Optimistic update.
        currentTrack = TrackSnapshot(
            itemId: current.itemId,
            imageTag: current.imageTag,
            title: current.title,
            artist: current.artist,
            album: current.album,
            runtime: current.runtime,
            position: .seconds(target),
            sessionId: current.sessionId
        )
        lastCommandAt = Date()

        do {
            try await client.seek(sessionId: current.sessionId, positionTicks: ticks)
            await poller?.forceRefresh()
            Self.logger.notice("Seek to \(target, privacy: .public)s OK")
        } catch let error as NetworkError {
            Self.logger.error("Seek failed: \(String(describing: error), privacy: .public)")
            showTransient(error.errorDescription ?? "Seek failed.")
        } catch {
            Self.logger.error("Seek failed: \(String(describing: error), privacy: .public)")
            showTransient(error.localizedDescription)
        }
    }

    private func flashFeedback(_ action: PlaybackAction) {
        commandFeedback = action
        commandFeedbackTask?.cancel()
        commandFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.commandFeedback = nil
        }
    }

    // MARK: Toast

    /// Called when the user clicked the ambient overlay to launch their
    /// Jellyfin client. Keeps the overlay visible for a 30 s grace window.
    func markAnticipating() {
        anticipating = true
        anticipatingTask?.cancel()
        anticipatingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.anticipating = false
        }
    }

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
        lastCommandAt = Date()
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
