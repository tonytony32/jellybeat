# Changelog

Notable changes to JellyBeat. Versions follow semver; pre-releases carry a
suffix (`-beta`, `-rc`).

## 0.3.0-beta

### Renamed: JellySleeve → JellyBeat

The app is now **JellyBeat**. The rename also changed its bundle identifier to
`software.trypwood.jellybeat`, so macOS treats it as a brand-new app.

- **Reconfigure after upgrading.** Settings and login do **not** carry over from
  the old build — open Settings and re-enter your Jellyfin server URL and API key.
- **Delete the old app.** `JellyBeat.app` is a distinct app from `JellySleeve.app`
  and the two coexist in `/Applications`; remove the old `JellySleeve.app`.
