import AppKit
import os

/// Owns the playback feed lifecycle: the WebSocket-preferred / polling-fallback
/// transport stack, its reconnection policy, the sleep/wake handling, and the
/// debounced reconfigure when connection settings change.
///
/// Split out of `AppDelegate` so the transport state machine can be reasoned
/// about (and eventually tested) without dragging in window management. The
/// owner wires window-visibility events to `pause(reason:)` / `resume(reason:)`.
@MainActor
final class PlaybackConnectionCoordinator {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellybeat",
        category: "state"
    )

    private let settings: SettingsStore
    private let player: PlayerStore
    private let artworkProvider: ArtworkCacheProvider

    private var poller: PlaybackPoller?
    private var socketClient: JellyfinSocketClient?
    private var socketStateTask: Task<Void, Never>?
    /// The pending 60 s WebSocket-revival timer scheduled after we've fallen
    /// back to polling. Held so a fresh failure cycle cancels the previous
    /// timer instead of stacking another sleeping task on top of it.
    private var socketReconnectTask: Task<Void, Never>?
    private var socketFailureStreak: Int = 0
    private var currentClient: JellyfinClient?
    private var debouncedReconfigure: Task<Void, Never>?
    private var sleepWakeObservers: [NSObjectProtocol] = []

    /// Once we've fallen back to polling we stop trying to revive the socket
    /// for this configuration. A reconfigure (new baseURL / user / key) or a
    /// relaunch resets it.
    private static let socketMaxConsecutiveFailures = 3

    init(
        settings: SettingsStore,
        player: PlayerStore,
        artworkProvider: ArtworkCacheProvider
    ) {
        self.settings = settings
        self.player = player
        self.artworkProvider = artworkProvider
    }

    // MARK: - Lifecycle

    /// Begin observing the system and the configuration, and bring up the
    /// transport stack from the current settings.
    func activate() {
        observeSleepWake()
        start()
        watchSettingsForReconfiguration()
    }

    /// Tear down the transport stack and stop observing the system. Called on
    /// app termination.
    func shutdown() {
        stop()
        for observer in sleepWakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        sleepWakeObservers.removeAll()
    }

    /// Reconfigure the playback feed (WebSocket preferred, polling fallback)
    /// from the current settings. Safe to call repeatedly; tears down any
    /// previous stack first.
    func start() {
        stop()
        guard let config = settings.jellyfinConfiguration else {
            Self.logger.notice("Configuration incomplete; staying in .idle.")
            player.updateConnection(.idle)
            return
        }
        let client = JellyfinClient(configuration: config)
        let cache = ArtworkCache(client: client)
        let poller = PlaybackPoller(store: player)
        let socket = JellyfinSocketClient(
            configuration: config,
            deviceId: settings.deviceId,
            store: player
        )

        self.currentClient = client
        self.artworkProvider.cache = cache
        self.poller = poller
        self.socketClient = socket
        self.socketFailureStreak = 0
        player.configure(client: client, poller: poller)
        player.connectionMode = .unknown
        player.updateConnection(.connecting)

        // Drive the swap-to-polling decision off the socket's state stream.
        socketStateTask?.cancel()
        socketStateTask = Task { [weak self] in
            await self?.observeSocketStates(socket)
        }

        Task { [weak self, socket, client, config] in
            guard let self else { return }
            await self.probeAndStart(socket: socket, client: client, userId: config.userId)
        }

        watchPlaybackForIntervalAdaptation()
    }

    /// Fetches the current session list before opening the WebSocket so the
    /// subscription interval is tuned from the very first push. If any session
    /// for this user is already playing → fast (1500 ms); otherwise → slow
    /// (4000 ms, 4× less traffic while idle). On probe failure, defaults to
    /// slow so a cold start with no active playback is always frugal.
    private func probeAndStart(
        socket: JellyfinSocketClient,
        client: JellyfinClient,
        userId: String
    ) async {
        var intervalMs = 4000
        do {
            let sessions = try await client.fetchSessions()
            if sessions.contains(where: { $0.userId == userId && $0.nowPlayingItem != nil }) {
                intervalMs = 1500
            }
        } catch {
            Self.logger.notice("Session probe failed (\(error.localizedDescription, privacy: .public)); using slow interval.")
        }
        Self.logger.notice("Session probe → \(intervalMs, privacy: .public) ms")
        await socket.start(intervalMs: intervalMs)
    }

    /// Adapts the WebSocket subscription interval whenever `currentTrack`
    /// changes. Playing → 1500 ms; idle → 4000 ms. `setSessionsInterval` is a
    /// no-op when the socket is not connected, so stale values are stored and
    /// applied automatically on the next `start()`.
    private func watchPlaybackForIntervalAdaptation() {
        withObservationTracking {
            _ = player.currentTrack
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.adaptSessionsInterval()
                self.watchPlaybackForIntervalAdaptation()
            }
        }
    }

    private func adaptSessionsInterval() {
        guard let socket = socketClient else { return }
        let ms = player.currentTrack != nil ? 1500 : 4000
        Self.logger.notice("Sessions interval adapted → \(ms, privacy: .public) ms")
        Task { await socket.setSessionsInterval(ms) }
    }

    func stop() {
        let oldPoller = poller
        let oldSocket = socketClient
        let oldClient = currentClient
        poller = nil
        socketClient = nil
        currentClient = nil
        artworkProvider.cache = nil
        socketStateTask?.cancel()
        socketStateTask = nil
        socketReconnectTask?.cancel()
        socketReconnectTask = nil
        player.configure(client: nil, poller: nil)
        player.connectionMode = .unknown
        if let oldPoller {
            Task { await oldPoller.stop() }
        }
        // Discard the socket *and* free its URLSession/delegate (a new stack is
        // built in `start()`). `invalidate` supersedes `stop` here.
        if let oldSocket {
            Task { await oldSocket.invalidate() }
        }
        // Same for the REST client's two sessions — the cache shared this
        // client, but it's been detached above, so nothing reuses them.
        oldClient?.invalidate()
    }

    // MARK: - WebSocket ⇄ polling orchestration

    /// Reacts to socket state transitions:
    ///  - `.connected` → make sure the poller is stopped (server is pushing).
    ///  - `.failed`    → increment the streak; if we hit the cap, hand over
    ///                   to the polling poller permanently for this config.
    private func observeSocketStates(_ socket: JellyfinSocketClient) async {
        for await state in socket.stateStream {
            guard !Task.isCancelled else { return }
            switch state {
            case .connecting, .idle:
                continue
            case .connected:
                socketFailureStreak = 0
                player.connectionMode = .webSocket
                player.updateConnection(.connected)
                if let poller {
                    Self.logger.notice("WebSocket up; pausing polling fallback.")
                    Task { await poller.stop() }
                }
            case .failed(let message):
                socketFailureStreak += 1
                Self.logger.error("WebSocket failed (\(self.socketFailureStreak, privacy: .public)/\(Self.socketMaxConsecutiveFailures, privacy: .public)): \(message, privacy: .public)")
                if socketFailureStreak >= Self.socketMaxConsecutiveFailures {
                    Self.logger.notice("WebSocket gave up after \(self.socketFailureStreak, privacy: .public) failures; switching to polling.")
                    startPollerFallback()
                    // Don't return — keep the loop alive so a successful
                    // reconnect can flip us back to WebSocket mode. Schedule
                    // a reconnect attempt after a 60 s backoff.
                    scheduleWebSocketReconnect(socket: socket)
                } else {
                    // Retry the socket with a short backoff before giving up.
                    Task { [weak self, socket] in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard !Task.isCancelled, let self else { return }
                        if self.socketClient === socket {
                            await socket.start()
                        }
                    }
                }
            }
        }
    }

    private func startPollerFallback() {
        guard let client = currentClient,
              let config = settings.jellyfinConfiguration,
              let poller else { return }
        // Idempotent: skip if the poller is already the active transport.
        // Called repeatedly during WebSocket reconnect cycles — only the
        // first call (or a call after a brief WebSocket reconnect) needs
        // to actually start the poller.
        guard player.connectionMode != .polling else { return }
        player.connectionMode = .polling
        Task { [poller, settings] in
            await poller.start(
                client: client,
                userId: config.userId,
                baseDelay: settings.refreshRate
            )
        }
    }

    /// Schedule a WebSocket reconnect attempt after a 60 s backoff. Called
    /// after the socket has permanently failed and the poller has taken over.
    /// If the reconnect succeeds, `observeSocketStates` receives `.connected`
    /// and stops the poller; if it fails again, the cycle repeats.
    private func scheduleWebSocketReconnect(socket: JellyfinSocketClient) {
        // Cancel any reconnect already counting down so repeated failure
        // cycles don't accumulate sleeping tasks.
        socketReconnectTask?.cancel()
        socketReconnectTask = Task { [weak self, socket] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled,
                  let self, self.socketClient === socket else { return }
            self.socketReconnectTask = nil
            Self.logger.notice("Retrying WebSocket after polling fallback.")
            // Reset streak so the socket gets a fresh set of attempts.
            self.socketFailureStreak = 0
            await socket.start()
        }
    }

    // MARK: - Pause / resume (driven by window visibility + sleep/wake)

    func pause(reason: String) {
        if let poller {
            Self.logger.notice("Pause poller (\(reason, privacy: .public))")
            Task { await poller.pause() }
        }
        if let socket = socketClient {
            Self.logger.notice("Stop socket (\(reason, privacy: .public))")
            Task { await socket.stop() }
        }
    }

    /// Force an immediate Jellyfin refresh. Used by the arbiter when control
    /// flips back to Jellyfin so the overlay repopulates promptly instead of
    /// waiting for the next transport tick.
    ///
    /// In polling mode, poke the poller. In WebSocket mode the poller is stopped,
    /// so poking it does nothing and the overlay would otherwise sit on stale
    /// state (e.g. the idle snapshot YouTube left) until the next socket push —
    /// up to several seconds, with the controls inert. Do a one-shot
    /// `fetchSessions` + `ingest` instead so the flip-back is instant regardless
    /// of transport. Both ingests run on the main actor, so this can't race the
    /// socket's.
    func forceRefresh() {
        if player.connectionMode == .polling, let poller {
            Task { await poller.forceRefresh() }
            return
        }
        guard let client = currentClient,
              let userId = settings.jellyfinConfiguration?.userId else { return }
        Task { @MainActor in
            guard let sessions = try? await client.fetchSessions() else { return }
            player.ingest(sessions: sessions, userId: userId)
        }
    }

    func resume(reason: String) {
        if let poller {
            Self.logger.notice("Resume poller (\(reason, privacy: .public))")
            Task { await poller.resume() }
        }
        if let socket = socketClient {
            Self.logger.notice("Reconnect socket (\(reason, privacy: .public))")
            Task { await socket.start() }
        }
    }

    // MARK: - Sleep / wake

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        let sleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pause(reason: "system will sleep")
            }
        }
        let wake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.resume(reason: "system woke")
                if let poller = self.poller {
                    Task { await poller.forceRefresh() }
                }
            }
        }
        sleepWakeObservers = [sleep, wake]
    }

    // MARK: - Settings-driven reconfigure

    private func watchSettingsForReconfiguration() {
        // Re-evaluate the polling stack whenever the user changes baseURL,
        // apiKey, userId, allowSelfSigned, or refreshRate. We observe those
        // properties precisely via the Observation framework rather than the
        // firehose `UserDefaults.didChangeNotification`, which also fires on
        // every overlay-position write in `windowDidMove` and would needlessly
        // schedule a reconfigure pass. Still debounced 500 ms because a
        // SecureField edit emits one mutation per keystroke.
        withObservationTracking {
            _ = settings.baseURLString
            _ = settings.apiKey
            _ = settings.userId
            _ = settings.allowSelfSigned
            _ = settings.refreshRate
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleDebouncedReconfigure()
                self.watchSettingsForReconfiguration()
            }
        }
    }

    private func scheduleDebouncedReconfigure() {
        debouncedReconfigure?.cancel()
        debouncedReconfigure = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.reconfigureFromSettings()
        }
    }

    private func reconfigureFromSettings() {
        // Coalesce bursts. Capture the new desired config and compare with the
        // one currently in flight. Window-level/opacity changes are applied
        // separately and in real time by `OverlayWindowController`, so this
        // path is purely about the transport stack.
        guard let desired = settings.jellyfinConfiguration else {
            if poller != nil {
                stop()
                player.updateConnection(.idle)
            }
            return
        }
        if currentClient?.configuration == desired,
           poller != nil {
            return
        }
        start()
    }
}
