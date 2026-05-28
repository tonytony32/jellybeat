import Foundation
import Testing
@testable import JellySleeve

/// Decoding tests for the Codable models against JSON fixtures resembling real
/// Jellyfin responses. Plan Fase 2 mandates fixtures for `/System/Info`,
/// `/Sessions` with a NowPlayingItem, and `/Sessions` empty.
nonisolated struct ModelsTests {
    @Test
    func decodesSystemInfo() throws {
        let data = try FixtureLoader.data(named: "system_info")
        let info = try JellyfinClient.makeDecoder().decode(ServerInfo.self, from: data)

        #expect(info.id == "example-server-id-1234567890abcdef")
        #expect(info.serverName == "JellyfinTestServer")
        #expect(info.version == "10.10.3")
    }

    @Test
    func decodesSessionsWithNowPlayingItem() throws {
        let data = try FixtureLoader.data(named: "sessions_playing")
        let sessions = try JellyfinClient.makeDecoder().decode([Session].self, from: data)

        #expect(sessions.count == 2)

        let active = sessions[0]
        #expect(active.id == "session-abc-123")
        #expect(active.userId == "user-xyz-789")
        #expect(active.client == "Jellyfin Web")
        #expect(active.deviceName == "Test Browser")
        #expect(active.lastActivityDate != nil)

        let item = try #require(active.nowPlayingItem)
        #expect(item.id == "item-track-456")
        #expect(item.name == "Test Track")
        #expect(item.artists == ["Test Artist", "Featuring Artist"])
        #expect(item.albumArtist == "Test Artist")
        #expect(item.album == "Test Album")
        #expect(item.runTimeTicks == 1_800_000_000)
        #expect(item.imageTags?.primary == "abc123def456")

        let state = try #require(active.playState)
        #expect(state.positionTicks == 600_000_000)
        #expect(state.isPaused == false)
        #expect(state.volumeLevel == 80)

        // The second session has no NowPlayingItem; both sub-objects must be nil
        // without breaking decoding of the rest of the array.
        let idle = sessions[1]
        #expect(idle.id == "session-other-999")
        #expect(idle.nowPlayingItem == nil)
        #expect(idle.playState == nil)
        #expect(idle.lastActivityDate != nil) // ISO-8601 without fractional seconds also accepted
    }

    @Test
    func decodesEmptySessionsArray() throws {
        let data = try FixtureLoader.data(named: "sessions_empty")
        let sessions = try JellyfinClient.makeDecoder().decode([Session].self, from: data)
        #expect(sessions.isEmpty)
    }
}
