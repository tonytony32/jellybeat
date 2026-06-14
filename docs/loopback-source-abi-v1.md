# Loopback PlaybackSource ABI — `loopback-source/1`

Normative contract for a **third-party playback source**: any local process that
implements this HTTP API on a loopback port becomes a source JellySleeve can
show in the overlay and remote-control, picked automatically by the arbiter
alongside Jellyfin and any other sources.

This is the contract the bundled **YouTube bridge** already speaks, lifted
vendor-neutral and frozen. The consumer side lives in
[`LoopbackSourceClient`](../JellySleeve/Networking/LoopbackSourceClient.swift) /
[`LoopbackSourceFeed`](../JellySleeve/State/LoopbackSourceFeed.swift); see
[`architecture.md`](architecture.md) §3/§5/§10 for how sources are arbitrated.

> Status: **phase 1**. Discovery, the wire format, and the manifest are stable.
> Authentication is intentionally absent in phase 1 (see §7); an optional token
> is *reserved* so it can be added without a major bump.

---

## 1. Versioning

- The ABI identifier is `loopback-source/MAJOR`. Phase 1 supports major **`1`**.
- A source declares its ABI in the **manifest** (`abi`, required) and *may* echo
  it from `GET /health` (`abi`, optional).
- **Unsupported major** → the source is loaded-but-ignored with a single logged
  warning; it never crashes discovery or degrades sibling sources.
- **Absent `abi`** (e.g. the originally-shipped YouTube bridge) → assume `1`.
- Minor evolution is **additive-only**: decoders ignore unknown JSON keys, and
  any new field defaults conservatively. No field is ever repurposed.

## 2. Transport

- **HTTP/1.1 over loopback only.** The host **MUST** be the `127.0.0.1` IP
  literal — not `localhost`, not IPv6, not a hostname. This keeps the call
  exempt from App Transport Security and makes DNS-rebinding impossible.
- All paths live under a per-source **prefix**, default `/v1`.
- The client uses a **2 s per-request timeout**, `waitsForConnectivity = false`,
  and an ephemeral `URLSession`. A source must answer fast or be treated as idle.

## 3. `GET {prefix}/health`

`200 application/json`:

```jsonc
{
  "abi": "loopback-source/1",      // optional in v1
  "sourceName": "YouTube",         // optional; diagnostics only — NOT the menu label (§7)
  "capabilities": {
    "canPlayPause": true, "canNext": true, "canPrevious": true,
    "canSeek": true, "canSetVolume": true,
    "hasFavorites": false, "hasQueue": false, "canFocusTab": false
  }
}
```

- Every field is optional. The five **transport** bits
  (`canPlayPause`/`canNext`/`canPrevious`/`canSeek`/`canSetVolume`) default
  **`true`**; `hasFavorites`/`hasQueue`/`canFocusTab` default **`false`**.
- Capabilities are the **single source of truth** for what the running process
  supports — the manifest deliberately cannot declare them, so it can never lie.
- The app never sends a command (§5) a capability did not advertise.

## 4. `GET {prefix}/now-playing`

`200 application/json`:

```jsonc
{
  "active": true,                 // false ⇒ idle (see below)
  "source": "youtube_music",      // string | null — diagnostics only
  "state": "playing",             // "playing" | "paused" | null
  "title": "…", "artist": "…", "album": "…",   // string | null — UNTRUSTED (§7)
  "durationSec": 240,             // number | null  (null ⇒ unknown / livestream)
  "positionSec": 30,              // number | null
  "volume": 0.8,                  // 0.0–1.0 | null
  "itemId": "abc123",             // string | null — stable identity for this item
  "artworkUrl": "https://…",      // string | null — UNTRUSTED; http/https only (§7)
  "updatedAtMs": 1700000000000    // number | null
}
```

- **Documented alias:** the decoder reads `itemId ?? videoId`, so a source that
  emits the older `videoId` key keeps working unmodified.
- **Idle is never an error.** Both `{"active": false}` **and** a
  refused / timed-out / dropped connection normalize to the single *idle*
  signal. A source that isn't running is simply idle, not broken.

## 5. `POST {prefix}/command`

Request body:

```jsonc
{ "action": "toggle", "value": null }
```

| `action`     | `value`            | meaning                          |
|--------------|--------------------|----------------------------------|
| `toggle`     | —                  | play/pause                       |
| `next`       | —                  | next track                       |
| `previous`   | —                  | previous track                   |
| `seek`       | seconds (number)   | seek to absolute position        |
| `setVolume`  | 0.0–1.0 (number)   | set output volume                |
| `focusTab`   | —                  | bring the source's window/tab to front |

Responses (best-effort / async — the *result* is observed on the next
`now-playing` read, which is the source of truth):

- `2xx` → accepted.
- `503` → temporarily unavailable (mapped to a transient transport error).
- any other non-`2xx` → server error.

A source should reject an action it doesn't support with a `4xx`; in practice
the app won't send one, because it gates every command on `/health` capabilities.

## 6. Idle vs error semantics

Connection-level failures that mean "the source just isn't listening" are
treated as **idle, silently**:

`cannotConnectToHost`, `cannotFindHost`, `networkConnectionLost`,
`notConnectedToInternet`, `timedOut`, `cancelled`.

Everything else — a JSON decode failure (schema drift) or an unexpected status —
is **logged** but still surfaced to the UI as idle, so a breaking change is
debuggable instead of an invisible permanent "idle".

## 7. Security & trust

Phase-1 posture, stated plainly so plugin authors and users know exactly what is
and isn't guaranteed.

- **Every string field is untrusted page content.** `title`, `artist`, `album`,
  `artworkUrl`, and `/health.sourceName` may be arbitrary, attacker-influenced
  text (a video can be titled `<img onerror=…>`). They are rendered **only**
  through escaping renderers (SwiftUI `Text`) and are **never** interpolated into
  markup, AppKit attributed strings, or markdown.
- **`artworkUrl` is dereferenced only when its scheme is `http`/`https`.** A
  `file://` or other-scheme value is dropped at the mapping boundary, so the
  artwork loader can never be turned into a local file read.
- **The menu label is the *trusted* manifest `displayName`**, written to disk by
  the user (or a plugin's installer) — **never** `/health.sourceName`, which is
  served by the (possibly squatting) process and kept for diagnostics only.
- **The loopback port is UNAUTHENTICATED.** This is an explicit, accepted
  residual risk for phase 1, bounded by design:
  - loopback-only — no remote attacker can reach it;
  - the app never executes code from a source, only reads now-playing and sends
    the fixed command vocabulary above — so a hostile source can at worst show a
    wrong/offensive now-playing card and receive transport clicks (no RCE, no
    exfiltration);
  - the only outbound fetch a source can cause is the scheme-restricted artwork.

  Any process that could abuse this already has user-level access to the machine
  (it must bind a local port and write to the user's Application Support dir).
- **Reserved for phase 2 (no major bump):** an optional app→source
  `Authorization` token (a shared secret the app writes and the source echoes),
  to harden against same-user squatters / browser-origin POSTs. The field name
  is reserved here so it can be added compatibly.

## 8. Discovery & manifest

JellySleeve scans **once at launch** (no hot-reload in phase 1; adding a source
needs a relaunch):

```
~/Library/Application Support/software.trypwood.jellysleeve/Sources/*.jellysource
```

Each `*.jellysource` file is JSON (the extension is plain JSON, named for
greppability) describing one source:

```jsonc
{
  "abi": "loopback-source/1",          // required; rejected if major ≠ 1
  "id": "com.example.spotify-bridge",  // required; reverse-DNS recommended.
                                       //   [a-z0-9._-], ≤128 chars. Becomes the
                                       //   stable source id + persistence key.
  "displayName": "Spotify",            // required; the TRUSTED menu label (§7)
  "port": 8980,                        // required; 1024–65535
  "pathPrefix": "/v1",                 // optional; default "/v1"
  "homeRank": 100,                     // optional; lower = more "home" (fallback
                                       //   when nothing is playing). Built-ins < 100.
  "tieRank": 100                       // optional; lower wins a same-tick tie
                                       //   between two playing sources.
}
```

- **Capabilities are NOT in the manifest** — they come from `/health` at runtime
  (§3), so a manifest can never overstate what the running process supports.
- A manifest is **dropped, with a logged warning** (never a crash), if it fails
  to decode, has a malformed/duplicate `id`, collides on a `port` with an
  earlier or built-in source, or declares an unsupported `abi` major. A missing
  directory yields zero sources.
- **Built-in sources** are compiled in, seeded first, and always win an `id`/
  `port` collision against a discovered manifest:
  - **Jellyfin** — a privileged, non-loopback built-in (it keeps its own
    WebSocket/polling transport). Its descriptor carries no port; the registry
    never builds a loopback client for it. `homeRank` 0 (the home source).
  - **YouTube** — the first built-in *loopback* source: `id` `youtube`, port
    `8976`, prefix `/v1`. Identical behavior to before, expressed as a
    descriptor instead of a hard-coded special case.

### Adding a source (third party)

1. Run a local process that implements §3–§6 on a `127.0.0.1` port.
2. Drop a `*.jellysource` manifest (above) into the Sources directory.
3. Relaunch JellySleeve. The source appears in the menu-bar **Source** picker and
   is arbitrated automatically.

No app code change is required to add a *source*. (Adding a non-HTTP *transport*
— XPC, Unix socket, MPRIS — is a deliberate future code change.)
