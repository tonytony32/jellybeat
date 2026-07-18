import Foundation
import Observation
import os

/// Decides which playback source drives the overlay — Jellyfin or any loopback
/// source (the built-in YouTube bridge, or a third-party source from a manifest)
/// — and enforces that only the active one writes shared state.
///
/// It owns the Jellyfin transport (`PlaybackConnectionCoordinator`, untouched)
/// and, via the `SourceRegistry`, one `LoopbackSourceFeed` per loopback source.
/// Every feed keeps running so its activeness is always observable; the arbiter
/// forwards only the winner's snapshot into `PlayerStore` and gates the losers
/// (Jellyfin via `PlayerStore.jellyfinIsActiveSource`, a loopback source by
/// simply not publishing its snapshot). On a flip it swaps the command sink +
/// capabilities so transport actions and capability-gated UI follow the active
/// source.
///
/// Decision (per `docs/architecture.md` §5): a forced selection wins outright;
/// in `auto`, the genuinely *playing* source drives; ties between several playing
/// sources go to the most-recently-*activated* one; and when nothing is playing
/// the overlay sticks to the current source while it still has a (paused) session,
/// only falling back to the registry's `homePriority` (Jellyfin, the home source)
/// once the current source goes fully idle. With nothing active at all, the
/// overlay likewise returns home, so Jellyfin's gate reopens and its real
/// transport state shows.
@MainActor
@Observable
final class SourceArbiter {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellybeat",
        category: "state"
    )

    private let settings: SettingsStore
    private let player: PlayerStore
    private let coordinator: PlaybackConnectionCoordinator
    private let registry: SourceRegistry

    /// The source currently driving the overlay. Read by the menu-bar "Source"
    /// section to mark the active one.
    private(set) var activeKind: SourceKind = .jellyfin

    /// Tracks which source was most-recently *activated* for the both-active
    /// tie-break (see `ActivationRecency`). Pure value type, fed each pass.
    private var recency = ActivationRecency()

    /// Previous per-source `active` state, so the arbiter can spot a loopback
    /// source *reconnecting* (idle→active) and re-read its capabilities live —
    /// without a JellyBeat restart (see `shouldRefreshOnReconnect`).
    private var previousActive: [SourceID: Bool] = [:]

    /// When the active source last flipped, used to damp oscillation between two
    /// simultaneously-active sources (the plan's "debounce flips slightly").
    private var lastFlipAt: Date = .distantPast
    private static let flipDebounce: TimeInterval = 1.0

    private var observationActive = false

    /// What woke the arbiter, so it only re-publishes a loopback snapshot when
    /// that source's own data is the fresh trigger (avoids churn on a Jellyfin
    /// tick). `.loopback` carries the id of the feed that polled.
    private enum Trigger: Equatable { case loopback(SourceID), jellyfin, selection, initial }

    init(
        settings: SettingsStore,
        player: PlayerStore,
        coordinator: PlaybackConnectionCoordinator,
        registry: SourceRegistry
    ) {
        self.settings = settings
        self.player = player
        self.coordinator = coordinator
        self.registry = registry
    }

    // MARK: - Lifecycle

    /// Bring up every feed and start arbitrating.
    func activate() {
        for (id, feed) in registry.feeds {
            feed.onUpdate = { [weak self] in self?.reevaluate(trigger: .loopback(id)) }
        }
        player.onJellyfinUpdate = { [weak self] in self?.reevaluate(trigger: .jellyfin) }

        coordinator.activate()
        for feed in registry.feeds.values { feed.start() }
        observeSourceSelection()
        reevaluate(trigger: .initial)
    }

    func shutdown() {
        coordinator.shutdown()
        for feed in registry.feeds.values { feed.stop() }
    }

    /// Pause every feed (window hidden / system sleep). The arbiter mirrors what
    /// the coordinator used to receive directly, so the loopback polls stop too.
    func pause(reason: String) {
        coordinator.pause(reason: reason)
        for feed in registry.feeds.values { feed.stop() }
    }

    func resume(reason: String) {
        coordinator.resume(reason: reason)
        for feed in registry.feeds.values {
            feed.start()
            Task { await feed.forceRefresh() }
        }
    }

    // MARK: - Arbitration

    private func reevaluate(trigger: Trigger) {
        // Sample every source's presence ONCE per pass into a uniform map, so
        // recency, the decision, and the debounce all read the same snapshot and
        // no source is special-cased downstream. `active` = has a session
        // (playing OR paused); `playing` = genuinely playing.
        var presence: [SourceID: SourcePresence] = [
            .jellyfin: SourcePresence(
                active: player.jellyfinHasNowPlaying,
                playing: player.jellyfinIsPlaying
            )
        ]
        for (id, feed) in registry.feeds {
            let ext = feed.latest ?? .idle
            presence[id] = SourcePresence(active: ext.active, playing: ext.active && !ext.isPaused)
        }

        // Record each source's activation edge (idle→active). A change *while
        // already active* (auto-advance) does not re-activate, so it can't win the
        // tie-break and steal the overlay. The registry's stable id order decides
        // same-pass ties.
        recency.observe(presence, order: registry.registeredIDs)

        // A pin to a source that isn't currently registered (e.g. an uninstalled
        // plugin) degrades to `.auto` for *this decision* — without rewriting the
        // stored preference, so a returning plugin restores the pin (see
        // `effectiveSelection`).
        let selection = effectiveSelection()
        let desired = Self.decide(
            selection: selection,
            presence: presence,
            recency: recency,
            homePriority: registry.homePriority,
            tiePriority: registry.tiePriority,
            current: activeKind
        )
        let kind = debounced(desired, presence: presence, forced: selection.forcedKind != nil)
        let didFlip = applyKind(kind)

        // Pick up a live capability change without a restart: when a loopback
        // source *reconnects* (its feed goes idle→active, e.g. after a rebuild /
        // reinstall) while it is already the active source and no flip happened
        // this pass, re-read its `/health`. A flip already refreshes (inside
        // `applyKind`), so this only fires for the no-flip reconnect, where
        // capabilities would otherwise stay cached until the next flip.
        if kind != .jellyfin, registry.feeds[kind] != nil,
           Self.shouldRefreshOnReconnect(
               sourceActive: presence[kind]?.active ?? false,
               sourceWasActive: previousActive[kind] ?? false,
               didFlip: didFlip,
               isActiveSource: true
           ) {
            refreshCapabilities(for: kind)
        }
        for (id, sourcePresence) in presence { previousActive[id] = sourcePresence.active }

        // Publish the winning loopback source's snapshot only when its own poll
        // (or a selection change / initial pass) is the fresh trigger — Jellyfin
        // writes its own state through `ingest`, and another source's *steady-state*
        // tick shouldn't republish this one. The exception is a Jellyfin tick that
        // *flips us onto* a loopback source (e.g. Jellyfin stops while a parked
        // YouTube is revealed): publish its already-in-hand snapshot on that same
        // pass so the overlay repaints instantly, mirroring the Jellyfin arm's
        // `coordinator.forceRefresh()`. Otherwise the cover would lag the menu's
        // `activeKind` + the command sink by up to one poll (~1 s).
        //
        // Always publish as `.connected`, never `.idle`: `.idle` is Jellyfin's
        // "not configured" state and the overlay renders it as the "Configure your
        // Jellyfin server" prompt. When a loopback source is active but has
        // nothing playing, we want the ambient "nothing playing" view
        // (`.connected` + no track), not a false Jellyfin-misconfiguration alarm.
        if kind != .jellyfin, let feed = registry.feeds[kind] {
            let publish: Bool
            switch trigger {
            case .loopback(let id): publish = (id == kind)
            case .selection, .initial: publish = true
            case .jellyfin: publish = didFlip   // flip TO this loopback source → repaint now
            }
            if publish {
                let ext = feed.latest ?? .idle
                player.applyExternalSnapshot(
                    track: ext.track,
                    isPaused: ext.isPaused,
                    volume: ext.volume,
                    connection: .connected
                )
            }
        }
    }

    /// The stored selection, demoted to `.auto` when it pins a source the registry
    /// doesn't currently know about. Non-destructive: the persisted value is left
    /// untouched, so reinstalling the plugin transparently restores the pin.
    private func effectiveSelection() -> SourceSelection {
        let selection = settings.sourceSelection
        if let forced = selection.forcedKind, !registry.registeredIDs.contains(forced) {
            return .auto
        }
        return selection
    }

    /// Pure decision policy (extracted for testing), generalized over an arbitrary
    /// set of sources keyed by `SourceID`. In order:
    /// 1. A forced selection wins outright.
    /// 2. Exactly one source genuinely *playing* → it wins (over any idle/paused
    ///    others). Resolves the common "Jellyfin parked while YouTube plays".
    /// 3. Several playing → most-recently-*activated* (the source the user started
    ///    last); auto-advance can't steal because it never re-activates. A
    ///    same-tick tie breaks by `tiePriority`.
    /// 4. None playing → "sticky pause": keep the current source while it still has
    ///    a (paused) session, so pausing what you're using doesn't hand the overlay
    ///    to a source merely parked in the background. Only once the current source
    ///    goes fully idle (stopped / closed) do we reveal the first source in
    ///    `homePriority` that has a session — so *stopping* the active source still
    ///    surfaces the home source.
    /// 5. With nothing active anywhere, fall back to the first source in
    ///    `homePriority` — never park on a dead source (see the return site).
    static func decide(
        selection: SourceSelection,
        presence: [SourceID: SourcePresence],
        recency: ActivationRecency,
        homePriority: [SourceID],
        tiePriority: [SourceID],
        current: SourceID
    ) -> SourceID {
        if let forced = selection.forcedKind { return forced }

        let playing = presence.keys.filter { presence[$0]?.playing == true }
        if playing.count == 1 { return playing[0] }
        if playing.count > 1 {
            // Highest activation rank wins; an equal-rank tie breaks by
            // `tiePriority`. The (rank, tieIndex) ordering is total, so the winner
            // is unambiguous regardless of which equal element `max` would return.
            if let best = playing.max(by: { a, b in
                let ra = recency.rank(of: a), rb = recency.rank(of: b)
                return ra != rb
                    ? ra < rb
                    : Self.tieIndex(a, tiePriority) > Self.tieIndex(b, tiePriority)
            }) {
                return best
            }
        }

        // None playing. "Sticky pause": keep the current source while it still has
        // a (paused) session, so pausing what you're actually using never hands the
        // overlay to a source merely parked in the background (the reported bug:
        // pausing YouTube while a long-paused Jellyfin session lingers made the
        // Jellyfin cover hijack the overlay). Only once the current source goes
        // fully idle (stopped / tab closed) do we reveal the first present source in
        // the home order — so *stopping* YouTube still surfaces a parked Jellyfin.
        if presence[current]?.active == true { return current }
        for kind in homePriority where presence[kind]?.active == true {
            return kind
        }
        // Nothing active anywhere → return home (`homePriority` first) rather
        // than holding the current source. Parking on a dead loopback source
        // kept `jellyfinIsActiveSource` false until a relaunch, muting
        // Jellyfin's real `.reconnecting`/`.error` states behind a stale
        // ambient `.connected` (quit Safari away from home → the overlay lies
        // "connected"). Going home reopens the gate so the overlay reports the
        // home transport's truth: real ambient when reachable, offline when
        // not. A merely-paused source never lands here — it is still `active`,
        // so the sticky-pause rule above keeps it.
        return homePriority.first ?? current
    }

    /// Position of `kind` in `order`, or `.max` when absent (sorts last).
    private static func tieIndex(_ kind: SourceID, _ order: [SourceID]) -> Int {
        order.firstIndex(of: kind) ?? .max
    }

    /// Damp a tie-break flip (both sources active) that lands within the debounce
    /// window of the last flip, so two simultaneously-active sources can't
    /// oscillate. A forced selection, or the current source going idle, flips
    /// immediately — the window only guards the both-active ambiguity. Reads
    /// `currentStillActive` from the same per-pass presence map, so no source is
    /// special-cased here either. Delegates to the pure `Self.debounced` core.
    private func debounced(_ desired: SourceID, presence: [SourceID: SourcePresence], forced: Bool) -> SourceID {
        Self.debounced(
            desired: desired,
            current: activeKind,
            currentStillActive: presence[activeKind]?.active ?? false,
            forced: forced,
            lastFlipAt: lastFlipAt,
            now: Date(),
            flipDebounce: Self.flipDebounce
        )
    }

    /// Pure flip-debounce policy (extracted for testing), mirroring `decide` /
    /// `shouldRefreshOnReconnect`. In order:
    /// 1. `desired == current` → nothing to flip; return it.
    /// 2. A forced selection flips immediately (the window only guards `auto`).
    /// 3. The current source going idle (`currentStillActive == false`) flips
    ///    immediately — there is no both-active ambiguity to damp.
    /// 4. Otherwise (both active) a flip within `flipDebounce` of `lastFlipAt`
    ///    holds `current` to avoid flapping; once the window has elapsed it flips
    ///    to `desired`. `now` is injected so this boundary is deterministic in
    ///    tests (no wall-clock read).
    static func debounced(
        desired: SourceID,
        current: SourceID,
        currentStillActive: Bool,
        forced: Bool,
        lastFlipAt: Date,
        now: Date,
        flipDebounce: TimeInterval
    ) -> SourceID {
        guard desired != current else { return desired }
        if forced { return desired }
        guard currentStillActive else { return desired }   // current went idle → flip now
        if now.timeIntervalSince(lastFlipAt) < flipDebounce {
            return current                                 // hold to avoid flapping
        }
        return desired
    }

    /// Apply the resolved source. Returns `true` if this was an actual flip (the
    /// active source changed), so the caller can tell a flip-driven capability
    /// refresh apart from a reconnect-driven one.
    @discardableResult
    private func applyKind(_ kind: SourceID) -> Bool {
        // Gate Jellyfin's writes to the shared state on every pass (idempotent),
        // so the flag always tracks the resolved source.
        player.jellyfinIsActiveSource = (kind == .jellyfin)

        guard kind != activeKind else { return false }
        Self.logger.notice("Source flip: \(self.activeKind.rawValue, privacy: .public) → \(kind.rawValue, privacy: .public)")
        activeKind = kind
        lastFlipAt = Date()

        if kind == .jellyfin {
            // Drop the loopback sink; the per-session Jellyfin sink is rebuilt on
            // the next `ingest`. Nudge a refresh so the overlay repopulates fast.
            player.setCommandSink(nil, capabilities: .jellyfin)
            coordinator.forceRefresh()
        } else if let client = registry.clients[kind], let feed = registry.feeds[kind] {
            player.setCommandSink(client, capabilities: feed.capabilities)
            refreshCapabilities(for: kind)
        }
        // (No `else`: an unknown id can't win — `decide`/`debounced` only ever
        // return a registered id or the current one.)
        return true
    }

    /// Whether to re-read a loopback source's `/health` on this pass because it
    /// just *reconnected*: it went idle→active (`sourceActive && !sourceWasActive`)
    /// while it is the active source (`isActiveSource`) and we did **not** flip
    /// this pass (`!didFlip` — a flip refreshes on its own). This is what lets a
    /// live source update (a rebuild advertising a new capability) land without
    /// restarting JellyBeat. Pure + unit-tested like `decide`.
    static func shouldRefreshOnReconnect(
        sourceActive: Bool,
        sourceWasActive: Bool,
        didFlip: Bool,
        isActiveSource: Bool
    ) -> Bool {
        sourceActive && !sourceWasActive && !didFlip && isActiveSource
    }

    /// Read a loopback source's self-described capabilities and apply them if that
    /// source is still the active one when the read returns.
    private func refreshCapabilities(for id: SourceID) {
        guard let client = registry.clients[id], let feed = registry.feeds[id] else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let caps = await client.fetchCapabilities()
            feed.applyCapabilities(caps)
            guard self.activeKind == id else { return }
            self.player.setCommandSink(client, capabilities: caps)
            Self.logger.debug("Loopback source \(id.rawValue, privacy: .public) capabilities refreshed (canFocusTab=\(caps.canFocusTab, privacy: .public))")
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

/// Uniform per-source presence, sampled once per arbitration pass so the decision
/// logic never special-cases a particular backend. `playing` implies `active`.
nonisolated struct SourcePresence: Equatable, Sendable {
    /// The source has a now-playing item — playing OR paused.
    let active: Bool
    /// The source is genuinely playing (active and not paused).
    let playing: Bool
}

/// Tracks which source was most-recently *activated* — the idle→active edge, i.e.
/// the moment the user started it. This is the signal the arbiter's both-active
/// tie-break consumes. Generalized over an arbitrary set of sources keyed by
/// `SourceID`, so adding a source needs no new fields here.
///
/// The crucial property: a source that stays *continuously* active never
/// re-activates, so its rank doesn't move. A background Jellyfin playlist
/// auto-advancing (or a YouTube video rolling into the next) keeps the source
/// active throughout and therefore cannot out-rank — cannot steal the overlay
/// from — whatever the user is actually watching. Only a fresh idle→active
/// transition (a deliberate "start this source") bumps the rank.
///
/// Ordering is a monotonic tick rather than wall-clock, so it's deterministic and
/// immune to clock skew / equal-timestamp ties.
nonisolated struct ActivationRecency: Equatable, Sendable {
    private var lastActive: [SourceID: Bool] = [:]
    private var rank: [SourceID: Int] = [:]
    private var tick = 0

    /// Feed the current presence of every source, in a caller-provided `order`.
    /// Stamps a fresh, higher rank on each source that crossed an idle→active edge
    /// since the last call.
    ///
    /// `order` MUST be a stable, deterministic sequence (the registry's
    /// registered-id order, built-ins first) — it decides which simultaneously-
    /// started source gets the lower tick on a same-pass double activation, so a
    /// reorder changes the tie outcome. Never pass `presence.keys` (unordered).
    mutating func observe(_ presence: [SourceID: SourcePresence], order: [SourceID]) {
        for kind in order {
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
    func rank(of kind: SourceID) -> Int { rank[kind] ?? 0 }
}
