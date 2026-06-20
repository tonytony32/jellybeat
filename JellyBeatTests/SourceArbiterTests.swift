import Foundation
import Testing
@testable import JellyBeat

/// Tests for the arbiter's pure decision policy (`SourceArbiter.decide`), the
/// generalized `ActivationRecency`, and the loopback source → normalized snapshot
/// mapping (`LoopbackSourceFeed.map`).
struct SourceArbiterTests {

    // MARK: - Helpers

    /// Build the per-source presence map the arbiter samples each pass.
    private func presence(
        yt: SourcePresence,
        jf: SourcePresence
    ) -> [SourceKind: SourcePresence] {
        [.youtube: yt, .jellyfin: jf]
    }

    /// Feed an activeness edge for both sources (presence only cares about
    /// `active` for recency, so `playing` is left false here).
    private func observe(_ r: inout ActivationRecency, yt: Bool, jf: Bool) {
        r.observe([
            .youtube: SourcePresence(active: yt, playing: false),
            .jellyfin: SourcePresence(active: jf, playing: false),
        ], order: [.jellyfin, .youtube])
    }

    /// True when YouTube activated no earlier than Jellyfin — the property the
    /// pre-generalization tie-break consumed, re-expressed over the rank API.
    private func ytNoOlderThanJf(_ r: ActivationRecency) -> Bool {
        r.rank(of: .youtube) >= r.rank(of: .jellyfin)
    }

    /// A recency whose ranks realize a given tie direction, via strict
    /// idle→active edges (so the resulting ranks are unequal and deterministic).
    private func recency(ytNoOlderThanJf: Bool) -> ActivationRecency {
        var r = ActivationRecency()
        if ytNoOlderThanJf {
            observe(&r, yt: false, jf: true)   // Jellyfin first  → rank 1
            observe(&r, yt: true, jf: true)    // YouTube later   → rank 2 (> Jellyfin)
        } else {
            observe(&r, yt: true, jf: false)   // YouTube first   → rank 1
            observe(&r, yt: true, jf: true)    // Jellyfin later  → rank 2 (> YouTube)
        }
        return r
    }

    /// The built-in priority orderings. A registry with only the two built-ins
    /// yields exactly these (pinned by `SourceRegistryTests`); `decide` is a pure
    /// function over them, so these tests supply them directly.
    private let homePriority: [SourceID] = [.jellyfin, .youtube]
    private let tiePriority: [SourceID] = [.youtube, .jellyfin]

    /// Run `decide` with the built-in priority orderings.
    private func autoDecide(
        _ presence: [SourceKind: SourcePresence],
        recency: ActivationRecency = ActivationRecency(),
        current: SourceKind
    ) -> SourceKind {
        SourceArbiter.decide(
            selection: .auto, presence: presence, recency: recency,
            homePriority: homePriority,
            tiePriority: tiePriority,
            current: current
        )
    }

    /// The pre-generalization decision policy, reproduced verbatim as an
    /// independent oracle so `decideGeneralizedMatchesLegacy` can prove the new
    /// generalized core is a faithful two-source projection of the old one.
    private static func legacyDecide(
        selection: SourceSelection,
        ytPlaying: Bool, ytActive: Bool,
        jfPlaying: Bool, jfActive: Bool,
        ytActivatedNoOlderThanJf: Bool,
        current: SourceKind
    ) -> SourceKind {
        if let forced = selection.forcedKind { return forced }
        if ytPlaying && !jfPlaying { return .youtube }
        if jfPlaying && !ytPlaying { return .jellyfin }
        if ytPlaying && jfPlaying { return ytActivatedNoOlderThanJf ? .youtube : .jellyfin }
        if jfActive { return .jellyfin }
        if ytActive { return .youtube }
        return current
    }

    // MARK: - Decision policy

    /// A forced selection wins regardless of which sources are active.
    @Test
    func forcedSelectionWinsOutright() {
        let p = presence(
            yt: SourcePresence(active: true, playing: true),
            jf: SourcePresence(active: false, playing: false)
        )
        #expect(SourceArbiter.decide(
            selection: .jellyfin, presence: p, recency: ActivationRecency(),
            homePriority: homePriority, tiePriority: tiePriority,
            current: .youtube
        ) == .jellyfin)

        let q = presence(
            yt: SourcePresence(active: false, playing: false),
            jf: SourcePresence(active: true, playing: true)
        )
        #expect(SourceArbiter.decide(
            selection: .youtube, presence: q, recency: ActivationRecency(),
            homePriority: homePriority, tiePriority: tiePriority,
            current: .jellyfin
        ) == .youtube)
    }

    /// In auto, the single active source drives.
    @Test
    func autoPicksTheActiveSource() {
        #expect(autoDecide(
            presence(yt: SourcePresence(active: true, playing: true),
                     jf: SourcePresence(active: false, playing: false)),
            current: .jellyfin
        ) == .youtube)

        #expect(autoDecide(
            presence(yt: SourcePresence(active: false, playing: false),
                     jf: SourcePresence(active: true, playing: true)),
            current: .youtube
        ) == .jellyfin)
    }

    /// A genuinely playing source beats one that is active but paused — even when
    /// the paused one activated more recently (so the tie-break alone would pick
    /// it). This is THE fix for "YouTube is playing but the overlay stays on a
    /// paused Jellyfin".
    @Test
    func autoPrefersPlayingOverPaused() {
        // YouTube playing, Jellyfin present but paused & activated later.
        #expect(autoDecide(
            presence(yt: SourcePresence(active: true, playing: true),
                     jf: SourcePresence(active: true, playing: false)),
            recency: recency(ytNoOlderThanJf: false),
            current: .jellyfin
        ) == .youtube)

        // YouTube paused, Jellyfin playing.
        #expect(autoDecide(
            presence(yt: SourcePresence(active: true, playing: false),
                     jf: SourcePresence(active: true, playing: true)),
            recency: recency(ytNoOlderThanJf: true),
            current: .youtube
        ) == .jellyfin)
    }

    /// In auto with both genuinely playing, the most-recently-*activated* source
    /// wins (the one the user started last).
    @Test
    func autoBreaksTiesByActivationRecency() {
        let both = presence(
            yt: SourcePresence(active: true, playing: true),
            jf: SourcePresence(active: true, playing: true)
        )
        #expect(autoDecide(both, recency: recency(ytNoOlderThanJf: true), current: .jellyfin) == .youtube)
        #expect(autoDecide(both, recency: recency(ytNoOlderThanJf: false), current: .youtube) == .jellyfin)
    }

    /// With neither active, the current source is kept (no spurious flip).
    @Test
    func autoKeepsCurrentWhenNeitherActive() {
        let none = presence(
            yt: SourcePresence(active: false, playing: false),
            jf: SourcePresence(active: false, playing: false)
        )
        #expect(autoDecide(none, current: .youtube) == .youtube)
        #expect(autoDecide(none, current: .jellyfin) == .jellyfin)
    }

    /// Neither source playing → fall back to Jellyfin (the home source) when it
    /// has a session, so pausing/stopping YouTube reveals Jellyfin instead of
    /// lingering on a paused YouTube. With no Jellyfin session, a paused YouTube
    /// keeps the overlay.
    @Test
    func autoFallsBackToJellyfinWhenNeitherPlaying() {
        // Both paused → home (Jellyfin) wins even though YouTube activated later.
        #expect(autoDecide(
            presence(yt: SourcePresence(active: true, playing: false),
                     jf: SourcePresence(active: true, playing: false)),
            recency: recency(ytNoOlderThanJf: true),
            current: .youtube
        ) == .jellyfin)

        // YouTube paused, no Jellyfin session → YouTube holds the overlay.
        #expect(autoDecide(
            presence(yt: SourcePresence(active: true, playing: false),
                     jf: SourcePresence(active: false, playing: false)),
            recency: recency(ytNoOlderThanJf: true),
            current: .youtube
        ) == .youtube)
    }

    /// The neither-playing "home" fallback is data, not hardcoded: flipping
    /// `homePriority` flips which present-but-idle source the overlay reveals.
    @Test
    func homePriorityIsConfigurable() {
        let bothPaused = presence(
            yt: SourcePresence(active: true, playing: false),
            jf: SourcePresence(active: true, playing: false)
        )
        #expect(SourceArbiter.decide(
            selection: .auto, presence: bothPaused, recency: ActivationRecency(),
            homePriority: [.jellyfin, .youtube], tiePriority: tiePriority,
            current: .youtube
        ) == .jellyfin)
        #expect(SourceArbiter.decide(
            selection: .auto, presence: bothPaused, recency: ActivationRecency(),
            homePriority: [.youtube, .jellyfin], tiePriority: tiePriority,
            current: .youtube
        ) == .youtube)
    }

    /// The both-playing tie direction is data too: with equal activation rank
    /// (a fresh recency), the winner is purely `tiePriority`. Pins YouTube-on-tie
    /// as the production choice.
    @Test
    func tiePriorityIsConfigurable() {
        let bothPlaying = presence(
            yt: SourcePresence(active: true, playing: true),
            jf: SourcePresence(active: true, playing: true)
        )
        #expect(SourceArbiter.decide(
            selection: .auto, presence: bothPlaying, recency: ActivationRecency(),
            homePriority: homePriority, tiePriority: [.youtube, .jellyfin],
            current: .jellyfin
        ) == .youtube)
        #expect(SourceArbiter.decide(
            selection: .auto, presence: bothPlaying, recency: ActivationRecency(),
            homePriority: homePriority, tiePriority: [.jellyfin, .youtube],
            current: .youtube
        ) == .jellyfin)
    }

    /// The generalized `decide` is a faithful two-source projection of the
    /// pre-generalization policy: across the grid of (active/playing) states ×
    /// tie direction × current source — all with *unequal* activation ranks — it
    /// agrees with the legacy oracle. The equal-rank tie (where the deliberate
    /// same-pass divergence lives) is pinned separately by `tiePriorityIsConfigurable`
    /// and `samePassDoubleActivationFavorsYouTube`.
    @Test
    func decideGeneralizedMatchesLegacy() {
        let bools = [false, true]
        for ytActive in bools {
            for ytPlaying in bools where !(ytPlaying && !ytActive) {
                for jfActive in bools {
                    for jfPlaying in bools where !(jfPlaying && !jfActive) {
                        for ytNewer in bools {
                            for current in [SourceKind.youtube, .jellyfin] {
                                let got = autoDecide(
                                    presence(
                                        yt: SourcePresence(active: ytActive, playing: ytPlaying),
                                        jf: SourcePresence(active: jfActive, playing: jfPlaying)),
                                    recency: recency(ytNoOlderThanJf: ytNewer),
                                    current: current)
                                let want = Self.legacyDecide(
                                    selection: .auto,
                                    ytPlaying: ytPlaying, ytActive: ytActive,
                                    jfPlaying: jfPlaying, jfActive: jfActive,
                                    ytActivatedNoOlderThanJf: ytNewer, current: current)
                                #expect(
                                    got == want,
                                    "mismatch ytA=\(ytActive) ytP=\(ytPlaying) jfA=\(jfActive) jfP=\(jfPlaying) ytNewer=\(ytNewer) current=\(current): got \(got), want \(want)")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Activation recency (auto-advance must not steal focus)

    /// The source that activated last wins the tie. Starting YouTube after
    /// Jellyfin makes YouTube rank higher.
    @Test
    func recencyRanksLastActivatedSource() {
        var r = ActivationRecency()
        observe(&r, yt: false, jf: true)         // Jellyfin starts
        #expect(ytNoOlderThanJf(r) == false)     // Jellyfin newer → it wins
        observe(&r, yt: true, jf: true)          // YouTube starts later
        #expect(ytNoOlderThanJf(r) == true)      // YouTube newer → it wins
    }

    /// THE auto-advance guard: once YouTube is the active winner, a Jellyfin
    /// playlist auto-advancing in the background (Jellyfin stays continuously
    /// active across the track change) must NOT bump Jellyfin's rank, so
    /// YouTube keeps the overlay.
    @Test
    func autoAdvanceDoesNotStealFocus() {
        var r = ActivationRecency()
        observe(&r, yt: false, jf: true)         // Jellyfin playing
        observe(&r, yt: true, jf: true)          // user starts YouTube → YT wins
        #expect(ytNoOlderThanJf(r) == true)

        // Jellyfin auto-advances several times — never goes idle, just keeps
        // playing the next track. Rank must not move.
        for _ in 0..<5 {
            observe(&r, yt: true, jf: true)
            #expect(ytNoOlderThanJf(r) == true)  // YouTube still wins
        }
    }

    /// The continuous-active property at the rank level (generalized
    /// auto-advance guard): a source held active across many passes keeps its
    /// exact rank while a later activation out-ranks it. With a 3rd `SourceKind`
    /// this extends unchanged — `observe` iterates `allCases`.
    @Test
    func recencyContinuousActiveDoesNotReRank() {
        var r = ActivationRecency()
        observe(&r, yt: false, jf: true)         // Jellyfin → rank 1
        observe(&r, yt: true, jf: true)          // YouTube  → rank 2
        let jfRank = r.rank(of: .jellyfin)
        let ytRank = r.rank(of: .youtube)
        #expect(ytRank > jfRank)

        for _ in 0..<5 { observe(&r, yt: true, jf: true) }   // both stay active
        #expect(r.rank(of: .jellyfin) == jfRank)             // unchanged
        #expect(r.rank(of: .youtube) == ytRank)              // unchanged
    }

    /// A genuine restart — Jellyfin goes idle, then active again — IS a fresh
    /// activation and does reclaim the tie (deliberate intent still works).
    @Test
    func restartReactivatesAndReclaims() {
        var r = ActivationRecency()
        observe(&r, yt: false, jf: true)
        observe(&r, yt: true, jf: true)          // YouTube wins
        #expect(ytNoOlderThanJf(r) == true)

        observe(&r, yt: true, jf: false)         // Jellyfin stops
        observe(&r, yt: true, jf: true)          // Jellyfin started again
        #expect(ytNoOlderThanJf(r) == false)     // Jellyfin reclaims
    }

    /// When both sources cross idle→active in the *same* pass, the deterministic
    /// observe `order` (the registry's id order — here [.jellyfin, .youtube])
    /// gives Jellyfin the lower tick and YouTube the higher — so YouTube
    /// out-ranks, consistent with `tiePriority` favoring YouTube. (The
    /// pre-generalization code's check order happened to favor Jellyfin in this
    /// edge case; the generalized code aligns it with the documented tie direction.)
    @Test
    func samePassDoubleActivationFavorsYouTube() {
        var r = ActivationRecency()
        observe(&r, yt: true, jf: true)          // both activate at once
        #expect(r.rank(of: .youtube) > r.rank(of: .jellyfin))

        let both = presence(
            yt: SourcePresence(active: true, playing: true),
            jf: SourcePresence(active: true, playing: true)
        )
        #expect(autoDecide(both, recency: r, current: .jellyfin) == .youtube)
    }

    // MARK: - Live capability refresh on reconnect

    /// A loopback source reconnecting (idle→active) while it is the active source
    /// and no flip happened triggers a live `/health` re-read — so a rebuilt
    /// source advertising a new capability lands without a JellyBeat restart.
    @Test
    func refreshesCapabilitiesOnReconnect() {
        #expect(SourceArbiter.shouldRefreshOnReconnect(
            sourceActive: true, sourceWasActive: false, didFlip: false, isActiveSource: true
        ) == true)
    }

    /// It must NOT refresh in the cases the reconnect rule deliberately excludes.
    @Test
    func doesNotRefreshOutsideReconnectEdge() {
        // Already active (no idle→active edge) — avoids re-fetching every poll.
        #expect(SourceArbiter.shouldRefreshOnReconnect(
            sourceActive: true, sourceWasActive: true, didFlip: false, isActiveSource: true
        ) == false)
        // A flip this pass already refreshed — don't double-fetch.
        #expect(SourceArbiter.shouldRefreshOnReconnect(
            sourceActive: true, sourceWasActive: false, didFlip: true, isActiveSource: true
        ) == false)
        // Not the active source — its capabilities aren't in play.
        #expect(SourceArbiter.shouldRefreshOnReconnect(
            sourceActive: true, sourceWasActive: false, didFlip: false, isActiveSource: false
        ) == false)
        // Going idle (active→idle), not reconnecting.
        #expect(SourceArbiter.shouldRefreshOnReconnect(
            sourceActive: false, sourceWasActive: true, didFlip: false, isActiveSource: true
        ) == false)
    }

    // MARK: - Flip debounce (pure core)

    /// A fixed epoch + window so the `now - lastFlipAt` boundary in branch (d) is
    /// exact and deterministic (no wall-clock read).
    private let flipDebounce: TimeInterval = 1.0
    private let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// (a) When the desired source already equals the current one there is
    /// nothing to debounce — it short-circuits and returns immediately, even
    /// inside the window with a non-forced both-active state.
    @Test
    func debouncedShortCircuitsWhenDesiredEqualsCurrent() {
        #expect(SourceArbiter.debounced(
            desired: .youtube, current: .youtube, currentStillActive: true,
            forced: false, lastFlipAt: epoch, now: epoch.addingTimeInterval(0.1),
            flipDebounce: flipDebounce
        ) == .youtube)
    }

    /// (b) A forced selection flips immediately, even within the debounce window
    /// — the window only guards the auto both-active tie-break.
    @Test
    func debouncedForcedFlipsImmediatelyInsideWindow() {
        #expect(SourceArbiter.debounced(
            desired: .youtube, current: .jellyfin, currentStillActive: true,
            forced: true, lastFlipAt: epoch, now: epoch.addingTimeInterval(0.1),
            flipDebounce: flipDebounce
        ) == .youtube)
    }

    /// (c) When the current source has gone idle (`currentStillActive == false`)
    /// there is no both-active ambiguity to damp, so it flips to a different
    /// desired source immediately even inside the window. This is the
    /// `autoRevealsHomeWhenCurrentSourceStops` path — stopping the active source
    /// reveals another straight away rather than holding a dead cover.
    @Test
    func debouncedFlipsImmediatelyWhenCurrentWentIdle() {
        #expect(SourceArbiter.debounced(
            desired: .jellyfin, current: .youtube, currentStillActive: false,
            forced: false, lastFlipAt: epoch, now: epoch.addingTimeInterval(0.1),
            flipDebounce: flipDebounce
        ) == .jellyfin)
    }

    /// (d) The both-active tie-break: a flip landing strictly inside the debounce
    /// window holds the current source (anti-flap); the same flip once the window
    /// has elapsed (`now - lastFlipAt >= flipDebounce`) goes through to the
    /// desired source. `now` is supplied so the boundary is exact.
    @Test
    func debouncedHoldsInsideWindowAndFlipsAfter() {
        // Inside the window (0.5 s < 1.0 s) → hold current.
        #expect(SourceArbiter.debounced(
            desired: .youtube, current: .jellyfin, currentStillActive: true,
            forced: false, lastFlipAt: epoch, now: epoch.addingTimeInterval(0.5),
            flipDebounce: flipDebounce
        ) == .jellyfin)

        // At the window boundary (1.0 s, not < 1.0 s) → flip to desired.
        #expect(SourceArbiter.debounced(
            desired: .youtube, current: .jellyfin, currentStillActive: true,
            forced: false, lastFlipAt: epoch, now: epoch.addingTimeInterval(1.0),
            flipDebounce: flipDebounce
        ) == .youtube)

        // Well past the window → flip to desired.
        #expect(SourceArbiter.debounced(
            desired: .youtube, current: .jellyfin, currentStillActive: true,
            forced: false, lastFlipAt: epoch, now: epoch.addingTimeInterval(5.0),
            flipDebounce: flipDebounce
        ) == .youtube)
    }

    // MARK: - Bridge → normalized mapping

    private func snapshot(
        active: Bool = true,
        state: String? = "playing",
        title: String? = "Song",
        artist: String? = "Channel",
        album: String? = nil,
        durationSec: Double? = 240,
        positionSec: Double? = 30,
        videoId: String? = "abc123",
        artworkUrl: String? = "https://i.ytimg.com/vi/abc123/hq.jpg",
        volume: Double? = 0.8,
        liked: Bool? = nil
    ) -> BridgeSnapshot {
        BridgeSnapshot(
            active: active, source: "youtube_music", state: state, title: title,
            artist: artist, album: album, durationSec: durationSec,
            positionSec: positionSec, videoId: videoId, artworkUrl: artworkUrl,
            volume: volume, liked: liked, updatedAtMs: 1
        )
    }

    /// A playing snapshot maps every field across; volume rounds 0–1 → 0–100.
    @Test
    func mapsPlayingSnapshot() {
        let mapped = LoopbackSourceFeed.map(snapshot())
        #expect(mapped.active)
        #expect(mapped.isPaused == false)
        #expect(mapped.volume == 80)
        let track = mapped.track
        #expect(track?.itemId == "abc123")
        #expect(track?.title == "Song")
        #expect(track?.artist == "Channel")
        #expect(track?.runtime == .seconds(240))
        #expect(track?.position == .seconds(30))
        #expect(track?.artworkURL?.absoluteString == "https://i.ytimg.com/vi/abc123/hq.jpg")
    }

    /// The source's `liked` drives the favorite (thumbs-up) state: true → favorited,
    /// and a missing/unknown `liked` is a safe `false`.
    @Test
    func mapsLikedState() {
        #expect(LoopbackSourceFeed.map(snapshot(liked: true)).track?.isFavorite == true)
        #expect(LoopbackSourceFeed.map(snapshot(liked: false)).track?.isFavorite == false)
        #expect(LoopbackSourceFeed.map(snapshot(liked: nil)).track?.isFavorite == false)
    }

    /// `state == "paused"` maps to `isPaused`.
    @Test
    func mapsPausedState() {
        let mapped = LoopbackSourceFeed.map(snapshot(state: "paused"))
        #expect(mapped.isPaused == true)
        #expect(mapped.active)
    }

    /// A nil snapshot (idle / unreachable) and an `active: false` body both
    /// normalize to idle.
    @Test
    func mapsIdle() {
        #expect(LoopbackSourceFeed.map(nil) == .idle)
        #expect(LoopbackSourceFeed.map(snapshot(active: false)) == .idle)
    }

    /// A non-http(s) artwork URL (e.g. `file://`) from an untrusted local source
    /// must be rejected so the artwork loader can't be turned into a file read.
    @Test
    func rejectsNonHttpArtworkURL() {
        let fileScheme = LoopbackSourceFeed.map(snapshot(artworkUrl: "file:///etc/passwd"))
        #expect(fileScheme.track?.artworkURL == nil)

        let httpsScheme = LoopbackSourceFeed.map(snapshot(artworkUrl: "https://i.ytimg.com/x.jpg"))
        #expect(httpsScheme.track?.artworkURL?.absoluteString == "https://i.ytimg.com/x.jpg")
    }

    /// A null `durationSec` (livestream / unknown) maps to a zero runtime.
    @Test
    func nullDurationMapsToZeroRuntime() {
        let mapped = LoopbackSourceFeed.map(snapshot(durationSec: nil))
        #expect(mapped.track?.runtime == .zero)
    }

    /// A missing `videoId` falls back to a stable id so the overlay's artwork /
    /// track-change smoothing doesn't thrash between polls.
    @Test
    func missingVideoIdUsesStableFallback() {
        let a = LoopbackSourceFeed.map(snapshot(videoId: nil))
        let b = LoopbackSourceFeed.map(snapshot(videoId: nil))
        #expect(a.track?.itemId == b.track?.itemId)
        #expect(a.track?.itemId.isEmpty == false)
    }

    // MARK: - Unit conversions

    /// Seconds round-trip through `Duration` for the bridge's second-based units.
    @Test
    func durationSecondsConversion() {
        #expect(Duration.seconds(12.5).seconds == 12.5)
        #expect(Duration.seconds(0).seconds == 0)
    }

    /// Jellyfin position ticks are 100-ns units.
    @Test
    func durationJellyfinTicks() {
        #expect(Duration.seconds(1).jellyfinTicks == 10_000_000)
        #expect(Duration.seconds(2.5).jellyfinTicks == 25_000_000)
    }
}

/// Integration coverage that drives the *real* `SourceArbiter.reevaluate`
/// pipeline (presence → recency → decide → debounce → publish) through the public
/// entry points — `activate()`, `PlayerStore.ingest`, and the source selection —
/// rather than only the pure `decide` / `debounced` cores. This catches wiring
/// regressions the unit tests can't: a mis-wired `current`, a decide/debounce
/// reorder, or a publish that shows the `.idle` "Configure your Jellyfin server"
/// prompt instead of the ambient loopback view.
///
/// The arbiter is built exactly as `AppDelegate` builds it, but over a throwaway
/// `UserDefaults` suite with **no** Jellyfin server configured, so the coordinator
/// stays `.idle` with no network, and the built-in YouTube feed polls a dead port
/// (always idle). Jellyfin presence is injected through `PlayerStore.ingest`, the
/// same path the live transport uses. Each test stays synchronous from
/// `activate()` through its assertions, so the feeds' background poll tasks (which
/// only run at a suspension point) can't interleave and every assertion is
/// deterministic.
@MainActor
struct SourceArbiterIntegrationTests {
    private static let userId = "user-1"

    private struct Env {
        let arbiter: SourceArbiter
        let player: PlayerStore
        let settings: SettingsStore
        let suiteName: String
    }

    private func makeEnv(selection: SourceSelection = .auto) -> Env {
        let suiteName = "test.arbiter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = SettingsStore(defaults: defaults, keychain: InMemoryKeychain())
        settings.sourceSelection = selection                 // before activate(): no observation yet
        let player = PlayerStore(defaults: defaults)
        let coordinator = PlaybackConnectionCoordinator(
            settings: settings, player: player, artworkProvider: ArtworkCacheProvider()
        )
        // `manifests: []` yields exactly the built-ins — Jellyfin + the YouTube
        // loopback feed — the same shape AppDelegate gets with no plugins installed.
        let arbiter = SourceArbiter(
            settings: settings, player: player,
            coordinator: coordinator, registry: SourceRegistry(manifests: [])
        )
        return Env(arbiter: arbiter, player: player, settings: settings, suiteName: suiteName)
    }

    private func tearDown(_ env: Env) {
        env.arbiter.shutdown()   // stops feeds, removes the coordinator's sleep/wake observers
        UserDefaults.standard.removePersistentDomain(forName: env.suiteName)
    }

    /// A Jellyfin session for `userId`, either playing or paused.
    private func jellyfinSession(paused: Bool) -> Session {
        Session(
            id: "s1", userId: Self.userId, client: "Jellyfin Web", deviceName: "Test",
            lastActivityDate: Date(),
            nowPlayingItem: NowPlayingItem(
                id: "jf-item", name: "Jellyfin Track", artists: ["Artist"],
                albumArtist: "Artist", album: "Album", runTimeTicks: 1_800_000_000,
                imageTags: nil, albumId: nil, albumPrimaryImageTag: nil, userData: nil
            ),
            playState: PlayState(positionTicks: 0, isPaused: paused, volumeLevel: 80),
            nowPlayingQueueFullItems: nil, nowPlayingQueue: nil
        )
    }

    /// Bug replay (the Jellyfin half of the sticky-pause scenario) through the
    /// real `reevaluate` pipeline: a Jellyfin session that starts playing drives
    /// the overlay, and *pausing* it must NOT flip away — with no other source
    /// active, the home fallback keeps Jellyfin. Driving presence via
    /// `PlayerStore.ingest` exercises the `decide → debounce → publish` chain and
    /// the `current == activeKind` coupling end-to-end, not just the pure core.
    @Test
    func autoKeepsJellyfinWhenItPausesWithNoOtherSource() {
        let env = makeEnv(selection: .auto)
        env.arbiter.activate()

        // (1) Jellyfin starts playing → it drives, overlay shows its track.
        env.player.ingest(sessions: [jellyfinSession(paused: false)], userId: Self.userId)
        #expect(env.arbiter.activeKind == .jellyfin)
        #expect(env.player.jellyfinIsActiveSource == true)
        #expect(env.player.currentTrack?.itemId == "jf-item")
        #expect(env.player.connectionState == .connected)

        // (2) Pause Jellyfin → stays Jellyfin (home fallback), no spurious flip.
        env.player.ingest(sessions: [jellyfinSession(paused: true)], userId: Self.userId)
        #expect(env.arbiter.activeKind == .jellyfin)
        #expect(env.player.jellyfinIsActiveSource == true)
        #expect(env.player.connectionState == .connected)

        tearDown(env)
    }

    /// Render-layer guard for the loopback flip (the `publish` behavior from #34):
    /// when a loopback source becomes active, the arbiter must publish a
    /// `.connected` snapshot — never `.idle`, which the overlay renders as the
    /// "Configure your Jellyfin server" prompt. Forcing `.youtube` makes the
    /// initial `reevaluate` flip deterministically; with the feed idle (dead port)
    /// the published snapshot is the ambient "nothing playing" view (`.connected`,
    /// no track), not a false Jellyfin-misconfiguration alarm. Also pins the
    /// flip's side effects: Jellyfin gated out and the loopback sink installed.
    @Test
    func loopbackFlipPublishesConnectedNeverIdlePrompt() {
        let env = makeEnv(selection: .youtube)   // pin YouTube
        env.arbiter.activate()                    // initial reevaluate flips to YouTube

        #expect(env.arbiter.activeKind == .youtube)
        #expect(env.player.jellyfinIsActiveSource == false)        // Jellyfin writes gated
        #expect(env.player.capabilities == .loopbackDefault)       // sink swapped to loopback
        #expect(env.player.connectionState == .connected)          // NOT the .idle prompt
        #expect(env.player.isLinkLive)
        #expect(env.player.currentTrack == nil)                    // ambient: connected, no track

        tearDown(env)
    }

    /// The arbiter feeds its own `activeKind` as `decide`'s `current`, so with
    /// nothing active the overlay holds the source it is already on rather than
    /// snapping home. Pin YouTube, drop to `auto`, then drive a `reevaluate`
    /// (empty Jellyfin ingest) with no source active: YouTube must be held. A
    /// mis-wired `current` (e.g. a hardcoded `.jellyfin`) would flip to Jellyfin
    /// here — swapping the sink and ungating Jellyfin — so the capability and
    /// gating assertions catch the regression too.
    @Test
    func autoHoldsCurrentSourceWhenNothingActive() {
        let env = makeEnv(selection: .youtube)
        env.arbiter.activate()
        #expect(env.arbiter.activeKind == .youtube)

        // Drop to auto; nothing is playing anywhere (no Jellyfin sessions, the
        // YouTube feed is idle). decide returns `current`, debounce short-circuits.
        env.settings.sourceSelection = .auto
        env.player.ingest(sessions: [], userId: Self.userId)

        #expect(env.arbiter.activeKind == .youtube)            // held, not flipped home
        #expect(env.player.capabilities == .loopbackDefault)   // no flip back to Jellyfin
        #expect(env.player.jellyfinIsActiveSource == false)

        tearDown(env)
    }
}
