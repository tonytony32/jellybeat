# Maintenance policy

Internal notes, not promises to the community.

## Issues

- Pass over the queue **at most once a week**. Sometimes longer.
- Close duplicates with a link to the original. Labels:
  - `bug`: confirmed defect, in scope
  - `enhancement`: feature request, in scope
  - `out-of-scope`: breaks a plan §7 no-goal. Close it with a polite
    reference.
  - `cannot-reproduce`: closed after 14 days with no reproduction
  - `help-wanted`: happy to merge it, just not working on it myself
- Zero commitment to fix anything by a deadline.

## Pull requests

- Reviewed when there's time. No SLA promised.
- Acceptance criteria, in order:
  1. The existing test suite stays green
  2. The change doesn't break a documented feature
  3. It lines up with `docs/plans/PLAN.md`, especially §7 (no-goals) and the
     architectural calls in §2–§5
  4. The diff is reasonably small and focused
- No CLA. By submitting, the contributor agrees their work ships under the
  project's AGPL-3.0 licence.

## Releases

- No cadence. Tag when there's something worth tagging.
- Use semver. Pre-releases get a suffix (`-beta`, `-rc1`).
- Bump the `Marketing version` in the Xcode project's build settings if (and
  only if) you cut a tagged release.
- **v0.3.0 renamed the app** (JellySleeve → JellyBeat) and its bundle id
  (`software.trypwood.jellybeat`). Since the bundle id changed, the built
  `JellyBeat.app` is a *different* app from the old `JellySleeve.app`, so a
  drag-install won't overwrite it. On upgrade, delete the old
  `/Applications/JellySleeve.app` by hand. There's no data migration either:
  settings and login don't carry over. That's fine pre-release, just
  reconfigure on first launch.

## Support

- The README says it plainly: best effort, no warranty.
- Owner: Antonio. No team behind this, and users know it.
- Security reports go through email, not GitHub issues. See
  `CONTRIBUTING.md`.

## Branching

- `main` is the only long-lived branch.
- Feature work happens in short-lived branches or straight in topic PRs.
- Tags are immutable once published. Never force-push one after a public
  announcement.
