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
no-op push). The scripts live in `.github/scripts/`. Run everything from the
repo root (`/home/user/duckdb`).

`v1.0.0` = `1f98600c2cf8722a6d2f2d805bb4af5e701319fc` (the shared base; a
predecessor of every mirror branch).

## Step 0 — connect history (shallow clones)

The clone is usually shallow, so first make the v1.0.0 base reachable from the
source branch `<SRC>` (retry network failures with backoff):

```bash
git fetch origin 1f98600c2cf8722a6d2f2d805bb4af5e701319fc
git fetch --shallow-since=2024-05-28 origin <SRC>          # e.g. v2.0
git merge-base --is-ancestor 1f98600c2cf8722a6d2f2d805bb4af5e701319fc origin/<SRC> && echo CONNECTED
```

If not CONNECTED, deepen more (`git fetch --shallow-since=2024-05-20 origin <SRC>`
or `git fetch --deepen=5000 origin <SRC>`) and re-check. Do not continue until
CONNECTED.

## Step 1 — pick the method

- **Trunk / standalone branch** (the common case, e.g. `v2.0`): build an
  independent orphan with `flatten-branch.sh`.
- **Sibling of an existing flat branch** whose real merge base was absorbed via
  a back-merge: a naive independent flatten would misplace the flat merge base.
  Graft with `flatten-onto.sh` instead (see "Sibling" below). Check with:
  `M=$(git merge-base origin/<OTHER-SRC> origin/<SRC>); git rev-list --first-parent origin/<SRC> | grep -Fxc -- "$M"`
  — if `0`, M is off `<SRC>`'s first-parent path, so `<SRC>` must be grafted onto
  the sibling whose first-parent path *does* contain M.

## Step 2a — build (trunk / standalone)

```bash
bash .github/scripts/flatten-branch.sh origin/<SRC> <SRC>-flat
# optional last arg = limit: only the first N commits after v1.0.0 (quick prototype)
```

## Step 2b — build (sibling, graft)

Build the branch that **contains the merge base on its first-parent path** first
(the "parent flat"), then:

```bash
bash .github/scripts/flatten-onto.sh origin/<SRC> <SRC>-flat <PARENT-FLAT> origin/<PARENT-SRC>
# e.g. flatten-onto.sh origin/v1.5-variegata v1.5-variegata-flat v1.4-andium-flat origin/v1.4-andium
```

## Step 3 — verify

```bash
# tip tree must equal the source tree (faithful snapshot)
[ "$(git rev-parse <SRC>-flat^{tree})" = "$(git rev-parse origin/<SRC>^{tree})" ] && echo TREE_OK
# shared inception
git log --oneline --reverse <SRC>-flat | head -2   # expect 4f757efa9 Empty root, 14c089fa5 🦆
# determinism (optional): rebuild into a temp branch, compare tips, delete temp
# sibling only: flat merge base corresponds to the real one
git merge-base <SRC>-flat <PARENT-FLAT>            # == flat(M)
```

## Step 4 — push

```bash
for i in 1 2 3 4; do git push -f origin <SRC>-flat && break || sleep $((2**i)); done
```

Do not commit tracked files or touch development branches — a flat branch is
generated, not authored.
