import Foundation
import Observation
import os

/// Normalized playback state produced by a non-Jellyfin source, ready to hand to
/// `PlayerStore.applyExternalSnapshot`. The arbiter reads `active` / `changeKey`
/// to decide which source drives, and forwards the rest when this source wins.
nonisolated struct ExternalPlayback: Equatable, Sendable {
    /// The mapped now-playing snapshot, or `nil` when idle.
    let track: TrackSnapshot?
    let isPaused: Bool
    let volume: Int?
    /// Whether the source is currently active (something playing/paused).
    let active: Bool
    /// Identity + transport fingerprint, so the arbiter can tell when playback
    /// *changed* (new video or play/pause flip) for most-recently-changed
    /// arbitration, without comparing every field.
    let changeKey: String

    static let idle = ExternalPlayback(
        track: nil, isPaused: false, volume: nil, active: false, changeKey: "idle"
    )
}

/// Sibling feed to the Jellyfin transport: a lightweight 1 s poll of the YouTube
/// bridge that maps each `BridgeSnapshot` onto the normalized `ExternalPlayback`
/// and notifies the arbiter. It owns no overlay state directly — the arbiter
/// decides whether this source is the active one and, if so, writes the snapshot
/// into `PlayerStore`. Keeps polling even while it's *not* the active source so
/// the arbiter can detect YouTube starting up.
@MainActor
@Observable
final class YouTubeBridgeFeed {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellysleeve",
        category: "state"
    )

    /// Stable identity for the current item when the bridge omits a `videoId`
    /// (e.g. a livestream): keeps `ArtworkView`'s load key and `PlayerStore`'s
    /// track-change smoothing from thrashing across polls.
    private static let fallbackItemId = "youtube-current"

    private let client: YouTubeBridgeClient
    private let pollInterval: Duration

    /// Latest mapped state. `nil` until the first poll completes.
    private(set) var latest: ExternalPlayback?

    /// Invoked after each poll so the owner (arbiter) can re-evaluate the active
    /// source against the refreshed `latest`.
    var onUpdate: (@MainActor () -> Void)?

    private var task: Task<Void, Never>?

    init(client: YouTubeBridgeClient = YouTubeBridgeClient(), pollInterval: Duration = .seconds(1)) {
        self.client = client
        self.pollInterval = pollInterval
    }

    // MARK: - Lifecycle

    func start() {
        guard task == nil else { return }
        Self.logger.notice("Starting YouTube bridge feed")
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        Self.logger.notice("Stopping YouTube bridge feed")
        task?.cancel()
        task = nil
    }

    /// Poll immediately rather than waiting for the next tick — used right after
    /// a flip so the overlay repopulates without a 1 s lag.
    func forceRefresh() async {
        await poll()
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await poll()
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func poll() async {
        let snapshot = await client.fetchNowPlaying()
        guard !Task.isCancelled else { return }
        latest = Self.map(snapshot)
        onUpdate?()
    }

    // MARK: - Mapping (BridgeSnapshot → normalized contract)

    static func map(_ snapshot: BridgeSnapshot?) -> ExternalPlayback {
        guard let snapshot, snapshot.active else { return .idle }

        let itemId = snapshot.videoId ?? fallbackItemId
        let isPaused = !snapshot.isPlaying
        // `durationSec == null` means unknown/livestream — represent as a zero
        // runtime, which the progress bar renders as an indeterminate length.
        let runtime: Duration = snapshot.durationSec.map { .seconds($0) } ?? .zero
        let position: Duration = .seconds(snapshot.positionSec ?? 0)
        let volume = snapshot.volume.map { Int(($0 * 100).rounded()) }

        let track = TrackSnapshot(
            itemId: itemId,
            imageTag: nil,
            artworkItemId: itemId,
            title: snapshot.title ?? "",
            artist: snapshot.artist ?? "",
            album: snapshot.album ?? "",
            runtime: runtime,
            position: position,
            sessionId: "",                    // unused for YouTube commands
            isFavorite: false,
            artworkURL: Self.safeArtworkURL(snapshot.artworkUrl)
        )

        return ExternalPlayback(
            track: track,
            isPaused: isPaused,
            volume: volume,
            active: true,
            changeKey: "\(itemId)|\(isPaused ? "paused" : "playing")"
        )
    }

    /// Accept an artwork URL only if it's `http`/`https`. The string comes from
    /// a local HTTP endpoint that is normally the trusted bridge, but binding to
    /// the port isn't authenticated (the contract's documented residual risk):
    /// a `file://` or other-scheme value must never be dereferenced by the
    /// artwork loader. The bridge already host-allowlists the URL at the source;
    /// this is the consumer-side belt-and-suspenders.
    private static func safeArtworkURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}
