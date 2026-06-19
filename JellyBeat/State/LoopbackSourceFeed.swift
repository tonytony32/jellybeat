import Foundation
import Observation
import os

/// Normalized playback state produced by a non-Jellyfin source, ready to hand to
/// `PlayerStore.applyExternalSnapshot`. The arbiter reads `active` to decide
/// which source drives, and forwards the rest when this source wins.
nonisolated struct ExternalPlayback: Equatable, Sendable {
    /// The mapped now-playing snapshot, or `nil` when idle.
    let track: TrackSnapshot?
    let isPaused: Bool
    let volume: Int?
    /// Whether the source is currently active (something playing/paused).
    let active: Bool

    static let idle = ExternalPlayback(
        track: nil, isPaused: false, volume: nil, active: false
    )
}

/// Sibling feed to the Jellyfin transport: a lightweight 1 s poll of one loopback
/// `PlaybackSource` that maps each `BridgeSnapshot` onto the normalized
/// `ExternalPlayback` and notifies the arbiter. It owns no overlay state directly
/// — the arbiter decides whether this source is the active one and, if so, writes
/// the snapshot into `PlayerStore`. Keeps polling even while it's *not* the active
/// source so the arbiter can detect this source starting up.
///
/// One instance per loopback source (built-in YouTube + any third-party manifest
/// source); the owning `SourceRegistry` builds them and the arbiter weighs them.
@MainActor
@Observable
final class LoopbackSourceFeed {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellybeat",
        category: "state"
    )

    /// This source's stable identity, used to key presence/recency in the arbiter
    /// and to derive the per-source fallback item id.
    let id: SourceID

    private let client: LoopbackSourceClient
    private let pollInterval: Duration

    /// Latest mapped state. `nil` until the first poll completes.
    private(set) var latest: ExternalPlayback?

    /// The source's self-described capabilities, read from `GET /health` on a
    /// flip. Owned here (not on the arbiter) so capability state lives with the
    /// feed it describes; the arbiter installs it into `PlayerStore` on a flip.
    /// Defaults to the conservative loopback set until a health read confirms.
    private(set) var capabilities: SourceCapabilities = .loopbackDefault

    /// Invoked after each poll so the owner (arbiter) can re-evaluate the active
    /// source against the refreshed `latest`.
    var onUpdate: (@MainActor () -> Void)?

    private var task: Task<Void, Never>?

    init(id: SourceID, client: LoopbackSourceClient, pollInterval: Duration = .seconds(1)) {
        self.id = id
        self.client = client
        self.pollInterval = pollInterval
    }

    // MARK: - Lifecycle

    func start() {
        guard task == nil else { return }
        Self.logger.notice("Starting loopback feed \(self.id.rawValue, privacy: .public)")
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        Self.logger.notice("Stopping loopback feed \(self.id.rawValue, privacy: .public)")
        task?.cancel()
        task = nil
    }

    /// Poll immediately rather than waiting for the next tick — used right after
    /// a flip so the overlay repopulates without a 1 s lag.
    func forceRefresh() async {
        await poll()
    }

    /// Replace the cached capabilities with a fresh read (the arbiter calls this
    /// after fetching `GET /health` on a flip to this source).
    func applyCapabilities(_ caps: SourceCapabilities) {
        capabilities = caps
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
        latest = Self.map(snapshot, fallbackItemId: "\(id.rawValue)-current")
        onUpdate?()
    }

    // MARK: - Mapping (BridgeSnapshot → normalized contract)

    /// `fallbackItemId` gives the item a stable identity when the source omits an
    /// `itemId` (e.g. a livestream), so `ArtworkView`'s load key and
    /// `PlayerStore`'s track-change smoothing don't thrash across polls. Defaults
    /// to a generic constant; the live feed passes a per-source value so distinct
    /// sources don't collide.
    static func map(
        _ snapshot: BridgeSnapshot?,
        fallbackItemId: String = "loopback-current"
    ) -> ExternalPlayback {
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
            sessionId: "",                    // unused for loopback commands
            isFavorite: snapshot.liked ?? false,
            artworkURL: Self.safeArtworkURL(snapshot.artworkUrl)
        )

        return ExternalPlayback(
            track: track,
            isPaused: isPaused,
            volume: volume,
            active: true
        )
    }

    /// Accept an artwork URL only if it's `http`/`https`. The string comes from a
    /// local HTTP endpoint that is normally the trusted source, but binding to the
    /// port isn't authenticated (the ABI's documented residual risk): a `file://`
    /// or other-scheme value must never be dereferenced by the artwork loader.
    /// Consumer-side belt-and-suspenders.
    private static func safeArtworkURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}
