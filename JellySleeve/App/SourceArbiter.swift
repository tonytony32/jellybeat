import Foundation
import Observation
import os

/// Decides which playback source drives the overlay — Jellyfin or the YouTube
/// bridge — and enforces that only the active one writes shared state.
///
/// It owns the two sibling feeds: the Jellyfin transport
/// (`PlaybackConnectionCoordinator`, untouched) and the `YouTubeBridgeFeed`.
/// Both keep running so their activeness is always observable; the arbiter
/// forwards only the winner's snapshot into `PlayerStore` and gates the loser
/// (Jellyfin via `PlayerStore.jellyfinIsActiveSource`, YouTube by simply not
/// publishing its snapshot). On a flip it swaps the command sink + capabilities
/// so transport actions and capability-gated UI follow the active source.
///
/// Decision (per `docs/youtube-bridge-arbiter-plan.md`): a forced selection wins
/// outright; in `auto`, the active source drives, and when both are active the
/// most-recently-changed one wins. With neither active, the last source stays.
@MainActor
@Observable
final class SourceArbiter {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellysleeve",
        category: "state"
    )

    private let settings: SettingsStore
    private let player: PlayerStore
    private let coordinator: PlaybackConnectionCoordinator
    private let ytFeed: YouTubeBridgeFeed
    private let ytClient: YouTubeBridgeClient

    /// The source currently driving the overlay. Read by the menu-bar "Source"
    /// section to mark the active one.
    private(set) var activeKind: SourceKind = .jellyfin

    /// Capabilities of the YouTube source, refreshed from `/v1/health` on a flip
    /// (defaults to the constant set the bridge advertises).
    private var ytCapabilities: SourceCapabilities = .youtube

    /// Tracks which source was most-recently *activated* for the both-active
    /// tie-break (see `ActivationRecency`). Pure value type, fed each pass.
    private var recency = ActivationRecency()

    /// When the active source last flipped, used to damp oscillation between two
    /// simultaneously-active sources (the plan's "debounce flips slightly").
    private var lastFlipAt: Date = .distantPast
    private static let flipDebounce: TimeInterval = 1.0

    private var observationActive = false

    /// What woke the arbiter, so it only re-publishes the YouTube snapshot when
    /// that data is the fresh trigger (avoids churn on every Jellyfin tick).
    private enum Trigger { case youtube, jellyfin, selection, initial }

    init(
        settings: SettingsStore,
        player: PlayerStore,
        coordinator: PlaybackConnectionCoordinator,
        ytFeed: YouTubeBridgeFeed,
        ytClient: YouTubeBridgeClient
    ) {
        self.settings = settings
        self.player = player
        self.coordinator = coordinator
        self.ytFeed = ytFeed
        self.ytClient = ytClient
    }

    // MARK: - Lifecycle

    /// Bring up both feeds and start arbitrating.
    func activate() {
        ytFeed.onUpdate = { [weak self] in self?.reevaluate(trigger: .youtube) }
        player.onJellyfinUpdate = { [weak self] in self?.reevaluate(trigger: .jellyfin) }

        coordinator.activate()
        ytFeed.start()
        observeSourceSelection()
        reevaluate(trigger: .initial)
    }

    func shutdown() {
        coordinator.shutdown()
        ytFeed.stop()
    }

    /// Pause both feeds (window hidden / system sleep). The arbiter mirrors what
    /// the coordinator used to receive directly, so the YouTube poll stops too.
    func pause(reason: String) {
        coordinator.pause(reason: reason)
        ytFeed.stop()
    }

    func resume(reason: String) {
        coordinator.resume(reason: reason)
        ytFeed.start()
        Task { await ytFeed.forceRefresh() }
    }

    // MARK: - Arbitration

    private func reevaluate(trigger: Trigger) {
        let yt = ytFeed.latest ?? .idle

        // Record each source's activation edge (idle→active). A change *while
        // already active* (auto-advance) does not re-activate, so it can't win
        // the tie-break and steal the overlay.
        recency.observe(ytActive: yt.active, jfActive: player.jellyfinHasNowPlaying)

        let kind = debounced(resolveActiveKind(yt: yt), yt: yt)
        applyKind(kind)

        // Publish the YouTube snapshot only when YouTube is the winner and the
        // wake was YouTube's own (or a selection change) — Jellyfin writes its
        // own state through `ingest`.
        //
        // Always publish as `.connected`, never `.idle`: `.idle` is Jellyfin's
        // "not configured" state and the overlay renders it as the "Configure
        // your Jellyfin server" prompt. When YouTube is the active source but
        // has nothing playing (bridge dormant / paused tab gone), we want the
        // ambient "nothing playing" view (`.connected` + no track), not a false
        // Jellyfin-misconfiguration alarm.
        if kind == .youtube, trigger != .jellyfin {
            player.applyExternalSnapshot(
                track: yt.track,
                isPaused: yt.isPaused,
                volume: yt.volume,
                connection: .connected
            )
        }
    }

    private func resolveActiveKind(yt: ExternalPlayback) -> SourceKind {
        Self.decide(
            selection: settings.sourceSelection,
            ytPlaying: yt.active && !yt.isPaused,
            ytActive: yt.active,
            jfPlaying: player.jellyfinIsPlaying,
            jfActive: player.jellyfinHasNowPlaying,
            ytActivatedNoOlderThanJf: recency.ytActivatedNoOlderThanJf,
            current: activeKind
        )
    }

    /// Pure decision policy (extracted for testing). In order:
    /// 1. A forced selection wins outright.
    /// 2. A source that is genuinely *playing* beats one that is merely active
    ///    but paused — the common case (Jellyfin parked/paused while YouTube
    ///    plays, or vice-versa) resolves to whatever is actually making sound.
    /// 3. Both playing (or neither, just paused/idle): the active sources tie-
    ///    break by most-recently-*activated* (the source the user started last).
    /// 4. With neither active, the current source stays put.
    static func decide(
        selection: SourceSelection,
        ytPlaying: Bool,
        ytActive: Bool,
        jfPlaying: Bool,
        jfActive: Bool,
        ytActivatedNoOlderThanJf: Bool,
        current: SourceKind
    ) -> SourceKind {
        if let forced = selection.forcedKind { return forced }
        // Genuinely playing beats merely-active-but-paused.
        if ytPlaying && !jfPlaying { return .youtube }
        if jfPlaying && !ytPlaying { return .jellyfin }
        // Both playing, or both only paused/active: activeness + recency.
        if ytActive && jfActive {
            return ytActivatedNoOlderThanJf ? .youtube : .jellyfin
        }
        if ytActive { return .youtube }
        if jfActive { return .jellyfin }
        return current
    }

    /// Damp a tie-break flip (both sources active) that lands within the
    /// debounce window of the last flip, so two simultaneously-active sources
    /// can't oscillate. A forced selection, or the current source going idle,
    /// flips immediately — the window only guards the both-active ambiguity.
    private func debounced(_ desired: SourceKind, yt: ExternalPlayback) -> SourceKind {
        guard desired != activeKind else { return desired }
        if settings.sourceSelection.forcedKind != nil { return desired }
        let currentStillActive = (activeKind == .youtube) ? yt.active : player.jellyfinHasNowPlaying
        guard currentStillActive else { return desired }   // current went idle → flip now
        if Date().timeIntervalSince(lastFlipAt) < Self.flipDebounce {
            return activeKind                              // hold to avoid flapping
        }
        return desired
    }

    private func applyKind(_ kind: SourceKind) {
        // Gate Jellyfin's writes to the shared state on every pass (idempotent),
        // so the flag always tracks the resolved source.
        player.jellyfinIsActiveSource = (kind == .jellyfin)

        guard kind != activeKind else { return }
        Self.logger.notice("Source flip: \(self.activeKind.rawValue, privacy: .public) → \(kind.rawValue, privacy: .public)")
        activeKind = kind
        lastFlipAt = Date()

        switch kind {
        case .youtube:
            player.setCommandSink(ytClient, capabilities: ytCapabilities)
            refreshYouTubeCapabilities()
        case .jellyfin:
            // Drop the YouTube sink; the per-session Jellyfin sink is rebuilt on
            // the next `ingest`. Nudge a refresh so the overlay repopulates fast.
            player.setCommandSink(nil, capabilities: .jellyfin)
            coordinator.forceRefresh()
        }
    }

    /// Read the YouTube source's self-described capabilities and apply them if
    /// YouTube is still the active source when the read returns.
    private func refreshYouTubeCapabilities() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let caps = await self.ytClient.fetchCapabilities()
            self.ytCapabilities = caps
            guard self.activeKind == .youtube else { return }
            self.player.setCommandSink(self.ytClient, capabilities: caps)
        }
    }

    // MARK: - Settings observation

    private func observeSourceSelection() {
        observationActive = true
        withObservationTracking {
            _ = settings.sourceSelection
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationActive else { return }
                self.reevaluate(trigger: .selection)
                self.observeSourceSelection()
            }
        }
    }
}

/// Tracks which source was most-recently *activated* — the idle→active edge,
/// i.e. the moment the user started it. This is the signal the arbiter's
/// both-active tie-break consumes.
///
/// The crucial property: a source that stays *continuously* active never
/// re-activates, so its rank doesn't move. A background Jellyfin playlist
/// auto-advancing (or a YouTube video rolling into the next) keeps the source
/// active throughout and therefore cannot out-rank — cannot steal the overlay
/// from — whatever the user is actually watching. Only a fresh idle→active
/// transition (a deliberate "start this source") bumps the rank.
///
/// Ordering is a monotonic tick rather than wall-clock, so it's deterministic
/// and immune to clock skew / equal-timestamp ties.
nonisolated struct ActivationRecency: Equatable, Sendable {
    private var lastYtActive = false
    private var lastJfActive = false
    private var ytRank = 0
    private var jfRank = 0
    private var tick = 0

    /// Feed the current activeness of both sources. Stamps a fresh rank only on
    /// an idle→active edge.
    mutating func observe(ytActive: Bool, jfActive: Bool) {
        if ytActive && !lastYtActive { tick += 1; ytRank = tick }
        if jfActive && !lastJfActive { tick += 1; jfRank = tick }
        lastYtActive = ytActive
        lastJfActive = jfActive
    }

    /// True when YouTube activated no earlier than Jellyfin (a tie — including
    /// the initial state where neither has activated — favors YouTube, matching
    /// `decide`'s tie-break direction).
    var ytActivatedNoOlderThanJf: Bool { ytRank >= jfRank }
}
