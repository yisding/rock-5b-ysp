#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
#
# Run the two rewrite KUnit suites on an emulated arm64 "virt" machine.
#
# The suites are built into a minimal kernel by the tree's own kunit.py and
# booted under QEMU, so every case executes without a board, a package, or a
# reboot.  This answers "does the suite pass, and does it stay quiet under
# lockdep and debug objects" in about five minutes cold and under one warm.
# It proves nothing about hardware: no RK3588 device probes on this machine,
# and the cases only ever touch their own fixtures.
set -euo pipefail

usage() {
  cat <<EOF
Usage: ${0##*/} <kernel-tree> [kunit.py filter glob ...]

  <kernel-tree>   clean rewrite source tree (a tree holding in-tree build
                  output is refused by Kbuild; export HEAD with git archive)

Environment:
  KUNIT_QEMU_BUILD_DIR  out-of-tree build directory
                        (default: \$ROCK5B_WORKSPACE/build/rewrite-kunit-qemu)
  ROCK5B_WORKSPACE      grouped board workspace (default: ../rock-5b)
  KUNIT_QEMU_KASAN=1    add generic KASAN (a separate, much slower build)
  JOBS                  make parallelism (default: nproc)
  CCACHE_DIR            compiler cache (default: ~/Code/.ccache)

qemu-system-aarch64 must be on PATH.  Without root, unpack the distribution
packages with "apt download" and "dpkg -x" and add that bin directory to PATH
and its library directory to LD_LIBRARY_PATH; pass the firmware directory in
KUNIT_QEMU_DATA_DIR.

Exit status is kunit.py's: non-zero when any case fails.  A kernel warning,
lockdep report or sanitizer report does not fail a case, so the script scans
the console for them afterwards and exits 3 when it finds one.
EOF
}

if [ "$#" -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  usage
  [ "$#" -ge 1 ] && exit 0
  exit 2
fi

tree="$(cd "$1" && pwd)"
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROCK5B_WORKSPACE="${ROCK5B_WORKSPACE:-$REPO_ROOT/../rock-5b}"
build_dir="${KUNIT_QEMU_BUILD_DIR:-$ROCK5B_WORKSPACE/build/rewrite-kunit-qemu}"
JOBS="${JOBS:-$(nproc)}"
export CCACHE_DIR="${CCACHE_DIR:-$HOME/Code/.ccache}"

command -v qemu-system-aarch64 >/dev/null 2>&1 || {
  echo "missing qemu-system-aarch64 on PATH (see --help)" >&2
  exit 1
}
[ -f "$tree/tools/testing/kunit/kunit.py" ] || {
  echo "not a kernel tree: $tree" >&2
  exit 1
}

mkdir -p "$build_dir"
config="$build_dir/rewrite.kunitconfig"
cat >"$config" <<'EOF'
CONFIG_KUNIT=y
CONFIG_ARCH_ROCKCHIP=y
CONFIG_IOMMU_SUPPORT=y
CONFIG_ROCKCHIP_IOMMU=y
CONFIG_VSI_IOMMU=y
# CONFIG_ROCKCHIP_MPP_SERVICE is not set
# CONFIG_ROCKCHIP_MULTI_RGA is not set
CONFIG_ROCKCHIP_MPP_REWRITE=y
CONFIG_ROCKCHIP_MPP_REWRITE_KUNIT_TEST=y
CONFIG_ROCKCHIP_RGA_REWRITE=y
CONFIG_ROCKCHIP_RGA_REWRITE_KUNIT_TEST=y
CONFIG_DEBUG_KERNEL=y
CONFIG_PROVE_LOCKING=y
CONFIG_DEBUG_ATOMIC_SLEEP=y
CONFIG_DEBUG_OBJECTS=y
CONFIG_DEBUG_OBJECTS_WORK=y
CONFIG_DEBUG_OBJECTS_TIMERS=y
CONFIG_DEBUG_OBJECTS_FREE=y
CONFIG_DEBUG_LIST=y
EOF
if [ "${KUNIT_QEMU_KASAN:-0}" = 1 ]; then
  printf 'CONFIG_KASAN=y\nCONFIG_KASAN_GENERIC=y\n' >>"$config"
fi

qemu_args="-m 2G"
if [ -n "${KUNIT_QEMU_DATA_DIR:-}" ]; then
  qemu_args="-L $KUNIT_QEMU_DATA_DIR $qemu_args"
fi

log="$build_dir/console.log"
rc=0
(
  cd "$tree"
  python3 tools/testing/kunit/kunit.py run --arch=arm64 \
    --build_dir="$build_dir/out" --kunitconfig="$config" \
    --jobs="$JOBS" --timeout=3600 \
    --make_options 'CC=ccache gcc' --make_options 'HOSTCC=ccache gcc' \
    --qemu_args="$qemu_args" --raw_output=all "$@"
) >"$log" 2>&1 || rc=$?

grep -E '^# Totals:|^(not )?ok [0-9]+ ' "$log" || true
echo "console: $log"
if [ "$rc" -ne 0 ]; then
  grep -E '^\s*not ok |error:' "$log" | head -40 >&2 || true
  exit "$rc"
fi

# kunit.py reports cases, not the kernel log around them.
if grep -E 'WARNING:|BUG:|Oops|Unable to handle kernel|ODEBUG:|KASAN:|UBSAN:|refcount_t:' \
    "$log" >&2; then
  echo "kernel reports found in a passing run; see $log" >&2
  exit 3
fi
echo "PASS: every case passed with no kernel report"
