#!/usr/bin/env bash
#
# replay-segment.sh RANGE  — cherry-pick the first-parent commits of RANGE
# (e.g. SEGMENT_FROM..NEXT_P1) onto the CURRENT HEAD (set HEAD = NEXT_P2 first),
# one commit at a time:
#   - apply commits that change something (`git cherry-pick -x`);
#   - **skip empties** — a commit whose change the advanced base already has.
#     git's cherry-pick has no portable `--empty=drop`/`--allow-empty=false` here
#     (they error), so empties are detected from the message and dropped with
#     `--skip`;
#   - **stop on the first conflict** and report the unmerged files. Resolve them
#     by hand using the merge tree as the oracle (skill step 3), run
#     `git cherry-pick --continue`, then re-run this script to finish the range.
# After it returns, assert `HEAD^{tree} == MERGE_TREE`; add a single reconcile
# commit only if a cross-side reconciliation remains.
set -uo pipefail
RANGE="${1:?range required, e.g. SEGMENT_FROM..NEXT_P1}"
for c in $(git rev-list --reverse --first-parent "$RANGE"); do
	s=$(git log -1 --format=%s "$c" | cut -c1-50)
	if git cherry-pick -x "$c" >/tmp/_replay_cp.out 2>&1; then
		echo "applied    ${c:0:9} $s"
	elif git diff --name-only --diff-filter=U | grep -q .; then
		echo "CONFLICT   ${c:0:9} $s — resolve, 'git cherry-pick --continue', then re-run"
		git diff --name-only --diff-filter=U | sed 's/^/    U /'
		exit 2
	elif grep -qiE 'empty|nothing to commit' /tmp/_replay_cp.out; then
		git cherry-pick --skip >/dev/null 2>&1
		echo "empty→skip ${c:0:9} $s"
	else
		echo "ERROR      ${c:0:9} $s"; tail -3 /tmp/_replay_cp.out; exit 1
	fi
done
echo "done: HEAD $(git rev-parse --short HEAD) tree $(git rev-parse HEAD^{tree})"
