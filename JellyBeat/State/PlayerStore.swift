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
        subsystem: "software.trypwood.jellybeat",
        category: "state"
    )

    enum ConnectionMode: Equatable, Sendable {
        case unknown
        case webSocket
        case polling
    }

    /// Lifecycle of the Instant Mix list shown in the queue panel's second tab.
    /// Drives the tab's spinner / empty / error states. The mix is fetched
    /// lazily (only when the user opens that tab) and rebuilt when the seed
    /// track changes.
    enum InstantMixState: Equatable, Sendable {
        case idle      // not requested for the current track yet
        case loading
        case loaded    // `instantMix` holds recommendations
        case empty     // the server returned no similar tracks
        case failed
    }

    var connectionState: ConnectionState = .idle
    var connectionMode: ConnectionMode = .unknown
    var currentTrack: TrackSnapshot? = nil
    var isPaused: Bool = false

    /// Capabilities of the source currently driving the overlay. Drives
    /// capability-gated UI (favorite heart, queue affordance). Defaults to
    /// Jellyfin because the app comes up on the Jellyfin transport; the arbiter
    /// swaps it when YouTube takes over.
    var capabilities: SourceCapabilities = .jellyfin

    /// The active client's play queue (current track + up next), surfaced in
    /// the controls' queue popover. Empty when the playing client doesn't
    /// report one. Cleared alongside `currentTrack` when playback stops.
    var queue: [QueueItem] = []

    /// Recommendations seeded from the current track ("Instant Mix"), surfaced
    /// in the queue panel's second tab. Fetched lazily and rebuilt when the
    /// track changes. Tapping a row replaces the play queue with this mix.
    var instantMix: [QueueItem] = []

    /// Loading lifecycle of `instantMix`, read by the panel to show a spinner /
    /// empty / error state.
    var instantMixState: InstantMixState = .idle

    /// The track id the current `instantMix` was seeded from, so we can reuse a
    /// cached mix while the same song plays and refetch when it changes.
    private var instantMixSeedId: String?

    /// Output volume (0...100) of the active client, as last reported by the
    /// poll or set optimistically via `nudgeVolume`. Drives the scroll-to-
    /// change-volume interaction and its on-overlay readout.
    var volume: Int = 100

    /// Manual override for the active-session heuristic (plan §4 point 2).
    /// Persisted across launches so a multi-device user keeps their pick.
    var selectedSessionId: String? {
        didSet {
            if selectedSessionId == nil {
                defaults.removeObject(forKey: Self.selectedSessionKey)
            } else {
                defaults.set(selectedSessionId, forKey: Self.selectedSessionKey)
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

    /// Set while the user is scrolling to change the volume so the overlay can
    /// flash a transient volume readout. Carries the level (0...100) to show;
    /// cleared ~1 s after the last scroll tick.
    var volumeFeedback: Int? = nil

    /// True while the queue popover is open. Scroll-to-change-volume is
    /// suppressed in that state so the wheel scrolls the queue list instead of
    /// fighting it.
    var isQueuePopoverOpen: Bool = false
    /// True while the cursor is inside the Minim overlay. Driven by an AppKit
    /// tracking area on the hosting view (robust across the window's
    /// hover-resize, unlike SwiftUI `.onHover`) and observed by
    /// `OverlayWindowController` to expand the strip upward on hover.
    var minimHovered: Bool = false

    // MARK: - Wired in by AppDelegate

    /// Jellyfin REST handle, used for the Jellyfin-only operations the
    /// vendor-neutral command sink doesn't cover: Instant Mix, queue jumps, and
    /// the authoritative favorite read. `nil` while no Jellyfin stack is built.
    private var client: JellyfinClient?
    private var poller: PlaybackPoller?

    /// The vendor-neutral transport sink for the source currently driving the
    /// overlay (a `JellyfinCommandSink` while Jellyfin is active, the YouTube
    /// bridge client while YouTube is). All transport / seek / volume / favorite
    /// actions route through this so the views never branch on the backend.
    private var commandSink: (any PlaybackCommanding)?

    // MARK: - Source arbitration (set by SourceArbiter)

    /// True when Jellyfin is the source allowed to write the shared overlay
    /// state. When false (YouTube is driving), Jellyfin keeps polling for
    /// presence but its `ingest` / `updateConnection` writes are dropped so they
    /// can't clobber the YouTube snapshot the arbiter is publishing. Defaults to
    /// true so direct `ingest` callers (tests, Jellyfin-only operation) behave
    /// exactly as before.
    var jellyfinIsActiveSource: Bool = true

    /// Presence signal for the arbiter, refreshed on every Jellyfin `ingest`
    /// regardless of gating: true when a Jellyfin session has a now-playing item
    /// (playing OR paused).
    private(set) var jellyfinHasNowPlaying: Bool = false

    /// Stronger signal for the arbiter: true when Jellyfin has a now-playing item
    /// AND it is actually playing (not paused). Lets the arbiter prefer a source
    /// that is genuinely playing over one merely parked/paused.
    private(set) var jellyfinIsPlaying: Bool = false

    /// Called after every Jellyfin `ingest` so the arbiter can re-evaluate which
    /// source should drive, using the refreshed presence signal above.
    var onJellyfinUpdate: (@MainActor () -> Void)?

    // MARK: - Internals

    private var transientTask: Task<Void, Never>?
    private var clearTrackTask: Task<Void, Never>?
    /// Authoritative favorite lookup fired on track change (the poll can't be
    /// trusted for this field). Cancelled when the track changes again.
    private var favoriteRefreshTask: Task<Void, Never>?
    /// True while a favorite toggle request is in flight, to drop double-clicks.
    private var favoriteInFlight: Bool = false
    /// Timestamp of the last local favorite toggle. For a source whose poll
    /// carries an authoritative favorite (the YouTube bridge's `liked`), the poll
    /// is ignored for this field briefly after a toggle so the optimistic flip
    /// doesn't snap back before the bridge has clicked the button and re-reported.
    private var lastFavoriteCommandAt: Date?
    /// When the last `focusTab` was dispatched, so a burst of double-clicks on
    /// the artwork sends at most one focus command per `focusDebounce`.
    private var lastFocusAt: Date?
    private static let focusDebounce: TimeInterval = 1.0
    private var anticipatingTask: Task<Void, Never>?
    private var commandFeedbackTask: Task<Void, Never>?
    private var volumeFeedbackTask: Task<Void, Never>?
    /// Throttles `SetVolume` requests: fires immediately on the first tick,
    /// then at most once every `volumeThrottleInterval` while scrolling.
    private var volumeSendTask: Task<Void, Never>?
    /// When the last `SetVolume` request was actually dispatched to the server.
    private var lastVolumeSentAt: Date?
    private static let volumeThrottleInterval: TimeInterval = 0.08
    /// Timestamp of the last local volume change, used to ignore poll-driven
    /// volume updates briefly so an optimistic scroll doesn't snap back before
    /// the client has acknowledged the new level.
    private var lastVolumeCommandAt: Date?
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
    /// Window during which poll-reported volume is ignored in favour of the
    /// local optimistic value. Covers the debounce plus a round-trip margin so
    /// the readout doesn't flicker back to a stale level mid-scroll.
    private static let optimisticVolumeWindow: TimeInterval = 2.0
    /// Window during which a poll's authoritative favorite is ignored in favour
    /// of the local optimistic flip. Sized for the bridge's worst case: our
    /// command queues, the next Safari sync (≤1 s) clicks the button, and the
    /// following now-playing read carries the new `liked`.
    private static let optimisticFavoriteWindow: TimeInterval = 2.5
    /// How long to wait before clearing `currentTrack` when a poll reports no
    /// active track. Smooths over the brief gap between songs while the web
    /// player loads the next one.
    private static let trackClearDebounce: UInt64 = 1_500_000_000
    private static let selectedSessionKey = "playerStore.selectedSessionId"

    /// Injected so the hosted test runner reads/writes a throwaway suite rather
    /// than the user's real `.standard` domain. Production passes `.standard`.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedSessionId = defaults.string(forKey: Self.selectedSessionKey)
    }

    // MARK: Configuration

    /// Called by the Jellyfin coordinator whenever the polling stack is
    /// (re)built. Pass `nil` for both to detach when the user clears the
    /// configuration. The vendor-neutral command sink is established separately:
    /// for Jellyfin it's rebuilt per session inside `ingest`.
    func configure(client: JellyfinClient?, poller: PlaybackPoller?) {
        self.client = client
        self.poller = poller
        if client == nil, commandSink is JellyfinCommandSink {
            commandSink = nil
        }
    }

    /// Install the active source's transport sink and capabilities. Called by
    /// the arbiter when YouTube takes over (and to hand control back to
    /// Jellyfin, which then rebuilds its per-session sink on the next `ingest`).
    func setCommandSink(_ sink: (any PlaybackCommanding)?, capabilities: SourceCapabilities) {
        self.commandSink = sink
        if self.capabilities != capabilities { self.capabilities = capabilities }
    }

    // MARK: Polling updates

    /// Apply a fresh poll result. `track == nil` means no active playback for
    /// this user; `connectionState` already reflects the connection lifecycle.
    func apply(
        connectionState: ConnectionState,
        track: TrackSnapshot?,
        isPaused: Bool,
        volume: Int?,
        sessions: [SessionSummary],
        queue: [QueueItem] = [],
        trustFavorite: Bool = false
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
        // Same optimistic protection for volume: a just-scrolled level wins
        // over the poll until the client has had time to acknowledge it.
        if let volume {
            let recentlyChanged = lastVolumeCommandAt
                .map { Date().timeIntervalSince($0) < Self.optimisticVolumeWindow }
                ?? false
            if !recentlyChanged, self.volume != volume {
                self.volume = volume
            }
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
            // Favorite handling depends on the source. Jellyfin's poll can't be
            // trusted for it (`/Sessions` doesn't reliably embed `UserData`), so we
            // carry the known value across polls and re-fetch on track change. The
            // YouTube bridge, by contrast, reports an authoritative `liked` every
            // poll (`trustFavorite`), which also reflects likes made directly in
            // the browser — so we take it, except briefly after a local toggle
            // where the optimistic flip should win until the bridge catches up.
            let isNewItem = currentTrack?.itemId != track.itemId
            if let existing = currentTrack, existing.itemId == track.itemId {
                let recentlyToggled = lastFavoriteCommandAt
                    .map { Date().timeIntervalSince($0) < Self.optimisticFavoriteWindow }
                    ?? false
                let favorite = (trustFavorite && !recentlyToggled)
                    ? track.isFavorite
                    : existing.isFavorite
                currentTrack = track.withFavorite(favorite)
            } else {
                currentTrack = track
            }
            // Music arrived — drop the "expecting music" hint.
            anticipating = false
            anticipatingTask?.cancel()
            if self.queue != queue { self.queue = queue }
            if isNewItem {
                // The mix was seeded from the previous song; drop it so the
                // panel rebuilds recommendations for the new track on demand.
                resetInstantMix()
                // Only Jellyfin needs the authoritative re-fetch; the bridge
                // already delivers a trusted `liked` in the snapshot above.
                if !trustFavorite { refreshFavorite(for: track.itemId) }
            }
        } else if currentTrack != nil {
            clearTrackTask?.cancel()
            clearTrackTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.trackClearDebounce)
                guard !Task.isCancelled else { return }
                self?.currentTrack = nil
                self?.queue = []
                self?.resetInstantMix()
            }
        }
    }

    /// Apply a snapshot from a non-Jellyfin source (the YouTube bridge), routed
    /// through the same `apply(...)` path so the optimistic-update protection
    /// for local play/pause and volume changes applies identically. Carries no
    /// sessions or queue (those are Jellyfin concepts). Favorites are trusted
    /// from the snapshot (`trustFavorite`): the bridge reports an authoritative
    /// `liked` each poll, so a like made in JellyBeat *or* directly in the
    /// browser stays in sync.
    func applyExternalSnapshot(
        track: TrackSnapshot?,
        isPaused: Bool,
        volume: Int?,
        connection: ConnectionState
    ) {
        apply(
            connectionState: connection,
            track: track,
            isPaused: isPaused,
            volume: volume,
            sessions: [],
            queue: [],
            trustFavorite: true
        )
    }

    /// Convenience for transient lifecycle states (connecting, reconnecting,
    /// errors) that do not carry a snapshot.
    func updateConnection(_ state: ConnectionState) {
        // Dropped while YouTube is driving: the Jellyfin transport keeps
        // running for presence, but its lifecycle blips (a reconnecting tick,
        // an idle reset) must not repaint the overlay the YouTube feed owns.
        guard jellyfinIsActiveSource else { return }
        // The poller re-emits `.reconnecting` on every failed tick; skip the
        // no-op assignment so we don't churn the Observation graph.
        guard connectionState != state else { return }
        connectionState = state
        // A hard error wipes the now-playing context (it isn't coming back
        // without user action). `.reconnecting` deliberately does NOT: the
        // overlay keeps the last track dimmed so the user has continuity while
        // the link heals on its own.
        if case .error = state {
            currentTrack = nil
            isPaused = false
            queue = []
            resetInstantMix()
        }
    }

    /// True only when the link is live enough to accept playback commands. The
    /// transport controls and seek/favorite gate on this so a press while the
    /// server is unreachable shows a one-line hint instead of firing a request
    /// that fails with a raw transport error.
    var isLinkLive: Bool {
        if case .connected = connectionState { return true }
        return false
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
        //    paused. Give paused sessions a wider window so a brief
        //    pause-and-glance-away survives, while still self-healing if the
        //    tab/app was actually closed while paused (e.g. Safari quit,
        //    which the Jellyfin server doesn't report for minutes). Dropping
        //    is cheap: resuming in the browser re-populates the overlay on
        //    the next heartbeat, so we don't need to hold a ghost cover long.
        let playingRecency: TimeInterval = 60
        let pausedRecency: TimeInterval = 3 * 60
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
        let volumeFromServer = pick?.playState?.volumeLevel
        let summaries = Self.summaries(of: sessions, userId: userId)
        let queue = pick.map { Self.makeQueue(from: $0) } ?? []

        // Refresh the arbiter's presence signals on every poll, gated or not, so
        // it can detect Jellyfin starting/stopping/pausing even while YouTube
        // drives.
        jellyfinHasNowPlaying = snapshot != nil
        jellyfinIsPlaying = snapshot != nil && !pausedFromServer
        onJellyfinUpdate?()

        // Gated: YouTube is the active source, so don't let Jellyfin write the
        // shared overlay state (it keeps polling purely for the presence signal
        // above). Also leave the command sink untouched — it points at YouTube.
        guard jellyfinIsActiveSource else { return }

        // Keep the transport sink pointed at the current Jellyfin session so
        // play/pause/seek/volume/favorite target the device we're mirroring.
        if let client, let session = pick?.id {
            commandSink = JellyfinCommandSink(client: client, sessionId: session)
        }

        apply(
            connectionState: .connected,
            track: snapshot,
            isPaused: pausedFromServer,
            volume: volumeFromServer,
            sessions: summaries,
            queue: queue
        )

        // Drop a manual device pick that no longer exists among this user's
        // Jellyfin sessions. Lives here (not in `apply`) so an external snapshot,
        // which carries no sessions, can't wipe the user's Jellyfin pick.
        if let pick = selectedSessionId,
           !summaries.contains(where: { $0.id == pick }) {
            Self.logger.notice("Dropping stale selectedSessionId \(pick, privacy: .public).")
            selectedSessionId = nil
        }
    }

    /// Resolve the friendliest artist label for an item, preferring the
    /// track-level `Artists` over the single `AlbumArtist` so the actual
    /// performer of the song shows through (e.g. featured guests or the
    /// individual artists on a compilation), not the album's headline artist.
    private static func artistLabel(for item: NowPlayingItem) -> String {
        if let trackArtist = item.artists?.joined(separator: ", "), !trackArtist.isEmpty {
            return trackArtist
        }
        if let albumArtist = item.albumArtist, !albumArtist.isEmpty {
            return albumArtist
        }
        return "Unknown artist"
    }

    private static func makeSnapshot(from session: Session) -> TrackSnapshot? {
        guard let item = session.nowPlayingItem else { return nil }
        let artist = artistLabel(for: item)
        let runtimeSeconds = Double(item.runTimeTicks ?? 0) / 10_000_000
        let positionSeconds = Double(session.playState?.positionTicks ?? 0) / 10_000_000
        let art = item.artworkSource
        return TrackSnapshot(
            itemId: item.id,
            imageTag: art.tag,
            artworkItemId: art.itemId,
            title: item.name,
            artist: artist,
            album: item.album ?? "",
            runtime: .seconds(runtimeSeconds),
            position: .seconds(positionSeconds),
            sessionId: session.id,
            isFavorite: item.userData?.isFavorite ?? false,
            artworkURL: nil
        )
    }

    /// Build the queue preview from a session's `NowPlayingQueueFullItems`,
    /// flagging the row that matches the current `NowPlayingItem`. Returns an
    /// empty array when the client doesn't report a queue.
    private static func makeQueue(from session: Session) -> [QueueItem] {
        guard let items = session.nowPlayingQueueFullItems, !items.isEmpty else {
            return []
        }
        return makeQueueItems(
            from: orderedQueueItems(full: items, order: session.nowPlayingQueue),
            currentId: session.nowPlayingItem?.id
        )
    }

    /// Reorder the (often unordered) `NowPlayingQueueFullItems` into the play
    /// order given by `NowPlayingQueue`. The server expands the full-items list
    /// via a lookup that doesn't preserve queue order, so without this the
    /// "Up Next" list shows tracks scrambled relative to the client. Falls back
    /// to the raw order when `NowPlayingQueue` is absent or doesn't line up.
    private static func orderedQueueItems(
        full items: [NowPlayingItem],
        order: [NowPlayingQueueEntry]?
    ) -> [NowPlayingItem] {
        guard let order, !order.isEmpty else { return items }
        // First occurrence wins so duplicate ids resolve to the same metadata.
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reordered = order.compactMap { byId[$0.id] }
        // If the order list didn't map cleanly (id mismatch), keep the raw list
        // rather than dropping rows.
        return reordered.count == items.count ? reordered : items
    }

    /// Map raw `NowPlayingItem`s to `QueueItem` rows, flagging the one matching
    /// `currentId` as the now-playing entry. Shared by the play-queue preview
    /// and the Instant Mix list so both render with the same row.
    private static func makeQueueItems(
        from items: [NowPlayingItem],
        currentId: String?
    ) -> [QueueItem] {
        items.enumerated().map { index, item in
            let art = item.artworkSource
            return QueueItem(
                id: "\(index)::\(item.id)",
                itemId: item.id,
                artworkItemId: art.itemId,
                imageTag: art.tag,
                title: item.name,
                artist: artistLabel(for: item),
                isCurrent: item.id == currentId
            )
        }
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

    /// One-line, user-facing reason the controls are inert, tailored to why the
    /// link is down. Never leaks transport internals.
    private var unreachableHint: String {
        if case .reconnecting(let isOffline) = connectionState {
            return isOffline ? "You're offline" : "Reconnecting to the server…"
        }
        return "Can't reach the server right now."
    }

    func playPause() async {
        // Don't fire a doomed command (and the raw-error toast that follows)
        // when the link is down — tell the user why nothing happened instead.
        guard isLinkLive else { showTransient(unreachableHint); return }
        // Drop presses landing inside the 300 ms cooldown *before* the optimistic
        // flip below. Otherwise a double-tap toggles the icon a second time while
        // `sendCommand` no-ops, leaving the overlay showing the opposite of what
        // the server will do until the optimistic window expires and a poll heals it.
        guard !isCommandInFlight else { return }
        // Optimistic UI: flip the icon at the press so latency is hidden.
        // The server's eventual confirmation through the poll either ratifies
        // (no visible change) or, if the command failed silently somewhere,
        // the apply() guard expires after 1.5 s and the poll's value wins.
        let expectedPaused = !isPaused
        isPaused.toggle()
        flashFeedback(.playPause)
        await sendCommand(name: "play/pause") { sink in
            try await sink.playPause()
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
                // Source-agnostic: the same symptom (a throttled background tab)
                // applies whether Jellyfin's web client or the YouTube bridge is
                // driving, so don't name a specific app here.
                self.showTransient("Player didn't respond — bring it to the foreground.")
            }
        }
    }

    func nextTrack() async {
        guard isLinkLive else { showTransient(unreachableHint); return }
        // Match playPause: ignore presses inside the cooldown so the feedback
        // flash doesn't fire for a command that sendCommand will drop.
        guard !isCommandInFlight else { return }
        flashFeedback(.next)
        await sendCommand(name: "next") { sink in
            try await sink.next()
        }
    }

    func previousTrack() async {
        guard isLinkLive else { showTransient(unreachableHint); return }
        guard !isCommandInFlight else { return }
        flashFeedback(.previous)
        await sendCommand(name: "previous") { sink in
            try await sink.previous()
        }
    }

    /// Jump playback to `item` in the play queue (tapped in the queue popover).
    /// Resends the whole queue with `PlayNow` and a `startIndex`, so the client
    /// keeps the same up-next order and just moves the playhead to that track.
    /// Tapping the current track is a no-op.
    func playQueueItem(_ item: QueueItem) async {
        guard isLinkLive else { showTransient(unreachableHint); return }
        guard !item.isCurrent else { return }
        guard let startIndex = queue.firstIndex(where: { $0.id == item.id }) else { return }
        let itemIds = queue.map(\.itemId)
        await sendJellyfinCommand(name: "play queue item") { client, sessionId in
            try await client.play(sessionId: sessionId, itemIds: itemIds, startIndex: startIndex)
        }
    }

    /// Lazily fetch the Instant Mix seeded from the current track. Idempotent:
    /// reuses a mix already loaded (or in flight) for the same song, so the
    /// panel can call this freely on tab-open and track-change. Guards against
    /// the track changing mid-flight so a slow response can't overwrite a newer
    /// seed's mix.
    func loadInstantMix() async {
        guard let client else { return }
        guard let seed = currentTrack?.itemId else {
            resetInstantMix()
            return
        }
        // Reuse a fresh (or already loading) mix for this track.
        if instantMixSeedId == seed,
           instantMixState == .loaded || instantMixState == .loading {
            return
        }
        instantMixSeedId = seed
        instantMixState = .loading
        instantMix = []
        do {
            let items = try await client.fetchInstantMix(seedItemId: seed)
            guard instantMixSeedId == seed else { return }  // track changed mid-flight
            instantMix = Self.makeQueueItems(from: items, currentId: currentTrack?.itemId)
            instantMixState = instantMix.isEmpty ? .empty : .loaded
            Self.logger.notice("Instant mix loaded: \(self.instantMix.count, privacy: .public) tracks")
        } catch {
            guard instantMixSeedId == seed else { return }
            Self.logger.error("Instant mix load failed: \(String(describing: error), privacy: .public)")
            instantMixState = .failed
        }
    }

    /// Start playback from a tapped Instant Mix row: make the tapped track the
    /// head of a new queue, followed by the mix entries *after* it — the ones
    /// before it in the recommendation list are dropped. So the new "Up Next"
    /// reads as [tapped, then the rest of the mix], with the tapped song first,
    /// rather than keeping earlier recommendations ahead of the playhead.
    /// (The play queue differs here from `playQueueItem`, which preserves the
    /// whole existing queue and only moves the playhead.)
    func playInstantMixItem(_ item: QueueItem) async {
        guard isLinkLive else { showTransient(unreachableHint); return }
        guard let startIndex = instantMix.firstIndex(where: { $0.id == item.id }) else { return }
        let itemIds = instantMix[startIndex...].map(\.itemId)
        await sendJellyfinCommand(name: "play instant mix item") { client, sessionId in
            try await client.play(sessionId: sessionId, itemIds: itemIds, startIndex: 0)
        }
    }

    /// Drop any loaded Instant Mix so it's rebuilt for the next track. Called on
    /// track change and when playback stops.
    private func resetInstantMix() {
        instantMixSeedId = nil
        instantMix = []
        instantMixState = .idle
    }

    /// Seek the currently playing track to an absolute `seconds` value.
    /// Updates the local snapshot optimistically so the progress bar moves
    /// before the WebSocket pushes the new state back from the server.
    func seek(toSeconds seconds: Double) async {
        guard isLinkLive else { showTransient(unreachableHint); return }
        guard let commandSink else { return }
        guard let current = currentTrack else { return }
        let target = max(0, seconds)

        // Optimistic update.
        currentTrack = TrackSnapshot(
            itemId: current.itemId,
            imageTag: current.imageTag,
            artworkItemId: current.artworkItemId,
            title: current.title,
            artist: current.artist,
            album: current.album,
            runtime: current.runtime,
            position: .seconds(target),
            sessionId: current.sessionId,
            isFavorite: current.isFavorite,
            artworkURL: current.artworkURL
        )
        lastCommandAt = Date()

        do {
            try await commandSink.seek(to: .seconds(target))
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

    /// Adjust the active client's volume by `delta` percentage points, clamped
    /// to 0...100. Called repeatedly while the user scrolls over the overlay.
    ///
    /// The local level updates immediately (and flashes a readout) so scrolling
    /// feels instant; the actual `SetVolume` request is throttled so the Jellyfin
    /// client follows the knob in real time without flooding the server.
    func nudgeVolume(by delta: Int) {
        guard delta != 0 else { return }
        // Suppressed while the queue popover is open so the wheel scrolls the
        // queue list rather than changing volume behind it.
        guard !isQueuePopoverOpen else { return }
        // Volume only means something when a source is actually playing.
        guard currentTrack != nil else { return }
        let newValue = min(100, max(0, volume + delta))
        lastVolumeCommandAt = Date()
        flashVolume(newValue)
        // At the 0 / 100 boundary the level can't move, but we still want the
        // readout to confirm the scroll registered — only schedule a network
        // send when the value genuinely changed.
        guard newValue != volume else { return }
        volume = newValue
        scheduleVolumeSend(to: newValue)
    }

    /// Set the volume to an absolute level (0–100) and push it to the source.
    /// Unlike `nudgeVolume`, this is NOT suppressed while the queue popover is
    /// open: it backs an explicit on-screen control (the Minim mute button),
    /// not the scroll wheel that the open queue list needs to scroll instead.
    func setVolume(toPercent value: Int) {
        guard currentTrack != nil else { return }
        let clamped = min(100, max(0, value))
        lastVolumeCommandAt = Date()
        flashVolume(clamped)
        guard clamped != volume else { return }
        volume = clamped
        scheduleVolumeSend(to: clamped)
    }

    /// Throttled `SetVolume` dispatch. Fires immediately on the first tick of a
    /// gesture, then at most once every `volumeThrottleInterval` so the Jellyfin
    /// client tracks the knob in real time rather than snapping at the end.
    private func scheduleVolumeSend(to value: Int) {
        volumeSendTask?.cancel()
        let elapsed = lastVolumeSentAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let remaining = Self.volumeThrottleInterval - elapsed

        if remaining <= 0 {
            lastVolumeSentAt = Date()
            Task { @MainActor [weak self] in
                await self?.sendVolume(value)
            }
        } else {
            volumeSendTask = Task { @MainActor [weak self] in
                let ns = UInt64(remaining * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                guard !Task.isCancelled, let self else { return }
                self.lastVolumeSentAt = Date()
                await self.sendVolume(value)
            }
        }
    }

    /// Volume sends are best-effort and intentionally silent on failure. Unlike
    /// the one-shot transport commands (which gate on `isLinkLive` and toast
    /// when the link is down), volume fires ~12×/s while scrolling and each
    /// command is idempotent — it carries the absolute level, so a dropped tick
    /// is corrected by the next one 80 ms later. A genuine outage already
    /// surfaces through `connectionState` (the poller flips the link indicator),
    /// so a per-tick toast would only spam noise that breaks the scroll's feel.
    private func sendVolume(_ value: Int) async {
        guard let commandSink else { return }
        do {
            try await commandSink.setVolume(percent: value)
            Self.logger.notice("SetVolume \(value, privacy: .public) OK")
        } catch {
            Self.logger.error("SetVolume failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func flashVolume(_ value: Int) {
        volumeFeedback = value
        volumeFeedbackTask?.cancel()
        volumeFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.volumeFeedback = nil
        }
    }

    /// Toggle the "favorite" flag on the currently playing item. Optimistic:
    /// the heart flips immediately, then the request reconciles with the
    /// server. On failure it reverts (only if the same track is still showing)
    /// and surfaces a toast.
    func toggleFavorite() async {
        guard isLinkLive else { showTransient(unreachableHint); return }
        // The active source has no favorites (YouTube); the heart is hidden, but
        // guard defensively so an errant call is a no-op rather than a misfire.
        guard capabilities.hasFavorites else { return }
        guard let commandSink else { return }
        guard let current = currentTrack else { return }
        // Drop overlapping toggles so a double-click doesn't fire two opposite
        // requests that race.
        guard !favoriteInFlight else { return }
        favoriteInFlight = true
        defer { favoriteInFlight = false }

        let target = !current.isFavorite

        // Optimistic flip. For Jellyfin the poll never overwrites favorite state;
        // for the YouTube bridge (whose poll *is* authoritative) this timestamp
        // suppresses the poll for `optimisticFavoriteWindow` so the flip holds
        // until the bridge has clicked the button and re-reported `liked`.
        lastFavoriteCommandAt = Date()
        currentTrack = current.withFavorite(target)

        do {
            // Trust the server's reported value rather than re-polling
            // `/Sessions` (which doesn't carry reliable `UserData`). A `nil`
            // result means the source doesn't track favorites — keep the
            // optimistic flip in that (unreachable) case.
            let result = try await commandSink.toggleFavorite(itemId: current.itemId, current: current.isFavorite)
            if let result, let now = currentTrack, now.itemId == current.itemId {
                currentTrack = now.withFavorite(result)
            }
            Self.logger.notice("Set favorite=\(String(describing: result), privacy: .public) OK")
        } catch let error as NetworkError {
            revertFavorite(itemId: current.itemId, to: current.isFavorite)
            Self.logger.error("Set favorite failed: \(String(describing: error), privacy: .public)")
            showTransient(error.errorDescription ?? "Couldn't update favorite.")
        } catch {
            revertFavorite(itemId: current.itemId, to: current.isFavorite)
            Self.logger.error("Set favorite failed: \(String(describing: error), privacy: .public)")
            showTransient(error.localizedDescription)
        }
    }

    /// Read the authoritative favorite state for `itemId` and apply it if that
    /// item is still showing. Fired on track change because the poll can't be
    /// trusted for this field.
    private func refreshFavorite(for itemId: String) {
        // Only meaningful for a source that has favorites (Jellyfin). Skipped for
        // YouTube — whose id is a videoId Jellyfin can't resolve — even though
        // the Jellyfin client stays alive in the background while YouTube drives.
        guard capabilities.hasFavorites else { return }
        guard let client else { return }
        favoriteRefreshTask?.cancel()
        favoriteRefreshTask = Task { @MainActor [weak self] in
            guard let value = try? await client.fetchFavorite(itemId: itemId) else { return }
            guard let self, !Task.isCancelled else { return }
            guard let current = self.currentTrack, current.itemId == itemId else { return }
            self.currentTrack = current.withFavorite(value)
        }
    }

    /// Restore a track's favorite flag after a failed toggle, but only if that
    /// same item is still on screen — a track change in the meantime wins.
    private func revertFavorite(itemId: String, to value: Bool) {
        guard let current = currentTrack, current.itemId == itemId else { return }
        currentTrack = current.withFavorite(value)
    }

    /// Bring the active source's window/tab to the front (the YouTube bridge's
    /// `focusTab`), wired to a double-click on the artwork. Best-effort and
    /// asynchronous: the bridge queues it and raises Safari on its next sync
    /// (≤ ~1 s), so there's no confirmation to wait on.
    ///
    /// Capability-gated and debounced so a burst of double-clicks sends at most
    /// one command per second. Every failure is swallowed — `503` (stale tab),
    /// `409` (no active player) and a refused connection (bridge idle) are all
    /// benign here; this is a convenience affordance, not a transport action
    /// worth a toast. Doesn't gate on `isLinkLive`: that tracks the Jellyfin
    /// link, which is irrelevant while the YouTube source is driving.
    func focusSource() async {
        guard capabilities.canFocusTab else { return }
        guard let commandSink else { return }
        if let lastFocusAt,
           Date().timeIntervalSince(lastFocusAt) < Self.focusDebounce {
            return
        }
        lastFocusAt = Date()
        do {
            try await commandSink.focusTab()
            Self.logger.notice("focusTab dispatched")
        } catch {
            Self.logger.debug("focusTab ignored (idle/stale): \(String(describing: error), privacy: .public)")
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

    /// Common transport-command path (vendor-neutral): marks `isCommandInFlight`,
    /// fires the request against the active source's sink, asks the Jellyfin
    /// poller for an immediate refresh (a no-op when YouTube drives), and ensures
    /// the in-flight flag stays true for at least 300 ms (plan §5.5).
    private func sendCommand(
        name: String,
        _ work: @Sendable (any PlaybackCommanding) async throws -> Void
    ) async {
        guard !isCommandInFlight else { return }
        guard let commandSink else {
            Self.logger.error("Command \(name, privacy: .public) ignored: no command sink")
            return
        }

        isCommandInFlight = true
        lastCommandAt = Date()
        let startNanos = DispatchTime.now().uptimeNanoseconds

        do {
            try await work(commandSink)
            await poller?.forceRefresh()
            Self.logger.notice("Command \(name, privacy: .public) OK")
        } catch let error as NetworkError {
            Self.logger.error("Command \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            showTransient(error.errorDescription ?? "Command failed.")
        } catch {
            Self.logger.error("Command \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            showTransient(error.localizedDescription)
        }

        await holdCooldown(since: startNanos)
        isCommandInFlight = false
    }

    /// Jellyfin-only command path for operations the vendor-neutral sink doesn't
    /// model (queue jumps via `play`). Targets the current session directly.
    /// Same in-flight / cooldown discipline as `sendCommand`.
    private func sendJellyfinCommand(
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

        await holdCooldown(since: startNanos)
        isCommandInFlight = false
    }

    /// Keep the cooldown at >= 300 ms from the original press, even if the
    /// command was faster, so double-taps are absorbed.
    private func holdCooldown(since startNanos: UInt64) async {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startNanos
        let target: UInt64 = 300_000_000
        if elapsed < target {
            try? await Task.sleep(nanoseconds: target - elapsed)
        }
    }
}
