# JellySleeve

A floating now-playing overlay for macOS that mirrors a remote Jellyfin
server's audio playback. Inspired visually by [Sleeve by Replay][sleeve],
built independently to work against the Jellyfin REST API and `/socket`
push — no AppleScript, no Apple Music dependency, no Mac-as-the-source.

[sleeve]: https://replay.software/sleeve

> **Status — v0.1.0-beta.** Functional milestone. Not packaged for
> distribution: no Developer ID signing, no notarised DMG, no public
> release yet.

## What it does

- Floats a borderless window over every Space showing the current track:
  artwork, title, artist, album, and a progress bar that interpolates
  smoothly between server updates.
- Sub-second latency over a WebSocket connection to `/socket`; falls back
  to REST polling if the socket can't establish or drops three times.
- Five built-in themes (Elegant, Stack, Classic, Minim, Aero) selectable
  from the Appearance tab in Settings. Each one is a layout preset, not
  a colour swap — switching themes resizes the window and rearranges the
  artwork / info / controls.
- Snaps to screen corners on drag, remembers its position per display.
- Hands media keys (F7 / F8 / F9), the Control Center module, and the
  Touch Bar to the same actions you'd use on the overlay buttons. The
  current track shows up in the system Now Playing module with artwork.
- Goes ambient when the server reports no active client: the window
  shrinks to the artwork's exact pixels, becomes invisible, and pops
  back on hover with the Jellyfin logo. One click launches the Safari
  "Add to Dock" web app for the same server if one is registered, or
  falls back to the default browser otherwise.
- Self-signed certificate trust is opt-in per server (useful for
  Tailscale or Caddy setups behind an internal CA).
- API key stored in the macOS Keychain by default (encrypted at rest).
  Can be switched to the preferences plist via Settings if needed.

## Requirements

- macOS 26.0 Tahoe or later, Apple Silicon
- A reachable Jellyfin server (10.7+ recommended for the WebSocket
  protocol JellySleeve uses)
- An API key from **Jellyfin Dashboard → Advanced → API Keys**
- Your user ID from **Dashboard → Users → your user**

## Build

The project is a vanilla SwiftUI / AppKit hybrid with no external
dependencies. Open in Xcode 26.5 or later:

```sh
git clone https://github.com/tonytony32/jellysleeve.git
cd jellysleeve
open JellySleeve.xcodeproj
```

Or build from the command line:

```sh
xcodebuild -project JellySleeve.xcodeproj -scheme JellySleeve \
           -configuration Release build
```

The resulting `.app` lands in `~/Library/Developer/Xcode/DerivedData/…`;
copy it to `/Applications` to launch via Spotlight / Launchpad.

## Configure

Open Settings (`⌘,`) and fill in the Server tab:

- **Base URL** — full URL with scheme and port, e.g.
  `http://192.168.3.80:8096` or `https://jellyfin.example.com`.
- **API key** — generated in the Jellyfin dashboard.
- **User ID** — your user's GUID; visible in the URL on your user's
  edit page in the dashboard.
- **Allow self-signed certificates** — only enable when you know what
  this means.
- **Store API key in UserDefaults** — off by default. The API key is
  stored encrypted in the macOS Keychain by default. Enable only if
  you need the key to survive a Keychain reset or for a specific
  migration reason (less secure: the key will be readable in the
  preferences plist).

Hit **Test connection** to verify. A green check with the server name and
version means you're good.

## Layout

```
JellySleeve.xcodeproj/        # Xcode project + shared scheme
JellySleeve/                  # Sources
  App/                        # App entry + coordinators (window, connection), MediaCenter
  Networking/                 # JellyfinClient, JellyfinSocketClient, models
  State/                      # PlayerStore, SettingsStore, poller, caches, KeychainHelper
  UI/                         # OverlayView, themes, Settings tabs, components
  Assets.xcassets             # AppIcon, AccentColor, JellyfinLogo
  Resources/                  # placeholder
JellySleeveTests/             # Swift Testing target with Jellyfin response fixtures
docs/                         # see docs/README.md for the full map
  architecture.md             # current architecture (multi-source playback)
  loopback-source-abi-v1.md   # the third-party source ABI contract
  BEST_PRACTICES.md           # architecture + best-practices guide for a rebuild
  MAINTENANCE.md              # internal maintenance policy
  plans/                      # historical implementation plans
  visualizations/             # standalone HTML diagrams
LICENSE                       # AGPL-3.0
```

### Architecture

The app layer is a thin coordinator over two focused collaborators rather
than one catch-all delegate:

- **`AppDelegate`** — owns the shared stores (`SettingsStore`, `PlayerStore`,
  `ThemeRegistry`, `ArtworkCacheProvider`) and wires the collaborators
  together. It holds almost no logic of its own.
- **`OverlayWindowController`** — all window geometry: creating the borderless
  window, applying level/opacity, the theme- and player-driven resize between
  the full and ambient layouts, edge/corner snapping, and per-display position
  persistence.
- **`PlaybackConnectionCoordinator`** — the playback-feed state machine:
  WebSocket-preferred transport with REST-polling fallback, the reconnection
  policy, sleep/wake handling, and the debounced reconfigure when connection
  settings change.

Window-visibility events that should pause or resume the feed (miniaturise,
close, deminiaturise) flow from the window controller to the connection
coordinator through closures, so neither holds a direct reference to the other.

Data flows one way up the layers — **Networking → State → UI**. The transport
clients decode raw models; `PlayerStore` runs the active-session heuristic and
holds the single source of truth for the overlay; the SwiftUI views and themes
read it. The shared transport vocabulary (`PlaybackAction`) lives in the State
layer so the store never depends on a view type.

## Tests

```sh
xcodebuild -project JellySleeve.xcodeproj -scheme JellySleeve \
           -destination 'platform=macOS' test
```

16 unit tests cover the REST client and API-key storage: fixture
decoding, HTTP error mapping, `X-Emby-Token` auth header, migration
from UserDefaults to Keychain, and read/write behaviour for each
toggle state. The WebSocket client and the SwiftUI layer aren't
currently under test.

## Support and maintenance

JellySleeve is a personal hobby project. Use it as you would any other
piece of AGPL-3.0-licensed software: **best effort, no warranty, no SLA on
issue triage or PR review.**

- Bug reports and feature requests are welcome — see the templates in
  [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/).
- Contributions: read [`CONTRIBUTING.md`](CONTRIBUTING.md). No CLA.
- Maintenance policy: [`docs/MAINTENANCE.md`](docs/MAINTENANCE.md).
- Security-sensitive reports go to email rather than a public issue —
  see `CONTRIBUTING.md`.

## Acknowledgements

Visual inspiration from [Sleeve by Replay][sleeve]; built independently
for Jellyfin. The Jellyfin logo asset comes from the
[`jellyfin/jellyfin-ux`](https://github.com/jellyfin/jellyfin-ux) repo
under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).

## License

GNU Affero General Public License v3.0 (AGPL-3.0). See [`LICENSE`](LICENSE).
