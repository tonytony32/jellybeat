import Foundation
import os

/// Normalized now-playing snapshot from a `PlaybackSource`, decoded from the
/// YouTube bridge's `GET /v1/now-playing`. Field shapes follow the bridge wire
/// format (`docs/api.md`); the vendor-neutral mapping onto `TrackSnapshot`
/// happens in `YouTubeBridgeFeed`.
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
    let videoId: String?
    let artworkUrl: String?
    let volume: Double?         // 0.0–1.0
    let liked: Bool?            // like / me gusta state; null = unknown
    let updatedAtMs: Double?

    var isPlaying: Bool { state == "playing" }
}

/// Stateless HTTP client for the YouTube Safari bridge — one implementation of
/// the vendor-neutral `PlaybackSource` contract, served on loopback at
/// `http://127.0.0.1:8976` (`docs/api.md`). A plain value type so it can be
/// shared by the polling feed and used directly as the `PlaybackCommanding`
/// sink across actor boundaries.
///
/// Reachability: a refused connection (Safari closed / no YouTube tab /
/// extension disabled) is the *normal idle* state, never an error — reads map it
/// to `nil`. Plain-HTTP to the `127.0.0.1` IP literal is exempt from App
/// Transport Security, and the app is unsandboxed, so no entitlement/ATS
/// exception is required for the loopback call.
nonisolated struct YouTubeBridgeClient: Sendable, PlaybackCommanding {
    static let baseURL = URL(string: "http://127.0.0.1:8976")!

    private let session: URLSession

    private static let logger = Logger(
        subsystem: "software.trypwood.jellysleeve",
        category: "networking"
    )

    /// `protocolClasses` lets tests inject a `MockURLProtocol` without a real
    /// bridge listening.
    init(protocolClasses: [AnyClass]? = nil) {
        let config = URLSessionConfiguration.ephemeral
        // The bridge is local and fast; a short budget keeps a hung handler from
        // stalling the 1 s poll cadence. Don't wait for connectivity — a refused
        // connection should resolve to "idle" immediately.
        config.timeoutIntervalForRequest = 2
        config.waitsForConnectivity = false
        if let protocolClasses {
            config.protocolClasses = protocolClasses
        }
        self.session = URLSession(configuration: config)
    }

    // MARK: - Reads

    /// Current now-playing snapshot, or `nil` when the source is idle or
    /// unreachable. A refused connection is treated as idle, never an error
    /// (the contract's §4). A `{"active": false}` body is normalized to `nil`
    /// too, so callers get a single "nothing is playing" signal.
    func fetchNowPlaying() async -> BridgeSnapshot? {
        do {
            let snapshot: BridgeSnapshot = try await get("/v1/now-playing")
            return snapshot.active ? snapshot : nil
        } catch {
            // A refused / dropped / timed-out connection is the *normal* idle
            // state (Safari closed, no YouTube tab) — stay quiet. Anything else
            // (a decode failure from a schema change, an unexpected status) is
            // logged so a silent permanent "idle" is debuggable instead of
            // invisible.
            if !Self.isExpectedIdleError(error) {
                Self.logger.error("Bridge now-playing read failed: \(String(describing: error), privacy: .public)")
            }
            return nil
        }
    }

    /// True for the connection-level failures that simply mean the bridge isn't
    /// listening — which the contract says to treat as idle, never an error.
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

    /// Self-describing capabilities from `GET /v1/health`. Falls back to the
    /// YouTube constant set when the source is unreachable or the body can't be
    /// read (the bridge reports these as constants anyway).
    func fetchCapabilities() async -> SourceCapabilities {
        guard let health: HealthEnvelope = try? await get("/v1/health"),
              let caps = health.capabilities else {
            return .youtube
        }
        return SourceCapabilities(
            canPlayPause: caps.canPlayPause ?? true,
            canNext: caps.canNext ?? true,
            canPrevious: caps.canPrevious ?? true,
            canSeek: caps.canSeek ?? true,
            canSetVolume: caps.canSetVolume ?? true,
            hasFavorites: caps.hasFavorites ?? false,
            hasQueue: caps.hasQueue ?? false,
            // The bridge's favorite is always YouTube's "like" — render a thumbs-up.
            favoriteStyle: .like,
            // Absent on older bridges that predate the command → stay false so
            // the artwork's focus affordance only lights up when supported.
            canFocusTab: caps.canFocusTab ?? false
        )
    }

    // MARK: - PlaybackCommanding (POST /v1/command)

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

    /// Toggle YouTube's "like" for the current video. We send the idempotent
    /// `like`/`unlike` (the bridge no-ops if already in that state) rather than a
    /// blind toggle, so a stale `current` can't double-flip. The command is
    /// best-effort/async on the bridge side, so we optimistically report the
    /// target value; the authoritative `liked` arrives in a later now-playing
    /// poll (which `PlayerStore` trusts for this source).
    func toggleFavorite(itemId: String, current: Bool) async throws -> Bool? {
        let target = !current
        try await command(target ? "like" : "unlike")
        return target
    }

    /// Raise the Safari tab+window that's playing. `focusTab` carries no value.
    /// Best-effort: the bridge replies `202` and delivers it to Safari on its
    /// next sync (≤ ~1 s); `503`/`409` (stale/no active player) surface as a
    /// transport error the caller swallows, and a refused connection is the
    /// normal idle state (`command` lets the `URLError` propagate for the
    /// caller to treat as idle).
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

    private func get<T: Decodable & Sendable>(_ path: String) async throws -> T {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Fire a transport command. Best-effort and asynchronous on the bridge side
    /// (it returns `202` and applies on the next sync), so we only surface hard
    /// transport failures; the resulting state shows up in a later now-playing
    /// read, which is the source of truth.
    private func command(_ action: String, value: Double? = nil) async throws {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/command"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CommandBody(action: action, value: value))
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.transport("Non-HTTP response from bridge")
        }
        switch http.statusCode {
        case 200...299:
            return
        case 503:
            // safari_disconnected — the tab went stale between our read and this
            // command. Treat as transport so the caller's toast reads sensibly.
            throw NetworkError.transport("YouTube isn't responding right now.")
        default:
            throw NetworkError.serverError(http.statusCode)
        }
    }
}
