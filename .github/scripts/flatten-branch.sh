#!/usr/bin/env bash
#
# Create a flat (squashed) orphan branch from a mirror of duckdb/duckdb.
#
# The source branches (v1.4-*, v1.5-*, v2.0) mirror upstream duckdb/duckdb,
# whose mainline is reachable via first-parent traversal: each first-parent
# step is one merged upstream commit. This script linearizes that first-parent
# history into an orphan branch, snapshotting the merged tree at each step and
# rewriting the message to the original message plus a link to the upstream
# commit. Feature-branch sub-commits are squashed away.
#
# Commits are reproduced deterministically (author + committer identity and
# dates are preserved), so re-running yields identical SHAs and a no-op push
# when nothing changed upstream.
#
# Usage: flatten-branch.sh <source-ref> <dest-branch> [limit]
#   source-ref   ref to flatten, e.g. origin/v2.0
#   dest-branch  branch name to (re)create, e.g. v2.0-flat
#   limit        optional; only the newest N first-parent commits (for prototypes)

set -euo pipefail

SRC="${1:?source ref required}"
DST="${2:?destination branch required}"
LIMIT="${3:-0}"

UPSTREAM_URL="https://github.com/duckdb/duckdb/commit"

# First-parent mainline, oldest -> newest.
mapfile -t commits < <(git rev-list --first-parent --reverse "$SRC")

if [ "$LIMIT" -gt 0 ] && [ "${#commits[@]}" -gt "$LIMIT" ]; then
	commits=("${commits[@]: -$LIMIT}")
fi

echo "Flattening ${#commits[@]} commit(s) from $SRC into $DST" >&2

parent=""
for c in "${commits[@]}"; do
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

	if [ -z "$parent" ]; then
		parent=$(printf '%s' "$message" | git commit-tree "$tree")
	else
		parent=$(printf '%s' "$message" | git commit-tree "$tree" -p "$parent")
	fi
done

git branch -f "$DST" "$parent"
echo "$DST -> $parent" >&2
