---
name: bubble
description: Maintain a perpetual `main-<release>` branch (e.g. `main-v1.5-variegata`) that mirrors `main`'s tree exactly while progressively de-merging the release branch's back-merges. Each self-contained, restartable run advances the bifurcation one merge commit ahead (onto that merge's second parent), keeping the chain green (release build + fast tests, shared ccache) and force-pushing only after asserting the tip tree is unchanged. Use to incrementally linearise main against a release line into a bisectable spine for vendoring (one such branch per minor release).
---

# Bubble: linearise `main` against a release line, one merge per run

## What it produces

`main-v1.5-variegata` is a **perpetual** branch whose **tree is always identical
to `main`**, but whose history has the release branch's back-merges progressively
**de-merged** from the bottom up. Each run moves the **bifurcation point** (where
the linear base forks from the release line) **one back-merge ahead** — onto that
merge's *second parent*. Run after run, the linear (merge-free) base grows toward
the tip; the fully-bubbled branch is a bisectable linear spine of `main` rooted on
the release line, which is what the R package vendors (cut at a release tag, e.g.
`v1.5.4`). One branch per minor release (`main-v1.5-variegata`, `main-v1.6-…`).

This is **replay done sequentially with deterministic checkpoints** — not the
flat first-parent squash (`add-flat-branch`) and not a per-commit cherry-pick onto
a fixed base (`build-linear-branch`). The merge trees are the checkpoints.

## Two invariants (hold at every force-push)

1. **Tree ≡ main.** `tree(main-<release>) == tree(main)` at the tip. The branch
   only ever rewrites *history* (where/how the release line is merged), never
   content. This is the force-push safety check (below).
2. **Green per commit.** Every commit on the rewritten chain builds (`release`)
   and passes the fast unit tests before the branch is published. CI re-verifies.

## Why one merge per run, and why it cannot be parallelised

A back-merge `M = merge(M^1, M^2)` re-syncs main with the release line; `M^2` is
the release-side parent and `tree(M)` is the maintainers' authoritative
reconciliation — a free, deterministic checkpoint. De-merging `M` means replaying
the first-parent segment below it onto `M^2` and reproducing `tree(M)`.

It is **strictly sequential**: each segment's PRs are authored on the *accumulated*
main line, so they only apply cleanly once **all earlier segments are already in
the base**. Anchoring batches independently on their own `M^2` (the parallel
temptation) drifts, and the drift is exactly the missing accumulated main chain —
measured here, it grows monotonically as the genuine main-only run between
back-merges lengthens:

| de-merge batch | segment PRs | conflicting commits | drift vs `tree(M)` (`-X theirs`) |
|---|---|---|---|
| 1 | 4 | 0 | 0 (identical) |
| 5 | 24 | 8 | 104 files |
| 6 | 30 | 9 | ~1,044 files |
| 13 | 105 | 47 | ~3,545 files |
| 14 | 89 | 56 | ~3,778 files |

So a run advances **one** merge, anchored on the **previous** checkpoint (which
carries the accumulated chain) — never on the bare `M^2`.

## State & resume (the branch is the state)

`origin/main-<release>`'s tip *is* the cursor. A fresh agent reconstructs the
plan from refs only:

```bash
SK=.claude/skills/bubble
eval "$(bash $SK/bubble-cursor.sh origin/v1.5-variegata origin/main)"
echo "$BRANCH: de-merged=$DEMERGED_SO_FAR remaining=$RELEASE_BACKMERGES_REMAINING next=$NEXT_MERGE"
```

`NEXT_MERGE` is the oldest release back-merge still on the branch; `NEXT_P2` is the
new bifurcation; `MERGE_TREE` is the checkpoint the de-merge must reproduce;
`SEGMENT_FROM..NEXT_P1` is the first-parent segment to replay. `NEXT_MERGE=` empty
means fully bubbled — only the tracking step (below) runs.

## The run (one self-contained invocation)

```bash
SK=.claude/skills/bubble
git fetch origin main "$RELEASE_BASENAME" "$BRANCH" 2>/dev/null || true
START=$(git rev-parse "origin/$BRANCH" 2>/dev/null || git rev-parse origin/main)
START_TREE=$(git rev-parse "${START}^{tree}")   # == tree(main) by invariant 1
git config rerere.enabled true
export CCACHE_DIR="$HOME/.cache/duckdb-linear-ccache"   # shared, survives worktrees
```

1. **Track main (append what's missing).** If `main` advanced since the branch's
   tip, append the new first-parent commits so the tip tree matches `main` again.
   New back-merges simply extend the to-de-merge list for future runs.
2. **Advance the bifurcation one merge.** Re-root the de-merged-so-far linear
   base **plus the next segment** onto `NEXT_P2`, dropping `NEXT_MERGE`, and
   re-attach the still-merged upper history unchanged:
   ```bash
   # conceptually: rebase (SEGMENT_FROM..NEXT^1) onto NEXT_P2, drop NEXT, keep the rest
   git rebase --rebase-merges --onto "$NEXT_P2" "$SEGMENT_FROM"   # mark NEXT for de-merge
   ```
   The de-merge **must** reproduce the checkpoint: `tree(at NEXT's position) ==
   MERGE_TREE`. Assert it; a mismatch is a resolution defect, not an accepted
   result.
3. **Resolve conflicts in the main agent** (this is the semantic work; do not
   delegate it):
   - `-X theirs` is a **provisional** fill, validated by build+test — never the
     final word.
   - **Generated files** (`settings.hpp`/`config.cpp` from `settings.json`; the
     PEG grammar; serialization; `enum_util`) must be **regenerated** (`make
     generate-files`), never merged — `-X theirs` mis-maps their indices and
     still compiles.
   - A real semantic break surfaces at build/test; **forward-port** the
     reconciliation from the later main commit that owns it (the merge tree is
     the oracle for what the end state should be).
4. **Commit optimistically, then test.** Commit the chain first; then build +
   run the fast suite (`release`, shared ccache). If anything is red, **fix in
   place, retest, and repeat until the *whole* chain is green** — message
   preserved, content amended/squashed minimally.
5. **Publish only if the tree is unchanged.** Force-push is allowed *only* after:
   ```bash
   test "$(git rev-parse "${BRANCH}^{tree}")" = "$START_TREE" || { echo "TREE CHANGED — abort"; exit 1; }
   git push --force-with-lease origin "$BRANCH"
   ```
   The rewrite changed history; it must not have changed content.

## Hard rules

- **Tree ≡ main, always.** The publish gate asserts `tip tree == start tree`.
  Never force-push a tree that differs from `main`.
- **Green per commit.** Push only a fully-green chain; CI re-checks. A break that
  needs a large refactor is escalated, not pushed red.
- **Sequential, one merge per run.** Anchor each de-merge on the previous
  checkpoint, never on a bare second parent; never attempt batches in parallel.
- **Checkpoints are law.** Each de-merge reproduces its `tree(M)`; the tip
  reproduces `tree(main)`. Divergence is a defect to reconcile.
- **Preserve authorship & messages.** Carry each source commit's message and
  upstream author; the committer is us (`noreply@anthropic.com`). Generated, not
  authored — don't hand-edit tracked source outside conflict resolution.
- **`--force-with-lease`, never blind `--force`.** A lease failure means main or
  the branch moved — re-run the cursor, don't clobber.
- **ccache is the budget.** Adjacent commits differ little; the shared
  `CCACHE_DIR` is what makes per-commit `release` builds affordable. Keep it.

## Relationship to the other skills

- `add-flat-branch` builds the squashed first-parent mirrors (`-flat`); it
  **discards** the back-merge structure (its merge base is the first-parent
  bifurcation, not the real one), which inflates apparent divergence.
- `add-flat-branch`'s `-dag` variant keeps the real merges — the substrate this
  skill reasons over (real `tree(M)` checkpoints, real second parents).
- `build-linear-branch` cherry-picks per-PR onto a *fixed* release base; bubble
  instead advances the base one merge at a time, using the merge trees as
  checkpoints, so drift is caught and localised every step.
