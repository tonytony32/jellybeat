import Foundation
import os

/// Async polling loop against the Jellyfin `/Sessions` endpoint. Owns the
/// active-session heuristic (plan §4 points 1-4), the backoff policy
/// (plan §5.1), and the hard-stop on 401 (plan §5.2). Pushes decoded snapshots
/// into `PlayerStore` on the main actor.
///
/// Lifecycle owned by `AppDelegate`:
///  - `start(client:userId:baseDelay:)` after a successful configuration
///  - `stop()` on quit or configuration removal
///  - `pause()` / `resume()` for sleep/wake (§5.3) and window hide (§5.4)
///  - `forceRefresh()` to coalesce a fresh poll after a control command
actor PlaybackPoller {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellysleeve",
        category: "networking"
    )

    private let store: PlayerStore
    private let backoffCap: TimeInterval = 30

    /// Task that drives the loop. Cancelling it stops polling.
    private var task: Task<Void, Never>?

    /// When true, the loop awaits a manual resume instead of issuing requests.
    private var paused: Bool = false
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    /// When true, the loop skips its sleep and polls immediately.
    private var refreshRequested: Bool = false
    private var refreshContinuation: CheckedContinuation<Void, Never>?

    private var consecutiveFailures: Int = 0

    init(store: PlayerStore) {
        self.store = store
    }

    /// Start polling with the given client. Stops any previous loop first.
    func start(client: JellyfinClient, userId: String, baseDelay: TimeInterval) {
        Self.logger.notice("Starting poller, baseDelay=\(baseDelay, privacy: .public)s")
        stopInternal()
        paused = false
        consecutiveFailures = 0
        task = Task { [weak self] in
            await self?.runLoop(client: client, userId: userId, baseDelay: baseDelay)
        }
    }

    func stop() {
        Self.logger.notice("Stopping poller")
        stopInternal()
    }

    private func stopInternal() {
        task?.cancel()
        task = nil
        // Unblock any awaiters so the task can exit cleanly.
        resumeContinuation?.resume()
        resumeContinuation = nil
        refreshContinuation?.resume()
        refreshContinuation = nil
    }

    func pause() {
        guard !paused else { return }
        Self.logger.notice("Pausing poller")
        paused = true
    }

    func resume() {
        guard paused else { return }
        Self.logger.notice("Resuming poller")
        paused = false
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    /// Wake the loop early so a command's effect is reflected without waiting
    /// for the next interval.
    func forceRefresh() {
        refreshRequested = true
        refreshContinuation?.resume()
        refreshContinuation = nil
    }

    // MARK: - Loop

    private func runLoop(
        client: JellyfinClient,
        userId: String,
        baseDelay: TimeInterval
    ) async {
        await MainActor.run { store.updateConnection(.connecting) }
        while !Task.isCancelled {
            await waitIfPaused()
            if Task.isCancelled { break }

            let outcome = await tick(client: client, userId: userId)
            switch outcome {
            case .ok:
                consecutiveFailures = 0
                await sleepBeforeNextTick(baseDelay: baseDelay)
            case .transient:
                consecutiveFailures += 1
                let delay = nextBackoff(baseDelay: baseDelay)
                Self.logger.notice("Transient failure #\(self.consecutiveFailures, privacy: .public), backing off \(delay, privacy: .public)s")
                await sleepBeforeNextTick(baseDelay: delay)
            case .fatal(let message):
                Self.logger.error("Fatal poll error: \(message, privacy: .public). Stopping loop.")
                await MainActor.run { store.updateConnection(.error(message)) }
                return
            }
        }
    }

    private enum TickOutcome {
        case ok
        case transient
        case fatal(String)
    }

    private func tick(client: JellyfinClient, userId: String) async -> TickOutcome {
        do {
            let sessions = try await client.fetchSessions()
            await MainActor.run {
                store.ingest(sessions: sessions, userId: userId)
            }
            return .ok
        } catch NetworkError.unauthorized {
            return .fatal("Unauthorized — check your API key.")
        } catch NetworkError.selfSignedCert {
            return .fatal("TLS rejected — enable 'Allow self-signed certificates' in Settings if your server uses one.")
        } catch let NetworkError.serverError(code) where (500...599).contains(code) {
            return .transient
        } catch NetworkError.transport, NetworkError.serverError {
            return .transient
        } catch {
            Self.logger.error("Unexpected poll error: \(String(describing: error), privacy: .public)")
            return .transient
        }
    }

    // MARK: - Backoff + sleep

    /// Plan §5.1: base*2, base*4, then cap at 30s.
    private func nextBackoff(baseDelay: TimeInterval) -> TimeInterval {
        switch consecutiveFailures {
        case 0...1: return min(baseDelay * 2, backoffCap)
        case 2: return min(baseDelay * 4, backoffCap)
        default: return backoffCap
        }
    }

    private func sleepBeforeNextTick(baseDelay: TimeInterval) async {
        // Wait the configured delay OR until something asks for an early refresh.
        let nanos = UInt64(max(baseDelay, 0.1) * 1_000_000_000)
        let waitTask = Task { try? await Task.sleep(nanoseconds: nanos) }
        await withCheckedContinuation { continuation in
            refreshContinuation = continuation
            Task {
                await waitTask.value
                if refreshContinuation != nil {
                    refreshContinuation?.resume()
                    refreshContinuation = nil
                }
            }
            // If a refresh was requested before we set the continuation, fire now.
            if refreshRequested {
                refreshRequested = false
                refreshContinuation?.resume()
                refreshContinuation = nil
            }
        }
        refreshRequested = false
    }

    private func waitIfPaused() async {
        guard paused else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            resumeContinuation = continuation
        }
    }
}
