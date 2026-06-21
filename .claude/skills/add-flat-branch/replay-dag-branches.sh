#!/usr/bin/env bash
#
# Incrementally replay existing "-dag" branches: append only the NEW upstream
# first-parent commits on top of each dag branch's current tip, re-linking
# cross-branch merges to the older branch's dag (see flatten-dag-onto.sh). The
# reproduction is deterministic, so this yields exactly what a full rebuild would
# and pushes as a fast-forward -- it is just cheap and append-only.
#
# This is the routine path for keeping existing dag branches current. For
# genuinely NEW branches use the add-flat-branch skill (flatten-dag-onto.sh)
# instead -- this script never creates a branch or re-grafts.
#
# Branches are processed oldest-first: a younger branch links its merges into the
# older branch's dag, so the older one must be replayed first. Each branch's
# older dag is auto-detected from its existing merge links (the second parent of
# a merge resolves onto exactly one other dag branch's first-parent path).
#
# Usage: replay-dag-branches.sh [<dag-branch> ...]
#   With no args, replays every "<name>-dag" branch found on origin.
#   Each "<name>-dag" is replayed from its source branch origin/<name>.
#
# Env:
#   DRY_RUN=1    build and verify locally, but do not push.
#   NO_FETCH=1   skip all fetching; use the remote-tracking refs as-is (offline).

set -euo pipefail

UPSTREAM_URL="https://github.com/duckdb/duckdb/commit"

retry_fetch() {
	[ "${NO_FETCH:-0}" = "1" ] && return 0
	local i
	for i in 1 2 3 4; do
		git fetch "$@" && return 0
		sleep $((2 ** i))
	done
	git fetch "$@"
}

# Reproduce one upstream commit as a flat commit; $1 = upstream commit, $2 = the
# linear chain parent, remaining args = merge second parents.
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
	local pargs=() p
	for p in "$@"; do pargs+=(-p "$p"); done
	printf '%s' "$message" | git commit-tree "$tree" "${pargs[@]}"
}

on_first_parent() { # <ref> <commit> -> 0 if <commit> on <ref> first-parent path
	[ "$(git rev-list --first-parent "$1" | grep -Fxc -- "$2" || true)" -ge 1 ]
}

# Ensure <last> is reachable on origin/<src>'s first-parent path, deepening a
# shallow clone if needed.
ensure_reachable() {
	local src="$1" last="$2" t
	on_first_parent "origin/$src" "$last" && return 0
	[ "$(git rev-parse --is-shallow-repository)" = "true" ] || return 1
	for t in 1 2 3; do
		retry_fetch --deepen=$((t * 3000)) origin "$src" >/dev/null 2>&1 || true
		on_first_parent "origin/$src" "$last" && return 0
	done
	return 1
}

contains() { # <needle> <haystack...>
	local n="$1"
	shift
	local x
	for x in "$@"; do [ "$x" = "$n" ] && return 0; done
	return 1
}

# All dag branches on origin (used for older-detection even when replaying a
# subset).
mapfile -t all_dags < <(
	git ls-remote --heads origin | sed -E 's#.*refs/heads/##' | grep -E -- '-dag$'
)

if [ "$#" -gt 0 ]; then
	dags=("$@")
else
	dags=("${all_dags[@]}")
fi

if [ "${#dags[@]}" -eq 0 ]; then
	echo "No -dag branches to replay." >&2
	exit 0
fi

# Fetch every source and dag branch up front.
for dag in "${all_dags[@]}"; do
	retry_fetch origin "${dag%-dag}" "$dag" >/dev/null 2>&1 || true
done

git commit-graph write --reachable >/dev/null 2>&1 || true

# Detect each dag's older dag branch from its existing merge links: the second
# parent of one of its merges lies on exactly one other dag's first-parent path.
declare -A OLDER_OF
for dag in "${dags[@]}"; do
	OLDER_OF[$dag]=""
	p2=$(git rev-list --parents "origin/$dag" 2>/dev/null | awk 'NF>=3 && !f {print $3; f=1}')
	[ -n "$p2" ] || continue
	for o in "${all_dags[@]}"; do
		[ "$o" = "$dag" ] && continue
		if on_first_parent "origin/$o" "$p2"; then
			OLDER_OF[$dag]="$o"
			break
		fi
	done
done

# Order oldest-first: a dag is ready once its older dag is already ordered (or is
# not part of this run).
ordered=()
remaining=("${dags[@]}")
while [ "${#remaining[@]}" -gt 0 ]; do
	progress=0
	next=()
	for dag in "${remaining[@]}"; do
		o="${OLDER_OF[$dag]}"
		if [ -z "$o" ] || contains "$o" "${ordered[@]}" || ! contains "$o" "${dags[@]}"; then
			ordered+=("$dag")
			progress=1
		else
			next+=("$dag")
		fi
	done
	remaining=("${next[@]}")
	if [ "$progress" -eq 0 ]; then
		echo "ERROR: cyclic/unresolvable dag ordering among: ${remaining[*]}" >&2
		exit 1
	fi
done

declare -A FLATMAP
build_flatmap() { # <ref>
	FLATMAP=()
	local fsha url up
	while read -r fsha url; do
		[ -n "$url" ] || continue
		up="${url##*/commit/}"
		[ "$up" != "$url" ] && FLATMAP["$up"]="$fsha"
	done < <(git log "$1" --format='%H %(trailers:key=Upstream-commit,valueonly)')
}

rc=0
for dag in "${ordered[@]}"; do
	src="${dag%-dag}"
	older="${OLDER_OF[$dag]}"
	echo "== $dag  (source: origin/$src${older:+, older: $older}) ==" >&2

	if ! git rev-parse --verify -q "refs/remotes/origin/$dag" >/dev/null; then
		echo "  ERROR: origin/$dag not found (use the skill to create it first)." >&2
		rc=1
		continue
	fi
	if ! git rev-parse --verify -q "refs/remotes/origin/$src" >/dev/null; then
		echo "  ERROR: source origin/$src not found." >&2
		rc=1
		continue
	fi

	tip=$(git rev-parse "origin/$dag")
	last=$(git log -1 "$tip" --format='%(trailers:key=Upstream-commit,valueonly)' |
		sed -E 's#.*/commit/##; s/[[:space:]]*$//')
	if [ -z "$last" ]; then
		echo "  ERROR: tip $tip has no Upstream-commit trailer; cannot replay." >&2
		rc=1
		continue
	fi

	if ! ensure_reachable "$src" "$last"; then
		echo "  ERROR: last reproduced commit $last is not on origin/$src's" >&2
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

	# Link merges into the (already replayed, if local) older dag. Older source
	# ref is the upstream branch behind the older dag, used for merge-base
	# recovery of merges recorded via an intermediate "merge fixes" commit.
	links=0
	oldersrc=""
	if [ -n "$older" ]; then
		oldersrc="${older%-dag}"
		retry_fetch origin "$oldersrc" >/dev/null 2>&1 || true
		# Prefer the just-replayed local older dag; fall back to origin.
		if git rev-parse --verify -q "refs/heads/$older" >/dev/null; then
			build_flatmap "$older"
		else
			build_flatmap "origin/$older"
		fi
	fi
	echo "  appending ${#new[@]} new commit(s) on top of $tip" >&2

	parent="$tip"
	for c in "${new[@]}"; do
		extra=()
		if [ -n "$older" ]; then
			read -r _ p1 rest < <(git rev-list --parents -1 "$c")
			for pk in $rest; do
				if [ -n "${FLATMAP[$pk]:-}" ]; then
					cand="$pk"
				else
					cand=$(git merge-base "$pk" "origin/$oldersrc" 2>/dev/null || true)
					cand="${cand%%$'\n'*}"
				fi
				[ -n "$cand" ] && [ -n "${FLATMAP[$cand]:-}" ] || continue
				git merge-base --is-ancestor "$cand" "$p1" && continue
				extra+=("${FLATMAP[$cand]}")
				links=$((links + 1))
			done
		fi
		parent=$(flat_commit "$c" "$parent" "${extra[@]}")
	done

	if [ "$(git rev-parse "$parent^{tree}")" != "$(git rev-parse "origin/$src^{tree}")" ]; then
		echo "  ERROR: replayed tip tree != origin/$src tree; leaving $dag unchanged." >&2
		rc=1
		continue
	fi

	git branch -f "$dag" "$parent"
	echo "  $dag -> $parent  (+${#new[@]} commit(s), $links new merge link(s))" >&2

	if [ "${DRY_RUN:-0}" = "1" ]; then
		echo "  DRY_RUN: not pushing." >&2
		continue
	fi

	# Fast-forward push (no force): a rewritten dag branch should fail loudly.
	pushed=
	for i in 1 2 3 4; do
		git push origin "refs/heads/$dag:refs/heads/$dag" && {
			pushed=1
			break
		}
		sleep $((2 ** i))
	done
	[ -n "$pushed" ] || {
		echo "  ERROR: push failed for $dag." >&2
		rc=1
	}
done

exit "$rc"
