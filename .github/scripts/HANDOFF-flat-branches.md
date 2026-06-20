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
  `limit` = advance only the FIRST N first-parent commits after the base
  (0 = all). `base` defaults to v1.0.0. Re-runs are deterministic.
- `.github/scripts/sync-flat-branches.sh` — discovers `^(v1\.4-|v1\.5-|v2\.0$)`
  source branches (excluding `-flat`), flattens each (full history from v1.0.0),
  force-pushes.
- `.github/workflows/SyncFlatBranches.yml` — triggers: `push` (v1.4-*/v1.5-*/v2.0),
  `schedule` (hourly), `workflow_dispatch`. `contents: write`, concurrency-guarded,
  `fetch-depth: 0`.

Prototype pushed to origin: **`v2.0-flat`** = 5 commits
(`empty root` -> `v1.0.0` reset -> 3 advancing commits, tip `9aeaf1a132`),
built with `flatten-branch.sh origin/v2.0 v2.0-flat 3`.

## Next steps

1. **Validate shared SHAs across all three flats.** Build prototypes for
   `v1.4-andium` and `v1.5-variegata` (deepen each past v1.0.0 first) and
   confirm the empty root, the v1.0.0 reset, and the early advancing commits
   have identical SHAs across all three `-flat` branches.
2. **Full rollout.** Drop the `limit` (advance all the way to each tip) and run
   `sync-flat-branches.sh`. Confirm `v2.0-flat`/`v1.5-variegata-flat`/
   `v1.4-andium-flat` reach their real tips and tip trees match the sources.
3. **Borrow the scrubbing code from the `duckdb-r` repo.** The flat snapshots
   should be scrubbed the same way `duckdb-r` scrubs the vendored duckdb source
   (strip/clean files) before committing. Locate that code in `krlmlr/duckdb-r`
   and apply the scrub to each tree before `commit-tree` in `flatten-branch.sh`.
   NOTE: GitHub MCP is scoped to `krlmlr/duckdb` only — use
   `mcp__claude-code-remote__list_repos` then `add_repo` to access `duckdb-r`.

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
