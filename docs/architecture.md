# JellyBeat Architecture

A reference for how JellyBeat is put together, with the emphasis on the
**multi-source playback** system (Jellyfin + YouTube bridge, arbitrated). For
the *why* behind the conventions see [`BEST_PRACTICES.md`](BEST_PRACTICES.md);
for the original feature plan see
[`youtube-bridge-arbiter-plan.md`](plans/youtube-bridge-arbiter-plan.md).

## 1. What it is

A native macOS app (SwiftUI + AppKit, **no external dependencies**) that shows a
floating "now playing" overlay and remote-controls whatever is currently
playing, be it **Jellyfin** or **YouTube / YouTube Music**, picking the source
automatically with a manual override in the menu bar.

## 2. Layering

One-way dependency flow: **Networking → State → UI**. A lower layer never knows
a higher one. App-level coordinators wire them together.

```
App/         AppDelegate, JellyBeatApp, SourceArbiter, SourceRegistry,
             PlaybackConnectionCoordinator, OverlayWindowController, …
State/       PlayerStore (single source of truth), SettingsStore,
             PlaybackPoller, LoopbackSourceFeed, ArtworkCache
Networking/  JellyfinClient, JellyfinSocketClient, LoopbackSourceClient,
             SourceManifest (+ loader), PlaybackCommanding (contract)
UI/          OverlayView + themes + components (read PlayerStore, send commands)
```

### Concurrency model

- `PlayerStore`, `SettingsStore`, `LoopbackSourceFeed`, `SourceRegistry`,
  `SourceArbiter`, `PlaybackConnectionCoordinator` are **`@MainActor`** (and the
  stores are `@Observable`). The UI observes them directly, no Combine.
- `PlaybackPoller` is an **`actor`**.
- Clients (`JellyfinClient`, `LoopbackSourceClient`) and all snapshot/contract
  value types are **`nonisolated` `Sendable` structs** with `async throws`
  methods, so they cross actor boundaries freely.
- Swift 6 strict concurrency is on: thread-safety errors are compile errors.

> **Key consequence for arbitration:** because every component that writes the
> shared overlay state runs on the main actor, "only the active source writes
> state" is enforced by *serialization*: two sources can never interleave a
> write mid-execution. The gate flag (below) only decides *whether* a write
> happens, it isn't guarding against a race.

## 3. Playback feeds & the source registry

Sources come in two flavors. All feeds keep running so each source's liveness is
always observable; the arbiter decides which one drives the UI.

### Jellyfin (privileged built-in, untouched transport)

`PlaybackConnectionCoordinator` owns a sophisticated transport: **WebSocket
preferred** (`JellyfinSocketClient`) with a **polling fallback**
(`PlaybackPoller`), reconnection/backoff, and sleep/wake handling. Both
transports funnel decoded sessions into `PlayerStore.ingest(sessions:userId:)`,
which runs the active-session heuristic and writes the snapshot. Jellyfin is the
one **non-loopback** source and keeps this dedicated transport.

### Loopback sources (built-in YouTube + third-party plugins)

Every other source speaks the **loopback `PlaybackSource` ABI**
([`loopback-source-abi-v1.md`](loopback-source-abi-v1.md)), a tiny HTTP API on a
`127.0.0.1` port. `LoopbackSourceClient` (`nonisolated struct`, parameterized by
`baseURL` + `pathPrefix`) is the consumer; `LoopbackSourceFeed` (`@MainActor`)
polls it once a second, mapping each `BridgeSnapshot` → the normalized
`ExternalPlayback` (a `TrackSnapshot` + `isPaused`/`volume`/`active`).

`SourceRegistry` (`@MainActor`) owns one client + feed per loopback source and
derives the arbiter's id ordering and home/tie priorities:

- **Built-in:** YouTube at `http://127.0.0.1:8976` (the `yt-safari-bridge` Safari
  Web Extension), now expressed as a descriptor rather than a special case.
- **Third-party:** any `*.jellysource` manifest in
  `~/Library/Application Support/software.trypwood.jellybeat/Sources/` (scanned
  once at launch, see §10).

Contract essentials (frozen from YouTube's behavior):
- A **refused connection is "idle", never an error**.
- `GET {prefix}/now-playing` → `BridgeSnapshot` → `ExternalPlayback`.
- `GET {prefix}/health` → `SourceCapabilities`, the single source of truth for
  what the running process supports (a manifest can't overstate it).
- `POST {prefix}/command` ← transport commands (`PlaybackCommanding`).
- Every string field is **untrusted page content**; artwork URLs are
  scheme-restricted to `http`/`https`. The port is unauthenticated, an accepted
  residual risk (ABI doc §8).

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

- **`JellyfinCommandSink`** adapts `JellyfinClient` (whose methods are keyed by
  a session id). Rebuilt per active session inside `PlayerStore.ingest`, so the
  captured `sessionId` always targets the mirrored device. Units: `Duration` →
  Jellyfin ticks; volume 0–100; favorites supported.
- **`LoopbackSourceClient`** handles the loopback side: `toggle`/`next`/`previous`
  map 1:1; `seek` value = seconds; `setVolume` value = percent/100; the favorite
  is the source's **"like"** (idempotent `like`/`unlike`, rendered as a thumbs-up
  via `SourceCapabilities.favoriteStyle`), and the `liked` field from each poll is
  the authoritative state. `PlayerStore` trusts it for loopback sources, so a like
  made in the source (e.g. the browser) stays in sync. One instance per loopback
  source (built-in YouTube + third-party manifests).

`PlayerStore` holds a `commandSink` (transport) **and** a `client:
JellyfinClient?` (for the Jellyfin-only operations the sink doesn't model:
Instant Mix, queue jumps, authoritative favorite reads). The Jellyfin-only ops
are dormant for a loopback source: `capabilities` hides their UI and the arbiter
gates the writes.

## 5. The arbiter (`SourceArbiter`)

```
              ┌──────────────────────────┐
 Jellyfin ───▶│ PlaybackConnectionCoord.  │──┐
              └──────────────────────────┘   │
                                              ├─▶ SourceArbiter ─▶ PlayerStore ─▶ UI
 loopback     ┌──────────────────────────┐   │   (SourceRegistry owns one
 sources ────▶│ LoopbackSourceFeed ×N(1s) │──┘    LoopbackSourceFeed per source)
              └──────────────────────────┘
```

`SourceArbiter` (`@MainActor @Observable`) owns the Jellyfin coordinator and the
registry's loopback feeds, decides which one drives, and exposes `activeKind` for
the menu.

### Re-evaluation triggers

The arbiter `reevaluate`s on: each loopback poll (`feed.onUpdate` →
`.loopback(id)`), each Jellyfin ingest (`player.onJellyfinUpdate`), and a
`sourceSelection` change.

### Live capability refresh

A loopback source's `/health` capabilities are read on a flip to it. They're
**also** re-read when that source *reconnects*: its feed crosses idle→active
(e.g. its bridge is rebuilt to advertise a new capability) while it's already the
active source and no flip happened this pass, so a live capability change lands
within one poll, with no restart (pure, tested: `shouldRefreshOnReconnect`).

### Decision policy (pure, tested: `SourceArbiter.decide`)

Generalized over an arbitrary set of sources keyed by `SourceKind` (today:
Jellyfin + YouTube), evaluated in order:

```
forced selection              → that source
auto, exactly one playing     → that source
auto, several playing         → most-recently-ACTIVATED (tie → tiePriority)
auto, none playing, current active → keep current ("sticky pause")
auto, none playing, current idle   → first present source in homePriority
auto, nothing active          → first source in homePriority (home)
```

- **Sticky pause, not eager home-reveal.** When nothing is playing, the overlay
  *stays* on the current source as long as it still has a (paused) session.
  Pausing what you're using must not hand control to a source merely parked in
  the background. Only once the current source goes fully idle (stopped / tab
  closed) does the overlay defer to `homePriority`. So *pausing* YouTube keeps
  YouTube (even with a long-paused Jellyfin session lingering), while *stopping*
  it still surfaces the parked Jellyfin.
- **All-idle returns home.** With nothing active anywhere, the overlay falls
  back to `homePriority` first (Jellyfin) instead of holding the last source.
  Parking on a dead loopback source kept `jellyfinIsActiveSource` false until a
  relaunch, muting Jellyfin's real `.reconnecting`/`.error` states behind a
  stale ambient `.connected`. Going home reopens the gate: true ambient when
  the server is reachable, "You're offline" when it isn't.
- **Two explicit priority lists, not one.** `homePriority` (`[.jellyfin,
  .youtube]`) picks the fallback when the current source has gone idle and others
  are still parked: Jellyfin, the "home" source, first. `tiePriority`
  (`[.youtube, .jellyfin]`) breaks an equal-rank both-playing tie in YouTube's
  favor. The two answers genuinely differ, so they're separate orderings, not
  derived from one list.
- **Most-recently-activated, not -changed.** Recency is bumped only on a
  source's **idle→active edge** (the user *starting* it), tracked by the pure,
  N-source `ActivationRecency` (a monotonic-tick rank per `SourceKind`). A source
  that stays continuously active (e.g. a Jellyfin playlist **auto-advancing** in
  the background) never re-activates, so it cannot out-rank and **steal** the
  overlay from what the user is actually watching. Deliberately starting a source
  still wins.
- **Flip debounce.** A *tie-break* flip (both active) landing within 1 s of the
  last flip is suppressed to damp oscillation. A forced selection, or the
  current source going idle, flips immediately.

### State ownership ("only the active source writes")

Rather than literally pausing the loser's transport (which would make
auto-flip-*back* undetectable while a paused tab keeps reporting active), **both
feeds keep running** and the arbiter gates *writes*:

- `PlayerStore.jellyfinIsActiveSource` (default `true`): when `false`,
  Jellyfin's `ingest` and `updateConnection` writes are dropped, but `ingest`
  still refreshes the **presence signals** (`jellyfinHasNowPlaying`,
  `jellyfinIsPlaying`) and fires `onJellyfinUpdate`, so Jellyfin's liveness
  stays observable even while YouTube drives.
- When YouTube wins, the arbiter writes its snapshot via
  `PlayerStore.applyExternalSnapshot(...)` (reusing the same optimistic-update
  protection as the Jellyfin path) and installs the YouTube sink + capabilities.
- On a flip back to Jellyfin, the sink is cleared (rebuilt per-session on the
  next ingest) and a `coordinator.forceRefresh()` repopulates the overlay fast.

**Flip+write atomicity:** `ingest` calls `onJellyfinUpdate()` *before* its gate
check, so the very poll that detects Jellyfin starting both flips the arbiter
(`jellyfinIsActiveSource = true`) and writes the snapshot in one main-actor pass.
The mirror direction is atomic too: a Jellyfin tick that *flips onto* a loopback
source (e.g. Jellyfin stops and a parked YouTube is revealed) publishes that
source's snapshot on the same pass (`publish = didFlip`), so the overlay cover,
the menu's `activeKind`, and the command sink all land on YouTube together,
rather than the cover lagging by one poll.

## 6. `PlayerStore`: the single source of truth

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
  read, restricted at both the mapping boundary and in `ArtworkView`).

## 8. Settings & menu

- `SettingsStore.sourceSelection`: `auto` or a specific source id (`jellyfin`,
  `youtube`, or any plugin id); an open `SourceSelection` value persisted in
  `UserDefaults` by `rawValue` (mirrors the `appPresence`/`@AppStorage` pattern
  so the menu binding reacts).
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

## 10. Adding another source

A third-party **loopback source** needs **no app code change**. That's the whole
point of the ABI ([`loopback-source-abi-v1.md`](loopback-source-abi-v1.md)):

1. Run a local process implementing `/health` + `/now-playing` + `/command` on a
   `127.0.0.1` port.
2. Drop a `*.jellysource` manifest (`id`, `displayName`, `port`, optional
   `pathPrefix`/`homeRank`/`tieRank`) into
   `~/Library/Application Support/software.trypwood.jellybeat/Sources/`.
3. Relaunch. `SourceRegistry` discovers it and builds its `LoopbackSourceClient`
   + `LoopbackSourceFeed`; the arbiter weighs it (`decide` and `ActivationRecency`
   generalize over the registry's id set, which becomes the observe order); and
   it appears in the menu's Source picker, labeled by the trusted manifest name.

What still requires app code:
- A **non-HTTP transport** (XPC, Unix socket, MPRIS/D-Bus): the ABI is
  HTTP-loopback-only in v1, and Jellyfin stays the one privileged non-loopback
  built-in with its own transport.
- `applyKind` has a dedicated Jellyfin arm; all loopback sources share one
  generic arm (a registry lookup), so a new *loopback* source never touches it.

The arbiter's decision logic, gating, and the capability-driven UI generalize
without touching the Jellyfin transport.

## 11. Tests

- `SourceArbiterTests`: the pure `decide` policy, `ActivationRecency`
  (including the **auto-advance-doesn't-steal** regression), bridge→snapshot
  mapping, artwork-scheme hardening, `Duration` conversions.
- `PlayerStoreSourceGatingTests`: gated ingest updates presence but not state;
  ungated ingest writes; `applyExternalSnapshot`; gated `updateConnection`.
- `PlayerStoreTests` (existing): Jellyfin active-session heuristic, queue,
  artist resolution, reconnect/error behaviour. Must stay green, no Jellyfin
  regression.
