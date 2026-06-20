#!/usr/bin/env bash
#
# Incrementally replay existing "-flat" branches: append only the NEW upstream
# first-parent commits on top of each flat branch's current tip. The flatten is
# deterministic, so this yields exactly what a full rebuild would and pushes as
# a fast-forward -- it is just cheap and append-only.
#
# This is the routine path for keeping existing flat branches current. For
# genuinely NEW branches use the add-flat-branch skill (flatten-branch.sh /
# flatten-onto.sh) instead -- this script never creates a branch or re-grafts.
#
# Usage: replay-flat-branches.sh [<flat-branch> ...]
#   With no args, replays every "<name>-flat" branch found on origin.
#   Each "<name>-flat" is replayed from its source branch origin/<name>.
#
# Env:
#   DRY_RUN=1   build and verify locally, but do not push.

set -euo pipefail

UPSTREAM_URL="https://github.com/duckdb/duckdb/commit"

retry_fetch() {
	local i
	for i in 1 2 3 4; do
		git fetch "$@" && return 0
		sleep $((2 ** i))
	done
	git fetch "$@"
}

# Reproduce one upstream commit as a flat commit on top of $2 (parent); same
# reproduction as flatten-branch.sh / flatten-onto.sh.
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

on_first_parent() { # <src> <commit> -> 0 if on origin/<src> first-parent path
	[ "$(git rev-list --first-parent "origin/$1" | grep -Fxc -- "$2" || true)" -eq 1 ]
}

# Ensure <last> is reachable on origin/<src>'s first-parent path, deepening a
# shallow clone if needed.
ensure_reachable() {
	local src="$1" last="$2" t
	on_first_parent "$src" "$last" && return 0
	[ "$(git rev-parse --is-shallow-repository)" = "true" ] || return 1
	for t in 1 2 3; do
		retry_fetch --deepen=$((t * 3000)) origin "$src" >/dev/null 2>&1 || true
		on_first_parent "$src" "$last" && return 0
	done
	return 1
}

if [ "$#" -gt 0 ]; then
	flats=("$@")
else
	mapfile -t flats < <(
		git ls-remote --heads origin | sed -E 's#.*refs/heads/##' | grep -E -- '-flat$'
	)
fi

if [ "${#flats[@]}" -eq 0 ]; then
	echo "No -flat branches to replay." >&2
	exit 0
fi

rc=0
for flat in "${flats[@]}"; do
	src="${flat%-flat}"
	echo "== $flat  (source: origin/$src) ==" >&2

	retry_fetch origin "$src" "$flat" >/dev/null 2>&1 || true
	if ! git rev-parse --verify -q "refs/remotes/origin/$flat" >/dev/null; then
		echo "  ERROR: origin/$flat not found (use the skill to create it first)." >&2
		rc=1
		continue
	fi
	if ! git rev-parse --verify -q "refs/remotes/origin/$src" >/dev/null; then
		echo "  ERROR: source origin/$src not found." >&2
		rc=1
		continue
	fi

	tip=$(git rev-parse "origin/$flat")

	# Last upstream commit already flattened = the tip's Upstream-commit trailer.
	last=$(git log -1 "$tip" --format='%(trailers:key=Upstream-commit,valueonly)' |
		sed -E 's#.*/commit/##; s/[[:space:]]*$//')
	if [ -z "$last" ]; then
		echo "  ERROR: tip $tip has no Upstream-commit trailer; cannot replay." >&2
		rc=1
		continue
	fi

	# Append-only safety: refuse to replay if upstream history was rewritten.
	if ! ensure_reachable "$src" "$last"; then
		echo "  ERROR: last flattened commit $last is not on origin/$src's" >&2
		echo "         first-parent path (history diverged). Rebuild via the" >&2
		echo "         add-flat-branch skill instead of replaying." >&2
		rc=1
		continue
	fi

	mapfile -t new < <(git rev-list --first-parent --reverse "$last..origin/$src")
	if [ "${#new[@]}" -eq 0 ]; then
		echo "  up to date (no new commits)." >&2
		continue
	fi
	echo "  appending ${#new[@]} new commit(s) on top of $tip" >&2

	parent="$tip"
	for c in "${new[@]}"; do
		parent=$(flat_commit "$c" "$parent")
	done

	# The replayed tip must be a faithful snapshot of the source tip.
	if [ "$(git rev-parse "$parent^{tree}")" != "$(git rev-parse "origin/$src^{tree}")" ]; then
		echo "  ERROR: replayed tip tree != origin/$src tree; leaving $flat unchanged." >&2
		rc=1
		continue
	fi

	git branch -f "$flat" "$parent"
	echo "  $flat -> $parent" >&2

	if [ "${DRY_RUN:-0}" = "1" ]; then
		echo "  DRY_RUN: not pushing." >&2
		continue
	fi

	# Fast-forward push (no force): a rewritten flat branch should fail loudly.
	pushed=
	for i in 1 2 3 4; do
		git push origin "refs/heads/$flat:refs/heads/$flat" && {
			pushed=1
			break
		}
		sleep $((2 ** i))
	done
	[ -n "$pushed" ] || {
		echo "  ERROR: push failed for $flat." >&2
		rc=1
	}
done

exit "$rc"
