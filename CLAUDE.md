# CLAUDE.md

Guidance for AI agents working in this repository.

## What this is

JellySleeve is a **native macOS app** (SwiftUI + AppKit, no external
dependencies) — a floating now-playing overlay for Jellyfin. See `README.md`
for the feature set and `docs/BEST_PRACTICES.md` for the architecture.

## Build & test

This is an **Xcode / Swift** project. There is no `package.json`, no `npm`, no
Node — if you ever see those, the tool output is wrong (see below). Build and
test from the command line:

```sh
xcodebuild -project JellySleeve.xcodeproj -scheme JellySleeve \
           -configuration Debug -destination 'platform=macOS' build

xcodebuild -project JellySleeve.xcodeproj -scheme JellySleeve \
           -destination 'platform=macOS' test
```

A cold `xcodebuild` takes tens of seconds. **Build once, at the end of a
change** — not after every edit. Trust that an `Edit`/`Write` that returned no
error applied; don't re-read files just to confirm it.

## Working efficiently here (hard-won)

Lessons from a session that took ~3x longer than the work warranted. Almost all
the waste came from how tool-call failures were handled, not from the task.

- **Sanity-check the environment before trusting tool output.** A glitch once
  returned *fabricated* file contents — a fake Electron `package.json` and
  `app/` tree — for this Swift repo, and minutes were lost reasoning about files
  that don't exist. If file contents contradict `git status` or the known stack,
  stop and run one cheap reality check (`git ls-files | head`) before reading or
  reasoning further. Never build on output that doesn't fit.

- **If a tool result doesn't come back, do NOT resend it.** Results can arrive
  on a delay. Resending the same Read/Bash "just in case" — or fanning out a big
  batch — floods the buffer and makes the backlog worse. Send one minimal probe
  and wait. (In the bad session, a single file was Read 8x in one batch.)

- **Never use `sleep` or `ScheduleWakeup` to "wait for the environment to
  recover."** The harness re-invokes you when work completes; self-imposed waits
  only add wall-clock and can re-fire stale follow-up turns after the work is
  already done.

- **Keep batches small and duplicate-free.** Independent calls in parallel are
  good; the same call repeated, or a 30-call batch that cancels as a block, is
  pure waste.
