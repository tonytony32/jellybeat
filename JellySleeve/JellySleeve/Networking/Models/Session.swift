import Foundation

/// One entry of the `/Sessions` array. `JellyfinClient.fetchSessions()` returns
/// `[Session]` and the poller (Fase 4) applies the active-session heuristic
/// from plan §4 over them.
nonisolated struct Session: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let userId: String?
    let client: String?
    let deviceName: String?
    let lastActivityDate: Date?
    let nowPlayingItem: NowPlayingItem?
    let playState: PlayState?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case userId = "UserId"
        case client = "Client"
        case deviceName = "DeviceName"
        case lastActivityDate = "LastActivityDate"
        case nowPlayingItem = "NowPlayingItem"
        case playState = "PlayState"
    }
}
