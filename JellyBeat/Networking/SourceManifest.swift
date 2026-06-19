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
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("software.trypwood.jellybeat/Sources", isDirectory: true)
    }

    private static let allowedIDCharacters =
        CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")

    /// Load and validate every `*.jellysource` in `directory`. A missing
    /// directory yields `[]` (not an error). The result is de-duplicated by `id`
    /// and by `port` (first valid file, in sorted filename order, wins) so the
    /// registry sees a clean, deterministic set.
    static func load(directory: URL?) -> [LoopbackSourceManifest] {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
              ) else {
            return []
        }

        let files = entries
            .filter { $0.pathExtension == "jellysource" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var seenIDs = Set<String>()
        var seenPorts = Set<Int>()
        var result: [LoopbackSourceManifest] = []

        for file in files {
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
        return result
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
