#!/usr/bin/env bash
#
# Regenerate and push the flat (squashed) orphan branches that mirror the
# upstream-tracking branches v1.4-*, v1.5-* and v2.0.
#
# Flattening is deterministic (see flatten-branch.sh), so an unchanged source
# branch produces an identical -flat branch and the push is a no-op; new
# upstream commits append on top as a fast-forward.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

# Fetch every source branch in full (override any narrow checkout refspec).
git fetch --prune origin '+refs/heads/*:refs/remotes/origin/*'

mapfile -t branches < <(
	git for-each-ref --format='%(refname:short)' 'refs/remotes/origin/*' |
		sed 's#^origin/##' |
		grep -E '^(v1\.4-|v1\.5-|v2\.0$)' |
		grep -v -- '-flat$'
)

if [ "${#branches[@]}" -eq 0 ]; then
	echo "No source branches matched v1.4-*, v1.5-*, v2.0" >&2
	exit 0
fi

echo "Source branches: ${branches[*]}" >&2

for b in "${branches[@]}"; do
	dst="${b}-flat"
	bash "$here/flatten-branch.sh" "origin/$b" "$dst"
	git push --force origin "refs/heads/$dst:refs/heads/$dst"
done
