import Foundation
import SwiftUI
import os

/// Two-tier artwork cache. Memory-first, then disk, then network through the
/// supplied `JellyfinClient`. Keys are `"<itemId>_<tag>"` so server-side
/// artwork changes (new tag) get fresh downloads automatically (plan §3.2).
///
/// `Data` is the public currency rather than `NSImage` so the actor stays
/// nonisolated-friendly and the UI layer constructs images on the main actor.
actor ArtworkCache {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellybeat",
        category: "state"
    )

    private let directory: URL
    private let memoryCap: Int
    private let client: JellyfinClient

    /// Insertion-ordered list of keys for cheap approximate-LRU pruning.
    private var memory: [String: Data] = [:]
    private var insertionOrder: [String] = []

    init(client: JellyfinClient, memoryCap: Int = 50) {
        self.client = client
        self.memoryCap = memoryCap
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        // Versioned subdirectory so changes to the fetch parameters (image
        // size, format) automatically invalidate the previously cached
        // entries instead of serving the lower-quality images forever.
        self.directory = cacheRoot
            .appendingPathComponent("software.trypwood.jellybeat", isDirectory: true)
            .appendingPathComponent("artwork_v3", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    /// Return PNG bytes for the requested artwork, fetching them if needed.
    /// (PNG, not JPEG: `fetchArtwork` requests `format=Png` to avoid ringing
    /// artefacts around lettering.) Returns nil only when both the cache and the
    /// network fail; the UI falls back to a placeholder in that case.
    func data(forItemId itemId: String, tag: String?) async -> Data? {
        let key = Self.cacheKey(itemId: itemId, tag: tag)

        if let cached = memory[key] {
            touch(key: key)
            return cached
        }

        let url = directory.appendingPathComponent("\(key).png")
        if let onDisk = try? Data(contentsOf: url) {
            store(key: key, data: onDisk)
            return onDisk
        }

        do {
            let fetched = try await client.fetchArtwork(itemId: itemId, tag: tag)
            try? fetched.write(to: url)
            store(key: key, data: fetched)
            return fetched
        } catch {
            Self.logger.error("Artwork fetch failed for \(itemId, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func store(key: String, data: Data) {
        if memory[key] == nil {
            insertionOrder.append(key)
        } else {
            promote(key: key)
        }
        memory[key] = data
        while insertionOrder.count > memoryCap {
            let evicted = insertionOrder.removeFirst()
            memory.removeValue(forKey: evicted)
        }
    }

    /// Mark an existing entry as most-recently-used so the eviction policy is
    /// true LRU rather than insertion-order FIFO: a frequently requested cover
    /// stays resident even when it was one of the first ones cached.
    private func touch(key: String) {
        guard memory[key] != nil else { return }
        promote(key: key)
    }

    private func promote(key: String) {
        guard let index = insertionOrder.firstIndex(of: key) else { return }
        insertionOrder.remove(at: index)
        insertionOrder.append(key)
    }

    private static func cacheKey(itemId: String, tag: String?) -> String {
        "\(itemId)_\(tag ?? "notag")"
    }
}

// MARK: - SwiftUI environment plumbing

/// Mutable holder so SwiftUI views can pick up a freshly-built `ArtworkCache`
/// after the overlay window has already been hosted. We can't inject the
/// `ArtworkCache` directly through `.environment(\.value)` because the
/// SwiftUI environment is captured at host time, before `applicationDidFinish-
/// Launching` finishes wiring the polling stack; nor can we re-inject without
/// rebuilding the view tree.
///
/// Wrapping it in an `@Observable` reference type means views re-evaluate when
/// `cache` flips from nil to non-nil (or to a different instance after the
/// user reconfigures the server), so the placeholder reload happens
/// automatically.
@MainActor
@Observable
final class ArtworkCacheProvider {
    var cache: ArtworkCache?
}
