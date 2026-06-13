# JellySleeve — Architecture

Reference for how JellySleeve is put together, with emphasis on the
**multi-source playback** system (Jellyfin + YouTube bridge, arbitrated). For
the *why* behind the conventions see [`BEST_PRACTICES.md`](BEST_PRACTICES.md);
for the original feature plan see
[`youtube-bridge-arbiter-plan.md`](youtube-bridge-arbiter-plan.md).

## 1. What it is

A native macOS app (SwiftUI + AppKit, **no external dependencies**) that shows a
floating "now playing" overlay and remote-controls whatever is currently
playing — **Jellyfin** or **YouTube / YouTube Music** — picking the source
automatically, with a manual override in the menu bar.

## 2. Layering

One-way dependency flow: **Networking → State → UI**. A lower layer never knows
a higher one. App-level coordinators wire them together.

```
App/         AppDelegate, JellySleeveApp, SourceArbiter,
             PlaybackConnectionCoordinator, OverlayWindowController, …
State/       PlayerStore (single source of truth), SettingsStore,
             PlaybackPoller, YouTubeBridgeFeed, ArtworkCache
Networking/  JellyfinClient, JellyfinSocketClient, YouTubeBridgeClient,
             PlaybackCommanding (contract)
UI/          OverlayView + themes + components (read PlayerStore, send commands)
```

### Concurrency model

- `PlayerStore`, `SettingsStore`, `YouTubeBridgeFeed`, `SourceArbiter`,
  `PlaybackConnectionCoordinator` are **`@MainActor`** (and the stores are
  `@Observable`). The UI observes them directly — no Combine.
- `PlaybackPoller` is an **`actor`**.
- Clients (`JellyfinClient`, `YouTubeBridgeClient`) and all snapshot/contract
  value types are **`nonisolated` `Sendable` structs** with `async throws`
  methods, so they cross actor boundaries freely.
- Swift 6 strict concurrency is on: thread-safety errors are compile errors.

> **Key consequence for arbitration:** because every component that writes the
> shared overlay state runs on the main actor, "only the active source writes
> state" is enforced by *serialization* — two sources can never interleave a
> write mid-execution. The gate flag (below) just decides *whether* a write
> happens, not against a race.

## 3. The two playback feeds

JellySleeve has two independent "now-playing + remote control" feeds. Both keep
running so each source's liveness is always observable; the arbiter decides
which one drives the UI.

### Jellyfin (existing, untouched transport)

`PlaybackConnectionCoordinator` owns a sophisticated transport: **WebSocket
preferred** (`JellyfinSocketClient`) with a **polling fallback**
(`PlaybackPoller`), reconnection/backoff, and sleep/wake handling. Both
transports funnel decoded sessions into `PlayerStore.ingest(sessions:userId:)`,
which runs the active-session heuristic and writes the snapshot.

### YouTube (new)

`YouTubeBridgeFeed` (`@MainActor`) polls a local Safari Web Extension —
`yt-safari-bridge` — once a second over loopback HTTP via `YouTubeBridgeClient`.
The bridge implements a **vendor-neutral `PlaybackSource` contract** (see the
bridge repo's `docs/playback-source.md` / `docs/api.md`); JellySleeve codes
against that normalized model, not against YouTube-specific shapes.

- Endpoint base: `http://127.0.0.1:8976` (hardcoded; IP literal → exempt from
  App Transport Security; the app is unsandboxed so no entitlement is needed).
- A **refused connection is "idle", never an error** (Safari closed / no YT tab).
- `GET /v1/now-playing` → `BridgeSnapshot`, mapped to the normalized
  `ExternalPlayback` (a `TrackSnapshot` + `isPaused`/`volume`/`active`).
- `GET /v1/health` → `SourceCapabilities` (YouTube: full transport, **no
  favorites, no queue**).
- `POST /v1/command` ← transport commands (`PlaybackCommanding` conformance).

## 4. The command sink (`PlaybackCommanding`)

The vendor-neutral remote-control protocol the UI's transport actions route
through, so views never branch on the backend:

```swift
protocol PlaybackCommanding: Sendable {
    func playPause() async throws
    func next() async throws
    func previous() async throws
    func seek(to position: Duration) async throws
    func setVolume(percent: Int) async throws                       // 0–100, normalized
    func toggleFavorite(itemId: String, current: Bool) async throws -> Bool?  // nil = unsupported
}
```

- **`JellyfinCommandSink`** — adapts `JellyfinClient` (whose methods are keyed by
  a session id). Rebuilt per active session inside `PlayerStore.ingest`, so the
  captured `sessionId` always targets the mirrored device. Units: `Duration` →
  Jellyfin ticks; volume 0–100; favorites supported.
- **`YouTubeBridgeClient`** — `toggle`/`next`/`previous` map 1:1; `seek` value =
  seconds; `setVolume` value = percent/100; favorites return `nil`.

`PlayerStore` holds a `commandSink` (transport) **and** a `client:
JellyfinClient?` (for the Jellyfin-only operations the sink doesn't model:
Instant Mix, queue jumps, authoritative favorite reads). The Jellyfin-only ops
are dormant for YouTube — `capabilities` hides their UI and the arbiter gates
the writes.

## 5. The arbiter (`SourceArbiter`)

```
            ┌─────────────────────────┐
Jellyfin ──▶│ PlaybackConnectionCoord. │──┐
            └─────────────────────────┘  │
                                          ├─▶ SourceArbiter ─▶ PlayerStore ─▶ UI
            ┌─────────────────────────┐  │
YT bridge ─▶│   YouTubeBridgeFeed (1s) │──┘
            └─────────────────────────┘
```

`SourceArbiter` (`@MainActor @Observable`) owns both feeds, decides which one
drives, and exposes `activeKind` for the menu.

### Re-evaluation triggers

The arbiter `reevaluate`s on: each YouTube poll (`ytFeed.onUpdate`), each
Jellyfin ingest (`player.onJellyfinUpdate`), and a `sourceSelection` change.

### Decision policy (pure, tested: `SourceArbiter.decide`)

Generalized over an arbitrary set of sources keyed by `SourceKind` (today:
Jellyfin + YouTube), evaluated in order:

```
forced selection              → that source
auto, exactly one playing     → that source
auto, several playing         → most-recently-ACTIVATED (tie → tiePriority)
auto, none playing            → first present source in homePriority
auto, nothing active          → keep current (last source)
```

- **Two explicit priority lists, not one.** `homePriority` (`[.jellyfin,
  .youtube]`) picks the fallback when nothing is playing — so pausing YouTube
  reveals Jellyfin, the "home" source. `tiePriority` (`[.youtube, .jellyfin]`)
  breaks an equal-rank both-playing tie in YouTube's favor. The two answers
  genuinely differ, so they're separate orderings, not derived from one list.
- **Most-recently-activated, not -changed.** Recency is bumped only on a
  source's **idle→active edge** (the user *starting* it), tracked by the pure,
  N-source `ActivationRecency` (a monotonic-tick rank per `SourceKind`). A source
  that stays continuously active — e.g. a Jellyfin playlist **auto-advancing** in
  the background — never re-activates, so it cannot out-rank and **steal** the
  overlay from what the user is actually watching. Deliberately starting a source
  still wins.
- **Flip debounce.** A *tie-break* flip (both active) landing within 1 s of the
  last flip is suppressed to damp oscillation. A forced selection, or the
  current source going idle, flips immediately.

### State ownership ("only the active source writes")

Rather than literally pausing the loser's transport (which would make
auto-flip-*back* undetectable while a paused tab keeps reporting active), **both
feeds keep running** and the arbiter gates *writes*:

- `PlayerStore.jellyfinIsActiveSource` (default `true`) — when `false`,
  Jellyfin's `ingest` and `updateConnection` writes are dropped, but `ingest`
  still refreshes the **presence signals** (`jellyfinHasNowPlaying`,
  `jellyfinIsPlaying`) and fires `onJellyfinUpdate`. So Jellyfin's liveness
  stays observable even while YouTube drives.
- When YouTube wins, the arbiter writes its snapshot via
  `PlayerStore.applyExternalSnapshot(...)` (reusing the same optimistic-update
  protection as the Jellyfin path) and installs the YouTube sink + capabilities.
- On a flip back to Jellyfin, the sink is cleared (rebuilt per-session on the
  next ingest) and a `coordinator.forceRefresh()` repopulates the overlay fast.

**Flip+write atomicity:** `ingest` calls `onJellyfinUpdate()` *before* its gate
check, so the very poll that detects Jellyfin starting both flips the arbiter
(`jellyfinIsActiveSource = true`) and writes the snapshot in one main-actor pass.

## 6. `PlayerStore` — single source of truth

`@MainActor @Observable`. The overlay reads it; the UI calls its command
vocabulary. Notable seams added for multi-source:

| Member | Role |
|---|---|
| `currentTrack`, `isPaused`, `volume`, `queue`, … | shared overlay state |
| `capabilities: SourceCapabilities` | drives capability-gated UI (heart/queue) |
| `commandSink` | active source's transport sink |
| `client: JellyfinClient?` | Jellyfin-only ops (mix, queue jump, favorite read) |
| `jellyfinIsActiveSource` | arbiter gate (see §5) |
| `jellyfinHasNowPlaying` / `jellyfinIsPlaying` | presence signals for the arbiter |
| `onJellyfinUpdate` | arbiter re-evaluation callback |
| `applyExternalSnapshot(...)` | external (YouTube) write path |
| `ingest(sessions:userId:)` | Jellyfin write path (gated) |

Command discipline (300 ms cooldown + `isCommandInFlight` + optimistic flips +
the post-command "didn't respond" check) is **preserved** and now source-agnostic.

## 7. `TrackSnapshot` & artwork

`TrackSnapshot` gained `artworkURL: URL?`:

- **Jellyfin** leaves it `nil` → `ArtworkView` fetches by `artworkItemId` +
  `imageTag` through the two-tier `ArtworkCache`.
- **YouTube** sets it to the bridge's `artworkUrl` → `ArtworkView` loads it
  directly. Only `http`/`https` schemes are dereferenced (hardening: the bridge
  port is unauthenticated, so an untrusted `file://` must never become a local
  read — restricted at both the mapping boundary and in `ArtworkView`).

## 8. Settings & menu

- `SettingsStore.sourceSelection` (`auto` | `jellyfin` | `youtube`), persisted in
  `UserDefaults` (mirrors the `appPresence`/`@AppStorage` pattern so the menu
  binding reacts).
- The menu-bar "Source" section is an inline `Picker` bound to `sourceSelection`
  (radio ✓), and in `auto` its label notes the currently-driving
  `arbiter.activeKind`.

## 9. Untrusted content

Every string field from the bridge is **attacker-controlled** page content (a
video can be titled `<img onerror=…>`). SwiftUI `Text` escapes on render, so
display is safe; never interpolate these into markup. Artwork URLs are
scheme-restricted (§7). `fetchNowPlaying` treats connection-level failures as
silent idle but **logs** decode/unexpected errors so a breaking bridge-schema
change is debuggable instead of an invisible permanent "idle".

## 10. Adding another source (extension point)

To add a backend (e.g. Spotify, MPRIS) as a `PlaybackSource`:

1. Write a client conforming to `PlaybackCommanding` (convert units in the
   adapter) and reporting a `SourceCapabilities`.
2. Produce a normalized `ExternalPlayback` (a `TrackSnapshot` + active/pause/
   volume), via a `@MainActor` feed analogous to `YouTubeBridgeFeed`.
3. Add a `SourceKind` case (+ `SourceSelection`), slot the source into
   `homePriority` / `tiePriority`, sample its presence into the arbiter's
   per-pass `[SourceKind: SourcePresence]` map, and add one `applyKind` arm to
   swap in its command sink. `decide` and `ActivationRecency` already generalize
   over `SourceKind.allCases`, so the decision core needs no change. Add a menu
   option.

The arbiter's decision logic, gating, and the capability-driven UI generalize
without touching the Jellyfin transport. (The per-source `applyKind` sink-swap
arm is the one spot still enumerated by kind — deliberately, until a real third
source justifies a registry abstraction.)

## 11. Tests

- `SourceArbiterTests` — the pure `decide` policy, `ActivationRecency`
  (including the **auto-advance-doesn't-steal** regression), bridge→snapshot
  mapping, artwork-scheme hardening, `Duration` conversions.
- `PlayerStoreSourceGatingTests` — gated ingest updates presence but not state;
  ungated ingest writes; `applyExternalSnapshot`; gated `updateConnection`.
- `PlayerStoreTests` (existing) — Jellyfin active-session heuristic, queue,
  artist resolution, reconnect/error behavior — must stay green (no Jellyfin
  regression).
