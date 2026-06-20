# Contributing to JellyBeat

Thanks for the interest. JellyBeat is a personal hobby project that happens
to be open source. Contributions are welcome, just calibrate your
expectations first:

- No SLA on issue triage or PR review. I get to the queue when I have the
  bandwidth, and sometimes that's a while.
- No CLA. Send a PR and you're agreeing it can ship under the project's
  AGPL-3.0 licence.
- Scope is set by [`docs/plans/PLAN.md`](docs/plans/PLAN.md). Anything that
  goes against the plan's no-goals (multi-server support, local audio
  playback, client-side scrobbling, iCloud sync, Mac App Store distribution)
  gets a polite no.

## Running the project

```sh
git clone https://github.com/tonytony32/jellybeat.git
cd jellybeat
open JellyBeat.xcodeproj
```

To build, you'll need:

- macOS 26.0 Tahoe SDK (Xcode 26.5 or later)
- Swift 6 with strict concurrency on
- Apple Silicon (`arm64` only)

Run the tests:

```sh
xcodebuild -project JellyBeat.xcodeproj -scheme JellyBeat \
           -destination 'platform=macOS' test
```

11 unit tests cover the REST client. The WebSocket client and the SwiftUI
layer aren't under test yet, so adding coverage there is fair game for a PR.

## Style

- 4 spaces, LF line endings, UTF-8 (`.editorconfig` keeps everyone honest).
- Prefer `let` over `var`, value types over reference types where it's
  reasonable, and structured concurrency (`async/await`, `Task`, actors)
  over completion handlers.
- Strict concurrency is on. Any new type that can cross an actor boundary
  should be `Sendable` (or `nonisolated` for a read-only value struct).
- `os.Logger` for diagnostics, never `print`. The subsystem is
  `software.trypwood.jellybeat` and categories follow the layer
  (`networking`, `state`, `ui`).
- Anything sensitive (API key, server URL, session ids) goes into
  `Logger.notice/.error` with `privacy: .private` or `.public(mask: .hash)`,
  and **never** `.public`.

## Submitting a PR

1. Open an issue first for anything non-trivial, so we can sanity-check the
   scope before you sink time into it.
2. Keep the diff focused. One concern per PR.
3. Make sure `xcodebuild test` is green locally.
4. Write a commit message that explains the **why**, not just the what. Have
   a look at the existing history for the tone.

## Security

Found something that smells like a security issue (a credential leaking into
logs, a trust delegate failing open, that kind of thing)? Please email
**antonio at trypwood dot com** instead of filing a public issue.
