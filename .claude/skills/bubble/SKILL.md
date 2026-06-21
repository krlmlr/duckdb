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
2. **Green per commit, certified once.** Every commit a run *rewrites* builds
   (`release`) and passes the fast unit tests before that run publishes. Commits
   left unchanged (the history past the de-merged merge, whose trees still equal
   `main`'s) are not rebuilt — they were green as `main` and get certified by the
   future run that linearises them. CI re-verifies the tip regardless.

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
# pass the immediately-OLDER release so only THIS release's back-merges count:
eval "$(bash $SK/bubble-cursor.sh origin/v1.5-variegata origin/main origin/v1.4-andium)"
echo "$BRANCH: de-merged=$DEMERGED_SO_FAR remaining=$RELEASE_BACKMERGES_REMAINING next=$NEXT_MERGE"
```

**Release scope — exclude the predecessor.** Each release line is built on the
previous one and back-merges it, so `v1.5-variegata` contains `v1.4-andium`'s
history; a naïve "second parent is an ancestor of the release" filter therefore
sweeps in every `v1.4→main` back-merge too (e.g. 31 = 15 `v1.4` + 16 `v1.5`).
Always pass the **predecessor release** (`origin/v1.4-andium` here) so the cursor
keeps only back-merges whose second parent is on *this* release but **not** the
predecessor's — the 16 genuine `v1.5→main` merges. The `v1.4→main` merges belong
to the `main-v1.4-andium` spine; v1.4's content is already in the v1.5 base. A
base release with no predecessor takes no third argument.

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

0. **Snapshot the original state & claim the run (the gate).** Before rewriting
   anything, push the pre-de-merge tip `$START` to the run's snapshot branch
   `$GATE_BRANCH` (= `<branch>-<NN>`, `NN` = `DEMERGED_SO_FAR`, 0-padded) with a
   **create-only** push. This preserves the exact state the later force-push will
   overwrite, *and* is the concurrency gate: the push **fails if the ref already
   exists**, meaning another run already holds this step — abort rather than run
   concurrently.
   ```bash
   git push --force-with-lease="refs/heads/$GATE_BRANCH:" origin \
     "$START:refs/heads/$GATE_BRANCH" || { echo "run $GATE_BRANCH already claimed — abort"; exit 1; }
   ```
   The snapshots form a numbered, immutable audit trail (`-00` = the original
   `main`, `-01` = after one de-merge, …); they are never force-updated.

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
4. **Commit optimistically, then test — only the rewritten segment.** Commit the
   chain first; then build + run the fast suite (`release`, shared ccache) on the
   **commits this run rewrote**, i.e. `CURRENT_FORK..` up to the de-merged merge's
   checkpoint. **Do not build the commits *past* the merge:** the upper history is
   re-attached unchanged (its trees still equal `main`'s, already green upstream),
   so it carries no new risk — it gets certified in the future run whose
   bifurcation reaches it. Green-certify the segment; if anything is red, **fix in
   place, retest, and repeat until that segment is green** — message preserved,
   content amended/squashed minimally. (The tip-tree assertion in step 5 is what
   guarantees the unbuilt upper part is still byte-for-byte `main`.)

   **Build budget — never pay a cold build per run.** A cold `release` build is
   ~10–17 min and will eat an entire session on its own. Don't let it: the
   tree-≡-main invariant makes builds cheap once the cache is warm.
   - **Persist and pre-warm the shared `CCACHE_DIR`.** Each de-merged commit's
     tree matches a real `main`/merge tree, so its object files are *identical*
     to a `main` build — a ccache warmed by building `main` (or simply kept from
     the previous run) gives near-total cache hits. Restore/keep `CCACHE_DIR`
     across runs; treat the one cold population as a setup cost, paid once, not
     per run (`ccache -s` to confirm a high hit rate).
   - **Build the chain in one persistent worktree, advancing commit by commit** —
     successive `make release` invocations relink incrementally and only the few
     files a commit actually touches recompile (and even those usually hit
     ccache). So a *sequence* of rewritten commits builds in seconds-to-minutes
     each after the first, not the cold ~17 min — adjacent commits differ little.
   - Size the run so the chain you must green-certify fits the window *after* the
     cache is warm; if you find yourself paying a cold build inside the budget,
     warm the cache first (build `main` once) rather than shrinking the chain.
5. **Publish only if the tree is unchanged.** Force-push is allowed *only* after:
   ```bash
   test "$(git rev-parse "${BRANCH}^{tree}")" = "$START_TREE" || { echo "TREE CHANGED — abort"; exit 1; }
   git push --force-with-lease origin "$BRANCH"
   ```
   The rewrite changed history; it must not have changed content.

## Proof of work: per-commit numstat (before vs after)

A faithful de-merge carries each PR's diff verbatim. After replaying a segment,
compare every commit's **per-file** numstat to the original — not the aggregate
shortstat, which hides *which* file moved. Diffing the two sorted per-file lists
is exact and cheap:

```bash
nsf(){ git show --numstat --format="" "$1" | awk -v OFS='\t' '{print $3,$1,$2}' | sort; }
# for each source commit C and its replayed C':
diff <(nsf "$C") <(nsf "$C_replayed")     # empty == carried verbatim; any line == a drifted file
```

An empty diff ⇒ the PR was reproduced exactly, file for file. Any line names a
file whose `+/-` changed — almost always a **generated file** (`-X theirs`
pulled in regenerated index churn) needing `make generate-files`, or a genuine
**forward-port**. Record the divergent files as the run's proof of work; a clean
run produces no lines.

Measured on this repo (validation, no build): a clean segment reproduced every
file identically (e.g. `src/.../physical_delete.hpp +278 -71` on both sides); the
one drift was `Replace magic number…`, where `src/main/config.cpp` went
`+2 -1 → +111 -136` — exactly the generated settings-index churn, correctly
named and flagged for regeneration.

## Hard rules

- **Tree ≡ main, always.** The publish gate asserts `tip tree == start tree`.
  Never force-push a tree that differs from `main`.
- **Green only what you rewrote.** Build + test the de-merged segment
  (`CURRENT_FORK..` the merge checkpoint); never build the unchanged history past
  the merge — it equals `main` and is certified by a later run. Push only a green
  segment; CI re-checks the tip. A break needing a large refactor is escalated,
  not pushed red.
- **Sequential, one merge per run.** Anchor each de-merge on the previous
  checkpoint, never on a bare second parent; never attempt batches in parallel.
- **Checkpoints are law.** Each de-merge reproduces its `tree(M)`; the tip
  reproduces `tree(main)`. Divergence is a defect to reconcile.
- **Preserve authorship & messages.** Carry each source commit's message and
  upstream author; the committer is us (`noreply@anthropic.com`). Generated, not
  authored — don't hand-edit tracked source outside conflict resolution.
- **`--force-with-lease`, never blind `--force`.** A lease failure means main or
  the branch moved — re-run the cursor, don't clobber.
- **ccache is the budget — warm, not cold.** Each rewritten commit's tree matches
  a `main` tree, so a persisted/pre-warmed `CCACHE_DIR` builds it from near-total
  cache hits; build the segment in one worktree so successive commits relink
  incrementally. Pay the cold build once (warm from `main`), never per run. Keep
  `CCACHE_DIR`.

## Relationship to the other skills

- `add-flat-branch` builds the squashed first-parent mirrors (`-flat`); it
  **discards** the back-merge structure (its merge base is the first-parent
  bifurcation, not the real one), which inflates apparent divergence.
- `add-flat-branch`'s `-dag` variant keeps the real merges — the substrate this
  skill reasons over (real `tree(M)` checkpoints, real second parents).
- `build-linear-branch` cherry-picks per-PR onto a *fixed* release base; bubble
  instead advances the base one merge at a time, using the merge trees as
  checkpoints, so drift is caught and localised every step.
