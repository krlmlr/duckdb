#!/usr/bin/env bash
#
# bubble-cursor.sh — resume cursor for a `main-<release>` bubble branch.
#
# The bubble branch mirrors `main`'s TREE exactly while progressively
# de-merging the release branch's back-merges: each run advances the
# bifurcation one back-merge ahead (onto that merge's second parent). This
# script enumerates the release back-merges (the ordered bubble steps) and
# reports the next one plus the deterministic checkpoints that validate it.
# It computes only — it never writes refs.
#
# Usage: bubble-cursor.sh <release-ref> <main-ref> [branch]
#   release-ref  the release line, e.g. origin/v1.5-variegata
#   main-ref     the upstream-main mirror the branch tracks, e.g. origin/main
#   branch       perpetual branch (default main-<release-basename>)
#
# A "release back-merge" is a first-parent merge on <main> whose SECOND parent
# is an ancestor of <release> (i.e. it pulls the release line into main). These,
# oldest-first, are the bubble steps. The branch's de-merge frontier = the
# count of release back-merges it has already linearised away (it carries fewer
# than main); the next step is the oldest release back-merge still present.

set -uo pipefail
REL="${1:?release ref required}"
MAIN="${2:?main ref required}"
BR="${3:-main-$(basename "$REL")}"

relmerges() { # ordered oldest-first release back-merges on $1's first-parent line
	git rev-list --reverse --first-parent --merges "$1" 2>/dev/null | while read -r m; do
		git merge-base --is-ancestor "${m}^2" "$REL" 2>/dev/null && echo "$m"
	done
}

mapfile -t MAIN_BM < <(relmerges "$MAIN")
if git rev-parse -q --verify "$BR" >/dev/null 2>&1; then
	mapfile -t BR_BM < <(relmerges "$BR"); EXISTS=yes
else
	BR_BM=("${MAIN_BM[@]}"); EXISTS=no
fi

echo "BRANCH=$BR"; echo "MAIN=$MAIN"; echo "RELEASE=$REL"; echo "EXISTS=$EXISTS"
echo "MAIN_TREE=$(git rev-parse "${MAIN}^{tree}")"
echo "RELEASE_BACKMERGES_ON_MAIN=${#MAIN_BM[@]}"
echo "RELEASE_BACKMERGES_REMAINING=${#BR_BM[@]}"
echo "DEMERGED_SO_FAR=$(( ${#MAIN_BM[@]} - ${#BR_BM[@]} ))"

NEXT="${BR_BM[0]:-}"
if [ -n "$NEXT" ]; then
	# segment lower bound = the previous release back-merge (one below NEXT), else
	# main's merge-base with the release (the original shared fork).
	idx=$(( ${#MAIN_BM[@]} - ${#BR_BM[@]} ))           # 0-based index of NEXT in MAIN_BM
	if [ "$idx" -gt 0 ]; then PREV="${MAIN_BM[$((idx-1))]}"; else PREV=$(git merge-base "$MAIN" "$REL"); fi
	echo "NEXT_MERGE=$NEXT"
	echo "NEXT_P1=$(git rev-parse "${NEXT}^1")"          # main tip just below the merge
	echo "NEXT_P2=$(git rev-parse "${NEXT}^2")"          # release side = the NEW bifurcation
	echo "MERGE_TREE=$(git rev-parse "${NEXT}^{tree}")"  # checkpoint: de-merge must reproduce this
	echo "SEGMENT_FROM=$PREV"
	echo "SEGMENT_LEN=$(git rev-list --count --first-parent "${PREV}..${NEXT}^1" 2>/dev/null)"
else
	echo "NEXT_MERGE="
	echo "STATUS=fully-bubbled (no release back-merge remains on the branch)"
fi
