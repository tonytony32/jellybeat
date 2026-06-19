# Maintenance policy

Internal notes — not promises to the community.

## Issues

- Pass over the queue **at most once a week**. Sometimes longer.
- Close duplicates with a link to the original. Apply labels:
  - `bug` — confirmed defect, in scope
  - `enhancement` — feature request, in scope
  - `out-of-scope` — violates plan §7 no-goals; close with a polite
    reference
  - `cannot-reproduce` — closed after 14 days without a reproduction
  - `help-wanted` — willing to merge but not actively working on it
- Zero commitment to fix anything on a deadline.

## Pull requests

- Review when there's time. No SLA promised.
- Acceptance criteria, in order:
  1. The existing test suite stays green
  2. The change doesn't break a documented feature
  3. The change is aligned with `docs/plans/PLAN.md`, in particular §7
     (no-goals) and the architectural decisions in §2-§5
  4. The diff is reasonably small / focused
- No CLA. By submitting, the contributor agrees their work ships under
  the project's AGPL-3.0 licence.

## Releases

- No cadence. Tag when there's something worth a tag.
- Use semver. Pre-releases get a suffix (`-beta`, `-rc1`).
- Update the corresponding `Marketing version` in the Xcode project's
  build settings if (and only if) you cut a tagged release.
- **v0.3.0 renamed the app** (JellySleeve → JellyBeat) and its bundle id
  (`software.trypwood.jellybeat`). Because the bundle id changed, the built
  `JellyBeat.app` is a *distinct* app from the old `JellySleeve.app` — a
  drag-install won't overwrite it. On upgrade, remove the old
  `/Applications/JellySleeve.app`. There is no data migration — settings/login do
  not carry over (acceptable pre-release; reconfigure on first launch).

## Support

- README is explicit: best effort, no warranty.
- Owner: Antonio. No team behind this; users know it.
- Security reports go through email, not GitHub issues — see
  `CONTRIBUTING.md`.

## Branching

- `main` is the only long-lived branch.
- Feature work happens in short-lived branches or directly in
  topic PRs.
- Tags are immutable once published — never force-push them after a
  public announcement.
