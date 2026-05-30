import Foundation
import Testing
@testable import JellySleeve

/// Tests for `PlayerStore.ingest(...)`, the active-session heuristic that
/// decides which session's track the overlay shows. The recency filter here is
/// subtle: it must drop sessions whose browser tab genuinely vanished without
/// dropping a session that's merely paused (and therefore legitimately stops
/// sending `LastActivityDate` heartbeats).
@MainActor
struct PlayerStoreTests {
    private static let userId = "user-1"

    private func session(
        id: String,
        secondsSinceActivity: TimeInterval,
        isPaused: Bool
    ) -> Session {
        Session(
            id: id,
            userId: Self.userId,
            client: "Jellyfin Web",
            deviceName: "Test Browser",
            lastActivityDate: Date().addingTimeInterval(-secondsSinceActivity),
            nowPlayingItem: NowPlayingItem(
                id: "item-\(id)",
                name: "Track",
                artists: ["Artist"],
                albumArtist: "Artist",
                album: "Album",
                runTimeTicks: 1_800_000_000,
                imageTags: nil,
                userData: nil
            ),
            playState: PlayState(positionTicks: 0, isPaused: isPaused, volumeLevel: 80),
            nowPlayingQueueFullItems: nil
        )
    }

    /// A paused session whose heartbeat went silent ~5 min ago (e.g. the web
    /// player was paused and minimized) must stay tracked — the overlay should
    /// keep showing the track, not flip to ambient mode.
    @Test
    func keepsPausedSessionThatStoppedHeartbeating() {
        let store = PlayerStore()
        store.ingest(
            sessions: [session(id: "s1", secondsSinceActivity: 5 * 60, isPaused: true)],
            userId: Self.userId
        )
        #expect(store.currentTrack != nil)
        #expect(store.isPaused == true)
    }

    /// A session that claims to be playing but hasn't checked in for over a
    /// minute is a disconnected client; it must be dropped so the overlay
    /// clears instead of showing a frozen cover.
    @Test
    func dropsPlayingSessionThatWentSilent() {
        let store = PlayerStore()
        store.ingest(
            sessions: [session(id: "s1", secondsSinceActivity: 90, isPaused: false)],
            userId: Self.userId
        )
        #expect(store.currentTrack == nil)
    }

    /// A paused session that's been silent past the generous paused window is
    /// treated as a tab closed while paused, and finally cleared.
    @Test
    func dropsPausedSessionPastGenerousWindow() {
        let store = PlayerStore()
        store.ingest(
            sessions: [session(id: "s1", secondsSinceActivity: 20 * 60, isPaused: true)],
            userId: Self.userId
        )
        #expect(store.currentTrack == nil)
    }

    /// A freshly-heartbeating playing session is tracked normally.
    @Test
    func keepsActivePlayingSession() {
        let store = PlayerStore()
        store.ingest(
            sessions: [session(id: "s1", secondsSinceActivity: 2, isPaused: false)],
            userId: Self.userId
        )
        #expect(store.currentTrack != nil)
        #expect(store.isPaused == false)
    }

    /// `NowPlayingQueueFullItems` is surfaced as `store.queue`, in order, with
    /// the entry matching the current `NowPlayingItem` flagged `isCurrent`.
    @Test
    func ingestSurfacesQueueWithCurrentFlag() {
        func item(_ id: String, _ name: String) -> NowPlayingItem {
            NowPlayingItem(
                id: id, name: name, artists: ["Artist"], albumArtist: "Artist",
                album: "Album", runTimeTicks: 1_800_000_000, imageTags: nil, userData: nil
            )
        }
        let queueItems = [item("a", "First"), item("b", "Current"), item("c", "Next")]
        let session = Session(
            id: "s1", userId: Self.userId, client: "Jellyfin Web",
            deviceName: "Test", lastActivityDate: Date(),
            nowPlayingItem: item("b", "Current"),
            playState: PlayState(positionTicks: 0, isPaused: false, volumeLevel: 80),
            nowPlayingQueueFullItems: queueItems
        )
        let store = PlayerStore()
        store.ingest(sessions: [session], userId: Self.userId)

        #expect(store.queue.map(\.title) == ["First", "Current", "Next"])
        #expect(store.queue.filter(\.isCurrent).map(\.title) == ["Current"])
    }

    /// A session without a reported queue leaves `store.queue` empty.
    @Test
    func ingestLeavesQueueEmptyWhenNotReported() {
        let store = PlayerStore()
        store.ingest(
            sessions: [session(id: "s1", secondsSinceActivity: 2, isPaused: false)],
            userId: Self.userId
        )
        #expect(store.queue.isEmpty)
    }

    // MARK: - Reconnecting / link-down behaviour

    /// Dropping into `.reconnecting` must KEEP the last track on screen (unlike
    /// `.error`, which wipes it) so the overlay can dim it and recover in place
    /// when the server comes back.
    @Test
    func reconnectingPreservesCurrentTrack() {
        let store = PlayerStore()
        store.ingest(
            sessions: [session(id: "s1", secondsSinceActivity: 2, isPaused: false)],
            userId: Self.userId
        )
        #expect(store.currentTrack != nil)

        store.updateConnection(.reconnecting(isOffline: false))
        #expect(store.currentTrack != nil)
        #expect(store.isLinkLive == false)
    }

    /// A hard error, by contrast, clears the track and pause state.
    @Test
    func errorClearsCurrentTrack() {
        let store = PlayerStore()
        store.ingest(
            sessions: [session(id: "s1", secondsSinceActivity: 2, isPaused: false)],
            userId: Self.userId
        )
        store.updateConnection(.error("Unauthorized — check your API key."))
        #expect(store.currentTrack == nil)
        #expect(store.isLinkLive == false)
    }

    /// Pressing play/pause while the link is down must NOT fire a doomed
    /// command. It should leave the optimistic pause state untouched and
    /// surface a one-line hint instead of a raw transport error.
    @Test
    func playPauseIsInertWhileReconnecting() async {
        let store = PlayerStore()
        store.ingest(
            sessions: [session(id: "s1", secondsSinceActivity: 2, isPaused: false)],
            userId: Self.userId
        )
        store.updateConnection(.reconnecting(isOffline: false))
        let pausedBefore = store.isPaused

        await store.playPause()

        #expect(store.isPaused == pausedBefore)
        #expect(store.transientMessage == "Reconnecting to the server…")
    }

    /// The offline variant tailors the hint copy.
    @Test
    func commandHintReflectsOfflineState() async {
        let store = PlayerStore()
        store.ingest(
            sessions: [session(id: "s1", secondsSinceActivity: 2, isPaused: false)],
            userId: Self.userId
        )
        store.updateConnection(.reconnecting(isOffline: true))

        await store.nextTrack()
        #expect(store.transientMessage == "You're offline")
    }
}
