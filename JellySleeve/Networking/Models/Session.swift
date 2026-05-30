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
    /// The client's full play queue (current track + what's up next), if the
    /// playing client reports one. Jellyfin embeds it in the same `/Sessions`
    /// reply, so the overlay's queue popover needs no extra request. Often nil
    /// for clients that don't push their queue (or for a single loose track).
    let nowPlayingQueueFullItems: [NowPlayingItem]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case userId = "UserId"
        case client = "Client"
        case deviceName = "DeviceName"
        case lastActivityDate = "LastActivityDate"
        case nowPlayingItem = "NowPlayingItem"
        case playState = "PlayState"
        case nowPlayingQueueFullItems = "NowPlayingQueueFullItems"
    }
}
