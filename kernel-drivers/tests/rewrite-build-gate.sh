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
ROCK5B_WORKSPACE="${ROCK5B_WORKSPACE:-$ROOT_DIR/../rock-5b}"

KERNEL_6_18="${KERNEL_6_18:-$ROCK5B_WORKSPACE/kernel/linux-6.18-rkvenc}"
KERNEL_MAINLINE="${KERNEL_MAINLINE:-$ROCK5B_WORKSPACE/kernel/linux}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"
KEEP_TMP="${KEEP_TMP:-0}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
FAIL_ON_WARNING="${FAIL_ON_WARNING:-1}"
REWRITE_BUILD_PROFILES="${REWRITE_BUILD_PROFILES:-normal}"
REWRITE_BUILD_TMP_ROOT="${REWRITE_BUILD_TMP_ROOT:-$ROOT_DIR/../tmp}"
VERIFY_ABI_STATIC_ASSERT="${VERIFY_ABI_STATIC_ASSERT:-0}"

TARGETS=(
  drivers/iommu/rockchip-iommu.o
  drivers/video/rockchip/mpp-rewrite/mpp_rewrite.o
  drivers/video/rockchip/rga-rewrite/rga_rewrite.o
  rockchip/rk3588-rock-5b.dtb
)

REWRITE_IDENTITY_FILES=(
  drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c
  drivers/video/rockchip/mpp-rewrite/Kconfig
  drivers/video/rockchip/mpp-rewrite/ABI.rst
  drivers/video/rockchip/rga-rewrite/rga_rewrite.c
  drivers/video/rockchip/rga-rewrite/Kconfig
  drivers/video/rockchip/rga-rewrite/ABI.rst
  include/uapi/linux/rk-mpp.h
)

tmp_root=

usage() {
  cat <<EOF
Usage: ${0##*/} [6.18|mainline|all|audit]

Environment:
  KERNEL_6_18       6.18 rewrite kernel checkout (default: ../rock-5b/kernel/linux-6.18-rkvenc)
  KERNEL_MAINLINE   mainline rewrite kernel checkout (default: ../rock-5b/kernel/linux)
  ROCK5B_WORKSPACE  grouped board workspace (default: ../rock-5b)
  ARCH              kernel ARCH (default: arm64)
  CROSS_COMPILE     cross compiler prefix (default: aarch64-linux-gnu-)
  JOBS              make parallelism (default: nproc)
  KEEP_TMP=1        keep scratch source/output/log directories
  ALLOW_DIRTY=1     allow dirty kernel worktrees, but still build HEAD archive
  FAIL_ON_WARNING=0 do not fail on "warning:" lines in the build log
  REWRITE_BUILD_PROFILES
                    space-separated profiles: normal, test-disabled, memory, race
                    normal: KUnit-enabled provider/rewrite/DTB build (default)
                    test-disabled: same targets with both rewrite KUnit suites off
                    memory: KASAN/fault-injection provider/rewrite/DTB build
                    race: KCSAN/lockdep provider/rewrite/DTB build
  REWRITE_BUILD_TMP_ROOT
                    scratch-directory parent (default: ../tmp beside this repo)
  VERIFY_ABI_STATIC_ASSERT=1
                    mutate the MPP ABI size in a test-disabled profile and
                    require the existing static assertion to fail compilation
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

audit_kunit_source() {
  python3 "$TEST_DIR/rewrite-kunit-source-audit.py" "$@"
}

check_cross_tree_identity() {
  local relative

  for relative in "${REWRITE_IDENTITY_FILES[@]}"; do
    if ! cmp -s "$KERNEL_6_18/$relative" "$KERNEL_MAINLINE/$relative"; then
      echo "rewrite cross-tree content differs: $relative" >&2
      exit 1
    fi
  done
  echo "PASS: rewrite driver, Kconfig, ABI, and UAPI files are byte-identical"
}

check_kunit_manifest() {
  local tree="$1"
  local suite
  local expected_count
  local expected_hash
  local source
  local actual_count
  local actual_hash

  while IFS=$'\t' read -r suite expected_count expected_hash; do
    case "$suite" in
    ""|\#*) continue ;;
    rk_mpp_rewrite)
      source="$tree/drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"
      ;;
    rockchip-rga-rewrite)
      source="$tree/drivers/video/rockchip/rga-rewrite/rga_rewrite.c"
      ;;
    *)
      echo "unknown suite in KUnit manifest: $suite" >&2
      exit 1
      ;;
    esac
    actual_count=$(sed -n \
      's/.*KUNIT_CASE(\([A-Za-z0-9_]*\)).*/\1/p' "$source" | wc -l)
    actual_hash=$(sed -n \
      's/.*KUNIT_CASE(\([A-Za-z0-9_]*\)).*/\1/p' "$source" |
      sha256sum | awk '{ print $1 }')
    if [ "$actual_count" != "$expected_count" ] ||
       [ "$actual_hash" != "$expected_hash" ]; then
      echo "KUnit manifest differs from registered source: $suite" >&2
      echo "  expected count/hash: $expected_count $expected_hash" >&2
      echo "  observed count/hash: $actual_count $actual_hash" >&2
      exit 1
    fi
  done < "$TEST_DIR/rewrite-kunit-manifest.tsv"
  echo "PASS: KUnit manifest matches registered source in $tree"
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
  test-disabled)
    "$src/scripts/config" --file "$out/.config" \
      -d ROCKCHIP_MPP_REWRITE_KUNIT_TEST \
      -d ROCKCHIP_RGA_REWRITE_KUNIT_TEST
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

require_config_disabled() {
  local config="$1"
  local symbol="$2"

  if grep -Eq "^CONFIG_${symbol}=[ym]$" "$config"; then
    echo "required config resolved enabled: CONFIG_${symbol}" >&2
    grep -E "CONFIG_(ROCKCHIP_(MPP|RGA)_REWRITE_KUNIT_TEST|KUNIT_ALL_TESTS)" \
      "$config" >&2 || true
    exit 1
  fi
}

check_opt_in_defaults() {
  local src="$1"
  local out="$2"
  local config="$out/.config.kunit-all"

  cp "$out/.config" "$config"
  "$src/scripts/config" --file "$config" \
    -e ARCH_ROCKCHIP \
    -d ROCKCHIP_MPP_SERVICE \
    -d ROCKCHIP_MULTI_RGA \
    -d VIDEO_ROCKCHIP_RGA \
    -e KUNIT \
    -e KUNIT_ALL_TESTS \
    -e ROCKCHIP_MPP_REWRITE \
    -u ROCKCHIP_MPP_REWRITE_KUNIT_TEST \
    -e ROCKCHIP_RGA_REWRITE \
    -u ROCKCHIP_RGA_REWRITE_KUNIT_TEST
  make -C "$src" O="$out" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
    KCONFIG_CONFIG="$config" olddefconfig >/dev/null
  for symbol in KUNIT_ALL_TESTS ROCKCHIP_MPP_REWRITE ROCKCHIP_RGA_REWRITE; do
    if ! grep -qx "CONFIG_${symbol}=y" "$config"; then
      echo "opt-in default proof lost required parent: CONFIG_${symbol}" >&2
      exit 1
    fi
  done
  require_config_disabled "$config" ROCKCHIP_MPP_REWRITE_KUNIT_TEST
  require_config_disabled "$config" ROCKCHIP_RGA_REWRITE_KUNIT_TEST
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

  check_opt_in_defaults "$src" "$out"
  set_rewrite_config "$src" "$out"
  set_profile_config "$src" "$out" "$profile"
  make -C "$src" O="$out" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

  require_config "$out" KUNIT
  require_config "$out" ARCH_ROCKCHIP
  require_config "$out" ROCKCHIP_IOMMU
  require_config "$out" ROCKCHIP_MPP_REWRITE
  require_config "$out" ROCKCHIP_RGA_REWRITE

  case "$profile" in
  normal)
    require_config "$out" ROCKCHIP_MPP_REWRITE_KUNIT_TEST
    require_config "$out" ROCKCHIP_RGA_REWRITE_KUNIT_TEST
    ;;
  test-disabled)
    require_config_disabled "$out/.config" ROCKCHIP_MPP_REWRITE_KUNIT_TEST
    require_config_disabled "$out/.config" ROCKCHIP_RGA_REWRITE_KUNIT_TEST
    ;;
  memory)
    require_config "$out" ROCKCHIP_MPP_REWRITE_KUNIT_TEST
    require_config "$out" ROCKCHIP_RGA_REWRITE_KUNIT_TEST
    require_config "$out" KASAN
    require_config "$out" FAULT_INJECTION
    require_config "$out" FAILSLAB
    require_config "$out" FAIL_PAGE_ALLOC
    require_config "$out" FAULT_INJECTION_USERCOPY
    ;;
  race)
    require_config "$out" ROCKCHIP_MPP_REWRITE_KUNIT_TEST
    require_config "$out" ROCKCHIP_RGA_REWRITE_KUNIT_TEST
    require_config "$out" KCSAN
    require_config "$out" PROVE_LOCKING
    ;;
  esac
}

verify_abi_static_assert() {
  local src="$1"
  local out="$2"
  local log="$3"
  local source="$src/drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"

  sed -i \
    's/^#define RK_MPP_MSG_V1_ABI_SIZE[[:space:]]*24$/#define RK_MPP_MSG_V1_ABI_SIZE			25/' \
    "$source"
  if ! grep -qx '#define RK_MPP_MSG_V1_ABI_SIZE[[:space:]]*25' "$source"; then
    echo "failed to apply deliberate MPP ABI mutation" >&2
    exit 1
  fi
  if make -C "$src" O="$out" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
    -j "$JOBS" drivers/video/rockchip/mpp-rewrite/mpp_rewrite.o \
    >"$log" 2>&1; then
    echo "deliberate MPP ABI mutation unexpectedly compiled" >&2
    exit 1
  fi
  if ! grep -Eiq 'static assertion failed|static_assert' "$log"; then
    echo "MPP ABI mutation failed for an unexpected reason; see $log" >&2
    exit 1
  fi
  echo "PASS: deliberate MPP ABI mutation failed at compile time"
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

  if [ "$VERIFY_ABI_STATIC_ASSERT" = 1 ]; then
    if [ "$profile" != test-disabled ]; then
      echo "VERIFY_ABI_STATIC_ASSERT=1 requires the test-disabled profile" >&2
      exit 2
    fi
    verify_abi_static_assert "$src" "$out" "$profile_tmp/abi-mutation.log"
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
  need_tool cmp

  case "$which" in
  audit)
    audit_kunit_source "$KERNEL_6_18" "$KERNEL_MAINLINE"
    check_cross_tree_identity
    check_kunit_manifest "$KERNEL_6_18"
    check_kunit_manifest "$KERNEL_MAINLINE"
    ;;
  6.18)
    audit_kunit_source "$KERNEL_6_18"
    check_kunit_manifest "$KERNEL_6_18"
    build_one "6.18" "$KERNEL_6_18"
    ;;
  mainline)
    audit_kunit_source "$KERNEL_MAINLINE"
    check_kunit_manifest "$KERNEL_MAINLINE"
    build_one "mainline" "$KERNEL_MAINLINE"
    ;;
  all)
    audit_kunit_source "$KERNEL_6_18" "$KERNEL_MAINLINE"
    check_cross_tree_identity
    check_kunit_manifest "$KERNEL_6_18"
    check_kunit_manifest "$KERNEL_MAINLINE"
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
