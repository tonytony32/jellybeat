import Foundation
import os

/// On-disk descriptor for a third-party loopback `PlaybackSource`, decoded from a
/// `*.jellysource` JSON file in the Sources directory (see
/// `docs/loopback-source-abi-v1.md` §8). Declares only identity, where to reach
/// the source, and arbitration ranking — **never** capabilities, which come from
/// `GET /health` at runtime so a manifest can't overstate what the process does.
nonisolated struct LoopbackSourceManifest: Decodable, Equatable, Sendable {
    let abi: String
    let id: String
    let displayName: String
    let port: Int
    let pathPrefix: String?
    let homeRank: Int?
    let tieRank: Int?
}

/// Scans the Sources directory once and returns the syntactically-valid,
/// de-duplicated manifests. Pure and filesystem-only (no network), so it's
/// unit-testable against a temp dir. Invalid entries are dropped with a logged
/// warning — discovery never crashes on a bad file.
nonisolated enum SourceManifestLoader {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellybeat",
        category: "state"
    )

    /// `~/Library/Application Support/software.trypwood.jellybeat/Sources`.
    static var defaultDirectory: URL? {
        sourcesDirectory(for: "software.trypwood.jellybeat")
    }

    /// Pre-rename location `~/Library/Application Support/software.trypwood.jellysleeve/Sources`.
    /// JellyBeat shipped as **JellySleeve** through v0.2.x; bridges installed
    /// against the old build still write their `*.jellysource` manifests here, so
    /// discovery scans it too (after `defaultDirectory`, which wins collisions).
    /// The old identifier lives in `LegacyIdentity.bundleID` (single source of
    /// truth) — it must stay `jellysleeve` or pre-rename bridges stop being found.
    static var legacyDirectory: URL? {
        sourcesDirectory(for: LegacyIdentity.bundleID)
    }

    /// Directories scanned at launch, in precedence order: the current location
    /// first (it wins `id`/`port` collisions), then the pre-rename one so
    /// not-yet-updated bridges keep working without an ABI bump.
    static var allDirectories: [URL?] { [defaultDirectory, legacyDirectory] }

    private static func sourcesDirectory(for bundleID: String) -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("\(bundleID)/Sources", isDirectory: true)
    }

    private static let allowedIDCharacters =
        CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")

    /// Load and validate every `*.jellysource` in a single `directory`. Kept for
    /// callers (and tests) that scan one location; delegates to the multi-dir
    /// loader. A missing directory yields `[]` (not an error).
    static func load(directory: URL?) -> [LoopbackSourceManifest] {
        load(directories: [directory])
    }

    /// Load and validate every `*.jellysource` across `directories`, with a
    /// SINGLE de-dup set shared across all of them: the first valid manifest for
    /// a given `id`/`port` wins, so earlier directories take precedence. Within a
    /// directory, files are processed in sorted filename order. A missing or
    /// unreadable directory contributes nothing (never an error). Pass the
    /// current Sources dir before the legacy one (see `allDirectories`) so a
    /// post-rename manifest shadows a stale pre-rename copy of the same source.
    static func load(directories: [URL?]) -> [LoopbackSourceManifest] {
        var seenIDs = Set<String>()
        var seenPorts = Set<Int>()
        var result: [LoopbackSourceManifest] = []

        for directory in directories {
            for file in jellysourceFiles(in: directory) {
                guard let data = try? Data(contentsOf: file),
                      let manifest = try? JSONDecoder().decode(LoopbackSourceManifest.self, from: data) else {
                    logger.warning("Ignoring unreadable source manifest \(file.lastPathComponent, privacy: .public)")
                    continue
                }
                if let reason = validationFailure(manifest) {
                    logger.warning("Ignoring source manifest \(file.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
                    continue
                }
                if seenIDs.contains(manifest.id) {
                    logger.warning("Ignoring source manifest \(file.lastPathComponent, privacy: .public): duplicate id \(manifest.id, privacy: .public)")
                    continue
                }
                if seenPorts.contains(manifest.port) {
                    logger.warning("Ignoring source manifest \(file.lastPathComponent, privacy: .public): port \(manifest.port, privacy: .public) already claimed")
                    continue
                }
                seenIDs.insert(manifest.id)
                seenPorts.insert(manifest.port)
                result.append(manifest)
            }
        }
        return result
    }

    /// `*.jellysource` files in `directory`, sorted by filename for determinism.
    /// A missing/unreadable directory (or `nil`) yields `[]`.
    private static func jellysourceFiles(in directory: URL?) -> [URL] {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
              ) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "jellysource" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `nil` when the manifest is valid, else a human-readable reason for the log.
    private static func validationFailure(_ m: LoopbackSourceManifest) -> String? {
        let major = m.abi.split(separator: "/").last.flatMap { Int($0) }
        guard m.abi.hasPrefix("loopback-source/"), major == 1 else {
            return "unsupported abi \"\(m.abi)\""
        }
        guard !m.id.isEmpty, m.id.count <= 128,
              m.id.unicodeScalars.allSatisfy(allowedIDCharacters.contains) else {
            return "malformed id \"\(m.id)\""
        }
        guard m.displayName.isEmpty == false else {
            return "empty displayName"
        }
        guard (1024...65535).contains(m.port) else {
            return "port \(m.port) out of range"
        }
        return nil
    }
}
