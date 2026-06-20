#!/usr/bin/env bash
#
# Build a flat branch for a sibling release branch by grafting it onto an
# already-built flat branch, keeping per-commit diffs faithful to upstream.
#
# flatten-branch.sh linearizes by --first-parent. A sibling shares the common
# first-parent trunk with the parent branch up to the point where their
# first-parent lines diverge. We graft the sibling onto the parent flat branch
# at that divergence -- the DEEPEST commit on the sibling's own first-parent
# path that is also reproduced in the parent flat branch -- and then append the
# sibling's remaining first-parent commits. Because the anchor is on the
# sibling's first-parent path, every appended commit is parented on the flat
# reproduction of its REAL first-parent, so each flat commit's diff matches the
# upstream commit's diff exactly.
#
# IMPORTANT: the anchor is the first-parent divergence, NOT `git merge-base`.
# When a real merge base was absorbed via a back-merge it sits off the
# first-parent path; grafting there parents the first appended commit on the
# wrong tree and produces a huge bogus diff. The resulting flat merge base is
# therefore the first-parent divergence point, which is what makes the diffs
# faithful.
#
# Usage: flatten-onto.sh <src> <dest-branch> <parent-flat>
#   src          sibling branch to flatten, e.g. origin/v1.5-variegata
#   dest-branch  branch to (re)create, e.g. v1.5-variegata-flat
#   parent-flat  already-built flat branch to graft onto, e.g. v1.4-andium-flat
#
# History must be connected locally along src's first-parent path down to the
# anchor (deepen a shallow clone first; CI uses fetch-depth: 0).

set -euo pipefail

SRC="${1:?source ref required}"
DST="${2:?destination branch required}"
PFLAT="${3:?parent flat branch required}"

UPSTREAM_URL="https://github.com/duckdb/duckdb/commit"

# Reproduce one upstream commit as a flat commit on top of $2 (parent); same
# reproduction as flatten-branch.sh.
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
		sed -r 's%#([0-9]+)%https://redirect.github.com/duckdb/duckdb/pull/\1%g' |
		git interpret-trailers --trailer "Upstream-commit: $UPSTREAM_URL/$c")
	printf '%s' "$message" | git commit-tree "$tree" -p "$parent"
}

# Upstream commits reproduced in the parent flat branch.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
git log "$PFLAT" --format='%(trailers:key=Upstream-commit,valueonly)' |
	sed -E 's#.*/commit/##; /^$/d' | sort -u >"$tmp"

# Anchor = deepest commit on src's first-parent path that is also reproduced in
# the parent flat branch (the first-parent divergence point). awk reads all
# input (no early exit) to avoid SIGPIPE under pipefail; src's first-parent log
# is newest-first, so the first match is the deepest.
anchor_up=$(git rev-list --first-parent "$SRC" |
	awk 'NR==FNR { s[$1]; next } (!found && ($1 in s)) { print $1; found = 1 }' "$tmp" -)
if [ -z "$anchor_up" ]; then
	echo "ERROR: no common first-parent commit between $SRC and $PFLAT." >&2
	exit 1
fi
echo "anchor (first-parent divergence) = $anchor_up" >&2

# flat(anchor_up) in the parent flat branch.
anchor=$(git log "$PFLAT" \
	--format='%H %(trailers:key=Upstream-commit,valueonly)' |
	awk -v m="$anchor_up" 'index($0, m) && !f { print $1; f = 1 }')
if [ -z "$anchor" ]; then
	echo "ERROR: flat($anchor_up) not found in $PFLAT." >&2
	exit 1
fi
echo "anchor flat commit in $PFLAT = $anchor" >&2

mapfile -t commits < <(git rev-list --first-parent --reverse "$anchor_up..$SRC")
echo "Grafting ${#commits[@]} commit(s) from $SRC onto $anchor into $DST" >&2

parent="$anchor"
for c in "${commits[@]}"; do
	parent=$(flat_commit "$c" "$parent")
done

git branch -f "$DST" "$parent"
echo "$DST -> $parent" >&2
