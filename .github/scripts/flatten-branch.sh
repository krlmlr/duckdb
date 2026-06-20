#!/usr/bin/env bash
#
# Create a flat (squashed) orphan branch from a mirror of duckdb/duckdb.
#
# The source branches (v1.4-*, v1.5-*, v2.0) mirror upstream duckdb/duckdb,
# whose mainline is reachable via first-parent traversal: each first-parent
# step is one merged upstream commit. This script linearizes that history into
# an orphan branch with the following layout:
#
#   1. a deterministic empty root commit (identical across every flat branch)
#   2. a "reset to v1.0.0" commit carrying the v1.0.0 tree -- the shared base.
#      v1.0.0 is a predecessor of the common merge-base of v1.4/v1.5/v2.0, so
#      this commit (and the empty root) are shared history across all flats.
#   3. one flat commit per upstream first-parent commit, advancing from v1.0.0
#      toward the source tip.
#
# Each flat commit snapshots the merged tree and rewrites the message to the
# original message plus a link to the upstream commit. Feature-branch
# sub-commits are squashed away.
#
# Commits are reproduced deterministically (author + committer identity and
# dates are preserved; the empty root uses a fixed identity/date), so
# re-running yields identical SHAs and a no-op push when nothing changed
# upstream. Because v1.0.0 and the early first-parent commits are shared, the
# empty root, the v1.0.0 reset, and the early commits get identical SHAs across
# v1.4-andium-flat, v1.5-variegata-flat and v2.0-flat.
#
# Usage: flatten-branch.sh <source-ref> <dest-branch> [limit] [base-ref]
#   source-ref   ref to flatten, e.g. origin/v2.0
#   dest-branch  branch name to (re)create, e.g. v2.0-flat
#   limit        optional; only the FIRST N first-parent commits after the base
#                (i.e. advance N commits toward the tip; for prototypes). 0=all.
#   base-ref     optional inception commit (default: v1.0.0). Must be an
#                ancestor of source-ref and fully connected locally (a shallow
#                clone must be deepened past the base, e.g. via --shallow-since).

set -euo pipefail

SRC="${1:?source ref required}"
DST="${2:?destination branch required}"
LIMIT="${3:-0}"
BASE="${4:-1f98600c2cf8722a6d2f2d805bb4af5e701319fc}" # v1.0.0

UPSTREAM_URL="https://github.com/duckdb/duckdb/commit"
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904

# Reproduce an upstream commit as a flat commit on top of $2 (parent), reusing
# its tree, message (+ Upstream-commit trailer) and author/committer identity.
flat_commit() {
	local c="$1" parent="$2" tree message
	tree=$(git rev-parse "$c^{tree}")
	export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
	export GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE
	GIT_AUTHOR_NAME=$(git log -1 --format=%an "$c")
	GIT_AUTHOR_EMAIL=$(git log -1 --format=%ae "$c")
	GIT_AUTHOR_DATE=$(git log -1 --format=%aI "$c")
	GIT_COMMITTER_NAME=$(git log -1 --format=%cn "$c")
	GIT_COMMITTER_EMAIL=$(git log -1 --format=%ce "$c")
	GIT_COMMITTER_DATE=$(git log -1 --format=%cI "$c")
	message=$(git log -1 --format=%B "$c" |
		git interpret-trailers --trailer "Upstream-commit: $UPSTREAM_URL/$c")
	printf '%s' "$message" | git commit-tree "$tree" -p "$parent"
}

# 1. Deterministic empty root (fixed identity/date -> identical across branches).
empty_root() {
	export GIT_AUTHOR_NAME=flat GIT_AUTHOR_EMAIL=flat@localhost
	export GIT_COMMITTER_NAME=flat GIT_COMMITTER_EMAIL=flat@localhost
	export GIT_AUTHOR_DATE="1970-01-01T00:00:00 +0000"
	export GIT_COMMITTER_DATE="1970-01-01T00:00:00 +0000"
	printf 'Empty root\n' | git commit-tree "$EMPTY_TREE"
}
parent=$(empty_root)

# 2. Reset to the shared base (v1.0.0).
parent=$(flat_commit "$BASE" "$parent")

# 3. Advance first-parent commits from the base toward the source tip.
mapfile -t commits < <(git rev-list --first-parent --reverse "$BASE..$SRC")
if [ "$LIMIT" -gt 0 ] && [ "${#commits[@]}" -gt "$LIMIT" ]; then
	commits=("${commits[@]:0:$LIMIT}")
fi

echo "Flattening empty root + v1.0.0 + ${#commits[@]} commit(s) from $SRC into $DST" >&2

for c in "${commits[@]}"; do
	parent=$(flat_commit "$c" "$parent")
done

git branch -f "$DST" "$parent"
echo "$DST -> $parent" >&2
