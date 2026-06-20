# Handoff: flat (`-flat`) branches for duckdb mirrors

Instructions for the next agent session. Read this top to bottom before touching anything.

## Goal

Create flat (squashed-commit) **orphan** branches for the upstream-tracking
mirror branches `v1.4-*`, `v1.5-*` and `v2.0`, suffixed `-flat`
(`v1.4-andium-flat`, `v1.5-variegata-flat`, `v2.0-flat`). All flat branches
share a common inception (empty root + a `v1.0.0` reset) so their early history
has identical SHAs. A GitHub Actions workflow keeps the `-flat` branches in
sync (on push + scheduled).

## Shared-history analysis (resolved)

The three mirror branches DO share history. The common ancestor of all three is:

```
ddbb5e2e4  2026-03-25  Backport `__EMSCRIPTEN__` fix (#21581)
```

verified with `git merge-base --octopus` + `--is-ancestor`. Pairwise bases:
`v1.4 ∩ v1.5 = ca5f01efe`, `v1.4 ∩ v2.0 = ddbb5e2e4`, `v1.5 ∩ v2.0 = 40721d560`.

The earlier "no shared inception" worry was an artifact of `--first-parent
--reverse` landing on different orphan roots (this mirror has many orphan roots
from extension/submodule merges). It does not reflect real ancestry.

`v1.0.0` (`1f98600c2cf8722a6d2f2d805bb4af5e701319fc`, 2024-05-29) is a
**predecessor of the common merge-base** and is used as the shared base commit.

NOTE: the local clone is **shallow**. To reach `v1.0.0` and connect it to the
branch tips, deepen first, e.g. `git fetch --shallow-since=2024-05-28 origin v2.0`
(CI uses `actions/checkout` with `fetch-depth: 0`, so this is a non-issue there).

## Flat branch layout (current design)

Produced by `flatten-branch.sh`:

1. a **deterministic empty root** commit (fixed identity/date -> identical SHA
   across all flat branches),
2. a **"reset to v1.0.0"** commit carrying the v1.0.0 tree (shared base),
3. one flat commit per upstream first-parent commit, advancing from v1.0.0
   toward the source tip. Each reuses the original message + an
   `Upstream-commit: https://github.com/duckdb/duckdb/commit/<sha>` trailer and
   preserves author/committer identity+dates (deterministic re-runs).

## What exists

On branch `claude/cool-goodall-n93k4q`:

- `.github/scripts/flatten-branch.sh` — `flatten-branch.sh <src> <dst> [limit] [base]`.
  Builds an independent orphan flat branch (empty root + v1.0.0 reset + advance).
  `limit` = advance only the FIRST N first-parent commits after the base
  (0 = all). `base` defaults to v1.0.0. Re-runs are deterministic.
- `.github/scripts/flatten-onto.sh` — `flatten-onto.sh <src> <dst> <parent-flat> <parent-src>`.
  Builds a flat branch for a sibling release branch by GRAFTING onto an already
  built flat branch at flat(M), where M = `git merge-base <parent-src> <src>`,
  so `merge-base(<parent-flat>, <dst>)` == flat(M) (corresponds to the real
  merge base). Requires M to be on `<parent-src>`'s first-parent path.
- `.github/scripts/sync-flat-branches.sh` — discovers `^(v1\.4-|v1\.5-|v2\.0$)`
  source branches (excluding `-flat`), flattens each (full history from v1.0.0),
  force-pushes. NOTE: this still flattens each branch INDEPENDENTLY; it does not
  yet use flatten-onto.sh, so sibling merge bases are not preserved by the sync
  workflow (see step 1 below).
- `.github/workflows/SyncFlatBranches.yml` — triggers: `push` (v1.4-*/v1.5-*/v2.0),
  `schedule` (hourly), `workflow_dispatch`. `contents: write`, concurrency-guarded,
  `fetch-depth: 0`.

Pushed to origin:
- **`v2.0-flat`** = 5 commits (prototype, tip `9aeaf1a132`), built with
  `flatten-branch.sh origin/v2.0 v2.0-flat 3`.
- **`v1.4-andium-flat`** = 2690 commits (full, tip `90b24fa9de`), built with
  `flatten-branch.sh origin/v1.4-andium v1.4-andium-flat`.
- **`v1.5-variegata-flat`** = 3938 commits (full, tip `150ebebb81`), built with
  `flatten-onto.sh origin/v1.5-variegata v1.5-variegata-flat v1.4-andium-flat origin/v1.4-andium`.

## Sibling merge bases (important)

`flatten-branch.sh` linearizes by `--first-parent`, so two INDEPENDENTLY
flattened orphans share an identical-SHA prefix only as long as their
first-parent sequences agree. Their flat merge base = longest common
first-parent prefix, which equals the real merge base ONLY when that merge base
lies on BOTH branches' first-parent paths.

For v1.4 ∩ v1.5 the real merge base is `M = ca5f01efe` ("backport
GetLocalFileSystem improvements to andium (#23130)"), which v1.5 absorbed via a
back-merge: M is on v1.4's first-parent path but NOT on v1.5's. So an
independent flatten of v1.5 would mis-place the flat merge base ~404 commits too
early (at `605eaf76`, 2025-09). The fix is `flatten-onto.sh`: build the branch
whose first-parent path CONTAINS the merge base first (v1.4), then graft the
sibling (v1.5) onto flat(M). Verified:
`merge-base(v1.4-andium-flat, v1.5-variegata-flat)` == flat(M), trailer ->
`ca5f01efe`; both tip trees match their sources; shared inception identical.

## Next steps

1. **Teach `sync-flat-branches.sh` about sibling merge bases.** It currently
   flattens each branch independently, which breaks the v1.4∩v1.5 merge base
   (see above). Make it build the trunk(s) first and graft siblings with
   `flatten-onto.sh`, ordering branches so each merge base is on its parent's
   first-parent path. Decide the trunk topology for all of v1.4/v1.5/v2.0
   (note: v2.0 ∩ v1.5 = `40721d560`, v2.0 ∩ v1.4 = `ddbb5e2e4`).
2. **Full rollout / re-sync.** Re-flatten v2.0 in full (drop the `limit`) and
   confirm all three flat branches reach their real tips with matching trees and
   correct pairwise merge bases.
3. **Borrow the file-scrubbing code from the `duckdb-r` repo.** Commit MESSAGES
   are already scrubbed (`#NNN` -> redirect.github.com, as in duckdb-r). Still
   TODO: scrub the snapshot TREES the same way duckdb-r scrubs vendored sources
   (e.g. `scripts/rconfigure.py` / `vendor-one.sh`) before `commit-tree`.
   GitHub MCP is scoped to `krlmlr/duckdb` only — `duckdb-r` is checked out at
   `/home/user/duckdb-r` (or use `list_repos` + `add_repo`).

## Open questions for the user (confirm before full rollout)

- **Squash scope:** current design = one flat commit per upstream first-parent
  commit. Confirm vs. a single squashed commit per branch.
- **Push trigger placement:** a `push` event resolves the workflow from the
  pushed branch, so the push trigger only fires once the workflow file lives on
  the source branches (which mirror upstream and arguably shouldn't be touched).
  The `schedule` trigger is the reliable path. Confirm schedule-only vs. landing
  the workflow on the source branches.

## Quick commands

```bash
# Deepen shallow clone past v1.0.0, then build the prototype (empty root +
# v1.0.0 reset + first 3 commits).
git fetch --shallow-since=2024-05-28 origin v2.0
bash .github/scripts/flatten-branch.sh origin/v2.0 v2.0-flat 3
git log --reverse v2.0-flat \
  --format='%h %s%n  %(trailers:key=Upstream-commit,valueonly)'

# Full sync (all source branches, full history from v1.0.0)
bash .github/scripts/sync-flat-branches.sh
```
