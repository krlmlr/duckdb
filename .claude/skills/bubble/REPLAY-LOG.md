# Replay log — `main-v1.5-variegata`

Provenance of every commit replayed since the v1.5 bifurcation, oldest-first
(`git log --reverse` order). **Growable:** each run appends a sub-bullet to every
entry (its role that run) and adds L1 entries for newly-reached original commits;
synthetic commits are inserted inline at their spine position. Links →
`github.com/krlmlr/duckdb`.

Per-run **role** of an original commit:
- **replayed** `sha` — cherry-picked onto that run's bifurcation (clean unless a L3 note says otherwise);
- **empty (absorbed)** — became empty because the advanced v1.5 base already contains it;
- **reattached** `sha` — above the de-merged merge that run, re-committed tree-verbatim by the graft (new SHA, unchanged tree).

Bifurcation base per run (each run re-roots the segment onto `NEXT_P2`):
- run #1 (de-merge #16) → [`00528f79`](https://github.com/krlmlr/duckdb/commit/00528f79b)
- run #2 (de-merge #17) → [`3710298a`](https://github.com/krlmlr/duckdb/commit/3710298ae)

---

- **#20369** feat(adbc): support the experimental `adbc.ingest.target_catalog` option — original: *(not on `main`; see `-dag`)*
  - `-dag`: [`728df5d9`](https://github.com/krlmlr/duckdb/commit/728df5d956da)
  - run #1: replayed [`c5d0ff7a`](https://github.com/krlmlr/duckdb/commit/c5d0ff7a43b7)
  - run #2: empty (absorbed)
- **#20414** Fix file opener propagation — original [`2617272f`](https://github.com/krlmlr/duckdb/commit/2617272f9f89)
  - `-dag`: [`d5feb7b2`](https://github.com/krlmlr/duckdb/commit/d5feb7b2d719)
  - run #1: replayed [`ab1e272f`](https://github.com/krlmlr/duckdb/commit/ab1e272fc357)
  - run #2: empty (absorbed)
- **#20394** [Optimizer] Support NOT elimination — original [`48bdbbeb`](https://github.com/krlmlr/duckdb/commit/48bdbbebe440)
  - `-dag`: [`d5da6c6a`](https://github.com/krlmlr/duckdb/commit/d5da6c6af935)
  - run #1: replayed [`3b5f37a7`](https://github.com/krlmlr/duckdb/commit/3b5f37a7fc9b)
  - run #2: replayed [`c82e14df`](https://github.com/krlmlr/duckdb/commit/c82e14dfffe4)
    - then **removed** by the run #2 reconcile commit (the back-merge dropped this main-only rule); see the synthetic entry below
- **#20447** Expose ArenaAllocator from PlanGenerator — original [`5438deaa`](https://github.com/krlmlr/duckdb/commit/5438deaaac98)
  - `-dag`: [`9a4ae087`](https://github.com/krlmlr/duckdb/commit/9a4ae087b45b)
  - run #1: replayed [`0ffd087c`](https://github.com/krlmlr/duckdb/commit/0ffd087cddb5) — **#16 checkpoint** (tree `358030af` == merge #16 tree)
  - run #2: empty (absorbed)
- **#20485** Optimize DELETE RETURNING by passing columns through from scan — original [`175069fd`](https://github.com/krlmlr/duckdb/commit/175069fd8cbe)
  - `-dag`: [`01cf68f2`](https://github.com/krlmlr/duckdb/commit/01cf68f21558)
  - run #1: reattached [`1131e35d`](https://github.com/krlmlr/duckdb/commit/1131e35d4654)
  - run #2: replayed [`112bd5a8`](https://github.com/krlmlr/duckdb/commit/112bd5a8ee36)
- **#20510** Replace magic number with `DConstants::INVALID_INDEX` in `DBConfig` — original [`1c62e11b`](https://github.com/krlmlr/duckdb/commit/1c62e11b8201)
  - `-dag`: [`8fba00c0`](https://github.com/krlmlr/duckdb/commit/8fba00c0750b)
  - run #1: reattached [`2ae32651`](https://github.com/krlmlr/duckdb/commit/2ae32651415c)
  - run #2: replayed [`a576264f`](https://github.com/krlmlr/duckdb/commit/a576264fcd80)
- **[synthetic] reconcile / checkpoint — linearized "Merge 1.5 → Main" (#20588)** — original merge [`3584d61c`](https://github.com/krlmlr/duckdb/commit/3584d61c125a)
  - `-dag`: [`5d91a654`](https://github.com/krlmlr/duckdb/commit/5d91a654fd2d)
  - run #1: reattached as a **merge** [`bafa967f`](https://github.com/krlmlr/duckdb/commit/bafa967feeab) (#17 not yet de-merged this run)
  - run #2: synthetic linear commit [`d0ab64a4`](https://github.com/krlmlr/duckdb/commit/d0ab64a4c323) — tree `e337ce86` == merge tree
    - resolution: reproduces the merge tree as the oracle (manual). Carries the cross-side reconciliation no main-side replay covers — removes the NOT-elimination rule (#20394) and the regenerated settings/grammar/enum churn. Audit in the commit message.

*Next target:* #18 "Merge 1.5 → Main" (#20644, [`419073fa`](https://github.com/krlmlr/duckdb/commit/419073fa46d1)) — not yet de-merged.
