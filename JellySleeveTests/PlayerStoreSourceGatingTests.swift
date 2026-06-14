import Foundation
import Testing
@testable import JellySleeve

/// Tests for the source-arbitration seams on `PlayerStore`: gating Jellyfin's
/// writes while another source drives, the presence signal the arbiter reads,
/// and applying an external (YouTube) snapshot.
@MainActor
struct PlayerStoreSourceGatingTests {
    private static let userId = "user-1"

    private func playingSession() -> Session {
        Session(
            id: "s1",
            userId: Self.userId,
            client: "Jellyfin Web",
            deviceName: "Test",
            lastActivityDate: Date(),
            nowPlayingItem: NowPlayingItem(
                id: "jf-item", name: "Jellyfin Track", artists: ["Artist"],
                albumArtist: "Artist", album: "Album", runTimeTicks: 1_800_000_000,
                imageTags: nil, albumId: nil, albumPrimaryImageTag: nil, userData: nil
            ),
            playState: PlayState(positionTicks: 0, isPaused: false, volumeLevel: 80),
            nowPlayingQueueFullItems: nil,
            nowPlayingQueue: nil
        )
    }

    private func ytTrack() -> TrackSnapshot {
        TrackSnapshot(
            itemId: "yt-video", imageTag: nil, artworkItemId: "yt-video",
            title: "YouTube Song", artist: "Channel", album: "",
            runtime: .seconds(200), position: .seconds(10), sessionId: "",
            isFavorite: false, artworkURL: URL(string: "https://i.ytimg.com/x.jpg")
        )
    }

    /// While gated (another source drives), a Jellyfin `ingest` must NOT write
    /// the shared overlay state, but it MUST still refresh the presence signal
    /// and fire the arbiter callback so the flip-back can be detected.
    @Test
    func gatedIngestUpdatesPresenceButNotState() {
        let store = PlayerStore()
        store.capabilities = .youtube
        store.jellyfinIsActiveSource = false

        var notified = false
        store.onJellyfinUpdate = { notified = true }

        store.ingest(sessions: [playingSession()], userId: Self.userId)

        #expect(store.currentTrack == nil)               // shared state untouched
        #expect(store.jellyfinHasNowPlaying == true)     // presence refreshed
        #expect(notified)
    }

    /// When Jellyfin is the active source (the default), `ingest` writes as before.
    @Test
    func ungatedIngestWritesState() {
        let store = PlayerStore()
        store.ingest(sessions: [playingSession()], userId: Self.userId)
        #expect(store.currentTrack?.itemId == "jf-item")
        #expect(store.jellyfinHasNowPlaying == true)
    }

    /// An external snapshot populates the shared state, carrying the direct
    /// artwork URL through.
    @Test
    func appliesExternalSnapshot() {
        let store = PlayerStore()
        store.capabilities = .youtube
        store.jellyfinIsActiveSource = false

        store.applyExternalSnapshot(
            track: ytTrack(), isPaused: false, volume: 70, connection: .connected
        )

        #expect(store.currentTrack?.itemId == "yt-video")
        #expect(store.currentTrack?.artworkURL?.absoluteString == "https://i.ytimg.com/x.jpg")
        #expect(store.volume == 70)
        #expect(store.isLinkLive)
    }

    /// While gated, a Jellyfin lifecycle blip (`updateConnection`) must not
    /// repaint the overlay the other source owns.
    @Test
    func gatedUpdateConnectionIsDropped() {
        let store = PlayerStore()
        store.jellyfinIsActiveSource = false
        store.applyExternalSnapshot(
            track: ytTrack(), isPaused: false, volume: 70, connection: .connected
        )

        store.updateConnection(.reconnecting(isOffline: false))

        // The YouTube snapshot stays put; the Jellyfin blip was ignored.
        #expect(store.currentTrack?.itemId == "yt-video")
        #expect(store.isLinkLive)
    }
}
