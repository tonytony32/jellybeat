import Foundation
import Testing
@testable import JellySleeve

/// Tests for the third-party loopback plugin system: the ABI `itemId`/`videoId`
/// alias, the `SourceSelection` open-id codec, the manifest loader's validation
/// and de-duplication, and the registry's id ordering + priority derivation.
@MainActor
struct LoopbackSourceTests {

    // MARK: - ABI: itemId / videoId alias

    private func decode(_ json: String) throws -> BridgeSnapshot {
        try JSONDecoder().decode(BridgeSnapshot.self, from: Data(json.utf8))
    }

    /// The canonical `itemId` (ABI v1) is preferred; the legacy `videoId` (the
    /// originally-shipped bridge) is the fallback; neither present → nil.
    @Test
    func bridgeSnapshotPrefersItemIdThenVideoId() throws {
        #expect(try decode(#"{"active":true,"itemId":"X","videoId":"Y"}"#).videoId == "X")
        #expect(try decode(#"{"active":true,"videoId":"Y"}"#).videoId == "Y")
        #expect(try decode(#"{"active":true}"#).videoId == nil)
    }

    // MARK: - SourceSelection codec (open id space)

    /// Built-in and arbitrary third-party ids round-trip losslessly through the
    /// persisted `rawValue`; "auto"/empty decode to `.auto`. The old persisted
    /// "jellyfin"/"youtube"/"auto" strings therefore migrate with zero rewrite.
    @Test
    func sourceSelectionRoundTripsAnyID() {
        #expect(SourceSelection(rawValue: "youtube")?.forcedKind == .youtube)
        #expect(SourceSelection(rawValue: "youtube")?.rawValue == "youtube")
        #expect(SourceSelection(rawValue: "auto")?.forcedKind == nil)
        #expect(SourceSelection(rawValue: "")?.forcedKind == nil)
        #expect(SourceSelection(rawValue: "auto")?.rawValue == "auto")

        let thirdParty = SourceSelection(rawValue: "com.example.spotify")
        #expect(thirdParty?.forcedKind == SourceID(rawValue: "com.example.spotify"))
        #expect(thirdParty?.rawValue == "com.example.spotify")
    }

    // MARK: - Manifest loader

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ json: String, to dir: URL, as name: String) throws {
        try Data(json.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func manifest(id: String, port: Int, abi: String = "loopback-source/1") -> String {
        #"{"abi":"\#(abi)","id":"\#(id)","displayName":"\#(id)","port":\#(port)}"#
    }

    @Test
    func loaderAcceptsValidAndDropsInvalid() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try write(manifest(id: "com.example.good", port: 8980), to: dir, as: "good.jellysource")
        try write(manifest(id: "com.example.badport", port: 80), to: dir, as: "badport.jellysource")
        try write(manifest(id: "com.example.badabi", port: 8981, abi: "loopback-source/2"),
                  to: dir, as: "badabi.jellysource")
        try write("not json", to: dir, as: "garbage.jellysource")
        try write(manifest(id: "com.example.good", port: 9001), to: dir, as: "z-dupid.jellysource")
        try write(manifest(id: "com.example.dupport", port: 8980), to: dir, as: "z-dupport.jellysource")
        // Wrong extension — ignored entirely.
        try write(manifest(id: "com.example.ignored", port: 9100), to: dir, as: "ignored.json")

        let loaded = SourceManifestLoader.load(directory: dir)
        let ids = loaded.map(\.id)

        #expect(ids == ["com.example.good"])           // only the one valid, non-colliding file
        #expect(loaded.first?.port == 8980)
    }

    @Test
    func loaderMissingDirectoryYieldsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        #expect(SourceManifestLoader.load(directory: missing).isEmpty)
        #expect(SourceManifestLoader.load(directory: nil).isEmpty)
    }

    // MARK: - Registry

    private let spotify = SourceID(rawValue: "com.example.spotify")

    @Test
    func registryBuiltInsReproduceHistoricalPriorities() {
        let registry = SourceRegistry(manifests: [])

        #expect(registry.registeredIDs == [.jellyfin, .youtube])
        #expect(registry.homePriority == [.jellyfin, .youtube])
        #expect(registry.tiePriority == [.youtube, .jellyfin])
        #expect(registry.displayName(for: .jellyfin) == "Jellyfin")
        #expect(registry.displayName(for: .youtube) == "YouTube")
        // Jellyfin is never a loopback descriptor (no client/feed); YouTube is.
        #expect(registry.feeds[.youtube] != nil)
        #expect(registry.clients[.youtube] != nil)
        #expect(registry.feeds[.jellyfin] == nil)
    }

    @Test
    func registryPlacesDiscoveredSourceByRank() {
        let m = LoopbackSourceManifest(
            abi: "loopback-source/1", id: spotify.rawValue, displayName: "Spotify",
            port: 8980, pathPrefix: nil, homeRank: 50, tieRank: 50
        )
        let registry = SourceRegistry(manifests: [m])

        // Jellyfin first, then loopback sources (built-in YouTube before discovered).
        #expect(registry.registeredIDs == [.jellyfin, .youtube, spotify])
        // home: Jellyfin (0), YouTube (10), Spotify (50).
        #expect(registry.homePriority == [.jellyfin, .youtube, spotify])
        // tie: YouTube (0), Spotify (50), then Jellyfin last.
        #expect(registry.tiePriority == [.youtube, spotify, .jellyfin])
        #expect(registry.displayName(for: spotify) == "Spotify")
        #expect(registry.feeds[spotify] != nil)
    }

    @Test
    func registryDropsManifestCollidingWithBuiltIn() {
        let sameID = LoopbackSourceManifest(
            abi: "loopback-source/1", id: "youtube", displayName: "Fake YouTube",
            port: 9000, pathPrefix: nil, homeRank: nil, tieRank: nil
        )
        let samePort = LoopbackSourceManifest(
            abi: "loopback-source/1", id: "com.example.squatter", displayName: "Squatter",
            port: 8976, pathPrefix: nil, homeRank: nil, tieRank: nil
        )
        let registry = SourceRegistry(manifests: [sameID, samePort])

        // Built-ins win both collisions; neither impostor is registered.
        #expect(registry.registeredIDs == [.jellyfin, .youtube])
        #expect(registry.displayName(for: .youtube) == "YouTube")   // not "Fake YouTube"
    }
}
