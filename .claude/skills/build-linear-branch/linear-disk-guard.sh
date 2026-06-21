#!/usr/bin/env bash
#
# Disk admission control for the "-linear" build loop. Each candidate commit is
# built in its own worktree (source checkout + build tree). ccache is shared and
# persistent, so it is NOT counted here.
#
# With the default `release` gate the build tree is small (~0.7 GiB measured on
# v2.0), so disk is rarely the binding constraint -- CPU/build-time is, and a
# single -j build already saturates the cores. This guard still applies, and
# matters most under the reldebug triage knob (~16 GiB trees), where the loop
# overlaps work by pruning intermediates right after link: at most ONE worktree
# is at its full peak while the others shrink to a pruned tree, so the space
# needed for k worktrees is one FULL build + (k-1) PRUNED trees.
#
# Usage: linear-disk-guard.sh [<scratch-dir>]   (default: current directory)
#   Prints an eval-able report and exits:
#     0  at least one build fits     (MAX_PARALLEL >= 1)
#     2  not even one full build fits (scrub finished worktrees, or stop)
#
# Env:
#   FULL_GIB     full (pre-prune) build estimate; auto-measured from the largest
#                build tree found, else this default (default: 2, ~release)
#   PRUNED_GIB   pruned (post-prune) test-tree estimate; auto-measured from the
#                smallest build tree found, else this default (default: 1)
#   RESERVE_GIB  free space to always keep (default: 5)
#   BUILD_GLOB   build trees to measure (default: <scratch>/*/build/* ./build/*)

set -euo pipefail

DIR="${1:-$PWD}"
RESERVE_GIB="${RESERVE_GIB:-5}"
FULL_GIB="${FULL_GIB:-2}"
PRUNED_GIB="${PRUNED_GIB:-1}"
SRC_BYTES=1610612736   # ~1.5 GiB source checkout per worktree

gib() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1073741824}'; }

# Measure real build trees if any exist: largest => full peak, smallest => pruned.
max=0; min=0
for g in ${BUILD_GLOB:-"$DIR"/*/build/* ./build/*}; do
	[ -d "$g" ] || continue
	sz=$(du -sb "$g" 2>/dev/null | cut -f1 || echo 0)
	[ "$sz" -gt "$max" ] && max="$sz"
	{ [ "$min" -eq 0 ] || [ "$sz" -lt "$min" ]; } && min="$sz"
done
if [ "$max" -gt 0 ]; then
	FULL_BYTES=$(( max + SRC_BYTES )); MEASURED=yes
else
	FULL_BYTES=$(( FULL_GIB * 1073741824 )); MEASURED=no
fi
if [ "$min" -gt 0 ]; then
	PRUNED_BYTES=$(( min + SRC_BYTES ))
else
	PRUNED_BYTES=$(( PRUNED_GIB * 1073741824 ))
fi

AVAIL_BYTES=$(( $(df -B1 --output=avail "$DIR" | tail -1) ))
USABLE=$(( AVAIL_BYTES - RESERVE_GIB * 1073741824 ))

MAX_PARALLEL=0
if [ "$USABLE" -ge "$FULL_BYTES" ]; then
	# one full build + as many pruned trees as the remainder allows
	MAX_PARALLEL=$(( 1 + (USABLE - FULL_BYTES) / PRUNED_BYTES ))
fi

cat <<-EOF
	AVAIL_GIB=$(gib "$AVAIL_BYTES")
	RESERVE_GIB=$RESERVE_GIB
	FULL_GIB=$(gib "$FULL_BYTES")
	PRUNED_GIB=$(gib "$PRUNED_BYTES")
	MEASURED=$MEASURED
	MAX_PARALLEL=$MAX_PARALLEL
EOF

[ "$MAX_PARALLEL" -ge 1 ] && exit 0
echo "LOW: not even one full build fits; scrub finished worktrees or stop." >&2
exit 2
