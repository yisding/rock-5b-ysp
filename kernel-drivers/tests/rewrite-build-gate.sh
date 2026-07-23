#!/usr/bin/env bash
# Reproduce the focused clean-source build gate for the RK3588 rewrite drivers.
#
# The gate intentionally builds from git-archive copies, not the live kernel
# worktrees, so generated files and local object state cannot hide portability
# problems. Each profile gets its own scratch tree, which is removed after that
# profile passes unless KEEP_TMP=1. It builds the two rewrite objects with their
# optional KUnit coverage, the Rockchip IOMMU provider used by MPP/RGA, and the
# Rock 5B DTB that wires the media topology.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"

KERNEL_6_18="${KERNEL_6_18:-$ROOT_DIR/../kernel/linux-6.18-rkvenc}"
KERNEL_MAINLINE="${KERNEL_MAINLINE:-$ROOT_DIR/../kernel/linux}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"
KEEP_TMP="${KEEP_TMP:-0}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
FAIL_ON_WARNING="${FAIL_ON_WARNING:-1}"
REWRITE_BUILD_PROFILES="${REWRITE_BUILD_PROFILES:-normal}"
REWRITE_BUILD_TMP_ROOT="${REWRITE_BUILD_TMP_ROOT:-$(dirname "$ROOT_DIR")}"

TARGETS=(
  drivers/iommu/rockchip-iommu.o
  drivers/video/rockchip/mpp-rewrite/mpp_rewrite.o
  drivers/video/rockchip/rga-rewrite/rga_rewrite.o
  rockchip/rk3588-rock-5b.dtb
)

tmp_root=

usage() {
  cat <<EOF
Usage: ${0##*/} [6.18|mainline|all]

Environment:
  KERNEL_6_18       6.18 rewrite kernel checkout (default: ../kernel/linux-6.18-rkvenc)
  KERNEL_MAINLINE   mainline rewrite kernel checkout (default: ../kernel/linux)
  ARCH              kernel ARCH (default: arm64)
  CROSS_COMPILE     cross compiler prefix (default: aarch64-linux-gnu-)
  JOBS              make parallelism (default: nproc)
  KEEP_TMP=1        keep scratch source/output/log directories
  ALLOW_DIRTY=1     allow dirty kernel worktrees, but still build HEAD archive
  FAIL_ON_WARNING=0 do not fail on "warning:" lines in the build log
  REWRITE_BUILD_PROFILES
                    space-separated profiles: normal, memory, race
                    normal: KUnit-enabled provider/rewrite/DTB build (default)
                    memory: KASAN/fault-injection provider/rewrite/DTB build
                    race: KCSAN/lockdep provider/rewrite/DTB build
  REWRITE_BUILD_TMP_ROOT
                    scratch-directory parent (default: parent of this repo)
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
    -e ARCH_ROCKCHIP \
    -d ROCKCHIP_MPP_SERVICE \
    -d ROCKCHIP_MULTI_RGA \
    -d VIDEO_ROCKCHIP_RGA \
    -e KUNIT \
    -e KUNIT_DEBUGFS \
    -e KUNIT_DEFAULT_ENABLED \
    -e KUNIT_AUTORUN_ENABLED \
    -e ROCKCHIP_IOMMU \
    -e ROCKCHIP_MPP_REWRITE \
    -e ROCKCHIP_MPP_REWRITE_KUNIT_TEST \
    -e ROCKCHIP_RGA_REWRITE \
    -e ROCKCHIP_RGA_REWRITE_KUNIT_TEST
}

set_profile_config() {
  local src="$1"
  local out="$2"
  local profile="$3"

  case "$profile" in
  normal)
    ;;
  memory)
    "$src/scripts/config" --file "$out/.config" \
      -e DEBUG_KERNEL \
      -e DEBUG_FS \
      -d KCSAN \
      -e KASAN \
      -e KASAN_GENERIC \
      -e KASAN_INLINE \
      -e KASAN_VMALLOC \
      -e FAULT_INJECTION \
      -e FAULT_INJECTION_DEBUG_FS \
      -e FAULT_INJECTION_STACKTRACE_FILTER \
      -e FAILSLAB \
      -e FAIL_PAGE_ALLOC \
      -e FAULT_INJECTION_USERCOPY \
      -e FUNCTION_ERROR_INJECTION \
      --set-val FRAME_WARN 4096
    ;;
  race)
    "$src/scripts/config" --file "$out/.config" \
      -e EXPERT \
      -e DEBUG_KERNEL \
      -d KASAN \
      -e KCSAN \
      -e PROVE_LOCKING \
      --set-val FRAME_WARN 4096
    ;;
  *)
    echo "unknown REWRITE_BUILD_PROFILES entry: $profile" >&2
    exit 2
    ;;
  esac
}

require_config() {
  local out="$1"
  local symbol="$2"

  if ! grep -qx "CONFIG_${symbol}=y" "$out/.config"; then
    echo "required config did not resolve to y: CONFIG_${symbol}" >&2
    echo "Relevant config lines:" >&2
    grep -E "CONFIG_(ARCH_ROCKCHIP|ROCKCHIP_(IOMMU|.*REWRITE)|ROCKCHIP_MPP_SERVICE|ROCKCHIP_MULTI_RGA|VIDEO_ROCKCHIP_RGA|KUNIT|KASAN|KCSAN|FAULT_INJECTION|FAILSLAB|FAIL_PAGE_ALLOC|PROVE_LOCKING|DEBUG_KERNEL|EXPERT)" "$out/.config" >&2 || true
    exit 1
  fi
}

configure_tree() {
  local label="$1"
  local tree="$2"
  local src="$3"
  local out="$4"
  local profile="$5"
  local base_config="$tree/.config"

  if [ -f "$base_config" ]; then
    cp "$base_config" "$out/.config"
    echo "[$label] config: copied $base_config"
  else
    echo "[$label] config: make defconfig"
    make -C "$src" O="$out" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" defconfig
  fi

  set_rewrite_config "$src" "$out"
  set_profile_config "$src" "$out" "$profile"
  make -C "$src" O="$out" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

  require_config "$out" KUNIT
  require_config "$out" ARCH_ROCKCHIP
  require_config "$out" ROCKCHIP_IOMMU
  require_config "$out" ROCKCHIP_MPP_REWRITE
  require_config "$out" ROCKCHIP_MPP_REWRITE_KUNIT_TEST
  require_config "$out" ROCKCHIP_RGA_REWRITE
  require_config "$out" ROCKCHIP_RGA_REWRITE_KUNIT_TEST

  case "$profile" in
  normal)
    ;;
  memory)
    require_config "$out" KASAN
    require_config "$out" FAULT_INJECTION
    require_config "$out" FAILSLAB
    require_config "$out" FAIL_PAGE_ALLOC
    require_config "$out" FAULT_INJECTION_USERCOPY
    ;;
  race)
    require_config "$out" KCSAN
    require_config "$out" PROVE_LOCKING
    ;;
  esac
}

build_one_profile() {
  local label="$1"
  local tree="$2"
  local profile="$3"
  local commit
  local profile_tmp
  local src
  local out
  local log

  check_clean_tree "$tree"
  commit="$(git -C "$tree" rev-parse --short=12 HEAD)"
  mkdir -p "$REWRITE_BUILD_TMP_ROOT"
  profile_tmp="$(mktemp -d "$REWRITE_BUILD_TMP_ROOT/rkcompat-rewrite-build.$label.$profile.XXXXXX")"
  tmp_root="$profile_tmp"
  src="$profile_tmp/src"
  out="$profile_tmp/out"
  log="$profile_tmp/build.log"

  mkdir -p "$src" "$out"
  echo "[$label/$profile] source: $tree @ $commit"
  git -C "$tree" archive --format=tar HEAD | tar -C "$src" -xf -

  configure_tree "$label/$profile" "$tree" "$src" "$out" "$profile"

  echo "[$label/$profile] build: ${TARGETS[*]}"
  make -C "$src" O="$out" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
    -j "$JOBS" "${TARGETS[@]}" 2>&1 | tee "$log"

  if [ "$FAIL_ON_WARNING" = 1 ] && grep -i "warning:" "$log"; then
    echo "[$label/$profile] build completed but emitted warnings; see $log" >&2
    exit 1
  fi

  echo "[$label/$profile] PASS: clean rewrite object build at $commit"
  if [ "$KEEP_TMP" = 1 ]; then
    echo "[$label/$profile] kept source: $src"
    echo "[$label/$profile] kept output: $out"
    echo "[$label/$profile] kept log:    $log"
  else
    rm -rf "$profile_tmp"
    tmp_root=
  fi
}

build_one() {
  local label="$1"
  local tree="$2"
  local profile

  for profile in $REWRITE_BUILD_PROFILES; do
    build_one_profile "$label" "$tree" "$profile"
  done
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
