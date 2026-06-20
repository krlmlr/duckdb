# Handoff: flat (`-flat`) branches for duckdb mirrors

Instructions for the next agent session. Read this top to bottom before touching anything.

## Goal

Create flat (squashed-commit) **orphan** branches for the upstream-tracking
mirror branches `v1.4-*`, `v1.5-*` and `v2.0`, suffixed `-flat`
(`v1.4-andium-flat`, `v1.5-variegata-flat`, `v2.0-flat`). Each flat commit
reuses the original commit message plus a trailer linking to the upstream
commit in `duckdb/duckdb`. Push directly. A GitHub Actions workflow keeps the
`-flat` branches in sync (on push + scheduled).

## What already exists (done in the previous session)

On branch `claude/bold-galileo-jlnmdx` (pushed):

- `.github/scripts/flatten-branch.sh` — flattens a source ref into a `-flat`
  orphan branch. Walks **first-parent** history oldest→newest, snapshots each
  commit's tree, rewrites the message with a `git interpret-trailers` trailer
  `Upstream-commit: https://github.com/duckdb/duckdb/commit/<sha>`. Preserves
  author + committer identity/dates, so output is **deterministic** (re-runs
  give identical SHAs; unchanged source = no-op push; new upstream commits
  append as a fast-forward). Takes an optional `limit` = newest N commits.
- `.github/scripts/sync-flat-branches.sh` — discovers source branches matching
  `^(v1\.4-|v1\.5-|v2\.0$)` (excluding `-flat`), flattens each, force-pushes.
- `.github/workflows/SyncFlatBranches.yml` — triggers: `push` (v1.4-*/v1.5-*/v2.0),
  `schedule` (hourly), `workflow_dispatch`. `contents: write`, concurrency-guarded.

Prototype pushed to origin: **`v2.0-flat`** = 3 commits, the **last** (newest)
three first-parent commits of `v2.0`, orphan root, tip tree byte-identical to
`origin/v2.0`. This is the prototype the next steps revise.

## Next steps (requested)

1. **Use the FIRST three commits (inception), not the last three.** The current
   `flatten-branch.sh` `limit` selects the *newest* N. Add an inception mode
   that takes the *oldest* three commits instead.
2. **Start with an empty initial commit**, so each prototype branch has **four**
   commits total (empty root + 3 flat commits). The empty commit must be
   deterministic (fixed message/identity/date) so it is identical across all
   three branches.
3. **Expect the three `-flat` branches to share a common history.** The empty
   root + shared early commits should produce identical SHAs across
   `v1.4-andium-flat`, `v1.5-variegata-flat`, `v2.0-flat`.

   ⚠️ OPEN ISSUE TO RESOLVE FIRST: with the current first-parent traversal the
   branches do **not** share an inception. Their reverse-first-parent roots
   differ:
   - `v2.0`           → `799ed6495`
   - `v1.4-andium`    → `85225a429`
   - `v1.5-variegata` → `c0765cea1`

   The history also has many orphan roots (extension/submodule merges), and
   `git log --reverse` surfaces a 2025-10 commit, not a true project genesis.
   Pairwise `git merge-base`:
   - `v2.0 ∩ v1.5` = `40721d560`
   - `v2.0 ∩ v1.4` = `85225a429`
   - `v1.5 ∩ v1.4` = `ca5f01efe`

   So before coding, determine the notion of "inception" that actually yields a
   shared history (candidates: true common merge-base of all three; a defined
   genesis commit; full-history `--reverse` rather than `--first-parent`). Pick
   the traversal that makes the first three commits identical across branches,
   then verify the resulting `-flat` SHAs match.

4. **Borrow the scrubbing code from the `duckdb-r` repo.** The flat snapshots
   should be scrubbed the same way `duckdb-r` scrubs the vendored duckdb source
   (strip/clean files) before committing. Locate that code in `krlmlr/duckdb-r`
   and reuse it in `flatten-branch.sh` (apply scrub to each tree before
   `commit-tree`). NOTE: GitHub MCP is scoped to `krlmlr/duckdb` only — use
   `mcp__claude-code-remote__list_repos` then `add_repo` (load via ToolSearch)
   to access `duckdb-r`, or fetch the script via WebFetch from GitHub.

## Open questions for the user (confirm before full rollout)

- **Squash scope:** current design = one flat commit per upstream first-parent
  commit (so "first three" = three flat commits). Confirm this vs. a single
  squashed commit per branch.
- **Push trigger placement:** a `push` event resolves the workflow from the
  pushed branch, so the push trigger only fires once the workflow file lives on
  the source branches (which mirror upstream and arguably shouldn't be touched).
  The `schedule` trigger is the reliable path. Confirm whether to land the
  workflow on the source branches or run schedule-only.

## Quick commands

```bash
# Prototype (current behavior: newest 3). Adjust per next steps to oldest 3 + empty root.
bash .github/scripts/flatten-branch.sh origin/v2.0 v2.0-flat 3
git log v2.0-flat --format='%h %s%n  %(trailers:key=Upstream-commit)'

# Full sync (all source branches)
bash .github/scripts/sync-flat-branches.sh
```
