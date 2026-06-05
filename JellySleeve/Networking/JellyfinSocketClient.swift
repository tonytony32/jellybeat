import Foundation
import os

/// WebSocket client that streams `Sessions` push events from the Jellyfin
/// server's `/socket` endpoint, eliminating the steady-state polling traffic
/// the REST `PlaybackPoller` produces.
///
/// State machine:
///  - `start(...)` opens the connection, sends `SessionsStart` to subscribe,
///    then enters the receive + heartbeat loops.
///  - On connection drop / decode error, transitions to `failed` and the
///    owner (`AppDelegate`) decides whether to retry or fall back to polling.
///  - `stop()` is idempotent and cancels every in-flight task.
///
/// Received `Sessions` payloads are funnelled into `PlayerStore.ingest` on
/// the main actor — the same path the poller uses — so downstream UI logic
/// is unchanged.
actor JellyfinSocketClient {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellysleeve",
        category: "networking"
    )

    nonisolated enum State: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private let configuration: JellyfinConfiguration
    private let deviceId: String
    private let store: PlayerStore
    private let session: URLSession

    /// The configured user whose sessions we subscribe to. Sourced from
    /// `configuration` so there is a single source of truth.
    private var userId: String { configuration.userId }

    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private(set) var state: State = .idle
    private var heartbeatIntervalNanos: UInt64 = 30_000_000_000
    /// Set to true before any intentional close so the receiveLoop's catch
    /// block doesn't misread the resulting URLError as a real failure.
    private var stoppedIntentionally = false
    /// The `SessionsStart` interval last sent to the server. Persisted so
    /// reconnects (sleep/wake, failure recovery) reuse the last known value
    /// instead of always defaulting to the fast interval.
    private var sessionsIntervalMs: Int = 1500

    /// Stream of state transitions. AppDelegate observes this to drive its
    /// "WebSocket connected → polling stopped" / "WebSocket failed → polling
    /// fallback" orchestration.
    let stateStream: AsyncStream<State>
    private let stateContinuation: AsyncStream<State>.Continuation

    init(
        configuration: JellyfinConfiguration,
        deviceId: String,
        store: PlayerStore
    ) {
        self.configuration = configuration
        self.deviceId = deviceId
        self.store = store

        let urlConfig = URLSessionConfiguration.ephemeral
        urlConfig.timeoutIntervalForRequest = 30
        let delegate: URLSessionDelegate? = configuration.allowSelfSigned
            ? TrustingURLSessionDelegate(expectedHost: configuration.baseURL.host)
            : nil
        self.session = URLSession(configuration: urlConfig, delegate: delegate, delegateQueue: nil)

        let (stream, continuation) = AsyncStream<State>.makeStream()
        self.stateStream = stream
        self.stateContinuation = continuation
    }

    /// Update the `SessionsStart` interval on a live connection. If the socket
    /// is not currently connected the new value is stored and applied on the
    /// next `start()` call.
    func setSessionsInterval(_ ms: Int) async {
        sessionsIntervalMs = ms
        guard state == .connected else { return }
        do {
            try await send(.sessionsStart(intervalMs: ms))
            Self.logger.notice("Sessions interval → \(ms, privacy: .public) ms")
        } catch {
            Self.logger.error("Sessions interval update failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// - Parameter intervalMs: Override the `SessionsStart` subscription
    ///   interval for this connection. Pass `nil` to reuse the last value
    ///   (useful for transparent reconnects after sleep/wake or failures).
    func start(intervalMs: Int? = nil) async {
        if let ms = intervalMs { sessionsIntervalMs = ms }
        // Cancel any in-flight task before opening a new one so we never have
        // two concurrent WebSocket connections to the same server. Set the
        // intentional-stop flag first so the old receiveLoop's catch block
        // doesn't emit a spurious .failed transition.
        // Flag must stay true until the very last moment before the new loops
        // start. The old receiveLoop/heartbeatLoop catch blocks run on the
        // actor, but they can't acquire it until the first await below. By
        // keeping the flag true throughout, any catch block that wakes up and
        // finds stoppedIntentionally=true exits silently instead of emitting a
        // spurious .failed that AppDelegate would interpret as a real failure
        // and schedule an unwanted retry.
        stoppedIntentionally = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        receiveTask?.cancel()
        heartbeatTask?.cancel()

        await transition(to: .connecting)

        guard let url = Self.buildSocketURL(configuration: configuration, deviceId: deviceId) else {
            await transition(to: .failed("Invalid socket URL."))
            return
        }

        let webSocket = session.webSocketTask(with: url)
        self.task = webSocket
        webSocket.resume()

        // Subscribe to the Sessions stream.
        do {
            try await send(.sessionsStart(intervalMs: sessionsIntervalMs))
        } catch {
            Self.logger.error("Socket SessionsStart failed: \(String(describing: error), privacy: .public)")
            await transition(to: .failed("Couldn't subscribe to Sessions."))
            return
        }

        await transition(to: .connected)
        // Log host:port only — never the full URL because the API key rides
        // along as a query parameter.
        let safeHost = "\(url.host ?? "?"):\(url.port.map { String($0) } ?? "?")"
        Self.logger.notice("WebSocket connected to \(safeHost, privacy: .public)")

        // Old loops had at least two actor-suspension points (the transitions
        // above) to observe stoppedIntentionally=true and exit. Reset now so
        // the new loops treat genuine failures as failures.
        stoppedIntentionally = false
        startLoops()
    }

    func stop() {
        Self.logger.notice("Stopping WebSocket")
        stoppedIntentionally = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Terminal teardown: stop the connection and break the
    /// `URLSession → delegate` retain cycle so the session (and, in self-signed
    /// mode, its `TrustingURLSessionDelegate`) deallocates. Unlike `stop()`, the
    /// socket can't be restarted afterwards; the owner only calls this when it
    /// is discarding this instance (a reconfigure), never on pause/resume.
    func invalidate() {
        stop()
        session.finishTasksAndInvalidate()
    }

    // MARK: - Loops

    private func startLoops() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            await self?.heartbeatLoop()
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let task else { return }
            do {
                let message = try await task.receive()
                let payload: Data
                switch message {
                case .string(let s):
                    payload = Data(s.utf8)
                case .data(let d):
                    payload = d
                @unknown default:
                    continue
                }
                let decoded = try IncomingSocketMessage.decode(payload)
                await handle(decoded)
            } catch {
                if stoppedIntentionally { return }
                Self.logger.error("Socket receive failed: \(String(describing: error), privacy: .public)")
                await transition(to: .failed(error.localizedDescription))
                return
            }
        }
    }

    private func heartbeatLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: heartbeatIntervalNanos)
            guard !Task.isCancelled else { return }
            do {
                try await send(.keepAlive())
            } catch {
                if stoppedIntentionally { return }
                Self.logger.error("Socket heartbeat failed: \(String(describing: error), privacy: .public)")
                await transition(to: .failed("Heartbeat failed."))
                return
            }
        }
    }

    private func handle(_ message: IncomingSocketMessage) async {
        switch message {
        case .sessions(let sessions):
            let userId = userId
            await MainActor.run { [store] in
                store.ingest(sessions: sessions, userId: userId)
            }
        case .keepAlive:
            // Server echoed our ping; nothing to do.
            break
        case .forceKeepAlive(let seconds):
            // Server wants us to ping faster.
            heartbeatIntervalNanos = UInt64(max(1, seconds - 5)) * 1_000_000_000
            Self.logger.notice("Server requested KeepAlive every \(seconds, privacy: .public)s")
        case .other(let type):
            Self.logger.debug("Socket received unsupported MessageType '\(type, privacy: .public)'")
        }
    }

    // MARK: - Send

    private func send(_ message: OutgoingSocketMessage) async throws {
        guard let task else { throw URLError(.cancelled) }
        let data = try JSONEncoder().encode(message)
        guard let string = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeRawData)
        }
        try await task.send(.string(string))
    }

    // MARK: - State

    private func transition(to next: State) async {
        guard state != next else { return }
        state = next
        stateContinuation.yield(next)
    }

    // MARK: - URL

    private static func buildSocketURL(
        configuration: JellyfinConfiguration,
        deviceId: String
    ) -> URL? {
        var components = URLComponents()
        components.scheme = configuration.baseURL.scheme == "https" ? "wss" : "ws"
        components.host = configuration.baseURL.host
        components.port = configuration.baseURL.port
        components.path = "/socket"
        components.queryItems = [
            URLQueryItem(name: "api_key", value: configuration.apiKey),
            URLQueryItem(name: "deviceId", value: deviceId),
        ]
        return components.url
    }
}
