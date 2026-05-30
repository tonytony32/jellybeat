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
                imageTags: nil
            ),
            playState: PlayState(positionTicks: 0, isPaused: isPaused, volumeLevel: 80)
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
}
