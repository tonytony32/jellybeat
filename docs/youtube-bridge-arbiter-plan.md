# Plan: YouTube-bridge source + multi-source arbiter

Goal: let JellySleeve show and control **whatever is playing right now** — Jellyfin **or**
YouTube / YouTube Music — picking the source **automatically**, with a manual override in the
macOS menu bar.

The YouTube side is fed by **`yt-safari-bridge`**, a Safari Web Extension that exposes a local
HTTP API at `http://127.0.0.1:8976`. It is one implementation of a vendor-neutral
**`PlaybackSource` contract** — read that repo's `docs/playback-source.md` and `docs/api.md`
first. Code against that normalized contract, **not** against YouTube-specific shapes.

> Companion branch in the bridge repo: `feature/playback-source-standard` (contract +
> self-describing `capabilities`).

## UX

- **Automatic** (default): if the YouTube bridge is *active* (something playing/paused in Safari,
  fresh within 3 s) → show YouTube. Otherwise → Jellyfin. If both are active, prefer the
  **most-recently-changed** source.
- **Override**: a "Source" section in the `MenuBarExtra` menu — **Automatic / Jellyfin /
  YouTube** with a ✓ on the active one. Persisted. Shows which source is currently driving.

## Architecture: keep Jellyfin's transport intact, add a sibling feed + an arbiter

JellySleeve's Jellyfin transport is sophisticated (WebSocket-preferred + polling fallback +
reconnect + sleep/wake, in `PlaybackConnectionCoordinator`). **Do not** force the bridge through
it. Instead:

```
            ┌─────────────────────────┐
Jellyfin ──▶│ PlaybackConnectionCoord. │──┐   (existing, untouched)
            └─────────────────────────┘  │
                                          ├─▶ SourceArbiter ──▶ PlayerStore ──▶ UI
            ┌─────────────────────────┐  │     (new, decides who         (existing @Observable)
YT bridge ─▶│ YouTubeBridgeFeed (1 s) │──┘      writes state + gets cmds)
            └─────────────────────────┘
```

Only the **active** source writes `PlayerStore` state and receives commands; the other is paused
so it can't clobber the shared state.

## Files

### New

1. **`Networking/PlaybackCommanding.swift`** — the command-sink protocol (vendor-neutral):
   ```swift
   protocol PlaybackCommanding: Sendable {
       func playPause() async throws
       func next() async throws
       func previous() async throws
       func seek(to position: Duration) async throws
       func setVolume(percent: Int) async throws            // 0–100, normalized
       func toggleFavorite(itemId: String, current: Bool) async throws -> Bool?  // nil = unsupported
   }
   ```
2. **`Networking/YouTubeBridgeClient.swift`** — `nonisolated struct`, `URLSession` to
   `127.0.0.1:8976`. (App needs the **outgoing-network** entitlement — already true if the app
   talks to a remote Jellyfin; confirm `com.apple.security.network.client` + ATS
   `NSAllowsLocalNetworking` for plain-HTTP loopback.)
   - `func fetchNowPlaying() async throws -> BridgeSnapshot?` (nil/throw → idle; map *connection
     refused* to idle, never error).
   - `func fetchCapabilities() async -> SourceCapabilities` (from `/v1/health`).
   - `PlaybackCommanding` conformance → `POST /v1/command` (`seek` value = seconds;
     `setVolume` value = percent/100.0; favorites → returns `nil`).
3. **`State/YouTubeBridgeFeed.swift`** — `@MainActor`, owns a 1 s poll `Task`. On each poll maps
   `BridgeSnapshot` → `TrackSnapshot` (+ `isPaused`, `volume`, `active`) and calls back into the
   arbiter. `start()` / `stop()` / `forceRefresh()`.
4. **`App/SourceArbiter.swift`** — `@MainActor`. Owns the `PlaybackConnectionCoordinator` and the
   `YouTubeBridgeFeed`; subscribes to settings' `sourceSelection`; decides the active source and:
   - sets `player.configure(commandSink:capabilities:)`,
   - lets **only** the active source write `player` state,
   - `coordinator.pause("yt active")` / `resume(...)` to gate Jellyfin,
   - exposes `activeKind` for the menu.
5. **`docs/`** — this file.

### Modified

- **`State/ConnectionState.swift`** — `TrackSnapshot`: add `let artworkURL: URL?` (nil for
  Jellyfin). Update `withFavorite` to carry it. (Definition ~lines 27–64.)
- **`State/PlayerStore.swift`**:
  - `private var client: JellyfinClient?` → `private var commandSink: PlaybackCommanding?`
    (~line 112). `configure(client:poller:)` → `configure(commandSink:poller:)` (~line 167) and
    add a `capabilities` published property.
  - `sendCommand(name:work:)` (~809–847) and `playPause()/nextTrack()/previousTrack()`
    (468/507/518) call `commandSink` instead of `JellyfinClient` directly. **Keep** the 300 ms
    cooldown + `isCommandInFlight`.
  - Add `func applyExternalSnapshot(track:isPaused:volume:connection:)` for the YT feed — reuse
    the existing **optimistic-update protection** (~lines 188–203) so local play/pause/volume
    changes aren't stomped by the next poll.
  - `ingest(sessions:userId:)` (~line 284) stays Jellyfin-only; the arbiter ensures it's only
    called while Jellyfin is active.
- **`App/AppDelegate.swift`** — create the `SourceArbiter` (instead of activating the coordinator
  directly); hand it the coordinator + a new `YouTubeBridgeFeed`.
- **`App/JellySleeveApp.swift`** — add the "Source" section to the `MenuBarExtra` (~line 27):
  three options bound to `settings.sourceSelection`, ✓ on `arbiter.activeKind`.
- **`State/SettingsStore.swift`** — add `sourceSelection` (`auto` | `jellyfin` | `youtube`),
  persisted in `UserDefaults` (mirror the `appPresence`/`@AppStorage` pattern at
  `JellySleeveApp.swift:10`).
- **`UI/Overlay/Components/ArtworkView.swift`** — if `artworkURL != nil`, load it directly
  (`URLSession`/`AsyncImage`-style) instead of `cache.data(forItemId:tag:)` (~line 79).
- **`UI/Overlay/Components/ControlsView.swift`** + queue UI — hide the favorite heart when
  `!capabilities.hasFavorites` and the queue affordance when `!capabilities.hasQueue`.

## Arbiter decision logic

```
func resolveActiveKind() -> SourceKind {
    switch settings.sourceSelection {
    case .forced(let k): return k
    case .auto:
        let ytActive = ytFeed.lastSnapshot?.active == true
        let jfActive = player.connectionMode != .unknown && jellyfinHasNowPlaying
        if ytActive && jfActive { return mostRecentlyChanged() }   // compare updatedAt
        if ytActive { return .youtube }
        return .jellyfin
    }
}
```

Re-evaluate on: each YT poll, Jellyfin `currentTrack` change (Observation), and a
`sourceSelection` change. On a *flip*, gate the feeds (pause loser, resume winner) and swap the
command sink + capabilities. Debounce flips slightly to avoid flapping when both briefly active.

## Mapping bridge → JellySleeve

| Bridge (`/v1/now-playing`) | TrackSnapshot / PlayerStore |
|---|---|
| `title` / `artist` / `album` | `title` / `artist` / `album` |
| `positionSec` / `durationSec` | `position` / `runtime` (`Duration.seconds`; `durationSec == null` → `.zero` + treat as unknown/livestream) |
| `state == "playing"` | `isPaused = false` |
| `volume` (0.0–1.0) | `volume = Int(round(v*100))` |
| `artworkUrl` | `artworkURL` (direct URL) |
| `videoId` | `itemId` (for identity; favorites unsupported) |
| `active == false` / conn refused | feed reports idle |

Commands out: `playPause/next/previous` → same; `seek(Duration)` → `value = seconds`;
`setVolume(percent)` → `value = percent/100.0`; favorites → no-op.

## Concurrency

`PlayerStore` is `@MainActor` + `@Observable`; `PlaybackPoller` is an `actor`; clients are
`nonisolated struct`s with `async throws` methods (mirror this for `YouTubeBridgeClient`). The
arbiter and feed are `@MainActor`. No Combine — Observation drives the UI.

## Risks / test plan

- **State ownership on flip** — the biggest risk. Ensure the losing feed is fully paused before
  the winner writes, so they don't interleave. Add unit tests for the arbiter's decision +
  flip-gating (mock both feeds).
- **Don't regress Jellyfin** — run the existing `JellySleeveTests` suite green at every step;
  the Jellyfin transport path must behave identically when YouTube is idle.
- **Loopback HTTP from a sandboxed app** — verify the entitlement/ATS; treat connection-refused
  as idle (it's the normal "Safari closed" state, not an error).
- **Capabilities-driven UI** — heart/queue hidden for YouTube, shown for Jellyfin.

## Suggested commit order (on `feature/youtube-bridge-arbiter`)

1. `TrackSnapshot.artworkURL` + ArtworkView URL path (no behavior change for Jellyfin).
2. `PlaybackCommanding` protocol + adapt `PlayerStore` to a command sink (Jellyfin still sole
   source; tests green).
3. `YouTubeBridgeClient` + `YouTubeBridgeFeed` (poll + map; not wired yet).
4. `SourceArbiter` + `SettingsStore.sourceSelection` + AppDelegate wiring (auto only).
5. MenuBarExtra "Source" override + capabilities-driven UI.
6. Arbiter unit tests + manual end-to-end (play YT in Safari ↔ play in Jellyfin, watch it flip).
