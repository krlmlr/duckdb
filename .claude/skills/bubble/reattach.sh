#!/usr/bin/env bash
set -euo pipefail
M="$1"; R="$2"; UPPER="$3"
declare -A MAP DESC; MAP[$M]=$(git rev-parse "$R")
# mark descendants of M (commits with M as ancestor) within range
while read -r c; do git merge-base --is-ancestor "$M" "$c" 2>/dev/null && DESC[$c]=1; done < <(git rev-list "${M}..${UPPER}")
n=0
while read -r c; do
  [ -n "${DESC[$c]:-}" ] || continue            # skip non-descendants (keep original SHA)
  read -r _ ps < <(git rev-list --parents -n1 "$c")
  np=""; for p in $ps; do np+=" -p ${MAP[$p]:-$p}"; done
  t=$(git rev-parse "$c^{tree}")
  export GIT_AUTHOR_NAME="$(git show -s --format=%an "$c")" GIT_AUTHOR_EMAIL="$(git show -s --format=%ae "$c")" GIT_AUTHOR_DATE="$(git show -s --format=%aI "$c")"
  export GIT_COMMITTER_NAME="$(git show -s --format=%cn "$c")" GIT_COMMITTER_EMAIL="$(git show -s --format=%ce "$c")" GIT_COMMITTER_DATE="$(git show -s --format=%cI "$c")"
  MAP[$c]=$(git show -s --format=%B "$c" | git commit-tree "$t" $np)
  n=$((n+1))
done < <(git rev-list --reverse --topo-order "${M}..${UPPER}")
echo "rewrote $n descendant commits" >&2
echo "${MAP[$(git rev-parse $UPPER)]}"
