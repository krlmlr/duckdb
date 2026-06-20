#!/usr/bin/env bash
#
# Green gate for one "-linear" commit, split into phases so the disk peak of one
# worktree does not block another:
#
#   build  -- compile + link, then PRUNE intermediate object files (the bulk of
#             a reldebug tree). Leaves a runnable test tree that is a fraction of
#             the peak size, so a SECOND worktree can start building while this
#             one only needs to run tests.
#   test   -- run the fast unit tests against the (pruned) tree.
#   all    -- build then test (default).
#
# ccache (shared across worktrees, persistent) makes the rebuild after a fix or
# a prune cheap: pruned .o files are repopulated from cache, not recompiled.
# Exit 0 == green. CI on GitHub Actions re-verifies independently.
#
# Usage: linear-build-test.sh [build|test|all] [<worktree-dir>]   (default: all .)
#
# Env:
#   DUCKDB_BUILD      build flavor / build dir name (default: reldebug). Set to a
#                     lighter flavor (e.g. release) to shrink the disk peak when
#                     even one reldebug tree will not fit twice.
#   PRUNE             1 = delete *.o after a successful build (default 1)
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

BUILD="${DUCKDB_BUILD:-reldebug}"
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
		# Object files are the disk hog and are not needed to RUN the tests; the
		# linked unittest binary and libraries stay. ccache rebuilds them fast.
		find "$BUILD_DIR" -type f -name '*.o' -delete 2>/dev/null || true
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
