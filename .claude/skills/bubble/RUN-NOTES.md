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

## What run #1 did (de-merge of #20488, `7eebd33`)

- Replayed the 4-commit main-side segment onto `M^2` (`00528f79`); dropped empties.
- **Checkpoint verified:** tip tree `== tree(7eebd33) = 358030af…`.
- **Proof of work:** all 4 replayed commits **verbatim** (per-file numstat
  identical to originals); zero drift.
- Re-attached 954 descendant commits tree-preserving (`reattach.sh`).
- **Publish gate:** `tip tree == tree(origin/main-dag) = 1f6f9e89…` ✅.
- Pushed new branch `main-v1.5-variegata`; cursor on it now reports
  `DEMERGED_SO_FAR=1, REMAINING=15, NEXT_MERGE=bafa967f…`.

## Run #2 (de-merge of #20588, `bafa967f`, "Merge 1.5 → Main")

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

## Run #2 (de-merge "Merge 1.5 → Main", checkpoint tree e337ce86)

Published: `main-v1.5-variegata` → `5bbadaa83` (`DEMERGED=2, REMAINING=14`).
Gate/snapshot `-01` = run #1 result (the state this run overwrote).

- **Base = the previous branch, not `main-dag`.** Run #2 starts from
  `origin/main-v1.5-variegata` and de-merges that branch's back-merge (its SHA;
  the same merge is a *different* SHA on `main-dag` after run #1's rewrite). A
  first attempt that re-attached onto `main-dag` was wrong — corrected.
- **Reconcile commit required.** The merge dropped the main-only "NOT
  elimination" rule (PR #20394), which no main-side replay reproduces; a single
  reconcile commit (tree == checkpoint) absorbs it. See its message for the audit.
- **Reconciliation audit** (`reconcile-audit.sh`): reconcile delta = 7 files, all
  the not_elimination removal (3 deletions + 4 semantic mods), **0 generated**.
  Reviewed; factual note recorded; proceeded.
- **Per-commit build times** (warm ccache, dedicated worktree, Ninja):
  baseline(run#1 tip) 723s/429obj · NOT-elim (base jump to new v1.5 root)
  308s/340 · DELETE-RETURNING 61s/20 · magic-number 42s/10 · reconcile 718s/301
  (`expression_type.hpp` is high-fanout). Fast tests: all passed. Cross-tree
  ccache hits were low (~12%) — unity builds bust on the v1.5↔main delta.

## Run #3 (de-merge of #20644, base `9c028743`)

**Clean run — no reconcile commit** (like run #1): replaying the 7-commit spine
onto `9c028743` reproduced the merge tree `ab8d98b8` exactly. 6 applied, 1 empty
(#20624 azure-ref, already in the base). **Published** `main-v1.5-variegata` →
`cd70b7c3`; **`DEMERGED=3, REMAINING=13`**; gate/snapshot `-02` = run #2 result.

Green-certify: all 6 commits **compile** green (`702/57/39/647/26/10s`); the fast
unit suite is run on the **checkpoint `76e52d65`** — the *linearized back-merge*
(tree == merge tree `ab8d98b8`). A back-merge's merged tree is a **combined
cross-line state** — reproducing it byte-for-byte does **not** make it tested, so
it is **not** green by construction (corrected from an earlier wrong call to skip
it). It is the highest-value functional test for the run. (`a803d034`, the
pre-reconcile synthetic tree, was also run and passed — a bonus, not the target.)

Three environment/script learnings, all folded into the skill:
- **Stale local ref / `origin/` gate name** — the cursor now prefers
  `origin/<branch>` and derives `GATE/WIP` from the bare basename.
- **Cherry-pick empties** — `--empty=drop`/`--allow-empty=false` error here; the
  replay loop detects empties from the message and `--skip`s (`replay-segment.sh`).
- **Branch deletion is a no-op here** — `git push --delete` silently fails, so
  `-02-wip` persists. Harmless (named by the advanced `DEMERGED`, never
  re-consulted); the skill no longer depends on deleting it.

## Resume

```bash
SK=.claude/skills/bubble
eval "$(bash $SK/bubble-cursor.sh origin/v1.5-variegata-dag origin/main-dag origin/v1.4-andium-dag main-v1.5-variegata)"
# de-merge the next back-merge on the branch (cursor resolves origin/<branch>)
```
