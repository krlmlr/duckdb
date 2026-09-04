# Glossary

Terms for the flat/`-dag` mirror-branch process and for vendoring the DuckDB
core into the `duckdb-r` package.

## A. Git & history foundations
*(the primitives both processes are built on)*

- **First parent** — A merge commit's first listed parent: the branch you were *on* when you merged. `git log --first-parent` walks only this line, giving the "mainline" of a branch. Diffs (`git show`, `^1`) are computed against the first parent.
- **Merge commit / second parent** — A commit with ≥2 parents. The non-first parents are the branches *merged in*. Cross-branch merges (e.g. "Merge v1.4 into v1.5") record the integrated branch as the second parent.
- **Merge base** — The best common ancestor of two commits (`git merge-base A B`); the point their histories diverged. Determines what a 3-way merge/diff considers "shared."
- **Orphan / root commit** — A commit with no parents. An *orphan branch* starts a fresh history disconnected from existing ones.
- **Graft** — Re-attaching a sequence of commits onto a different base, re-creating them with new parents (and thus new SHAs).
- **Fast-forward** — A push/merge where the new tip is a direct descendant of the old tip; no new merge needed. Append-only updates fast-forward.
- **Topological order / `--reverse`** — Ordering commits so parents precede children. `--reverse` emits oldest-first, the order needed to rebuild history.
- **Ancestry path** (`--ancestry-path`) — Restricts a revision range to commits actually *on a path* between two endpoints.
- **commit-graph** — A git cache (`git commit-graph write`) that makes ancestry/merge-base queries near-instant; essential when running thousands of `merge-base` calls.
- **Squash** — Collapsing multiple commits (or a merge's side branch) into a single linear commit, discarding the branching structure.

## B. Flat / DAG mirror-branch process
*(deterministic per-commit mirrors of upstream release branches)*

- **Mirror branch** — A generated branch that re-creates upstream history one commit at a time, never authored by hand. The `-flat` and `-dag` families are mirrors.
- **`-flat` branch** — A **linear** (squashed-merge) mirror: cross-branch merges are flattened away, leaving one first-parent chain. E.g. `v2.0-flat`.
- **`-dag` branch** — A **merge-DAG** mirror: identical first-parent chain as `-flat`, but each cross-branch merge is replayed as a real two-parent commit. E.g. `v2.0-dag`. Gives faithful diffs **and** the true merge base.
- **Flatten / reproduction (flat commit)** — Re-creating one upstream commit on a new base via `git commit-tree`: same tree, author/committer, date, and message, but new parent(s) → new SHA.
- **`Upstream-commit` trailer** — A trailer appended to every reproduced commit's message (`Upstream-commit: …/commit/<sha>`) recording which upstream commit it mirrors. The link back to upstream and the key used to map/resume.
- **Inception** — The deterministic shared start of every flat/dag branch: an empty root commit + a reset to the `v1.0.0` tree. Makes all branches share history.
- **Anchor / first-parent divergence** — The deepest commit on a sibling's first-parent path that is already reproduced in the parent mirror; the point where a younger branch is grafted on.
- **Trunk / sibling / older branch** — The release lineage: `v1.4-andium` (trunk) → `v1.5-variegata` → `v2.0`. Each younger branch grafts onto the *older* one.
- **Merge link** — In a `-dag` branch, the second parent added to a reproduced cross-branch merge, pointing at the corresponding flat commit in the older branch's dag.
- **Merge-base recovery** — Resolving which older commit a merge integrated when the literal second parent isn't an older-branch tip: `git merge-base <second-parent> <older-source>`. Handles merges recorded via an intermediate **"merge fixes" commit**.
- **"Merge fixes" commit** — An intermediate commit between a cross-branch merge and the older tip (the merge wasn't clean); requires merge-base recovery to find the real integrated commit.
- **Bidirectional cross-merge** — When two release branches merge *each other* over time (v1.4 ↔ v1.5). Breaks naïve `merge-base(commit, older)` detection (it lands on the wrong branch) — the reason detection must inspect the *second parent*.
- **"Introduces new older history" guard** — The rule that a merge is only linked if the integrated older commit is **not already an ancestor of the first parent**. Excludes ordinary feature-PR merges and bidirectional-merge noise.
- **Faithful diff / bogus diff** — A reproduced commit is *faithful* if its changed-file set equals the upstream commit's. A *bogus diff* (huge flat diff vs small upstream diff) signals the anchor landed off the first-parent path.
- **Deterministic reproduction** — Because every input (tree, metadata, parents) is fixed, re-running produces identical SHAs — so a full rebuild and an incremental append agree and push as a fast-forward.
- **Incremental replay** — Appending only the *new* upstream first-parent commits onto an existing mirror tip (vs. a full rebuild), re-linking any new merges. Cheap, append-only, fast-forward.
- **Scripts** — `flatten-branch.sh` (trunk), `flatten-onto.sh` (sibling, linear), `flatten-dag-onto.sh` (sibling, merge-DAG), `replay-flat-branches.sh` / `replay-dag-branches.sh` (incremental refresh).
- **PR redirect rewrite** — During reproduction, `#NNN` references are rewritten to `https://redirect.github.com/duckdb/duckdb/pull/NNN` so they don't create cross-repo backreferences.

## C. Vendoring the DuckDB core into the R package (`duckdb-r`)

- **Vendoring** — Copying a complete snapshot of upstream DuckDB C++ into the R package (`src/duckdb/`) so the package builds self-contained, with no external libduckdb dependency.
- **Upstream** — The `duckdb/duckdb` C++ repo; the source of vendored code (same release branches the mirrors track: `main`/`v2.0`, `v1.5-variegata`, `v1.4-andium`).
- **`src/duckdb/`** — The vendored tree (~1700 `.cpp` + ~1400 headers): `src/`, `third_party/`, and `extension/`.
- **`third_party/`** — Bundled upstream dependencies vendored alongside the core (brotli, fmt, libpg_query, zstd, re2, utf8proc, yyjson, parquet/thrift, …).
- **Amalgamation / unity build** — Grouping many `.cpp` files into combined `ub_*.cpp` translation units to cut compile time (~20 files per unit, `DUCKDB_BUILD_UNITY`). Produced by upstream's `package_build.py`.
- **Patch stack (`patch/`)** — Ordered `NNNN-*.patch` files re-applied on every vendor run to make the core CRAN-/platform-compliant (e.g. remove `exit()` in Brotli, silence uninitialized-member warnings). Patches that no longer apply are dropped.
- **`rconfigure.py`** — The vendoring configurator: selects linked extensions, extracts the version, normalizes file newlines, and drives `package_build.py` to generate the source list.
- **Vendor commit** — A generated commit with message `vendor: Update vendored sources to duckdb/duckdb@<sha>`, embedding the upstream SHA (the vendoring analogue of the `Upstream-commit:` trailer).
- **`vendor.sh` / `vendor-one.sh`** — Manual single-pass vendor, and the CI per-commit vendor (`--commits N`) that walks new upstream commits one at a time.
- **Static extension linking** — `parquet` and `core_functions` are compiled directly into the package (not dynamically loadable); they are part of the vendored core.
- **`DUCKDB_SOURCE_ID`** — The upstream commit identifier embedded in the built library; identifies exactly which core snapshot was vendored.
- **`duckdb_version` (`R/version.R`)** — The vendored DuckDB version, extracted from `pragma_version.cpp` during vendoring.

---

**Relationship between the two processes:** both are *commit-by-commit mirrors of the same upstream release branches*, each tagging every generated commit with the upstream SHA (the `Upstream-commit:` trailer in the flat/`-dag` branches; the `vendor: …@<sha>` message in `duckdb-r`). The `-flat`/`-dag` branches give a clean, navigable git view of upstream history; vendoring produces the buildable R-package snapshots. They run in parallel rather than one feeding the other.
