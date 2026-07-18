# JellyBeat
<img width="1424" height="810" alt=" 2026-06-19 a las 12 24 53" src="https://github.com/user-attachments/assets/4fd3d46b-bc88-421c-a0b5-7fa06ed3a045" />

If you do care about music, you must have a local library of files: Mp3s with different bitrates, FLACs, ALACs, and more. But having the files is just the beginning, because [metadata](https://picard.musicbrainz.org/) is what keeps your collection organised and pristine. However, whenever you want to play your music, file browsing is not enough. You need a full player that leverages metadata to cater the music experience to you. This is when [Jellyfin](https://jellyfin.org/) for music comes in.

JellyBeat is a floooating now-playing overlay for Jellyfin Music 🎵 in macOS. Home is a remote Jellyfin server, mirrored over the REST API and the `/socket` push feed, but it could also pick up whatever else is playing: YouTube in Safari, or any third-party loopback source. [Sleeve by Replay][sleeve] was the visual inspiration. Everything under the hood is built from scratch for Jellyfin, with no AppleScript and no Apple Music dependency. Because of reasons.

[sleeve]: https://replay.software/sleeve

## Features

- 🎵 **One overlay, many sources.** Jellyfin is home. For anyone who cares about music, a personal music library is a must, and this is the reason why Jellyfin is the player, while I keep GBs of mp3s, m4as, and flacs carefully curated with [Musicbrainz](https://musicbrainz.org/) tags and covers. However, YouTube, YouTube Music and any loopback plugin get picked up on their own (fingers crossed). Whatever you started last is what you see.
- 🪟 **There when you want it, gone when you don't.** A borderless window that floooats over every Space, then shrinks to just the artwork and disappears the moment the music stops.
- ⚡ **Real-time, not refresh-and-pray.** Sub-second updates over WebSocket, with a REST fallback that steps in by itself if the socket drops.
- 🎨 **Themes that actually rearrange things.** Standard, Classic, Minim and Aero are real layout presets, not a recoloured skin.
- ⌨️ **At home on your Mac.** Media keys, Control Center, the Touch Bar and the system Now Playing module all just work, artwork included.
- 📞 **Knows when to back off.** A call lands over Continuity or FaceTime and it pauses Jellyfin for you. You decide when it comes back.
- 🔒 **Your keys, your call.** API key encrypted in the Keychain by default, and self-signed certs trusted only when you flip the switch.

> **Status: v0.3.0-beta.** The multi-source milestone, tidied up: a proper
> third-party loopback plugin ABI, a Source-first menu bar with theme previews
> that actually look like the themes, and a round of overlay and reliability
> fixes. These are tagged source betas, nothing more. Not packaged for
> distribution yet: no Developer ID signing, no notarised DMG.

## What it does

- It floats a borderless window over every Space with the current track: artwork, title, artist, album, and a progress bar that glides smoothly between server updates instead of jumping.
- **It mirrors more than one source.** Jellyfin is home base, but YouTube and YouTube Music (through the [yt-safari-bridge](https://github.com/tonytony32/yt-safari-bridge.git) Safari extension) and any third-party loopback plugin get picked up on their own. Whatever you started most recently drives the overlay, and there's a manual override in the menu-bar **Source** picker if you want the last word. (More in [Sources](#sources).)
- Four built-in themes (Standard, Classic, Minim, Aero), pick one from the Appearance tab in Settings. Each is a full layout preset, not just a colour swap: switching themes resizes the window and rearranges the artwork, the info and the controls.
- Snaps to the screen corners when you drag it, and remembers where you left it on each display.
- The media keys (F7, F8, F9), the Control Center module and the Touch Bar all do the same thing the overlay buttons do. The current track also shows up in the system Now Playing module, artwork included.
- When a call comes in on the Mac (an iPhone call relayed over Continuity, or FaceTime) it auto-pauses Jellyfin. It won't auto-resume though, that part is on you.
- When nothing is playing anywhere, it goes ambient: the window shrinks to the exact pixels of the artwork, turns invisible, and pops back on hover with the Jellyfin logo. One click opens the Safari "Add to Dock" web app for your configured server, or the default browser if you haven't registered one.
- **Ambient doesn't lie about the server.** When Jellyfin isn't reachable — you're off the home network, or it's down — the ambient glyph becomes a crossed-out wifi symbol, and clicking it says so instead of opening a web app onto a blank page. Whatever source was playing last, the overlay always reports the state of the *home* link.
- **A pause is not a stop.** Pause something and the artwork stays put, even if the source then goes quiet for a while — a Safari tab in the background can stop reporting for tens of seconds, and that used to collapse the overlay to ambient and back in a loop. Only a real stop clears it (or a paused track left alone for ten minutes).
- **Two gestures, one meaning each.** A **single click** on the ambient glyph opens your Jellyfin client — that's the gesture for "take me home", and it only exists where there's no music to go to. A **double click** on the **artwork** means "take me to what's playing": it brings the active source's own window to the front, so a track playing in a background Safari tab is one gesture away. Sources that can't be raised (Jellyfin itself — the web app is what you'd be looking at anyway) simply don't answer that gesture, rather than quietly doing something else with it. Hover either one and a tooltip tells you what the click will do; a stray double click on the ambient glyph won't open the client twice.
- Sub-second latency over a WebSocket connection to `/socket`. If the socket won't connect or drops three times, it quietly falls back to REST polling.
- Trusting self-signed certificates is opt-in, per server (handy for Tailscale or Caddy setups sitting behind an internal CA).
- Your API key lives in the macOS Keychain by default, encrypted at rest. You can move it to the preferences plist from Settings if you ever need to, though it's less safe there.

## Requirements

- macOS 26.0 Tahoe or later, Apple Silicon
- A reachable Jellyfin server (10.7+ recommended for the WebSocket protocol JellyBeat uses)
- An API key from **Jellyfin Dashboard → Advanced → API Keys**
- Your user ID from **Dashboard → Users → your user**

My personal recommendation is to run a Jellyfin server on a Raspberry Pi, attach a HDD to it, and stream anywhere.

## Build

It's a vanilla SwiftUI and AppKit hybrid, zero external dependencies. Open it in Xcode 26.5 or later:

```sh
git clone https://github.com/tonytony32/jellybeat.git
cd jellybeat
open JellyBeat.xcodeproj
```

Or build it straight from the command line:

```sh
xcodebuild -project JellyBeat.xcodeproj -scheme JellyBeat \
           -configuration Release build
```

The `.app` lands somewhere under `~/Library/Developer/Xcode/DerivedData/…`.
Copy it into `/Applications` and you can launch it from Spotlight or Launchpad
like anything else.

Eventually I will release the .dmg

## Configure

Open Settings (`⌘,`) and fill in the Server tab:

- **Base URL**: the full URL, scheme and port included, e.g.
  `http://192.168.3.80:8096` or `https://jellyfin.example.com`.
- **API key**: the one you generated in the Jellyfin dashboard.
- **User ID**: your user's GUID. You'll find it in the URL of your user's
  edit page in the dashboard.
- **Allow self-signed certificates**: only turn this on if you actually know
  what it means.
- **Store API key in UserDefaults**: off by default, and best left that way.
  The key sits encrypted in the macOS Keychain otherwise. Only flip it on if
  you need the key to survive a Keychain reset or for some specific migration,
  and go in knowing the trade-off: it'll be readable in the preferences plist.

Hit **Test connection** to check. A green tick with the server name and
version means you're good to go.

## Sources

JellyBeat can mirror and remote-control more than one backend, and it always
shows whichever one is actually playing:

- **Jellyfin**: the privileged built-in (WebSocket and REST), and the home source the overlay falls back to when nothing else is going.
- **YouTube and YouTube Music**: surfaced by the [yt-safari-bridge](https://github.com/tonytony32/yt-safari-bridge.git) Safari Web
  Extension as a local loopback source on `127.0.0.1`.
- **Third-party plugins**: any local process that speaks the loopback ABI and drops a `*.jellysource` manifest into
  `~/Library/Application Support/software.trypwood.jellybeat/Sources/`. No change to the app's own code needed.

Selection runs itself: the most recently started source wins, with a manual override in the menu-bar **Source** picker. The arbiter and the plugin contract
are written up in [`docs/architecture.md`](docs/architecture.md) and [`docs/loopback-source-abi-v1.md`](docs/loopback-source-abi-v1.md).

## Layout

```
JellyBeat.xcodeproj/        # Xcode project + shared scheme
JellyBeat/                  # Sources
  App/                        # AppDelegate, coordinators, SourceArbiter, SourceRegistry, monitors
  Networking/                 # JellyfinClient + socket, LoopbackSourceClient, SourceManifest, models
  State/                      # PlayerStore, SettingsStore, poller, source feeds, caches, Keychain
  UI/                         # OverlayView, themes, Settings tabs, components
  Assets.xcassets             # AppIcon, AccentColor, JellyfinLogo
JellyBeatTests/             # Swift Testing target with Jellyfin response fixtures
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

The app layer is a thin coordinator sitting over a handful of focused collaborators, rather than one catch-all delegate that does everything:

- **`AppDelegate`**: owns the shared stores (`SettingsStore`, `PlayerStore`,
  `ThemeRegistry`, `ArtworkCacheProvider`) plus the `SourceArbiter` and
  `SourceRegistry`, and wires everyone together. It barely holds any logic of
  its own.
- **`OverlayWindowController`**: everything about window geometry. Creating the
  borderless window, setting level and opacity, the theme- and player-driven
  resize between the full and ambient layouts, edge and corner snapping, and
  remembering the position per display.
- **`PlaybackConnectionCoordinator`**: the Jellyfin playback-feed state machine.
  WebSocket first with REST polling as the fallback, the reconnection policy,
  sleep and wake handling, and the debounced reconfigure when connection
  settings change.
- **`SourceArbiter` and `SourceRegistry`**: the multi-source layer. The registry
  keeps one feed per loopback source (built-in YouTube plus any plugins it
  finds), and the arbiter decides whether Jellyfin or a loopback source drives
  the overlay, gating the writes so only the active one ever shows. Full design
  in [`docs/architecture.md`](docs/architecture.md).

Window-visibility events that should pause or resume the feed (miniaturise,
close, deminiaturise) travel from the window controller to the connection
coordinator through closures, so neither one has to hold a direct reference to
the other.

Data flows one way up the layers: **Networking → State → UI**. The transport
clients decode the raw models, `PlayerStore` runs the active-session heuristic
and holds the single source of truth for the overlay, and the SwiftUI views and
themes just read from it. The shared transport vocabulary (`PlaybackAction`)
lives in the State layer so the store never has to depend on a view type.

## Tests

```sh
xcodebuild -project JellyBeat.xcodeproj -scheme JellyBeat \
           -destination 'platform=macOS' test
```

Around 90 unit tests (Swift Testing) cover the networking and state layers:
REST fixture decoding, HTTP error mapping and the `X-Emby-Token` auth header,
Keychain storage and the UserDefaults→Keychain migration, the loopback source
ABI client, and the multi-source layer itself (the pure `SourceArbiter.decide`
policy, activation recency, bridge→snapshot mapping, artwork-scheme hardening,
and `PlayerStore` source-gating). The WebSocket client and the SwiftUI layer
aren't directly under test, fair warning.

## Support and maintenance

JellyBeat is a personal hobby project. Treat it like any other bit of
AGPL-3.0-licensed software: **best effort, no warranty, and no SLA on issue
triage or PR review.**

- Bug reports and feature requests are welcome, there are templates waiting in
  [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/).
- Want to contribute? Read [`CONTRIBUTING.md`](CONTRIBUTING.md) first. No CLA.
- Maintenance policy: [`docs/MAINTENANCE.md`](docs/MAINTENANCE.md).
- Security-sensitive reports go to email, not a public issue. Details in
  `CONTRIBUTING.md`.

## Acknowledgements

Visual inspiration from [Sleeve by Replay][sleeve], built independently for Jellyfin. The Jellyfin logo asset comes from the
[`jellyfin/jellyfin-ux`](https://github.com/jellyfin/jellyfin-ux) repo
under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).

## License

Mozilla Public License 2.0 (MPL 2.0). See [`LICENSE`](LICENSE).
