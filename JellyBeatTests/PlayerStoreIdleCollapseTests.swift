import Foundation
import Testing
@testable import JellyBeat

/// Tests for the idle collapse: how long the overlay keeps showing a track
/// after playback stops, and when it finally clears so the window can shrink to
/// the ambient note (`connected` + no track).
///
/// The subtlety is that "nothing is playing" arrives *repeatedly* — every
/// source keeps reporting while idle, faster than the grace period — so the
/// deadline has to be absolute. Treating each report as a fresh reason to
/// restart it is what left a stopped track frozen on screen forever.
@MainActor
struct PlayerStoreIdleCollapseTests {
    /// Short enough to keep the suite fast, long enough that the scheduling
    /// jitter of a loaded machine can't reorder the assertions below.
    private static let grace: TimeInterval = 0.6

    private func makeStore() -> PlayerStore {
        PlayerStore(idleCollapseGrace: Self.grace)
    }

    private func track(id: String) -> TrackSnapshot {
        TrackSnapshot(
            itemId: id,
            imageTag: nil,
            artworkItemId: id,
            title: "Track \(id)",
            artist: "Artist",
            album: "Album",
            runtime: .seconds(180),
            position: .seconds(10),
            sessionId: "session-1",
            isFavorite: false,
            artworkURL: nil
        )
    }

    /// Push a snapshot the way an active loopback source does each poll.
    private func publish(_ store: PlayerStore, track: TrackSnapshot?, isPaused: Bool = false) {
        store.applyExternalSnapshot(
            track: track,
            isPaused: isPaused,
            volume: nil,
            connection: .connected
        )
    }

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - Collapse deadline

    /// The regression. A stopped source keeps reporting "nothing playing" every
    /// poll (~1 s for the loopback feed, `refreshRate` for Jellyfin) — far more
    /// often than the grace period. Those repeats must NOT postpone the clear,
    /// or the deadline is never reached and the overlay shows a dead track
    /// indefinitely (with a blank cover, since the artwork lives in view state
    /// that resets independently).
    @Test
    func repeatedIdleReportsDoNotPostponeTheCollapse() async {
        let store = makeStore()
        publish(store, track: track(id: "a"))
        #expect(store.currentTrack != nil)

        // Stop, then keep polling as a real source does. Under the old
        // cancel-and-rearm behaviour the last of these would push the deadline
        // out to 1.0 s and the assertion below would still see the track.
        publish(store, track: nil)
        for _ in 0..<4 {
            await wait(0.1)
            publish(store, track: nil)
        }

        await wait(0.4)

        #expect(store.currentTrack == nil)
        #expect(store.queue.isEmpty)
        // The pair the overlay reads to enter ambient mode.
        #expect(store.isLinkLive == true)
    }

    /// Once a collapse has fired, the next stop has to arm a fresh deadline —
    /// otherwise arming "only once" would mean only once per process, and the
    /// second track of the session would never clear.
    @Test
    func collapseArmsAgainAfterASecondStop() async {
        let store = makeStore()

        publish(store, track: track(id: "a"))
        publish(store, track: nil)
        await wait(Self.grace + 0.3)
        #expect(store.currentTrack == nil)

        publish(store, track: track(id: "b"))
        #expect(store.currentTrack?.itemId == "b")

        publish(store, track: nil)
        await wait(Self.grace + 0.3)
        #expect(store.currentTrack == nil)
    }

    // MARK: - What must NOT collapse

    /// Pausing is not stopping. A paused source still reports its track, so the
    /// overlay keeps it — you need to see what you paused, and the controls to
    /// resume it. (Jellyfin ages genuinely-abandoned paused sessions out after
    /// 3 min in `ingest`; that's the mechanism for this case, not the collapse.)
    @Test
    func pausedPlaybackDoesNotCollapse() async {
        let store = makeStore()
        publish(store, track: track(id: "a"))

        for _ in 0..<5 {
            publish(store, track: track(id: "a"), isPaused: true)
            await wait(0.15)
        }

        #expect(store.currentTrack?.itemId == "a")
        #expect(store.isPaused == true)
    }

    /// A gap shorter than the grace is what the grace is *for*: loading the
    /// next song, navigating between videos, a bridge restart. Playback
    /// resuming inside the window cancels the pending collapse outright — the
    /// deadline must not survive to fire underneath the new track.
    @Test
    func playbackResumingWithinTheGraceCancelsTheCollapse() async {
        let store = makeStore()
        publish(store, track: track(id: "a"))

        publish(store, track: nil)
        await wait(Self.grace / 2)
        publish(store, track: track(id: "b"))

        // Well past the original deadline: if it were still pending it would
        // have wiped "b" by now.
        await wait(Self.grace + 0.3)
        #expect(store.currentTrack?.itemId == "b")
    }
}
