#!/usr/bin/env bash
#
# Cursor / work-list for a "-linear" vendored branch (see the build-linear-branch
# skill). A linear branch v<DEV>-v<TAG>-linear replays, in order and test-gated,
# the dev-specific commits of a "-flat" branch on top of the flat commit that
# corresponds to a release tag. Its state lives entirely in git history: the tip
# of origin/<TARGET> is the last green commit, and every linear commit keeps the
# source flat commit's "Upstream-commit" trailer, so a fresh agent resumes by
# reading the tip.
#
# Usage:
#   linear-todo.sh env  <release-tag> [dev]   # eval-able BASE=/TARGET=/... lines
#   linear-todo.sh list <release-tag> [dev]   # remaining source flat SHAs, oldest-first
#
#   <release-tag>  upstream release tag whose flat commit is the base, e.g. v1.5.4
#   <dev>          dev line to linearize (default: v2.0); its flat branch is <dev>-flat
#
# Env: DEV (alternative to the positional dev arg).

set -euo pipefail

UPSTREAM_COMMIT_PREFIX="https://github.com/duckdb/duckdb/commit/"

retry_fetch() {
	local i
	for i in 1 2 3 4; do
		git fetch "$@" && return 0
		sleep $((2 ** i))
	done
	git fetch "$@"
}

# The upstream commit a flat/linear commit reproduces (its Upstream-commit trailer).
upstream_of() {
	git log -1 "$1" --format='%(trailers:key=Upstream-commit,valueonly)' |
		sed -E "s#.*/commit/##; s/[[:space:]]*\$//"
}

MODE="${1:?usage: linear-todo.sh env|list <release-tag> [dev]}"
TAG="${2:?missing <release-tag>}"
DEV="${3:-${DEV:-v2.0}}"
DEV_FLAT="${DEV}-flat"
TARGET="${DEV}-${TAG}-linear"

# Refresh the refs we depend on (best-effort; later lookups fail loudly if absent).
retry_fetch origin --tags "$DEV_FLAT" "$TARGET" >/dev/null 2>&1 || true
retry_fetch origin "refs/tags/${TAG}:refs/tags/${TAG}" >/dev/null 2>&1 || true

TAG_UP=$(git rev-list -1 "refs/tags/${TAG}" 2>/dev/null || true)
[ -n "$TAG_UP" ] || { echo "ERROR: tag $TAG not found on origin." >&2; exit 1; }

# Release flat branch = the v<MAJOR>.<MINOR>(-*)?-flat branch whose history holds
# the flat commit for TAG_UP. Search every matching candidate and pick BASE.
MINOR=$(printf '%s' "$TAG" | grep -oE '^v[0-9]+\.[0-9]+')
mapfile -t CANDS < <(
	git ls-remote --heads origin "refs/heads/${MINOR}-flat" "refs/heads/${MINOR}-*-flat" 2>/dev/null |
		sed -E 's#.*refs/heads/##'
)
RELEASE_FLAT=""; BASE=""
for c in "${CANDS[@]}"; do
	retry_fetch origin "$c" >/dev/null 2>&1 || true
	b=$(git log "origin/$c" --format='%H' \
		--grep="Upstream-commit: ${UPSTREAM_COMMIT_PREFIX}${TAG_UP}" -1 2>/dev/null || true)
	if [ -n "$b" ]; then RELEASE_FLAT="$c"; BASE="$b"; break; fi
done
[ -n "$BASE" ] || {
	echo "ERROR: no ${MINOR}*-flat branch contains a flat commit for tag $TAG ($TAG_UP)." >&2
	exit 1
}

git rev-parse --verify -q "refs/remotes/origin/$DEV_FLAT" >/dev/null || {
	echo "ERROR: source origin/$DEV_FLAT not found (create it with the add-flat-branch skill)." >&2
	exit 1
}

# Dev-specific work = flat commits reachable from <dev>-flat but not from BASE,
# oldest-first. The shared prefix (up to the flat merge base) is already in BASE.
mapfile -t ALL < <(git rev-list --reverse "$BASE..origin/$DEV_FLAT")

# Resume: drop everything up to and including the source already at the target tip.
REMAINING=("${ALL[@]}")
TIP=""; DONE=0
if git rev-parse --verify -q "refs/remotes/origin/$TARGET" >/dev/null; then
	TIP=$(git rev-parse "origin/$TARGET")
	tip_up=$(upstream_of "$TIP")
	if [ -n "$tip_up" ]; then
		REMAINING=(); seen=0
		for c in "${ALL[@]}"; do
			if [ "$seen" = 1 ]; then REMAINING+=("$c"); continue; fi
			[ "$(upstream_of "$c")" = "$tip_up" ] && { seen=1; }
		done
		[ "$seen" = 1 ] || {
			echo "ERROR: target tip's Upstream-commit ($tip_up) is not in $BASE..$DEV_FLAT;" >&2
			echo "       source history diverged -- rebuild from a clean base instead." >&2
			exit 1
		}
		DONE=$(( ${#ALL[@]} - ${#REMAINING[@]} ))
	fi
fi

case "$MODE" in
env)
	cat <<-EOF
		DEV=$DEV
		DEV_FLAT=$DEV_FLAT
		RELEASE_FLAT=$RELEASE_FLAT
		RELEASE_TAG=$TAG
		BASE=$BASE
		TARGET=$TARGET
		TARGET_TIP=${TIP:-$BASE}
		DONE=$DONE
		REMAINING=${#REMAINING[@]}
		TOTAL=${#ALL[@]}
	EOF
	;;
list)
	printf '%s\n' "${REMAINING[@]}"
	;;
*)
	echo "ERROR: unknown mode '$MODE' (use env|list)." >&2
	exit 2
	;;
esac
