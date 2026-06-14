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
/// Decision (per `docs/architecture.md` §5): a forced selection wins outright;
/// in `auto`, the genuinely *playing* source drives; ties between several
/// playing sources go to the most-recently-*activated* one; and when nothing is
/// playing the overlay falls back to the first present source in `homePriority`
/// (Jellyfin, the home source). With nothing active at all, the current source
/// stays put.
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

    /// Tracks which source was most-recently *activated* for the both-active
    /// tie-break (see `ActivationRecency`). Pure value type, fed each pass.
    private var recency = ActivationRecency()

    /// When the active source last flipped, used to damp oscillation between two
    /// simultaneously-active sources (the plan's "debounce flips slightly").
    private var lastFlipAt: Date = .distantPast
    private static let flipDebounce: TimeInterval = 1.0

    /// Whether YouTube's feed was active on the previous pass, so we can detect
    /// the bridge's idle→active *reconnect* edge and re-read its capabilities
    /// live (see `shouldRefreshOnReconnect`).
    private var ytWasActive = false

    /// Decision priorities, expressed as two explicit orderings rather than
    /// derived from one list — because the two answers genuinely differ:
    ///  - `homePriority`: when *nothing* is playing, which present-but-idle/paused
    ///    source the overlay falls back to. Jellyfin is "home", so pausing YouTube
    ///    reveals Jellyfin instead of lingering on a paused YouTube cover.
    ///  - `tiePriority`: when *several* sources are genuinely playing and were
    ///    activated on the same tick, who wins. YouTube wins the tie (matching the
    ///    historical `ytActivatedNoOlderThanJf >=` direction).
    /// A new source slots into both lists; `decide` and `ActivationRecency`
    /// already generalize over `SourceKind.allCases`. Internal (not private) so
    /// the test suite can pin the production orderings.
    static let homePriority: [SourceKind] = [.jellyfin, .youtube]
    static let tiePriority: [SourceKind] = [.youtube, .jellyfin]

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

        // Sample every source's presence ONCE per pass into a uniform map, so
        // recency, the decision, and the debounce all read the same snapshot and
        // no source is special-cased downstream. `active` = has a session
        // (playing OR paused); `playing` = genuinely playing.
        let presence: [SourceKind: SourcePresence] = [
            .jellyfin: SourcePresence(
                active: player.jellyfinHasNowPlaying,
                playing: player.jellyfinIsPlaying
            ),
            .youtube: SourcePresence(
                active: yt.active,
                playing: yt.active && !yt.isPaused
            ),
        ]

        // Record each source's activation edge (idle→active). A change *while
        // already active* (auto-advance) does not re-activate, so it can't win
        // the tie-break and steal the overlay.
        recency.observe(presence)

        let desired = Self.decide(
            selection: settings.sourceSelection,
            presence: presence,
            recency: recency,
            homePriority: Self.homePriority,
            tiePriority: Self.tiePriority,
            current: activeKind
        )
        let kind = debounced(desired, presence: presence)
        let didFlip = applyKind(kind)

        // Pick up a live capability change without a restart: when the bridge
        // reconnects — its feed goes idle→active, e.g. after a rebuild/reinstall
        // — while YouTube is already the active source, re-read `/v1/health`. A
        // flip TO youtube already refreshes (inside `applyKind`), so this only
        // fires for the no-flip reconnect, where capabilities would otherwise
        // stay cached until the next flip (the "had to restart JellySleeve to
        // see a new bridge capability" papercut).
        if Self.shouldRefreshOnReconnect(
            ytActive: yt.active, ytWasActive: ytWasActive,
            didFlip: didFlip, active: activeKind
        ) {
            refreshYouTubeCapabilities()
        }
        ytWasActive = yt.active

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

    /// Pure decision policy (extracted for testing), generalized over an
    /// arbitrary set of sources keyed by `SourceKind`. In order:
    /// 1. A forced selection wins outright.
    /// 2. Exactly one source genuinely *playing* → it wins (over any idle/paused
    ///    others). Resolves the common "Jellyfin parked while YouTube plays".
    /// 3. Several playing → most-recently-*activated* (the source the user
    ///    started last); auto-advance can't steal because it never re-activates.
    ///    A same-tick tie breaks by `tiePriority`.
    /// 4. None playing → fall back to the first source in `homePriority` that has
    ///    a session, so pausing/stopping the active source reveals the home
    ///    source instead of lingering on a paused cover.
    /// 5. With nothing active anywhere, the current source stays put.
    static func decide(
        selection: SourceSelection,
        presence: [SourceKind: SourcePresence],
        recency: ActivationRecency,
        homePriority: [SourceKind],
        tiePriority: [SourceKind],
        current: SourceKind
    ) -> SourceKind {
        if let forced = selection.forcedKind { return forced }

        let playing = SourceKind.allCases.filter { presence[$0]?.playing == true }
        if playing.count == 1 { return playing[0] }
        if playing.count > 1 {
            // Highest activation rank wins; an equal-rank tie breaks by
            // `tiePriority`. The (rank, tieIndex) ordering is total, so the
            // winner is unambiguous regardless of which equal element `max`
            // would otherwise return.
            if let best = playing.max(by: { a, b in
                let ra = recency.rank(of: a), rb = recency.rank(of: b)
                return ra != rb
                    ? ra < rb
                    : Self.tieIndex(a, tiePriority) > Self.tieIndex(b, tiePriority)
            }) {
                return best
            }
        }

        // None playing: prefer the first present source in the home order.
        for kind in homePriority where presence[kind]?.active == true {
            return kind
        }
        // Nothing active anywhere → keep the current source (no spurious flip).
        return current
    }

    /// Position of `kind` in `order`, or `.max` when absent (sorts last).
    private static func tieIndex(_ kind: SourceKind, _ order: [SourceKind]) -> Int {
        order.firstIndex(of: kind) ?? .max
    }

    /// Damp a tie-break flip (both sources active) that lands within the
    /// debounce window of the last flip, so two simultaneously-active sources
    /// can't oscillate. A forced selection, or the current source going idle,
    /// flips immediately — the window only guards the both-active ambiguity.
    /// Reads `currentStillActive` from the same per-pass presence map, so no
    /// source is special-cased here either.
    private func debounced(_ desired: SourceKind, presence: [SourceKind: SourcePresence]) -> SourceKind {
        guard desired != activeKind else { return desired }
        if settings.sourceSelection.forcedKind != nil { return desired }
        let currentStillActive = presence[activeKind]?.active ?? false
        guard currentStillActive else { return desired }   // current went idle → flip now
        if Date().timeIntervalSince(lastFlipAt) < Self.flipDebounce {
            return activeKind                              // hold to avoid flapping
        }
        return desired
    }

    /// Apply the resolved source. Returns `true` if this was an actual flip
    /// (the active source changed), so the caller can tell a flip-driven
    /// capability refresh apart from a reconnect-driven one.
    @discardableResult
    private func applyKind(_ kind: SourceKind) -> Bool {
        // Gate Jellyfin's writes to the shared state on every pass (idempotent),
        // so the flag always tracks the resolved source.
        player.jellyfinIsActiveSource = (kind == .jellyfin)

        guard kind != activeKind else { return false }
        Self.logger.notice("Source flip: \(self.activeKind.rawValue, privacy: .public) → \(kind.rawValue, privacy: .public)")
        activeKind = kind
        lastFlipAt = Date()

        switch kind {
        case .youtube:
            player.setCommandSink(ytClient, capabilities: ytFeed.capabilities)
            refreshYouTubeCapabilities()
        case .jellyfin:
            // Drop the YouTube sink; the per-session Jellyfin sink is rebuilt on
            // the next `ingest`. Nudge a refresh so the overlay repopulates fast.
            player.setCommandSink(nil, capabilities: .jellyfin)
            coordinator.forceRefresh()
        }
        return true
    }

    /// Whether to re-read the YouTube source's `/v1/health` on this pass because
    /// the bridge just *reconnected*. True only when YouTube's feed went
    /// idle→active (`ytActive && !ytWasActive`) while YouTube is already the
    /// active source and we did **not** flip this pass (a flip refreshes on its
    /// own). This is what lets a live bridge update — a rebuild that starts
    /// advertising a new capability — land without restarting JellySleeve.
    static func shouldRefreshOnReconnect(
        ytActive: Bool,
        ytWasActive: Bool,
        didFlip: Bool,
        active: SourceKind
    ) -> Bool {
        ytActive && !ytWasActive && !didFlip && active == .youtube
    }

    /// Read the YouTube source's self-described capabilities and apply them if
    /// YouTube is still the active source when the read returns.
    private func refreshYouTubeCapabilities() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let caps = await self.ytClient.fetchCapabilities()
            self.ytFeed.applyCapabilities(caps)
            guard self.activeKind == .youtube else { return }
            self.player.setCommandSink(self.ytClient, capabilities: caps)
            Self.logger.debug("YouTube capabilities refreshed (canFocusTab=\(caps.canFocusTab, privacy: .public))")
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

/// Uniform per-source presence, sampled once per arbitration pass so the
/// decision logic never special-cases a particular backend. `playing` implies
/// `active`.
nonisolated struct SourcePresence: Equatable, Sendable {
    /// The source has a now-playing item — playing OR paused.
    let active: Bool
    /// The source is genuinely playing (active and not paused).
    let playing: Bool
}

/// Tracks which source was most-recently *activated* — the idle→active edge,
/// i.e. the moment the user started it. This is the signal the arbiter's
/// both-active tie-break consumes. Generalized over an arbitrary set of sources
/// keyed by `SourceKind`, so adding a source needs no new fields here.
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
    private var lastActive: [SourceKind: Bool] = [:]
    private var rank: [SourceKind: Int] = [:]
    private var tick = 0

    /// Feed the current presence of every source. Stamps a fresh, higher rank on
    /// each source that crossed an idle→active edge since the last call.
    ///
    /// Iterates `SourceKind.allCases` so a same-pass double activation resolves
    /// deterministically every run. DO NOT reorder the enum's cases without
    /// revisiting the tie semantics this ordering pins.
    mutating func observe(_ presence: [SourceKind: SourcePresence]) {
        for kind in SourceKind.allCases {
            let isActive = presence[kind]?.active ?? false
            if isActive && !(lastActive[kind] ?? false) {
                tick += 1
                rank[kind] = tick
            }
            lastActive[kind] = isActive
        }
    }

    /// Activation rank of `kind`: higher = activated more recently. `0` means the
    /// source has never activated, so the initial all-zero state is a tie (the
    /// caller breaks it with `tiePriority`).
    func rank(of kind: SourceKind) -> Int { rank[kind] ?? 0 }
}
