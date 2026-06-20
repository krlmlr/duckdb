#!/usr/bin/env bash
#
# Green gate for one "-linear" commit, split into phases so the disk peak of one
# worktree does not block another:
#
#   build  -- compile + link, then PRUNE build intermediates (*.o, *.a).
#   test   -- run the fast unit tests against the tree.
#   all    -- build then test (default).
#
# Default flavor is `release`. Measured on v2.0: release runs the SAME 4859
# registered / 4517 executed tests with the SAME outcomes (0 failures) as
# reldebug, builds faster (1016s vs 1508s), and the tree is 0.7 GiB vs 16.1 GiB
# -- so disk stops being the binding constraint and concurrency is CPU-bound.
# Use a heavier flavor only to triage a failure: DUCKDB_BUILD=reldebug (debug
# symbols) or `make relassert` (optimized + assertions).
#
# ccache (shared across worktrees, persistent) makes the rebuild after a fix or
# a prune cheap: pruned objects are repopulated from cache, not recompiled.
# Exit 0 == green. CI on GitHub Actions re-verifies independently.
#
# Usage: linear-build-test.sh [build|test|all] [<worktree-dir>]   (default: all .)
#
# Env:
#   DUCKDB_BUILD      build flavor / build dir name (default: release). Set to
#                     reldebug to triage a failure with debug symbols.
#   PRUNE             1 = delete *.o and *.a after a successful build (default 1)
#   CCACHE_DIR        shared ccache (default: $HOME/.cache/duckdb-linear-ccache)
#   CCACHE_MAXSIZE    ccache cap (default: 12G)
#   UNITTEST_ARGS     args for the unittest binary (default: none = fast suite)
#   JOBS              parallel build jobs (default: nproc)

set -euo pipefail

PHASE="all"
case "${1:-}" in
build | test | all) PHASE="$1"; shift ;;
esac
WT="${1:-$PWD}"
cd "$WT"

BUILD="${DUCKDB_BUILD:-release}"
BUILD_DIR="build/$BUILD"

do_build() {
	export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/duckdb-linear-ccache}"
	export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-12G}"
	mkdir -p "$CCACHE_DIR"
	if command -v ccache >/dev/null 2>&1; then
		export CC="ccache ${CC:-cc}"
		export CXX="ccache ${CXX:-c++}"
		ccache --max-size="$CCACHE_MAXSIZE" >/dev/null 2>&1 || true
	else
		echo "WARN: ccache not found; build will not be incremental." >&2
	fi
	[ -n "${GEN:-}" ] && export GEN
	export CMAKE_BUILD_PARALLEL_LEVEL="${JOBS:-$(nproc)}"

	echo "== build $BUILD ($(git rev-parse --short HEAD)) ==" >&2
	make "$BUILD"

	if [ "${PRUNE:-1}" = "1" ]; then
		local before after
		before=$(du -sb "$BUILD_DIR" 2>/dev/null | cut -f1 || echo 0)
		# Objects and static libs are intermediates, not needed to RUN the tests;
		# binaries/libraries/extensions stay. ccache rebuilds them fast. (For a
		# release tree this is minor -- the whole tree is already ~0.7 GiB.)
		find "$BUILD_DIR" -type f \( -name '*.o' -o -name '*.a' \) -delete 2>/dev/null || true
		after=$(du -sb "$BUILD_DIR" 2>/dev/null | cut -f1 || echo 0)
		awk -v a="$before" -v b="$after" \
			'BEGIN{printf "== pruned intermediates: %.1f -> %.1f GiB ==\n", a/1073741824, b/1073741824}' >&2
	fi
}

do_test() {
	[ -x "$BUILD_DIR/test/unittest" ] || {
		echo "ERROR: $BUILD_DIR/test/unittest missing; run the build phase first." >&2
		exit 1
	}
	echo "== unittest (fast, $BUILD) ==" >&2
	# shellcheck disable=SC2086
	"$BUILD_DIR/test/unittest" ${UNITTEST_ARGS:-}
}

case "$PHASE" in
build) do_build ;;
test) do_test ;;
all) do_build; do_test ;;
esac

echo "GREEN[$PHASE] $(git rev-parse HEAD)" >&2
