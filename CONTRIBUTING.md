# Contributing to JellySleeve

Thanks for the interest. JellySleeve is a personal hobby project that
happens to be open source; contributions are welcome, but please calibrate
expectations:

- No SLA on issue triage or PR review. I look at the queue when I have
  the bandwidth.
- No CLA. By submitting a PR you agree it can ship under the project's
  AGPL-3.0 licence.
- Scope is fixed by [`docs/plans/PLAN.md`](docs/plans/PLAN.md). Features that
  contradict the plan's no-goals (multi-server support, local audio
  playback, scrobble from the client, iCloud sync, Mac App Store
  distribution) will be politely declined.

## Running the project

```sh
git clone https://github.com/tonytony32/jellysleeve.git
cd jellysleeve
open JellySleeve.xcodeproj
```

Build target requires:

- macOS 26.0 Tahoe SDK (Xcode 26.5 or later)
- Swift 6 with strict concurrency on
- Apple Silicon (`arm64` only)

Run the tests:

```sh
xcodebuild -project JellySleeve.xcodeproj -scheme JellySleeve \
           -destination 'platform=macOS' test
```

11 unit tests cover the REST client. The WebSocket client and the
SwiftUI layer aren't currently under test — adding coverage there is
fair game for PRs.

## Style

- 4 spaces, LF line endings, UTF-8 (`.editorconfig` enforces this).
- Prefer `let` over `var`, value types over reference types where
  reasonable, and structured concurrency (`async/await`, `Task`,
  actors) over completion handlers.
- Strict concurrency is on. New types that can be passed across actor
  boundaries should be `Sendable` (or `nonisolated` for read-only value
  structs).
- `os.Logger` for diagnostics — never `print`. The subsystem is
  `software.trypwood.jellysleeve` and categories follow the layer
  (`networking`, `state`, `ui`).
- Anything sensitive (API key, server URL, session ids) goes into
  `Logger.notice/.error` arguments with `privacy: .private` /
  `.public(mask: .hash)` and **never** `.public`.

## Submitting a PR

1. Open an issue first for anything non-trivial so we can sanity-check
   scope before you spend time on it.
2. Keep the diff focused. One concern per PR.
3. Make sure `xcodebuild test` is green locally.
4. Write a commit message that explains the **why**, not just the
   what — see existing history for the tone.

## Security

If you find something that looks like a security issue (credential
leak in logs, trust delegate failing open, etc.), please email
**antonio at trypwood dot com** rather than filing a public issue.
