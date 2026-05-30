import Foundation

/// Connection lifecycle of the Jellyfin link, surfaced in the overlay and used
/// by the universal special-states code paths (idle / error) in `OverlayView`.
nonisolated enum ConnectionState: Equatable, Sendable {
    /// No configuration yet (missing baseURL / API key / userId).
    case idle
    /// Validating credentials or running the very first poll.
    case connecting
    /// Polling loop is up; the server is reachable.
    case connected
    /// Hard failure. The associated string is shown to the user. Poller is
    /// stopped (plan §5.2 for 401, §5.1 after the backoff cap is reached).
    case error(String)
}

/// Snapshot of the currently playing item, materialised by the poller from a
/// `Session` + `NowPlayingItem` + `PlayState`. Pure value type so it can flow
/// between the actor poller and the @MainActor PlayerStore freely.
nonisolated struct TrackSnapshot: Equatable, Sendable {
    let itemId: String
    let imageTag: String?
    let title: String
    let artist: String
    let album: String
    let runtime: Duration
    let position: Duration
    /// Owning session id; needed to target playback commands at the right
    /// client device.
    let sessionId: String
    /// Whether the current user has marked this item as a favorite. Drives the
    /// heart button's filled/outline state.
    let isFavorite: Bool

    /// Returns a copy with a different `isFavorite`. Used by `PlayerStore` for
    /// the optimistic heart toggle (and its revert on failure) without rebuilding
    /// every field by hand.
    func withFavorite(_ value: Bool) -> TrackSnapshot {
        TrackSnapshot(
            itemId: itemId,
            imageTag: imageTag,
            title: title,
            artist: artist,
            album: album,
            runtime: runtime,
            position: position,
            sessionId: sessionId,
            isFavorite: value
        )
    }
}

/// Lightweight description of one session shown in the manual selector
/// (plan §4 point 2). Stored in `PlayerStore.availableSessions` so the UI can
/// offer a picker when more than one device is playing for the same user.
nonisolated struct SessionSummary: Equatable, Sendable, Identifiable {
    let id: String
    let client: String?
    let deviceName: String?
    let lastActivity: Date?
    /// True iff this session has a `NowPlayingItem`. The poller also exposes
    /// idle sessions so users can preempt them, but the picker dims them.
    let hasNowPlaying: Bool
}
