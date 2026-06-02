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
    /// The authoritative play order of the queue: `{Id, PlaylistItemId}` entries
    /// in the order the client will play them. `NowPlayingQueueFullItems` (the
    /// expanded metadata) is NOT guaranteed to be in this order — the server
    /// expands it via a lookup that loses the queue order — so we reorder the
    /// full items against this list when building the queue preview.
    let nowPlayingQueue: [NowPlayingQueueEntry]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case userId = "UserId"
        case client = "Client"
        case deviceName = "DeviceName"
        case lastActivityDate = "LastActivityDate"
        case nowPlayingItem = "NowPlayingItem"
        case playState = "PlayState"
        case nowPlayingQueueFullItems = "NowPlayingQueueFullItems"
        case nowPlayingQueue = "NowPlayingQueue"
    }
}

/// One entry of a session's `NowPlayingQueue`: an item id plus the client's
/// per-queue-slot id. The array order is the play order, used to sort the
/// (unordered) `NowPlayingQueueFullItems` into what the user actually sees.
nonisolated struct NowPlayingQueueEntry: Codable, Sendable, Equatable {
    let id: String
    let playlistItemId: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case playlistItemId = "PlaylistItemId"
    }
}
