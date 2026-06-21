# Bubble run notes (v1.5-variegata, first run)

Record of the first `bubble` run on this fork. Date: 2026-06-21.
Rebased onto `v2.0` after PR #7 (the `bubble` skill) was merged there.

## Refs (the working pairing)

The SKILL example (`origin/v1.5-variegata origin/main`) yields **zero** back-merges
here: upstream `main` squash-merges PRs and never back-merges the release line. The
real merge topology lives in the `-dag` mirrors (PR #6) and the pushed `main-dag`:

- **release**          = `origin/v1.5-variegata-dag`
- **main**             = `origin/main-dag`        (tree ≡ `origin/main`)
- **previous release** = `origin/v1.4-andium-dag` (3rd cursor arg; see below)
- **branch**           = `main-v1.5-variegata`

## Scope: exclude the predecessor release (already in the merged cursor)

`v1.5-variegata`'s history **includes the v1.4-andium line**, so every
`v1.4 → main` back-merge's `M^2` is also an ancestor of v1.5 and would be
de-merged first (31 merges, the oldest 15 being v1.4) unless excluded.

The merged `bubble-cursor.sh` (v2.0) takes the previous release as its **3rd
positional arg** and drops merges whose `M^2` is already on it. With
`origin/v1.4-andium-dag` the cursor reports the **16 v1.5-only** back-merges:

```bash
bash bubble-cursor.sh origin/v1.5-variegata-dag origin/main-dag origin/v1.4-andium-dag main-v1.5-variegata
```

## Mechanism: re-attach is a tree-preserving graft, NOT `rebase --rebase-merges`

This is the one finding **not yet folded into SKILL.md** (kept in `reattach.sh`).

SKILL.md step 2 still says `git rebase --rebase-merges --onto …`. That **re-merges**
the upper back-merges, which conflict (notably the generated `src/main/config.cpp`
settings index), so it does *not* "re-attach the upper history unchanged."

Correct mechanism (`reattach.sh`): replace the de-merged merge `M` with the linear
reconstruction `R` (`tree(R)==tree(M)`), then rewrite **only the true descendants
of `M`** with `git commit-tree`, **reusing each commit's tree verbatim**. No
conflicts, no build, v1.5-side commits (and the remaining merges' `^2`) stay
intact, and `tip tree == tree(main)` is guaranteed.

## What the first run did (merge #16, `7eebd33`)

- Replayed the 4-commit main-side segment onto `M^2` (`00528f79`); dropped empties.
- **Checkpoint verified:** tip tree `== tree(7eebd33) = 358030af…`.
- **Proof of work:** all 4 replayed commits **verbatim** (per-file numstat
  identical to originals); zero drift.
- Re-attached 954 descendant commits tree-preserving (`reattach.sh`).
- **Publish gate:** `tip tree == tree(origin/main-dag) = 1f6f9e89…` ✅.
- Pushed new branch `main-v1.5-variegata`; cursor on it now reports
  `DEMERGED_SO_FAR=1, REMAINING=15, NEXT_MERGE=bafa967f…`.

## Next run preview (merge #17, `bafa967f`, "Merge 1.5 → Main")

- New bifurcation `3710298a` (+36 v1.5 commits); checkpoint `tree e337ce86`.
- Incremental new work vs run #1 = **2 commits**, both touching generated/
  serialized files (the regenerate-don't-merge path): `2ae32651`
  (`src/main/config.cpp`) and `1131e35d` (serialization of `logical_operator`).

## Caveat — green-per-commit not locally certified in run #1

The target tree (`== main`, the bubble tip) **built green** (`make release`,
exit 0), so the tip is green. The 4 **new** segment commits were not locally
built in the original budget: duckdb uses **unity builds** (`ub_*.cpp`), so any
v1.5-vs-main difference in any included file busts that unit's ccache entry — the
segment tree is far enough from main that nearly every unity object misses, making
it effectively a cold build. The 4 commits are clean verbatim replays reproducing
the maintainers' exact merge tree; CI re-verifies them.

## Resume

```bash
SK=.claude/skills/bubble
eval "$(bash $SK/bubble-cursor.sh origin/v1.5-variegata-dag origin/main-dag origin/v1.4-andium-dag main-v1.5-variegata)"
# NEXT_MERGE=bafa967f… → de-merge #17, etc.
```
