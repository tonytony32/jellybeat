import Foundation
import Testing
@testable import JellySleeve

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
    /// source advertising a new capability lands without a JellySleeve restart.
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
