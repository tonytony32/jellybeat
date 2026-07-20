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
    /// Stands in for the 10 min production value: several times `grace`, so a
    /// "hasn't collapsed yet" assertion past the short deadline is meaningful,
    /// but still short enough to wait out in a test.
    private static let pausedGrace: TimeInterval = 2.4
    /// Stands in for the 60 s production value. Deliberately distinct from both
    /// graces above so a collapse can be attributed to the deadline that fired.
    private static let reconnectGrace: TimeInterval = 1.2

    private func makeStore() -> PlayerStore {
        PlayerStore(
            idleCollapseGrace: Self.grace,
            pausedIdleCollapseGrace: Self.pausedGrace,
            reconnectHoldGrace: Self.reconnectGrace
        )
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

    // MARK: - Asymmetric grace

    /// The YouTube regression. A paused Safari tab that macOS throttles in the
    /// background makes the bridge report `{active:false}` intermittently, so a
    /// live pause arrives as "nothing playing". That must not collapse on the
    /// short grace — the overlay flickered cover↔ambient every ~30 s. A pause
    /// only ends when the user ends it.
    @Test
    func pausedThenSilenceSurvivesTheShortGrace() async {
        let store = makeStore()
        publish(store, track: track(id: "a"), isPaused: true)
        #expect(store.isPaused == true)

        publish(store, track: nil)
        for _ in 0..<3 {
            await wait(0.15)
            publish(store, track: nil)
        }
        await wait(Self.grace)

        // Well past the playing deadline, and the paused one is still far off.
        #expect(store.currentTrack?.itemId == "a")
        // The transport still reads "paused", so the button offers resume.
        #expect(store.isPaused == true)
    }

    /// The other half of the asymmetry, stated directly: silence after actual
    /// playback still means "it stopped", and still collapses on 8 s.
    @Test
    func playingThenSilenceCollapsesOnTheShortGrace() async {
        let store = makeStore()
        publish(store, track: track(id: "a"), isPaused: false)

        publish(store, track: nil)
        await wait(Self.grace + 0.3)

        #expect(store.currentTrack == nil)
    }

    /// The long grace is a deadline, not an exemption: a tab closed while
    /// paused reports nothing forever, and the overlay must eventually shrink
    /// to the ambient note rather than stranding a dead track for the session.
    @Test
    func pausedThenSilenceCollapsesOnTheLongGrace() async {
        let store = makeStore()
        publish(store, track: track(id: "a"), isPaused: true)

        publish(store, track: nil)
        await wait(Self.pausedGrace + 0.4)

        #expect(store.currentTrack == nil)
        #expect(store.queue.isEmpty)
    }

    // MARK: - Link-down hold

    /// The reported bug, in its worst shape. A YouTube track is on screen when
    /// the bridge goes away; the arbiter hands the overlay home to Jellyfin,
    /// which is unreachable (off the home network). Nothing can ever call
    /// `apply(track: nil)` — that needs the server to *answer* — so before the
    /// hold deadline the dead cover sat there dimmed under a "Reconnecting…"
    /// badge until the app was relaunched.
    @Test
    func linkDownEventuallyCollapsesAGhostFromADepartedSource() async {
        let store = makeStore()

        // A loopback source is driving: Jellyfin is gated out.
        store.jellyfinIsActiveSource = false
        publish(store, track: track(id: "yt-1"))
        #expect(store.currentTrack != nil)

        // The source goes away and the arbiter falls back home, reopening
        // Jellyfin's gate — onto a link that can't be reached.
        store.jellyfinIsActiveSource = true
        store.updateConnection(.reconnecting(isOffline: false))
        // The poller keeps retrying and re-emitting for as long as it's down.
        for _ in 0..<3 {
            await wait(0.15)
            store.updateConnection(.reconnecting(isOffline: false))
        }
        #expect(store.currentTrack != nil, "the hold is the point — don't blank mid-blip")

        await wait(Self.reconnectGrace)

        #expect(store.currentTrack == nil)
        #expect(store.queue.isEmpty)
        // The pair the overlay reads to shrink to the ambient glyph, which
        // renders the crossed-out wifi symbol off `jellyfinLinkHealth`.
        #expect(store.showsAmbient == true)
        #expect(store.isLinkLive == false)
    }

    /// The hold earning its keep: a link that comes back inside the window
    /// recovers *in place*, with the same track and no flicker through ambient.
    @Test
    func linkRecoveringWithinTheHoldKeepsTheTrack() async {
        let store = makeStore()
        publish(store, track: track(id: "a"))

        store.updateConnection(.reconnecting(isOffline: false))
        await wait(Self.reconnectGrace / 2)
        // A successful tick: the transport answers again with the same track.
        publish(store, track: track(id: "a"))

        // Well past the original deadline — a surviving timer would wipe it.
        await wait(Self.reconnectGrace + 0.3)
        #expect(store.currentTrack?.itemId == "a")
        #expect(store.isLinkLive == true)
    }

    /// Losing the network *while* reconnecting flips `isOffline`, which is a
    /// distinct `ConnectionState` and so re-enters the branch that arms the
    /// hold. It must not re-arm: a link that degrades on a timer would push the
    /// deadline out of reach exactly like the repeated idle reports above.
    @Test
    func theOfflineFlipDoesNotSlideTheHoldDeadline() async {
        let store = makeStore()
        publish(store, track: track(id: "a"))

        store.updateConnection(.reconnecting(isOffline: false))
        await wait(Self.reconnectGrace * 0.75)
        store.updateConnection(.reconnecting(isOffline: true))

        // Only a little past the *original* deadline. Re-arming would have
        // bought another full grace and left the track on screen.
        await wait(Self.reconnectGrace * 0.5)
        #expect(store.currentTrack == nil)
    }
}
