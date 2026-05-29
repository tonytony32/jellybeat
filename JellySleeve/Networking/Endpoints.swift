import Foundation

/// Jellyfin REST paths used by `JellyfinClient`. All paths are relative to
/// `JellyfinConfiguration.baseURL`. Auth is supplied via the `X-Emby-Token`
/// header (plan §4) so paths do not include query-string credentials.
nonisolated enum Endpoints {
    static let systemInfo = "/System/Info"
    static let sessions = "/Sessions"

    static func itemPrimaryImage(itemId: String) -> String {
        "/Items/\(itemId)/Images/Primary"
    }

    static func sessionPlayPause(sessionId: String) -> String {
        "/Sessions/\(sessionId)/Playing/PlayPause"
    }

    static func sessionNext(sessionId: String) -> String {
        "/Sessions/\(sessionId)/Playing/NextTrack"
    }

    static func sessionPrevious(sessionId: String) -> String {
        "/Sessions/\(sessionId)/Playing/PreviousTrack"
    }

    /// Seek inside the currently playing item. The target position is sent
    /// as a `seekPositionTicks` query parameter (Jellyfin ticks are 100 ns).
    static func sessionSeek(sessionId: String) -> String {
        "/Sessions/\(sessionId)/Playing/Seek"
    }
}
