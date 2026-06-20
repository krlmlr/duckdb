#!/usr/bin/env bash
#
# Build a flat branch for a release branch whose REAL merge base with an
# already-flattened sibling is NOT on its own first-parent path, so that the
# flat branches' merge base corresponds to the real (IRL) merge base.
#
# Why this is needed: flatten-branch.sh linearizes a branch by --first-parent.
# Two independently flattened orphan branches share an identical-SHA prefix only
# as long as their first-parent sequences agree, so their flat merge base is the
# longest common first-parent prefix -- which is the real merge base ONLY when
# that merge base lies on both branches' first-parent paths. For siblings where
# the merge base was absorbed via a back-merge (a non-first-parent edge), the
# naive flat merge base lands much earlier than reality.
#
# Construction: the merge base M = `git merge-base <parent-src> <src>` must lie
# on the first-parent path of <parent-src> (so <parent-flat>, built by
# flatten-branch.sh, already contains a flat commit reproducing M). We reuse
# <parent-flat>'s history up to that flat(M) commit and append one flat commit
# per first-parent commit in M..<src>. Result:
#     git merge-base <parent-flat> <dest-branch>  ==  flat(M)
# which corresponds to the real merge base M. Fully deterministic.
#
# Usage: flatten-onto.sh <src> <dest-branch> <parent-flat> <parent-src>
#   src          release branch to flatten, e.g. origin/v1.5-variegata
#   dest-branch  branch to (re)create, e.g. v1.5-variegata-flat
#   parent-flat  already-built flat branch containing flat(M), e.g. v1.4-andium-flat
#   parent-src   source of parent-flat, e.g. origin/v1.4-andium
#
# History must be connected locally past M (deepen a shallow clone first; CI
# uses actions/checkout with fetch-depth: 0).

set -euo pipefail

SRC="${1:?source ref required}"
DST="${2:?destination branch required}"
PFLAT="${3:?parent flat branch required}"
PSRC="${4:?parent source ref required}"

UPSTREAM_URL="https://github.com/duckdb/duckdb/commit"

# Reproduce an upstream commit as a flat commit on top of $2 (parent); same
# reproduction as flatten-branch.sh (tree + scrubbed message + trailer + ident).
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

M=$(git merge-base "$PSRC" "$SRC")
echo "merge base $PSRC ∩ $SRC = $M" >&2

# M must be on the parent's first-parent path so parent-flat contains flat(M).
# (grep -c / awk read all input -- avoid -q/exit which SIGPIPE under pipefail.)
on_fp=$(git rev-list --first-parent "$PSRC" | grep -Fxc -- "$M" || true)
if [ "${on_fp:-0}" -eq 0 ]; then
	echo "ERROR: merge base $M is not on the first-parent path of $PSRC." >&2
	echo "       Swap the roles (flatten $SRC first and graft $PSRC onto it)," >&2
	echo "       or pick a trunk whose first-parent path contains the merge base." >&2
	exit 1
fi

# Locate flat(M) in parent-flat via its Upstream-commit trailer.
anchor=$(git log "$PFLAT" \
	--format='%H %(trailers:key=Upstream-commit,valueonly)' |
	awk -v m="$M" 'index($0, m) && !found { print $1; found = 1 }')
if [ -z "$anchor" ]; then
	echo "ERROR: flat($M) not found in $PFLAT (was it built with flatten-branch.sh?)." >&2
	exit 1
fi
echo "anchor flat(M) in $PFLAT = $anchor" >&2

# Append one flat commit per first-parent commit after M on the source branch.
mapfile -t commits < <(git rev-list --first-parent --reverse "$M..$SRC")
echo "Grafting ${#commits[@]} commit(s) from $SRC onto $anchor into $DST" >&2

parent="$anchor"
for c in "${commits[@]}"; do
	parent=$(flat_commit "$c" "$parent")
done

git branch -f "$DST" "$parent"
echo "$DST -> $parent" >&2
