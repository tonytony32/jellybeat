import Foundation

/// Vendor-neutral "remote control" sink for the currently driving playback
/// source. JellySleeve's `PlayerStore` routes its transport actions through one
/// of these without knowing whether Jellyfin or the YouTube bridge is behind it
/// (see `docs/youtube-bridge-arbiter-plan.md` and the bridge's
/// `docs/playback-source.md`).
///
/// Implementations are value types crossing actor boundaries, so the protocol
/// is `Sendable` with `async throws` methods. Each method is self-contained:
/// the sink already knows how to target its backend (Jellyfin captures the
/// session id; the bridge targets the active tab), so callers pass no routing.
nonisolated protocol PlaybackCommanding: Sendable {
    func playPause() async throws
    func next() async throws
    func previous() async throws
    /// Seek to an absolute position from the start of the item.
    func seek(to position: Duration) async throws
    /// Set output volume, normalized to 0–100 (sinks convert to their own unit).
    func setVolume(percent: Int) async throws
    /// Toggle the favorite flag for `itemId`. Returns the server's resulting
    /// value, or `nil` when the source has no concept of favorites (YouTube).
    func toggleFavorite(itemId: String, current: Bool) async throws -> Bool?
    /// Bring the source's window/tab to the foreground (the YouTube bridge's
    /// `focusTab`). Best-effort and asynchronous; sources that can't surface a
    /// window (Jellyfin) implement it as a no-op. Capability-gated in the UI by
    /// `SourceCapabilities.canFocusTab`, so it's only invoked on a source that
    /// advertises it.
    func focusTab() async throws
}

/// Self-describing feature set of a playback source, mirrored from the
/// contract's `capabilities` block. Drives capability-gated UI: the favorite
/// heart and the queue affordance are hidden when the active source doesn't
/// support them.
nonisolated struct SourceCapabilities: Equatable, Sendable {
    var canPlayPause: Bool
    var canNext: Bool
    var canPrevious: Bool
    var canSeek: Bool
    var canSetVolume: Bool
    var hasFavorites: Bool
    var hasQueue: Bool
    /// How the "favorite" affordance should read for this source — a library
    /// favorite (Jellyfin → heart) vs. a YouTube "like" (thumbs-up). Lets the
    /// overlay pick the right glyph without knowing the concrete backend.
    var favoriteStyle: FavoriteStyle = .heart

    /// The source can raise its own window/tab to the foreground (the bridge's
    /// `focusTab`). Drives the artwork's "double-click to go to the tab"
    /// affordance. False for sources that don't advertise it (Jellyfin, older
    /// bridges, future non-YouTube sources), so the affordance stays hidden.
    var canFocusTab: Bool = false

    /// Jellyfin: full transport control plus favorites (a heart) and a play queue.
    /// No tab to focus — the overlay's double-click opens the Jellyfin client
    /// instead.
    static let jellyfin = SourceCapabilities(
        canPlayPause: true, canNext: true, canPrevious: true,
        canSeek: true, canSetVolume: true, hasFavorites: true, hasQueue: true,
        favoriteStyle: .heart, canFocusTab: false
    )

    /// YouTube bridge default: full transport control plus favorites (the "like",
    /// a thumbs-up), no queue. Used as the immediate fallback before `/v1/health`
    /// is read; `canFocusTab` stays conservatively `false` until health confirms
    /// the source supports it (older bridges won't advertise the capability).
    static let youtube = SourceCapabilities(
        canPlayPause: true, canNext: true, canPrevious: true,
        canSeek: true, canSetVolume: true, hasFavorites: true, hasQueue: false,
        favoriteStyle: .like, canFocusTab: false
    )
}

/// Presentation style for a source's favorite affordance: a heart for a library
/// favorite (Jellyfin), a thumbs-up for a YouTube "like / me gusta".
nonisolated enum FavoriteStyle: Sendable, Equatable {
    case heart
    case like
}

/// Which backend is currently driving the overlay. Used by the arbiter and the
/// menu-bar "Source" override.
nonisolated enum SourceKind: String, CaseIterable, Sendable {
    case jellyfin
    case youtube
}

/// Adapts `JellyfinClient` (whose command methods are keyed by a session id) to
/// the vendor-neutral `PlaybackCommanding` sink. Rebuilt per active session by
/// `PlayerStore.ingest`, so the captured `sessionId` always targets the device
/// the overlay is currently mirroring.
nonisolated struct JellyfinCommandSink: PlaybackCommanding {
    let client: JellyfinClient
    let sessionId: String

    func playPause() async throws { try await client.playPause(sessionId: sessionId) }
    func next() async throws { try await client.nextTrack(sessionId: sessionId) }
    func previous() async throws { try await client.previousTrack(sessionId: sessionId) }

    func seek(to position: Duration) async throws {
        try await client.seek(sessionId: sessionId, positionTicks: position.jellyfinTicks)
    }

    func setVolume(percent: Int) async throws {
        try await client.setVolume(sessionId: sessionId, volume: percent)
    }

    func toggleFavorite(itemId: String, current: Bool) async throws -> Bool? {
        try await client.setFavorite(itemId: itemId, isFavorite: !current)
    }

    /// Jellyfin has no window to raise from here — no-op. The overlay never
    /// invokes this (Jellyfin's `canFocusTab` is false); the artwork's
    /// double-click opens the Jellyfin client through a separate path.
    func focusTab() async throws {}
}

extension Duration {
    /// Whole + fractional seconds as a `Double`. Used to map the normalized
    /// position onto backends that speak seconds (the YouTube bridge).
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    /// Jellyfin position unit: 100-nanosecond "ticks".
    var jellyfinTicks: Int64 {
        Int64((seconds * 10_000_000).rounded())
    }
}
