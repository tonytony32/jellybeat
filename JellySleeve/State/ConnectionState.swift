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
    /// The link dropped (server down, network blip, or device offline) but the
    /// transport is still retrying with backoff. Distinct from `.error`: the
    /// overlay keeps the last track on screen (dimmed) and recovers on its own
    /// when the server comes back — no user action, no "Open Settings". When
    /// `isOffline` is true the device itself has no network path.
    case reconnecting(isOffline: Bool)
    /// Hard failure that retrying won't heal (bad API key / untrusted cert).
    /// The associated string is shown to the user and the poller stops
    /// (plan §5.2 for 401). This is the only state that routes to Settings.
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

/// One row of the active client's play queue, materialised from a session's
/// `NowPlayingQueueFullItems`. Read-only: Jellyfin exposes the queue but no
/// "jump to this entry" session command, so the popover is a preview of what's
/// playing and what's up next, with `isCurrent` marking the now-playing row.
nonisolated struct QueueItem: Equatable, Sendable, Identifiable {
    /// Stable within one queue snapshot. Composed from the position + item id
    /// because the same track can legitimately appear twice in a queue.
    let id: String
    let itemId: String
    let imageTag: String?
    let title: String
    let artist: String
    let isCurrent: Bool
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
