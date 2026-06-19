import AppKit
import MediaPlayer
import os

/// Bridges JellyBeat to macOS's system-wide Now Playing infrastructure.
///
/// Wiring `MPRemoteCommandCenter` makes the hardware media keys (F7-F9 on
/// Apple keyboards), the Control Center module, and the Touch Bar
/// transport widget all route through JellyBeat — no Accessibility
/// permission required, unlike `NSEvent.addGlobalMonitorForEvents`.
///
/// `MPNowPlayingInfoCenter` keeps the OS up to date so the track surfaces
/// in the Now Playing module with title, artist, album, and a fetched
/// artwork. Image refreshes happen out of band so the main actor never
/// blocks on disk/network I/O.
@MainActor
final class MediaCenterController {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellybeat",
        category: "state"
    )

    private let player: PlayerStore
    private let artworkProvider: ArtworkCacheProvider
    private var observationTask: Task<Void, Never>?
    private var lastAppliedArtworkKey: String?
    /// Whether the most recent non-nil track came from a browser-backed source
    /// (YouTube via the Safari bridge). Safari registers its *own* system Now
    /// Playing entry while it plays audio, and macOS strands that entry when
    /// Safari quits (a dead-PID card lingering with the video's artwork). We use
    /// this to know when to evict it — see `evictStaleBrowserNowPlaying`.
    private var lastSourceWasBrowser = false
    /// In-flight eviction (a brief re-assert, then stop). Cancelled if a new
    /// track arrives first, so we never wipe live playback.
    private var evictionTask: Task<Void, Never>?

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
        // play/pause are directional: only act if the state actually needs
        // to change. macOS sends pauseCommand on incoming calls or audio
        // interrupts — if music is already paused, a toggle would wrongly
        // start playback instead of doing nothing.
        center.playCommand.addTarget { [weak self] _ in
            self?.dispatch {
                guard let self, self.player.isPaused else { return }
                await self.player.playPause()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.dispatch {
                guard let self, !self.player.isPaused else { return }
                await self.player.playPause()
            }
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
            _ = player.jellyfinIsActiveSource
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshAndArm()
            }
        }
    }

    private func refreshNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = player.currentTrack else {
            if lastSourceWasBrowser {
                evictStaleBrowserNowPlaying(center)
            } else {
                center.nowPlayingInfo = nil
                center.playbackState = .stopped
            }
            lastAppliedArtworkKey = nil
            lastSourceWasBrowser = false
            return
        }

        // A real track is up: cancel any pending eviction so its delayed clear
        // can't wipe live playback.
        evictionTask?.cancel()
        evictionTask = nil

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
        // Remember whether this source registers its own system card, so we know
        // to evict Safari's stranded entry when it goes idle.
        lastSourceWasBrowser = !player.jellyfinIsActiveSource

        ensureArtwork(for: track)
    }

    /// The browser-backed source (YouTube via Safari) just went idle. Safari owns
    /// a separate system Now Playing entry while it plays audio, and macOS leaves
    /// it stranded — with the dead PID — when Safari quits, so the card lingers
    /// with the video's title and artwork. We can't clear another app's entry via
    /// `MPNowPlayingInfoCenter`, but we can *supersede* it: assert a fresh playing
    /// edge so `mediaremoteagent` promotes us to the active now-playing app over
    /// the dead Safari entry, then stop — our `.stopped` clears the surface.
    ///
    /// This works because JellyBeat is already a now-playing app without
    /// producing local audio (it owns the surface for Jellyfin the same way); the
    /// only reason Safari outranked us during playback was that it was the live
    /// audio source. Once it's gone, a new assertion wins.
    private func evictStaleBrowserNowPlaying(_ center: MPNowPlayingInfoCenter) {
        // Re-assert with the just-departed track's info (whatever we last set),
        // bumped to a playing rate, so the assertion is a valid playing edge.
        var info = center.nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        center.nowPlayingInfo = info
        center.playbackState = .playing

        evictionTask?.cancel()
        evictionTask = Task { @MainActor [weak self] in
            // Give the agent a beat to re-point the surface at us before we clear.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let center = MPNowPlayingInfoCenter.default()
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            self?.evictionTask = nil
        }
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let attoseconds = duration.components.attoseconds
        return Double(duration.components.seconds) + Double(attoseconds) / 1e18
    }

    // MARK: - Artwork sync

    private func ensureArtwork(for track: TrackSnapshot) {
        let key = "\(track.artworkItemId)_\(track.imageTag ?? "none")"
        guard key != lastAppliedArtworkKey else { return }
        lastAppliedArtworkKey = key
        guard let cache = artworkProvider.cache else { return }

        Task { [weak self, key] in
            guard let data = await cache.data(forItemId: track.artworkItemId, tag: track.imageTag),
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
