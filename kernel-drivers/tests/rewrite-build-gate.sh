#!/usr/bin/env bash
# Reproduce the focused clean-source build gate for the RK3588 rewrite drivers.
#
# The gate intentionally builds from git-archive copies, not the live kernel
# worktrees, so generated files and local object state cannot hide portability
# problems. It only builds the two rewrite objects with their optional KUnit
# coverage enabled.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"

KERNEL_6_18="${KERNEL_6_18:-$ROOT_DIR/../linux-6.18-rkvenc}"
KERNEL_MAINLINE="${KERNEL_MAINLINE:-$ROOT_DIR/../linux}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"
KEEP_TMP="${KEEP_TMP:-0}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
FAIL_ON_WARNING="${FAIL_ON_WARNING:-1}"

TARGETS=(
  drivers/video/rockchip/mpp-rewrite/mpp_rewrite.o
  drivers/video/rockchip/rga-rewrite/rga_rewrite.o
)

tmp_root=

usage() {
  cat <<EOF
Usage: ${0##*/} [6.18|mainline|all]

Environment:
  KERNEL_6_18       6.18 rewrite kernel checkout (default: ../linux-6.18-rkvenc)
  KERNEL_MAINLINE   mainline rewrite kernel checkout (default: ../linux)
  ARCH              kernel ARCH (default: arm64)
  CROSS_COMPILE     cross compiler prefix (default: aarch64-linux-gnu-)
  JOBS              make parallelism (default: nproc)
  KEEP_TMP=1        keep /tmp source/output/log directories
  ALLOW_DIRTY=1     allow dirty kernel worktrees, but still build HEAD archive
  FAIL_ON_WARNING=0 do not fail on "warning:" lines in the build log
EOF
}

cleanup() {
  if [ "$KEEP_TMP" != 1 ] && [ -n "$tmp_root" ] && [ -d "$tmp_root" ]; then
    rm -rf "$tmp_root"
  fi
}
trap cleanup EXIT

need_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required tool: $1" >&2
    exit 1
  }
}

check_clean_tree() {
  local tree="$1"

  git -C "$tree" rev-parse --verify HEAD >/dev/null
  if [ "$ALLOW_DIRTY" != 1 ] &&
     ! git -C "$tree" diff-index --quiet HEAD --; then
    echo "dirty kernel tree: $tree" >&2
    echo "Set ALLOW_DIRTY=1 to build the committed HEAD anyway." >&2
    exit 1
  fi
}

set_rewrite_config() {
  local src="$1"
  local out="$2"

  "$src/scripts/config" --file "$out/.config" \
    -d ROCKCHIP_MPP_SERVICE \
    -d ROCKCHIP_MULTI_RGA \
    -d VIDEO_ROCKCHIP_RGA \
    -e KUNIT \
    -e KUNIT_DEBUGFS \
    -e KUNIT_DEFAULT_ENABLED \
    -e KUNIT_AUTORUN_ENABLED \
    -e ROCKCHIP_MPP_REWRITE \
    -e ROCKCHIP_MPP_REWRITE_KUNIT_TEST \
    -e ROCKCHIP_RGA_REWRITE \
    -e ROCKCHIP_RGA_REWRITE_KUNIT_TEST
}

require_config() {
  local out="$1"
  local symbol="$2"

  if ! grep -qx "CONFIG_${symbol}=y" "$out/.config"; then
    echo "required config did not resolve to y: CONFIG_${symbol}" >&2
    echo "Relevant config lines:" >&2
    grep -E "CONFIG_(ROCKCHIP_.*REWRITE|ROCKCHIP_MPP_SERVICE|ROCKCHIP_MULTI_RGA|VIDEO_ROCKCHIP_RGA|KUNIT)" "$out/.config" >&2 || true
    exit 1
  fi
}

configure_tree() {
  local label="$1"
  local tree="$2"
  local src="$3"
  local out="$4"
  local base_config="$tree/.config"

  if [ -f "$base_config" ]; then
    cp "$base_config" "$out/.config"
    echo "[$label] config: copied $base_config"
  else
    echo "[$label] config: make defconfig"
    make -C "$src" O="$out" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" defconfig
  fi

  set_rewrite_config "$src" "$out"
  make -C "$src" O="$out" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

  require_config "$out" KUNIT
  require_config "$out" ROCKCHIP_MPP_REWRITE
  require_config "$out" ROCKCHIP_MPP_REWRITE_KUNIT_TEST
  require_config "$out" ROCKCHIP_RGA_REWRITE
  require_config "$out" ROCKCHIP_RGA_REWRITE_KUNIT_TEST
}

build_one() {
  local label="$1"
  local tree="$2"
  local commit
  local src
  local out
  local log

  check_clean_tree "$tree"
  commit="$(git -C "$tree" rev-parse --short=12 HEAD)"
  src="$tmp_root/$label-src"
  out="$tmp_root/$label-out"
  log="$tmp_root/$label-build.log"

  mkdir -p "$src" "$out"
  echo "[$label] source: $tree @ $commit"
  git -C "$tree" archive --format=tar HEAD | tar -C "$src" -xf -

  configure_tree "$label" "$tree" "$src" "$out"

  echo "[$label] build: ${TARGETS[*]}"
  make -C "$src" O="$out" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
    -j "$JOBS" "${TARGETS[@]}" 2>&1 | tee "$log"

  if [ "$FAIL_ON_WARNING" = 1 ] && grep -i "warning:" "$log"; then
    echo "[$label] build completed but emitted warnings; see $log" >&2
    exit 1
  fi

  echo "[$label] PASS: clean rewrite object build at $commit"
  if [ "$KEEP_TMP" = 1 ]; then
    echo "[$label] kept source: $src"
    echo "[$label] kept output: $out"
    echo "[$label] kept log:    $log"
  fi
}

main() {
  local which="${1:-all}"

  if [ "$which" = "-h" ] || [ "$which" = "--help" ]; then
    usage
    exit 0
  fi

  need_tool git
  need_tool tar
  need_tool make
  need_tool grep

  tmp_root="$(mktemp -d -t rkcompat-rewrite-build.XXXXXX)"

  case "$which" in
  6.18)
    build_one "6.18" "$KERNEL_6_18"
    ;;
  mainline)
    build_one "mainline" "$KERNEL_MAINLINE"
    ;;
  all)
    build_one "6.18" "$KERNEL_6_18"
    build_one "mainline" "$KERNEL_MAINLINE"
    ;;
  *)
    usage >&2
    exit 2
    ;;
  esac
}

main "$@"
