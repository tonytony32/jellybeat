import Foundation
import Testing
@testable import JellySleeve

/// Tests for the arbiter's pure decision policy (`SourceArbiter.decide`) and the
/// YouTube bridge → normalized snapshot mapping (`YouTubeBridgeFeed.map`).
struct SourceArbiterTests {

    // MARK: - Decision policy

    /// A forced selection wins regardless of which sources are active.
    @Test
    func forcedSelectionWinsOutright() {
        #expect(SourceArbiter.decide(
            selection: .jellyfin, ytActive: true, jfActive: false,
            ytActivatedNoOlderThanJf: true, current: .youtube
        ) == .jellyfin)

        #expect(SourceArbiter.decide(
            selection: .youtube, ytActive: false, jfActive: true,
            ytActivatedNoOlderThanJf: false, current: .jellyfin
        ) == .youtube)
    }

    /// In auto, the single active source drives.
    @Test
    func autoPicksTheActiveSource() {
        #expect(SourceArbiter.decide(
            selection: .auto, ytActive: true, jfActive: false,
            ytActivatedNoOlderThanJf: false, current: .jellyfin
        ) == .youtube)

        #expect(SourceArbiter.decide(
            selection: .auto, ytActive: false, jfActive: true,
            ytActivatedNoOlderThanJf: true, current: .youtube
        ) == .jellyfin)
    }

    /// In auto with both active, the most-recently-*activated* source wins (the
    /// one the user started last). Auto-advance keeps a source continuously
    /// active without re-activating it, so it never bumps this signal — the
    /// arbiter's activation-edge tracking (not exercised here) is what guarantees
    /// a background playlist can't steal focus; this test pins the consumption of
    /// that signal.
    @Test
    func autoBreaksTiesByActivationRecency() {
        #expect(SourceArbiter.decide(
            selection: .auto, ytActive: true, jfActive: true,
            ytActivatedNoOlderThanJf: true, current: .jellyfin
        ) == .youtube)

        #expect(SourceArbiter.decide(
            selection: .auto, ytActive: true, jfActive: true,
            ytActivatedNoOlderThanJf: false, current: .youtube
        ) == .jellyfin)
    }

    /// With neither active, the current source is kept (no spurious flip).
    @Test
    func autoKeepsCurrentWhenNeitherActive() {
        #expect(SourceArbiter.decide(
            selection: .auto, ytActive: false, jfActive: false,
            ytActivatedNoOlderThanJf: true, current: .youtube
        ) == .youtube)

        #expect(SourceArbiter.decide(
            selection: .auto, ytActive: false, jfActive: false,
            ytActivatedNoOlderThanJf: false, current: .jellyfin
        ) == .jellyfin)
    }

    // MARK: - Activation recency (auto-advance must not steal focus)

    /// The source that activated last wins the tie. Starting YouTube after
    /// Jellyfin makes YouTube rank higher.
    @Test
    func recencyRanksLastActivatedSource() {
        var r = ActivationRecency()
        r.observe(ytActive: false, jfActive: true)   // Jellyfin starts
        #expect(r.ytActivatedNoOlderThanJf == false) // Jellyfin newer → it wins
        r.observe(ytActive: true, jfActive: true)    // YouTube starts later
        #expect(r.ytActivatedNoOlderThanJf == true)  // YouTube newer → it wins
    }

    /// THE auto-advance guard: once YouTube is the active winner, a Jellyfin
    /// playlist auto-advancing in the background (Jellyfin stays continuously
    /// active across the track change) must NOT bump Jellyfin's rank, so
    /// YouTube keeps the overlay.
    @Test
    func autoAdvanceDoesNotStealFocus() {
        var r = ActivationRecency()
        r.observe(ytActive: false, jfActive: true)   // Jellyfin playing
        r.observe(ytActive: true, jfActive: true)    // user starts YouTube → YT wins
        #expect(r.ytActivatedNoOlderThanJf == true)

        // Jellyfin auto-advances several times — never goes idle, just keeps
        // playing the next track. Rank must not move.
        for _ in 0..<5 {
            r.observe(ytActive: true, jfActive: true)
            #expect(r.ytActivatedNoOlderThanJf == true)  // YouTube still wins
        }
    }

    /// A genuine restart — Jellyfin goes idle, then active again — IS a fresh
    /// activation and does reclaim the tie (deliberate intent still works).
    @Test
    func restartReactivatesAndReclaims() {
        var r = ActivationRecency()
        r.observe(ytActive: false, jfActive: true)
        r.observe(ytActive: true, jfActive: true)    // YouTube wins
        #expect(r.ytActivatedNoOlderThanJf == true)

        r.observe(ytActive: true, jfActive: false)   // Jellyfin stops
        r.observe(ytActive: true, jfActive: true)    // Jellyfin started again
        #expect(r.ytActivatedNoOlderThanJf == false) // Jellyfin reclaims
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
        volume: Double? = 0.8
    ) -> BridgeSnapshot {
        BridgeSnapshot(
            active: active, source: "youtube_music", state: state, title: title,
            artist: artist, album: album, durationSec: durationSec,
            positionSec: positionSec, videoId: videoId, artworkUrl: artworkUrl,
            volume: volume, updatedAtMs: 1
        )
    }

    /// A playing snapshot maps every field across; volume rounds 0–1 → 0–100.
    @Test
    func mapsPlayingSnapshot() {
        let mapped = YouTubeBridgeFeed.map(snapshot())
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

    /// `state == "paused"` maps to `isPaused`.
    @Test
    func mapsPausedState() {
        let mapped = YouTubeBridgeFeed.map(snapshot(state: "paused"))
        #expect(mapped.isPaused == true)
        #expect(mapped.active)
    }

    /// A nil snapshot (idle / unreachable) and an `active: false` body both
    /// normalize to idle.
    @Test
    func mapsIdle() {
        #expect(YouTubeBridgeFeed.map(nil) == .idle)
        #expect(YouTubeBridgeFeed.map(snapshot(active: false)) == .idle)
    }

    /// A non-http(s) artwork URL (e.g. `file://`) from an untrusted local source
    /// must be rejected so the artwork loader can't be turned into a file read.
    @Test
    func rejectsNonHttpArtworkURL() {
        let fileScheme = YouTubeBridgeFeed.map(snapshot(artworkUrl: "file:///etc/passwd"))
        #expect(fileScheme.track?.artworkURL == nil)

        let httpsScheme = YouTubeBridgeFeed.map(snapshot(artworkUrl: "https://i.ytimg.com/x.jpg"))
        #expect(httpsScheme.track?.artworkURL?.absoluteString == "https://i.ytimg.com/x.jpg")
    }

    /// A null `durationSec` (livestream / unknown) maps to a zero runtime.
    @Test
    func nullDurationMapsToZeroRuntime() {
        let mapped = YouTubeBridgeFeed.map(snapshot(durationSec: nil))
        #expect(mapped.track?.runtime == .zero)
    }

    /// A missing `videoId` falls back to a stable id so the overlay's artwork /
    /// track-change smoothing doesn't thrash between polls.
    @Test
    func missingVideoIdUsesStableFallback() {
        let a = YouTubeBridgeFeed.map(snapshot(videoId: nil))
        let b = YouTubeBridgeFeed.map(snapshot(videoId: nil))
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
