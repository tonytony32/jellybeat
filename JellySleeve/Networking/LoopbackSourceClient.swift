import Foundation
import os

/// Normalized now-playing snapshot from a loopback `PlaybackSource`, decoded from
/// `GET {prefix}/now-playing` (see `docs/loopback-source-abi-v1.md`). The
/// vendor-neutral mapping onto `TrackSnapshot` happens in `LoopbackSourceFeed`.
///
/// All string fields are **untrusted page content** (a video can be titled
/// `<img onerror=…>`). SwiftUI `Text` escapes on render, so they're safe to
/// display as-is, but never interpolate them into HTML/markup.
nonisolated struct BridgeSnapshot: Decodable, Equatable, Sendable {
    let active: Bool
    let source: String?
    let state: String?          // "playing" | "paused"
    let title: String?
    let artist: String?
    let album: String?
    let durationSec: Double?    // null = unknown / livestream
    let positionSec: Double?
    /// Stable item identity. ABI v1 alias: decoded from `itemId`, falling back to
    /// the legacy `videoId` the originally-shipped YouTube bridge emits.
    let videoId: String?
    let artworkUrl: String?
    let volume: Double?         // 0.0–1.0
    let updatedAtMs: Double?

    var isPlaying: Bool { state == "playing" }

    /// Explicit memberwise init — the custom `init(from:)` below otherwise
    /// suppresses the synthesized one, and tests build fixtures by hand.
    init(
        active: Bool, source: String? = nil, state: String? = nil,
        title: String? = nil, artist: String? = nil, album: String? = nil,
        durationSec: Double? = nil, positionSec: Double? = nil, videoId: String? = nil,
        artworkUrl: String? = nil, volume: Double? = nil, updatedAtMs: Double? = nil
    ) {
        self.active = active
        self.source = source
        self.state = state
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSec = durationSec
        self.positionSec = positionSec
        self.videoId = videoId
        self.artworkUrl = artworkUrl
        self.volume = volume
        self.updatedAtMs = updatedAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case active, source, state, title, artist, album
        case durationSec, positionSec, videoId, itemId, artworkUrl, volume, updatedAtMs
    }

    /// Custom decode so the canonical `itemId` (ABI v1) and the legacy `videoId`
    /// (shipped bridge) both populate `videoId`. Kept `nonisolated` (struct-level)
    /// so the `Decodable` conformance stays Sendable for the generic `get`.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = try c.decode(Bool.self, forKey: .active)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        durationSec = try c.decodeIfPresent(Double.self, forKey: .durationSec)
        positionSec = try c.decodeIfPresent(Double.self, forKey: .positionSec)
        videoId = try c.decodeIfPresent(String.self, forKey: .itemId)
            ?? c.decodeIfPresent(String.self, forKey: .videoId)
        artworkUrl = try c.decodeIfPresent(String.self, forKey: .artworkUrl)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume)
        updatedAtMs = try c.decodeIfPresent(Double.self, forKey: .updatedAtMs)
    }
}

/// Stateless HTTP client for one loopback `PlaybackSource` — the consumer side of
/// `docs/loopback-source-abi-v1.md`, parameterized by `baseURL` + `pathPrefix` so
/// the same code serves the built-in YouTube bridge (`127.0.0.1:8976`) and any
/// third-party source declared by a manifest. A plain value type so it can be
/// shared by the polling feed and used directly as the `PlaybackCommanding` sink
/// across actor boundaries.
///
/// Reachability: a refused connection (the source isn't running) is the *normal
/// idle* state, never an error — reads map it to `nil`. Plain-HTTP to the
/// `127.0.0.1` IP literal is exempt from App Transport Security, and the app is
/// unsandboxed, so no entitlement/ATS exception is required for the loopback call.
nonisolated struct LoopbackSourceClient: Sendable, PlaybackCommanding {
    let baseURL: URL
    let pathPrefix: String

    private let session: URLSession

    private static let logger = Logger(
        subsystem: "software.trypwood.jellysleeve",
        category: "networking"
    )

    /// `protocolClasses` lets tests inject a `MockURLProtocol` without a real
    /// source listening.
    init(baseURL: URL, pathPrefix: String = "/v1", protocolClasses: [AnyClass]? = nil) {
        self.baseURL = baseURL
        self.pathPrefix = pathPrefix
        let config = URLSessionConfiguration.ephemeral
        // The source is local and fast; a short budget keeps a hung handler from
        // stalling the 1 s poll cadence. Don't wait for connectivity — a refused
        // connection should resolve to "idle" immediately.
        config.timeoutIntervalForRequest = 2
        config.waitsForConnectivity = false
        if let protocolClasses {
            config.protocolClasses = protocolClasses
        }
        self.session = URLSession(configuration: config)
    }

    /// `{baseURL}{pathPrefix}/{name}` — e.g. `http://127.0.0.1:8976/v1/command`.
    private func endpoint(_ name: String) -> URL {
        baseURL
            .appendingPathComponent(pathPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            .appendingPathComponent(name)
    }

    // MARK: - Reads

    /// Current now-playing snapshot, or `nil` when the source is idle or
    /// unreachable. A refused connection is treated as idle, never an error
    /// (the ABI's §6). A `{"active": false}` body is normalized to `nil` too, so
    /// callers get a single "nothing is playing" signal.
    func fetchNowPlaying() async -> BridgeSnapshot? {
        do {
            let snapshot: BridgeSnapshot = try await get("now-playing")
            return snapshot.active ? snapshot : nil
        } catch {
            // A refused / dropped / timed-out connection is the *normal* idle
            // state (the source isn't running) — stay quiet. Anything else
            // (a decode failure from a schema change, an unexpected status) is
            // logged so a silent permanent "idle" is debuggable instead of
            // invisible.
            if !Self.isExpectedIdleError(error) {
                Self.logger.error("Source now-playing read failed: \(String(describing: error), privacy: .public)")
            }
            return nil
        }
    }

    /// True for the connection-level failures that simply mean the source isn't
    /// listening — which the ABI says to treat as idle, never an error.
    private static func isExpectedIdleError(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        switch url.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .notConnectedToInternet, .timedOut, .cancelled:
            return true
        default:
            return false
        }
    }

    /// Self-describing capabilities from `GET {prefix}/health`. Falls back to the
    /// conservative loopback default when the source is unreachable or the body
    /// can't be read.
    func fetchCapabilities() async -> SourceCapabilities {
        guard let health: HealthEnvelope = try? await get("health"),
              let caps = health.capabilities else {
            return .loopbackDefault
        }
        return SourceCapabilities(
            canPlayPause: caps.canPlayPause ?? true,
            canNext: caps.canNext ?? true,
            canPrevious: caps.canPrevious ?? true,
            canSeek: caps.canSeek ?? true,
            canSetVolume: caps.canSetVolume ?? true,
            hasFavorites: caps.hasFavorites ?? false,
            hasQueue: caps.hasQueue ?? false,
            // Absent on older sources that predate the command → stay false so
            // the artwork's focus affordance only lights up when supported.
            canFocusTab: caps.canFocusTab ?? false
        )
    }

    // MARK: - PlaybackCommanding (POST {prefix}/command)

    func playPause() async throws { try await command("toggle") }
    func next() async throws { try await command("next") }
    func previous() async throws { try await command("previous") }

    func seek(to position: Duration) async throws {
        try await command("seek", value: position.seconds)
    }

    func setVolume(percent: Int) async throws {
        let clamped = min(100, max(0, percent))
        try await command("setVolume", value: Double(clamped) / 100.0)
    }

    /// Loopback sources don't model favorites — report unsupported so the heart
    /// UI stays hidden and `PlayerStore` keeps its optimistic state untouched.
    func toggleFavorite(itemId: String, current: Bool) async throws -> Bool? {
        nil
    }

    /// Raise the source's window/tab. `focusTab` carries no value. Best-effort:
    /// the source replies `2xx` and applies it asynchronously; `503`/`409`
    /// (stale/no active player) surface as a transport error the caller swallows,
    /// and a refused connection is the normal idle state (`command` lets the
    /// `URLError` propagate for the caller to treat as idle).
    func focusTab() async throws { try await command("focusTab") }

    // MARK: - Internals

    private struct HealthEnvelope: Decodable, Sendable {
        let capabilities: Capabilities?
        struct Capabilities: Decodable, Sendable {
            let canPlayPause: Bool?
            let canNext: Bool?
            let canPrevious: Bool?
            let canSeek: Bool?
            let canSetVolume: Bool?
            let hasFavorites: Bool?
            let hasQueue: Bool?
            let canFocusTab: Bool?
        }
    }

    private struct CommandBody: Encodable {
        let action: String
        let value: Double?
    }

    private func get<T: Decodable & Sendable>(_ name: String) async throws -> T {
        var request = URLRequest(url: endpoint(name))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        // Reject a non-2xx *before* decoding (mirrors the POST/command path), so
        // an unexpected status surfaces as a logged error in `fetchNowPlaying`
        // (ABI §6) instead of a body that happens to decode being silently
        // treated as idle. The UI outcome stays "idle" either way.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NetworkError.serverError(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Fire a transport command. Best-effort and asynchronous on the source side
    /// (it returns `2xx` and applies later), so we only surface hard transport
    /// failures; the resulting state shows up in a later now-playing read, which
    /// is the source of truth.
    private func command(_ action: String, value: Double? = nil) async throws {
        var request = URLRequest(url: endpoint("command"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CommandBody(action: action, value: value))
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.transport("Non-HTTP response from source")
        }
        switch http.statusCode {
        case 200...299:
            return
        case 503:
            // The source went stale between our read and this command. Treat as
            // transport so the caller's toast reads sensibly.
            throw NetworkError.transport("The source isn't responding right now.")
        default:
            throw NetworkError.serverError(http.statusCode)
        }
    }
}
