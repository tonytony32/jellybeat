# Changelog

Notable changes to JellyBeat. Versions follow semver; pre-releases carry a
suffix (`-beta`, `-rc`).

## Unreleased

### The overlay stops flickering, and stops lying about the server

A run of fixes from the 2026-07-18 listening-journey UX audit
(`docs/audits/`), all of which show up while you're actually listening.

- **A pause is no longer mistaken for silence.** A Safari tab throttled in the
  background can stop reporting for tens of seconds; the overlay used to read
  that as "nothing is playing", collapse to the ambient glyph, and snap back on
  the next heartbeat — over and over. A paused track now survives a quiet
  source, and only a real stop clears it.
- **Ambient tells the truth about Jellyfin.** When the server isn't reachable —
  off the home network, or down — the ambient glyph becomes a crossed-out wifi
  symbol and says so, instead of opening your Jellyfin client onto a blank page
  and then waiting 30 s for music that can't arrive.
- **The overlay finds its way home.** With nothing playing anywhere it now
  falls back to Jellyfin rather than parking on the source that went away, so
  the connection state you see is the server's real one again — previously it
  could sit on a cheerful "connected" until you relaunched the app.
- **Gestures mean one thing each.** A single click on the ambient glyph opens
  your Jellyfin client; a double click on the artwork goes to the active
  source's own window. Each gesture now hovers with a tooltip explaining
  itself, a stray double click can't launch the client twice, and the artwork's
  double click no longer doubles as an open-Jellyfin shortcut.

### For plugin authors

- The loopback source ABI gained a normative **§7 "Staleness and pauses"**
  (`docs/loopback-source-abi-v1.md`): how long a presence TTL must be relative
  to your heartbeat, and why a paused state must not decay into an inactive
  one. A plugin that ignores it will reproduce the flicker above. Sections 7
  and 8 of the previous revision are now 8 and 9.

## 0.3.0-beta

### Renamed: JellySleeve → JellyBeat

The app is now **JellyBeat**. The rename also changed its bundle identifier to
`software.trypwood.jellybeat`, so macOS treats it as a brand-new app.

- **Reconfigure after upgrading.** Settings and login do **not** carry over from
  the old build — open Settings and re-enter your Jellyfin server URL and API key.
- **Delete the old app.** `JellyBeat.app` is a distinct app from `JellySleeve.app`
  and the two coexist in `/Applications`; remove the old `JellySleeve.app`.
