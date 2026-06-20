---
name: build-linear-branch
description: Build or resume a "-linear" vendored DuckDB branch (e.g. v2.0-v1.5.4-linear) — a linear, test-gated replay of a dev "-flat" branch's commits on top of the flat commit for a release tag. Each commit keeps its original message and must build + pass its own tests before being pushed. The branch is the state: a fresh agent resumes from its tip. Use when asked to create, advance, resume, or rebuild a -linear branch.
---

# Build a linear branch

A `v<DEV>-v<TAG>-linear` branch (e.g. `v2.0-v1.5.4-linear`) is a linear,
**test-gated** vendoring spine for the R package. It replays the dev-specific
commits of a `-flat` branch (default source `v2.0-flat`, see the
`add-flat-branch` skill) on top of the flat commit that corresponds to a
**release tag**, fixing each one until it builds and passes its tests.

Three invariants — keep all three true at every push:

1. **Rooted on the release.** The first commit's parent is `flat(<TAG>)` — the
   `-flat` commit whose `Upstream-commit` trailer is the tag's upstream commit
   (for `v1.5.4`: `2b2347a75`). Pick a different tag and you get a different,
   independent target (`v2.0-v1.5.5-linear`, …) built from a clean base.
2. **Every source commit, in spirit, same message.** Carry the dev-flat commits
   in order. A plain `cherry-pick` preserves the message verbatim, including the
   `Upstream-commit` trailer — do not rewrite subjects or strip trailers.
3. **Green per commit.** A commit is pushed only after a `release` build and the
   fast unit tests pass on it. CI on GitHub Actions re-verifies independently.
   (Measured on `v2.0`: `release` runs the identical 4859 registered / 4517
   executed tests with identical outcomes vs `reldebug`, builds faster, and its
   tree is 0.7 GiB vs 16.1 GiB — so it is the default gate; `reldebug` /
   `relassert` are triage knobs via `DUCKDB_BUILD`.)

This runs in a clone of **`krlmlr/duckdb`** (`origin`); the target is pushed
there alongside the `-flat` branches. It is a long, **restartable** job (≈956
commits for `v2.0` onto `v1.5.4`): push incrementally so progress is durable.

## The state is the branch (restart)

`origin/<TARGET>`'s tip is the last green commit; each commit keeps its source's
`Upstream-commit` trailer, so the next commit to do is fully determined by the
tip. A fresh agent just runs the cursor:

The helper scripts live beside this file; run them from the repo root:

```bash
SK=.claude/skills/build-linear-branch
bash $SK/linear-todo.sh env  v1.5.4        # BASE/TARGET/DONE/REMAINING
bash $SK/linear-todo.sh list v1.5.4        # remaining source SHAs, oldest-first
# second positional arg overrides the dev line (default v2.0), e.g. ... v1.5.4 v2.0
```

`list` already drops everything up to the target tip — start at its first line.
If the tip's `Upstream-commit` is not in `BASE..<dev>-flat`, the source history
was rewritten: stop and rebuild from a clean base, do not force-push.

## Step 0 — orient

```bash
SK=.claude/skills/build-linear-branch
eval "$(bash $SK/linear-todo.sh env v1.5.4)"
echo "$TARGET  base=$BASE  done=$DONE  remaining=$REMAINING"
# create/checkout the working branch at the resume point
git fetch origin "$TARGET" 2>/dev/null || true
git checkout -B "$TARGET" "${TARGET_TIP}"
```

## Step 1 — one-time setup

- **Shared ccache** (the reason per-commit builds are affordable — adjacent
  commits differ little). It lives outside worktrees and survives scrubbing:
  `export CCACHE_DIR="$HOME/.cache/duckdb-linear-ccache"`.
- **A scratch dir** (`SCRATCH`) for worktrees, on the same filesystem you measure
  with the disk guard.

## Step 2 — the loop (one commit at a time)

For each source flat commit `C` from `linear-todo.sh list` (oldest-first):

1. **Disk admission.** Never start a worktree blind:
   ```bash
   bash $SK/linear-disk-guard.sh "$SCRATCH" || { scrub a finished worktree; retry; }
   ```
   With the default `release` gate a build tree is ~0.7 GiB, so disk is not the
   binding constraint — **CPU/build-time is** (a single `-j` build saturates the
   cores), and the guard will report a large `MAX_PARALLEL`. Cap real concurrency
   by cores, not disk. The guard earns its keep mainly under the `reldebug`
   triage knob (~16 GiB trees), where it models **one full build + (k−1) pruned
   trees** and measures actual sizes once they exist.

2. **Apply + resolve (main checkout).** This is the semantic work: the base
   carries the release line's backports, the dev line carries its own versions
   of overlapping fixes, so conflicts are *expected* here (unlike the purely
   mechanical `add-flat-branch` / `advance-green-dev` skills).
   ```bash
   git cherry-pick "$C"        # keeps author + message (incl. Upstream-commit)
   ```
   - Resolve conflicts so the result is faithful to the dev change; **finish the
     commit with the same message** (`git cherry-pick --continue` keeps it).
   - If the pick is **empty** (the change is already in the base), the commit is
     present in spirit — `git cherry-pick --skip` and move on.

3. **Build → test in a worktree.** Worktrees share ccache; the build phase
   prunes intermediates after link (minor for `release`, large for `reldebug`):
   ```bash
   WT="$SCRATCH/wt-$(git rev-parse --short HEAD)"
   git worktree add --detach "$WT" HEAD
   bash $SK/linear-build-test.sh build "$WT"   # compile+link, then prune *.o/*.a
   bash $SK/linear-build-test.sh test  "$WT"   # run the fast unittest
   ```
   **Overlap to use a second process:** under `release` the limit is **CPU**, not
   disk — a single `-j` build already uses all cores, so a second concurrent
   build mostly splits throughput rather than adding it; the useful overlap is
   running `test(N)` (the ~9 min suite) while `build(N+1)` compiles. So the
   pipeline is `build(N) → [test(N) ‖ build(N+1)]`, bounded by cores (and, under
   the `reldebug` knob, by `MAX_PARALLEL`). Only overlap commits you do **not**
   expect to fix — a fix to `K` invalidates a speculative `K+1` built
   on it (see step 5). While builds run, resolve later commits in the main
   checkout.

4. **Green → push, then scrub.** Push only the green tip; pushes are
   fast-forward and append-only, so the branch is valid at every point and CI
   runs per pushed commit:
   ```bash
   git push -u origin "$TARGET"          # no --force; a non-ff push means trouble — stop
   git worktree remove --force "$WT"     # reclaim disk; keep CCACHE_DIR
   ```

5. **Red → fix in place (still "in spirit").** Make the smallest change that
   greens the commit while preserving its message:
   - amend a minimal fix into the commit (API drift, a moved symbol, a test
     expectation), or
   - squash a non-building intermediate forward into the commit that completes
     it.
   Rebuild (ccache makes the retry cheap), then push when green. If a commit
   cannot be made green without large refactoring, **stop and report** with the
   commit and the failure — do not push red and do not skip silently.

## Step 3 — finishing & re-runs

- When `linear-todo.sh env` reports `REMAINING=0`, the target tree should equal
  the dev-flat tip's intent; the branch is complete and CI is the final word.
- **New release base.** When `v1.5.5` lands, do not rewrite `v2.0-v1.5.4-linear`.
  Run the skill with the new tag → a new `v2.0-v1.5.5-linear` from a clean base
  (fewer conflicts, since the base already contains more upstream fixes). Old
  targets stay as historical pins.

## Constraints (hard rules)

- **Push only green.** A commit reaches `origin/<TARGET>` only after
  `linear-build-test.sh` passes on it. CI/GHA is the independent re-check.
- **Fast-forward, append-only.** Never force-push a `-linear` branch. A non-ff
  push or a tip whose `Upstream-commit` is off `BASE..<dev>-flat` means the
  source was rewritten → rebuild from a clean base, never force.
- **Preserve messages.** Carry each source commit's message verbatim, including
  the `Upstream-commit` trailer (the restart cursor). Fixes amend/squash content
  only.
- **Disk-bounded concurrency.** Consult `linear-disk-guard.sh` before every new
  worktree; never exceed `MAX_PARALLEL`. Scrub each worktree after its commit is
  pushed; keep the shared `CCACHE_DIR`.
- **Resolve, don't paper over.** Conflicts are expected and must be resolved
  faithfully to the dev change. An empty pick (already in base) is skipped; a
  commit that needs a large refactor to go green is escalated, not forced.
- **One target per release tag.** The target name encodes the base
  (`v<DEV>-v<TAG>-linear`); a new base is a new branch, not a rewrite.
- **Generated branch.** `-linear` branches are produced, not authored — do not
  commit tracked source files or touch development branches while building one.
