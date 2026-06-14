import Foundation
import Observation
import os

/// The set of playback sources JellySleeve knows about: the privileged built-in
/// **Jellyfin** (a non-loopback source with its own WebSocket/polling transport),
/// the built-in **YouTube** loopback source at `127.0.0.1:8976`, and any
/// third-party loopback source declared by a `*.jellysource` manifest (see
/// `docs/loopback-source-abi-v1.md`).
///
/// It owns one `LoopbackSourceClient` + `LoopbackSourceFeed` per loopback source
/// and derives the arbiter's id ordering and home/tie priorities. With only the
/// built-ins present it yields exactly the historical priorities
/// (`homePriority == [.jellyfin, .youtube]`, `tiePriority == [.youtube, .jellyfin]`)
/// so the arbiter's behavior is unchanged for existing users.
@MainActor
@Observable
final class SourceRegistry {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellysleeve",
        category: "state"
    )

    /// A loopback source the registry can talk to (built-in YouTube or a
    /// discovered third party). Jellyfin is deliberately NOT a descriptor — it
    /// has no loopback endpoint and keeps its own transport.
    struct LoopbackDescriptor: Sendable {
        let id: SourceID
        let displayName: String
        let baseURL: URL
        let pathPrefix: String
        let homeRank: Int
        let tieRank: Int
        let isBuiltIn: Bool
    }

    /// Loopback sources in deterministic registry order: built-ins first (YouTube),
    /// then discovered sources by id.
    private(set) var descriptors: [LoopbackDescriptor] = []
    private(set) var clients: [SourceID: LoopbackSourceClient] = [:]
    private(set) var feeds: [SourceID: LoopbackSourceFeed] = [:]

    init(manifests: [LoopbackSourceManifest]) {
        var descs: [LoopbackDescriptor] = []
        var ids: Set<SourceID> = [.jellyfin]   // jellyfin's id is reserved
        var ports = Set<Int>()

        // Built-in YouTube loopback source — seeded first, always wins a collision.
        if let youtube = Self.builtInYouTube() {
            descs.append(youtube)
            ids.insert(youtube.id)
            ports.insert(Self.youtubePort)
        }

        // Discovered third-party sources, in a deterministic id order. Drop any
        // that collide (id or port) with a built-in or an earlier survivor.
        for manifest in manifests.sorted(by: { $0.id < $1.id }) {
            let id = SourceID(rawValue: manifest.id)
            guard !ids.contains(id) else {
                Self.logger.warning("Skipping source \(manifest.id, privacy: .public): id collides with a built-in/earlier source")
                continue
            }
            guard !ports.contains(manifest.port) else {
                Self.logger.warning("Skipping source \(manifest.id, privacy: .public): port \(manifest.port, privacy: .public) already claimed")
                continue
            }
            guard let url = Self.loopbackURL(port: manifest.port) else {
                Self.logger.warning("Skipping source \(manifest.id, privacy: .public): bad loopback URL")
                continue
            }
            descs.append(LoopbackDescriptor(
                id: id,
                displayName: manifest.displayName,
                baseURL: url,
                pathPrefix: manifest.pathPrefix ?? "/v1",
                homeRank: manifest.homeRank ?? 100,
                tieRank: manifest.tieRank ?? 100,
                isBuiltIn: false
            ))
            ids.insert(id)
            ports.insert(manifest.port)
        }

        descriptors = descs
        for descriptor in descs {
            let client = LoopbackSourceClient(baseURL: descriptor.baseURL, pathPrefix: descriptor.pathPrefix)
            clients[descriptor.id] = client
            feeds[descriptor.id] = LoopbackSourceFeed(id: descriptor.id, client: client)
        }
    }

    /// Build a registry by scanning the on-disk Sources directory.
    static func loadingFromDisk() -> SourceRegistry {
        SourceRegistry(manifests: SourceManifestLoader.load(directory: SourceManifestLoader.defaultDirectory))
    }

    // MARK: - Identity & ordering

    /// Every registered source id in stable registry order: Jellyfin first, then
    /// loopback sources (built-ins before discovered). Fed to
    /// `ActivationRecency.observe` as its iteration order, so it must be stable —
    /// Jellyfin-before-YouTube preserves the historical same-pass tie outcome.
    var registeredIDs: [SourceID] { [.jellyfin] + descriptors.map(\.id) }

    /// Ids the menu's Source picker can pin.
    var selectableIDs: [SourceID] { registeredIDs }

    /// Home-fallback order when nothing is playing: Jellyfin first (the home
    /// source), then loopback sources by ascending `homeRank` (ties by id).
    var homePriority: [SourceID] {
        [.jellyfin] + descriptors
            .sorted { ($0.homeRank, $0.id.rawValue) < ($1.homeRank, $1.id.rawValue) }
            .map(\.id)
    }

    /// Both-playing equal-rank tie order: loopback sources by ascending `tieRank`
    /// (ties by id), then Jellyfin last — the home source yields a tie to any
    /// genuinely-playing loopback source.
    var tiePriority: [SourceID] {
        descriptors
            .sorted { ($0.tieRank, $0.id.rawValue) < ($1.tieRank, $1.id.rawValue) }
            .map(\.id) + [.jellyfin]
    }

    /// The TRUSTED display name (from the manifest / built-in), never the
    /// `/health.sourceName` a possibly-squatting process serves.
    func displayName(for id: SourceID) -> String {
        if id == .jellyfin { return "Jellyfin" }
        return descriptors.first { $0.id == id }?.displayName ?? id.rawValue
    }

    // MARK: - Built-ins

    private static let youtubePort = 8976

    private static func builtInYouTube() -> LoopbackDescriptor? {
        guard let url = loopbackURL(port: youtubePort) else { return nil }
        return LoopbackDescriptor(
            id: .youtube, displayName: "YouTube", baseURL: url,
            pathPrefix: "/v1", homeRank: 10, tieRank: 0, isBuiltIn: true
        )
    }

    private static func loopbackURL(port: Int) -> URL? {
        URL(string: "http://127.0.0.1:\(port)")
    }
}
