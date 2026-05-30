import Foundation

/// Subset of the `NowPlayingItem` field embedded inside a `Session` (plan §4).
///
/// Jellyfin emits `Artists` as an array and also a single `AlbumArtist`
/// string; we keep both so callers can pick the friendliest representation.
nonisolated struct NowPlayingItem: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let artists: [String]?
    let albumArtist: String?
    let album: String?
    /// 100-nanosecond ticks. Divide by 10_000_000 to obtain seconds.
    let runTimeTicks: Int64?
    let imageTags: ImageTags?
    /// Per-user metadata embedded in the item; carries the favorite flag so the
    /// overlay can render the heart filled without a separate lookup.
    let userData: UserData?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case artists = "Artists"
        case albumArtist = "AlbumArtist"
        case album = "Album"
        case runTimeTicks = "RunTimeTicks"
        case imageTags = "ImageTags"
        case userData = "UserData"
    }

    nonisolated struct ImageTags: Codable, Sendable, Equatable {
        let primary: String?
        enum CodingKeys: String, CodingKey {
            case primary = "Primary"
        }
    }

    /// Subset of Jellyfin's `UserItemDataDto`. We only need the favorite flag.
    nonisolated struct UserData: Codable, Sendable, Equatable {
        let isFavorite: Bool?
        enum CodingKeys: String, CodingKey {
            case isFavorite = "IsFavorite"
        }
    }
}
