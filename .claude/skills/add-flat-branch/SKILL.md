---
name: add-flat-branch
description: Create, recreate, or refresh a "-flat" squashed orphan mirror branch (e.g. v2.0-flat, v1.5-variegata-flat) for a duckdb upstream-tracking branch. Each flat branch shares a deterministic inception (empty root + v1.0.0 reset); siblings are grafted at their first-parent divergence so every flat commit's diff matches upstream. Use whenever asked to add/recreate/rebuild a flat branch.
---

# Add a flat branch

A `-flat` branch is a deterministic, linear (squashed) **orphan** mirror of an
upstream-tracking branch (`v1.4-andium`, `v1.5-variegata`, `v2.0`, ...). Layout:

1. a fixed empty root commit — always `4f757efa92792bb37e837c399424c34ff5ecb31c`
2. a "reset to v1.0.0" commit (v1.0.0 tree) — always `14c089fa597e26924276cef74fdc028d20e1040d`
3. one flat commit per upstream **first-parent** commit, each carrying the
   original message (with `#NNN` scrubbed to redirect.github.com URLs) plus an
   `Upstream-commit` trailer.

Builds are deterministic: re-running yields identical SHAs (unchanged source =
no-op push). The scripts live alongside this skill in
`.claude/skills/add-flat-branch/`; run them from the repo root. They are kept
out of `.github/` on purpose, so duckdb's CI does not run on flat-branch tooling
changes (the workflows exclude `.claude/**`).

`v1.0.0` = `1f98600c2cf8722a6d2f2d805bb4af5e701319fc` (the shared base; a
predecessor of every mirror branch).

## Refreshing existing branches

To keep an EXISTING flat branch current, do NOT rebuild it — run the
incremental replayer, which appends only the new upstream first-parent commits
(deterministic, fast-forward push):

```bash
bash .claude/skills/add-flat-branch/replay-flat-branches.sh            # all -flat branches
bash .claude/skills/add-flat-branch/replay-flat-branches.sh v2.0-flat  # one branch
# DRY_RUN=1 builds/verifies without pushing
```

The `-dag` branches (see below) have their own incremental replayer, which also
re-links new cross-branch merges. It processes branches oldest-first and
auto-detects each branch's older dag from its existing links:

```bash
bash .claude/skills/add-flat-branch/replay-dag-branches.sh            # all -dag branches
bash .claude/skills/add-flat-branch/replay-dag-branches.sh v2.0-dag   # one branch
# DRY_RUN=1 builds/verifies without pushing; NO_FETCH=1 uses tracking refs as-is
```

Use the rest of this skill only for **genuinely new** branches.

## Topology: a chain by age

The flatten linearizes by `--first-parent`, so two flat branches share an
identical-SHA prefix only while their first-parent sequences agree; their flat
merge base is that common prefix's end — the **first-parent divergence** point.
A younger branch is **grafted** there onto the older one (`flatten-onto.sh`):
the anchor is the deepest commit on the younger branch's first-parent path that
is also reproduced in the older flat branch.

Anchor at the first-parent divergence, NOT at `git merge-base`. A real merge
base is often a back-merge commit that sits OFF the first-parent path; grafting
there parents the first appended commit on the wrong tree and yields a huge
bogus diff (e.g. ~2000 changed files where upstream changed 2). The first-parent
divergence keeps every flat commit's diff faithful to upstream.

Chain by age (oldest = trunk; each younger branch grafts onto the next-older):

```
v1.4-andium (trunk)  <-  v1.5-variegata  <-  v2.0   (youngest)
```

Canonical builds (each reuses the previous branch's flat history):

```bash
flatten-branch.sh origin/v1.4-andium    v1.4-andium-flat
flatten-onto.sh   origin/v1.5-variegata v1.5-variegata-flat v1.4-andium-flat
flatten-onto.sh   origin/v2.0           v2.0-flat           v1.5-variegata-flat
```

## Step 0 — connect history (shallow clones)

The clone is usually shallow, so make the v1.0.0 base reachable from `<SRC>`
(retry network failures with backoff):

```bash
git fetch origin 1f98600c2cf8722a6d2f2d805bb4af5e701319fc
git fetch --shallow-since=2024-05-28 origin <SRC>          # e.g. v2.0
git merge-base --is-ancestor 1f98600c2cf8722a6d2f2d805bb4af5e701319fc origin/<SRC> && echo CONNECTED
```

If not CONNECTED, deepen more (`--shallow-since=2024-05-20`, or
`--deepen=5000`) and re-check. Do not continue until CONNECTED.

## Step 1 — pick the method

- **Oldest mirror (the trunk, e.g. `v1.4-andium`)** — build a standalone orphan
  with `flatten-branch.sh`.
- **Any younger mirror** — graft onto the **nearest older sibling**'s flat
  branch with `flatten-onto.sh`. The script finds the anchor itself (the deepest
  commit on `<SRC>`'s first-parent path that the older flat branch reproduces),
  so you only pass the source, dest, and the older flat branch.

## Step 2a — build (trunk)

```bash
bash .claude/skills/add-flat-branch/flatten-branch.sh origin/<SRC> <SRC>-flat
# optional last arg = limit: only the first N commits after v1.0.0 (quick prototype)
```

## Step 2b — build (younger sibling, graft)

The older sibling's flat branch must already exist locally.

```bash
bash .claude/skills/add-flat-branch/flatten-onto.sh origin/<SRC> <SRC>-flat <OLDER-FLAT>
```

## Step 3 — verify

```bash
# tip tree must equal the source tree (faithful snapshot)
[ "$(git rev-parse <SRC>-flat^{tree})" = "$(git rev-parse origin/<SRC>^{tree})" ] && echo TREE_OK
# shared inception
git log --oneline --reverse <SRC>-flat | head -2   # expect 4f757efa9 Empty root, 14c089fa5 🦆

# NO BOGUS DIFFS: every flat commit must change the same files as its upstream
# commit. Check the FIRST commit after the merge base (the graft seam) and a
# few others — flat diff size must equal the upstream diff size.
fmb=$(git merge-base <SRC>-flat <OLDER-FLAT>)       # the graft seam (flat merge base)
seam=$(git rev-list --reverse --ancestry-path ${fmb}..<SRC>-flat | head -1)
up=$(git log -1 $seam --format='%(trailers:key=Upstream-commit,valueonly)' | sed -E 's#.*/commit/##')
echo "flat: $(git diff --name-only ${seam}^1 $seam | wc -l)  upstream: $(git diff --name-only ${up}^1 $up | wc -l)"
# the two counts MUST match; a large flat count vs small upstream count = the
# anchor bug (graft landed off <SRC>'s first-parent path).
```

## Step 4 — push

```bash
for i in 1 2 3 4; do git push -f origin <SRC>-flat && break || sleep $((2**i)); done
```

## Variant: merge-DAG branches (`-dag`)

The `-flat` branches are linear: cross-branch merges are squashed. The `-dag`
variant instead replays each "Merge `<older>` into `<current>`" as a real
two-parent commit — first parent = the linear chain (so trees and first-parent
diffs stay identical to `-flat`), second parent = the corresponding flat commit
in the older branch's dag. The second parent is found by merge-base recovery
(`git merge-base <commit> <older-source>`), so it works whether the merge is
clean or recorded via an intermediate "merge fixes" commit.

```bash
# trunk dag == trunk flat (no older branch)
git branch -f v1.4-andium-dag v1.4-andium-flat
# younger siblings: graft + add merge second parents into the older dag
bash .claude/skills/add-flat-branch/flatten-dag-onto.sh origin/v1.5-variegata v1.5-variegata-dag v1.4-andium-dag    origin/v1.4-andium
bash .claude/skills/add-flat-branch/flatten-dag-onto.sh origin/v2.0           v2.0-dag           v1.5-variegata-dag origin/v1.5-variegata
```

Verify as in Step 3 (tip tree, inception, no bogus diffs), and additionally
confirm the merge links exist: the "Merge `<older>`" commits should have two
parents, the second resolving into the older dag, e.g.
`git rev-list --merges --parents <SRC>-dag | head`.

Flat branches are generated, not authored — do not commit tracked files or touch
development branches.
