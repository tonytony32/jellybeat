# JellyBeat docs

Map of the documentation. Start here.

## Current reference (living docs)

These describe how the app works **today** and are kept in sync with the code.
Some are referenced directly from Swift source comments, so they stay at the
`docs/` root.

| Doc | What it covers |
|-----|----------------|
| [`architecture.md`](architecture.md) | The current architecture, with emphasis on the multi-source playback system (Jellyfin + loopback sources, arbitrated). The main entry point for "how is this put together". |
| [`loopback-source-abi-v1.md`](loopback-source-abi-v1.md) | Normative ABI contract for third-party playback sources (the `loopback-source/1` HTTP API). What a plugin must implement. |
| [`BEST_PRACTICES.md`](BEST_PRACTICES.md) | The *why* behind the conventions — design decisions that keep the code testable and concurrency-safe. Written as a guide for rebuilding from scratch. *(Spanish.)* |

## Project policy

| Doc | What it covers |
|-----|----------------|
| [`MAINTENANCE.md`](MAINTENANCE.md) | Internal maintenance policy: issue triage, PR acceptance criteria, release cadence, branching. Not promises to the community. |

## Plans — [`plans/`](plans/)

Historical planning documents. Useful for context and intent, but **superseded
by the reference docs above** where they disagree. Not kept in sync with the
code.

| Doc | What it covers |
|-----|----------------|
| [`plans/PLAN.md`](plans/PLAN.md) | The original implementation plan (v3) this project followed: stack, phases, endpoints, no-goals. *(Spanish.)* |
| [`plans/youtube-bridge-arbiter-plan.md`](plans/youtube-bridge-arbiter-plan.md) | The plan that produced the multi-source arbiter. Superseded by [`architecture.md`](architecture.md) §5 for the shipped behavior. |

## Visualizations — [`visualizations/`](visualizations/)

Standalone HTML diagrams — open them in a browser.

| File | What it shows |
|------|---------------|
| [`visualizations/git-historia.html`](visualizations/git-historia.html) | Git graph & rebase history. |
| [`visualizations/websocket-timeline.html`](visualizations/websocket-timeline.html) | The WebSocket connection/reconnection timeline. |

## Not in version control

- `themes/` — theme/layout design spec (`music-player-themes.md`) plus the
  mockup JPGs. Local-only design scratch (git-ignored); not part of the
  published docs.
