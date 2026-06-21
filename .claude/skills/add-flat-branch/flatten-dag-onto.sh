#!/usr/bin/env bash
#
# Build a merge-DAG flat branch: like flatten-onto.sh, but cross-branch merges
# are replayed as real two-parent commits instead of being squashed.
#
# As with flatten-onto.sh, the sibling is grafted onto the parent flat branch at
# the first-parent divergence and its remaining first-parent commits are
# appended (first parent = the linear chain, so trees and first-parent diffs
# stay faithful to upstream). ADDITIONALLY, whenever an appended commit
# integrates new history from the older branch (a "Merge <older> into <current>"
# commit), a SECOND parent is added pointing at the corresponding flat commit in
# the parent (older) flat branch.
#
# The corresponding older commit is found by merge-base recovery:
#   A = git merge-base <appended-commit> <older-source>
# i.e. the latest older-branch commit the merge integrated. This handles both
# clean merges (A is the merged older tip) and merges recorded via an
# intermediate "merge fixes" commit (A is still recovered correctly). The flat
# reproduction of A in the parent flat branch becomes the second parent.
#
# Usage: flatten-dag-onto.sh <src> <dest-branch> <parent-flat> <older-source>
#   src           sibling branch to flatten, e.g. origin/v1.5-variegata
#   dest-branch   branch to (re)create, e.g. v1.5-variegata-dag
#   parent-flat   older branch's flat/dag branch to graft and link onto,
#                 e.g. v1.4-andium-dag
#   older-source  the older branch's source ref, e.g. origin/v1.4-andium
#
# History must be connected locally along src's first-parent path down to the
# anchor (deepen a shallow clone first; CI uses fetch-depth: 0).

set -euo pipefail

SRC="${1:?source ref required}"
DST="${2:?destination branch required}"
PFLAT="${3:?parent flat branch required}"
OLDER="${4:?older source ref required}"

UPSTREAM_URL="https://github.com/duckdb/duckdb/commit"

# Reproduce one upstream commit as a flat commit; $1 = upstream commit, the rest
# are parents (first = linear chain parent, others = merge second parents).
flat_commit() {
	local c="$1"
	shift
	local tree message
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
	local pargs=()
	local p
	for p in "$@"; do pargs+=(-p "$p"); done
	printf '%s' "$message" | git commit-tree "$tree" "${pargs[@]}"
}

# Speed up the many merge-base queries below.
git commit-graph write --reachable >/dev/null 2>&1 || true

# Map upstream-commit -> flat-commit for the parent flat branch.
declare -A flatmap
while read -r fsha url; do
	[ -n "$url" ] || continue
	up="${url##*/commit/}"
	[ "$up" != "$url" ] && flatmap["$up"]="$fsha"
done < <(git log "$PFLAT" --format='%H %(trailers:key=Upstream-commit,valueonly)')

# Anchor = deepest commit on src's first-parent path also reproduced in PFLAT
# (the first-parent divergence). awk reads all input (no early exit) -> no
# SIGPIPE under pipefail; src's first-parent log is newest-first.
keys=$(mktemp)
trap 'rm -f "$keys"' EXIT
printf '%s\n' "${!flatmap[@]}" >"$keys"
anchor_up=$(git rev-list --first-parent "$SRC" |
	awk 'NR==FNR { s[$1]; next } (!found && ($1 in s)) { print $1; found = 1 }' "$keys" -)
if [ -z "$anchor_up" ]; then
	echo "ERROR: no common first-parent commit between $SRC and $PFLAT." >&2
	exit 1
fi
anchor="${flatmap[$anchor_up]}"
echo "anchor (first-parent divergence) = $anchor_up -> $anchor" >&2

mapfile -t commits < <(git rev-list --first-parent --reverse "$anchor_up..$SRC")
echo "Grafting ${#commits[@]} commit(s) from $SRC onto $anchor into $DST" >&2

# For each appended commit, inspect its non-first parents. A "merge <older> into
# <current>" integrates an older-branch commit via a non-first parent. Identify
# that older commit and add it (its flat reproduction) as a second parent.
#   - if the non-first parent is itself reproduced in the older flat (a clean
#     merge of the older tip), use it directly;
#   - otherwise recover it as merge-base(non-first-parent, older) (handles merges
#     recorded via an intermediate "merge fixes" commit).
# Bidirectional cross-merges make this ambiguous unless we require the recovered
# commit to introduce NEW older history -- i.e. it must NOT already be an
# ancestor of the first parent. That guard also excludes ordinary feature-PR
# merges (whose base is already integrated).
links=0
parent="$anchor"
for c in "${commits[@]}"; do
	extra=()
	read -r _ p1 rest < <(git rev-list --parents -1 "$c")
	for pk in $rest; do
		if [ -n "${flatmap[$pk]:-}" ]; then
			cand="$pk"
		else
			cand=$(git merge-base "$pk" "$OLDER" 2>/dev/null || true)
			cand="${cand%%$'\n'*}"
		fi
		[ -n "$cand" ] && [ -n "${flatmap[$cand]:-}" ] || continue
		git merge-base --is-ancestor "$cand" "$p1" && continue # already integrated
		extra+=("${flatmap[$cand]}")
		links=$((links + 1))
	done
	parent=$(flat_commit "$c" "$parent" "${extra[@]}")
done

git branch -f "$DST" "$parent"
echo "$DST -> $parent  ($links merge link(s) into $PFLAT)" >&2
