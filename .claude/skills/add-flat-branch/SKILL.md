---
name: add-flat-branch
description: Create, recreate, or refresh a "-flat" squashed orphan mirror branch (e.g. v2.0-flat, v1.5-variegata-flat) for a duckdb upstream-tracking branch. Each flat branch shares a deterministic inception (empty root + v1.0.0 reset) and, for siblings, preserves the real merge base. Use whenever asked to add/recreate/rebuild a flat branch.
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

Use the rest of this skill only for **genuinely new** branches.

## Topology: a chain by age

The flatten linearizes by `--first-parent`, so two flat branches share an
identical-SHA prefix only while their first-parent sequences agree; their flat
merge base is that common prefix. To make a flat merge base equal the *real*
merge base, the younger branch is **grafted** onto the older one at the real
merge-base commit (`flatten-onto.sh`).

Flat orphans form a tree, so for three branches only **adjacent** pairs can have
exact merge bases. We chain by age (oldest = trunk; each younger branch grafts
onto the next-older sibling), which keeps the adjacent (release-to-next-release)
merge bases exact and sacrifices only the oldest-vs-youngest pair:

```
v1.4-andium (trunk)  <-  v1.5-variegata  <-  v2.0   (youngest)
```

Canonical builds (each reuses the previous branch's flat history):

```bash
flatten-branch.sh origin/v1.4-andium    v1.4-andium-flat
flatten-onto.sh   origin/v1.5-variegata v1.5-variegata-flat v1.4-andium-flat    origin/v1.4-andium
flatten-onto.sh   origin/v2.0           v2.0-flat           v1.5-variegata-flat origin/v1.5-variegata
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
  branch with `flatten-onto.sh`. The real merge base `M` must lie on the older
  sibling's first-parent path (so its flat branch contains `flat(M)`); verify:
  `M=$(git merge-base origin/<OLDER-SRC> origin/<SRC>); git rev-list --first-parent origin/<OLDER-SRC> | grep -Fxc -- "$M"` → must be `1`.

## Step 2a — build (trunk)

```bash
bash .claude/skills/add-flat-branch/flatten-branch.sh origin/<SRC> <SRC>-flat
# optional last arg = limit: only the first N commits after v1.0.0 (quick prototype)
```

## Step 2b — build (younger sibling, graft)

The older sibling's flat branch must already exist locally.

```bash
bash .claude/skills/add-flat-branch/flatten-onto.sh origin/<SRC> <SRC>-flat <OLDER-FLAT> origin/<OLDER-SRC>
```

## Step 3 — verify

```bash
# tip tree must equal the source tree (faithful snapshot)
[ "$(git rev-parse <SRC>-flat^{tree})" = "$(git rev-parse origin/<SRC>^{tree})" ] && echo TREE_OK
# shared inception
git log --oneline --reverse <SRC>-flat | head -2   # expect 4f757efa9 Empty root, 14c089fa5 🦆
# sibling only: flat merge base corresponds to the real one
git merge-base <SRC>-flat <OLDER-FLAT>             # == flat(M)
# determinism (optional): rebuild into a temp branch, compare tips, delete temp
```

## Step 4 — push

```bash
for i in 1 2 3 4; do git push -f origin <SRC>-flat && break || sleep $((2**i)); done
```

Flat branches are generated, not authored — do not commit tracked files or touch
development branches.
