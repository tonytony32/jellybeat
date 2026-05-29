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
- API key stored either in the Keychain (encrypted, opt-in) or in the
  app's preferences plist (cleartext, default — the user picks).

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
- **Store API key in Keychain** — off by default. When on, the key is
  written to the macOS Keychain instead of the cleartext preferences
  plist.

Hit **Test connection** to verify. A green check with the server name and
version means you're good.

## Layout

```
JellySleeve.xcodeproj/        # Xcode project + shared scheme
JellySleeve/                  # Sources
  App/                        # NSApplicationDelegateAdaptor, NSWindow, MediaCenter
  Networking/                 # JellyfinClient, JellyfinSocketClient, models
  State/                      # PlayerStore, SettingsStore, KeychainHelper
  UI/                         # OverlayView, themes, Settings tabs, components
  Assets.xcassets             # AppIcon, AccentColor, JellyfinLogo
  Resources/                  # placeholder
JellySleeveTests/             # XCTest target with Jellyfin response fixtures
docs/
  PLAN.md                     # The implementation plan this project followed
LICENSE                       # MIT
```

## Tests

```sh
xcodebuild -project JellySleeve.xcodeproj -scheme JellySleeve \
           -destination 'platform=macOS' test
```

11 unit tests cover the REST client: fixture decoding, HTTP error
mapping, and the `X-Emby-Token` auth header. The WebSocket client and
the SwiftUI layer aren't currently under test.

## Acknowledgements

Visual inspiration from [Sleeve by Replay][sleeve]; built independently
for Jellyfin. The Jellyfin logo asset comes from the
[`jellyfin/jellyfin-ux`](https://github.com/jellyfin/jellyfin-ux) repo
under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).

## License

MIT. See [`LICENSE`](LICENSE).
