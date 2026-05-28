import AppKit
import MediaPlayer
import os

/// Bridges JellySleeve to macOS's system-wide Now Playing infrastructure.
///
/// Wiring `MPRemoteCommandCenter` makes the hardware media keys (F7-F9 on
/// Apple keyboards), the Control Center module, and the Touch Bar
/// transport widget all route through JellySleeve — no Accessibility
/// permission required, unlike `NSEvent.addGlobalMonitorForEvents`.
///
/// `MPNowPlayingInfoCenter` keeps the OS up to date so the track surfaces
/// in the Now Playing module with title, artist, album, and a fetched
/// artwork. Image refreshes happen out of band so the main actor never
/// blocks on disk/network I/O.
@MainActor
final class MediaCenterController {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellysleeve",
        category: "state"
    )

    private let player: PlayerStore
    private let artworkProvider: ArtworkCacheProvider
    private var observationTask: Task<Void, Never>?
    private var lastAppliedArtworkKey: String?

    init(player: PlayerStore, artworkProvider: ArtworkCacheProvider) {
        self.player = player
        self.artworkProvider = artworkProvider
    }

    /// Register the remote command targets and start observing the
    /// `PlayerStore`. Safe to call once at launch; subsequent state changes
    /// keep flowing through the observation loop.
    func activate() {
        registerCommands()
        startObservation()
    }

    // MARK: - Remote commands

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.dispatch { await self?.player.playPause() }
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            self?.dispatch { await self?.player.playPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.dispatch { await self?.player.playPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.dispatch { await self?.player.nextTrack() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.dispatch { await self?.player.previousTrack() }
            return .success
        }
    }

    private func dispatch(_ work: @escaping @MainActor () async -> Void) {
        Task { @MainActor in
            await work()
        }
    }

    // MARK: - Now Playing info

    private func startObservation() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            self?.refreshAndArm()
        }
    }

    /// Re-applies Now Playing info, then re-arms an Observation tracking
    /// block so the next mutation calls back into this method.
    private func refreshAndArm() {
        refreshNowPlayingInfo()
        withObservationTracking {
            _ = player.currentTrack
            _ = player.isPaused
            _ = player.connectionState
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshAndArm()
            }
        }
    }

    private func refreshNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = player.currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            lastAppliedArtworkKey = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: durationSeconds(track.runtime),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: durationSeconds(track.position),
            MPNowPlayingInfoPropertyPlaybackRate: player.isPaused ? 0.0 : 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]

        // Preserve the previously fetched artwork while we asynchronously
        // pull the new one — avoids a flash of "no image" in the Control
        // Centre.
        if let existing = center.nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = existing
        }

        center.nowPlayingInfo = info
        center.playbackState = player.isPaused ? .paused : .playing

        ensureArtwork(for: track)
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let attoseconds = duration.components.attoseconds
        return Double(duration.components.seconds) + Double(attoseconds) / 1e18
    }

    // MARK: - Artwork sync

    private func ensureArtwork(for track: TrackSnapshot) {
        let key = "\(track.itemId)_\(track.imageTag ?? "none")"
        guard key != lastAppliedArtworkKey else { return }
        lastAppliedArtworkKey = key
        guard let cache = artworkProvider.cache else { return }

        Task { [weak self, key] in
            guard let data = await cache.data(forItemId: track.itemId, tag: track.imageTag),
                  let image = NSImage(data: data) else { return }
            let artwork = Self.makeArtwork(image: image)
            await MainActor.run { [weak self] in
                guard let self,
                      self.lastAppliedArtworkKey == key,
                      var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    /// `MPMediaItemArtwork`'s request handler is invoked from MediaPlayer's
    /// own dispatch queue, so it must not inherit `@MainActor` isolation
    /// (Swift 6 would crash with a queue-assertion failure). We build it
    /// inside a `nonisolated` context to detach it from `self`.
    nonisolated private static func makeArtwork(image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
