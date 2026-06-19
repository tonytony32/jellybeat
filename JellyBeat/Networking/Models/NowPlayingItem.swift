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
    /// Parent album id and its primary-image tag. Audio tracks frequently have
    /// no embedded cover of their own (`imageTags.primary == nil`); the cover
    /// lives on the album. These let us fall back to the album's image so the
    /// artwork matches what the Jellyfin web client shows.
    let albumId: String?
    let albumPrimaryImageTag: String?
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
        case albumId = "AlbumId"
        case albumPrimaryImageTag = "AlbumPrimaryImageTag"
        case userData = "UserData"
    }

    /// The `(itemId, tag)` to fetch the cover from: the track's own primary
    /// image when it has one, otherwise the parent album's. Audio tracks often
    /// have only the album cover, so requesting the track's own image 404s —
    /// this mirrors the web client's album fallback. Falls back to the track id
    /// with no tag when neither is available (yields a placeholder).
    var artworkSource: (itemId: String, tag: String?) {
        if let own = imageTags?.primary { return (id, own) }
        if let albumId, let albumPrimaryImageTag {
            return (albumId, albumPrimaryImageTag)
        }
        return (id, nil)
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
