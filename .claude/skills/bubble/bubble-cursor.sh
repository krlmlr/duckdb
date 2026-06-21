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
# Usage: bubble-cursor.sh <release-ref> <main-ref> [prev-release-ref] [branch]
#   release-ref       the release line, e.g. origin/v1.5-variegata
#   main-ref          the upstream-main mirror tracked, e.g. origin/main
#   prev-release-ref  the immediately-OLDER release whose back-merges to EXCLUDE
#                     (e.g. origin/v1.4-andium for the v1.5 spine). Empty for a
#                     base release with no predecessor.
#   branch            perpetual branch (default main-<release-basename>)
#
# A "release back-merge" is a first-parent merge on <main> whose SECOND parent is
# on <release> but NOT on <prev-release> — it pulls THIS release line (not an
# older one it descends from) into main. The predecessor exclusion is required:
# <release> back-merges <prev-release>, so every prev→main merge's second parent
# is also an ancestor of <release> and would be swept in otherwise (e.g. v1.4→main
# merges polluting the v1.5 spine). These, oldest-first, are the bubble steps;
# the branch's de-merge frontier is how many it has linearised away (it carries
# fewer than main), and the next step is the oldest still present.

set -uo pipefail
REL="${1:?release ref required}"
MAIN="${2:?main ref required}"
PREV="${3:-}"
BR="${4:-main-$(basename "$REL")}"

relmerges() { # oldest-first back-merges of REL (excluding the predecessor line) on $1's first-parent
	git rev-list --reverse --first-parent --merges "$1" 2>/dev/null | while read -r m; do
		git merge-base --is-ancestor "${m}^2" "$REL" 2>/dev/null || continue           # 2nd parent on the release line
		[ -n "$PREV" ] && git merge-base --is-ancestor "${m}^2" "$PREV" 2>/dev/null && continue  # but not the predecessor's
		echo "$m"
	done
}

mapfile -t MAIN_BM < <(relmerges "$MAIN")
if git rev-parse -q --verify "$BR" >/dev/null 2>&1; then
	mapfile -t BR_BM < <(relmerges "$BR"); EXISTS=yes
else
	BR_BM=("${MAIN_BM[@]}"); EXISTS=no
fi

echo "BRANCH=$BR"; echo "MAIN=$MAIN"; echo "RELEASE=$REL"; echo "PREV_RELEASE=${PREV:-<none>}"; echo "EXISTS=$EXISTS"
echo "MAIN_TREE=$(git rev-parse "${MAIN}^{tree}")"
echo "RELEASE_BACKMERGES_ON_MAIN=${#MAIN_BM[@]}"
echo "RELEASE_BACKMERGES_REMAINING=${#BR_BM[@]}"
DEMERGED=$(( ${#MAIN_BM[@]} - ${#BR_BM[@]} ))
echo "DEMERGED_SO_FAR=$DEMERGED"
# Snapshot/gate branch for THIS run: the pre-de-merge state, named by de-merges
# already applied (0-padded). A create-only push to it backs up the state that
# force-push will overwrite AND atomically claims the run (an existing ref means
# another run already holds this step — abort to avoid concurrent runs).
printf 'GATE_BRANCH=%s-%02d\n' "$BR" "$DEMERGED"

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
