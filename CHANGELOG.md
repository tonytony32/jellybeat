# Changelog

Notable changes to JellyBeat. Versions follow semver; pre-releases carry a
suffix (`-beta`, `-rc`).

## 0.3.0-beta

### Renamed: JellySleeve → JellyBeat

The app is now **JellyBeat**. The rename also changed its bundle identifier
(`software.trypwood.jellysleeve` → `software.trypwood.jellybeat`).

- **Your login and settings carry over automatically.** On first launch JellyBeat
  migrates your Jellyfin server URL, API key (whether it lived in UserDefaults or
  the Keychain), selected source, theme, window placement, and install identity
  from the previous version. Nothing from the old install is deleted, so you can
  still roll back to JellySleeve.
- **Existing source bridges keep working.** Discovery now scans both the new
  `~/Library/Application Support/software.trypwood.jellybeat/Sources` directory
  and the previous `…/software.trypwood.jellysleeve/Sources` one, so a bridge
  installed against the old build is still found (the current path wins any
  collision). New bridges should target the `jellybeat` path. The loopback-source
  ABI is unchanged (still `loopback-source/1`).
- **Delete the old app after upgrading.** Because the bundle identifier changed,
  `JellyBeat.app` is a *distinct* app from `JellySleeve.app` and the two coexist
  in `/Applications`. Once JellyBeat works, remove the old `JellySleeve.app`.
