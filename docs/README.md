# JellyBeat docs

A map of the documentation. Start here.

## Current reference (living docs)

These describe how the app works **today**, and they're kept in sync with the
code. Some are linked straight from the Swift source comments, so they live at
the `docs/` root.

| Doc | What it covers |
|-----|----------------|
| [`architecture.md`](architecture.md) | The current architecture, with the focus on the multi-source playback system (Jellyfin plus loopback sources, arbitrated). Your main entry point for "how is this thing put together". |
| [`loopback-source-abi-v1.md`](loopback-source-abi-v1.md) | The normative ABI contract for third-party playback sources (the `loopback-source/1` HTTP API). What a plugin has to implement. |
| [`BEST_PRACTICES.md`](BEST_PRACTICES.md) | The *why* behind the conventions: the design decisions that keep the code testable and concurrency-safe. Written as a guide for rebuilding from scratch. *(Spanish.)* |

## Project policy

| Doc | What it covers |
|-----|----------------|
| [`MAINTENANCE.md`](MAINTENANCE.md) | The internal maintenance policy: issue triage, PR acceptance criteria, release cadence, branching. Notes to self, not promises to the community. |

## Plans ([`plans/`](plans/))

Historical planning documents. Handy for context and intent, but **the
reference docs above win** wherever they disagree. Not kept in sync with the
code.

| Doc | What it covers |
|-----|----------------|
| [`plans/PLAN.md`](plans/PLAN.md) | The original implementation plan (v3) the project followed: stack, phases, endpoints, no-goals. *(Spanish.)* |
| [`plans/youtube-bridge-arbiter-plan.md`](plans/youtube-bridge-arbiter-plan.md) | The plan that produced the multi-source arbiter. Superseded by [`architecture.md`](architecture.md) §5 for the shipped behaviour. |

## Visualizations ([`visualizations/`](visualizations/))

Standalone HTML diagrams. Open them in a browser.

| File | What it shows |
|------|---------------|
| [`visualizations/git-historia.html`](visualizations/git-historia.html) | The git graph and rebase history. |
| [`visualizations/websocket-timeline.html`](visualizations/websocket-timeline.html) | The WebSocket connection and reconnection timeline. |

## Audits ([`audits/`](audits/))

Dated, point-in-time reviews. Like `plans/`, they capture the state of things
on their date and are **not** kept in sync with the code afterwards.

| Doc | What it covers |
|-----|----------------|
| [`audits/2026-07-18-listening-journey-ux.html`](audits/2026-07-18-listening-journey-ux.html) | UX audit of the listening journey: the source→overlay pipeline and its timers, the cover↔ambient flicker with a paused throttled Safari tab, the blank-window launch when Jellyfin is unreachable, and the proposed target state machine. Standalone HTML, open in a browser. *(Spanish.)* |
| [`audits/2026-07-18-listening-journey-prompts.md`](audits/2026-07-18-listening-journey-prompts.md) | The five self-contained implementation prompts for that audit's fixes, with their ordering and dependencies. *(Spanish.)* |

## Not in version control

- `themes/`: the theme/layout design spec (`music-player-themes.md`) plus the
  mockup JPGs. Local-only design scratch (git-ignored), not part of the
  published docs.
