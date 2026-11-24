#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
#
# Run the two rewrite KUnit suites in a virtual arm64 "virt" machine.
#
# The committed HEAD of a rewrite kernel tree is exported to a scratch source
# tree, built into a minimal kernel by that tree's own kunit.py, and booted
# under QEMU with KVM, so every case executes without a package or a reboot of
# the board.  A warm run takes well under a minute.  It proves nothing about
# hardware: no RK3588 device probes in the guest, and the cases only ever touch
# their own fixtures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROCK5B_WORKSPACE="${ROCK5B_WORKSPACE:-$REPO_ROOT/../rock-5b}"
QEMU_ROOT="${KUNIT_QEMU_ROOT:-$ROCK5B_WORKSPACE/build/qemu-userland/root}"
ACCEL="${KUNIT_QEMU_ACCEL:-kvm}"
RAW_NESTING="${KUNIT_QEMU_RAW_NESTING:-0}"
KASAN="${KUNIT_QEMU_KASAN:-0}"
JOBS="${JOBS:-$(nproc)}"
LOCKNEST_PATCH="$SCRIPT_DIR/../patches/debug-kernel/0002-lockdep-make-PROVE_RAW_LOCK_NESTING-prompt-uncondit.patch"

QEMU_PACKAGES=(
  qemu-system-arm qemu-system-common qemu-system-data
  libpmem1 librdmacm1t64 libslirp0 libaio1t64 liburing2 libndctl6 libdaxctl1
)

usage() {
  cat <<EOF
Usage: ${0##*/} <kernel-tree> [kunit.py filter glob ...]
       ${0##*/} --install-qemu

  <kernel-tree>   git checkout of a rewrite line.  Its committed HEAD is what
                  runs; uncommitted changes are ignored, and the checkout
                  itself is not touched.

Environment:
  KUNIT_QEMU_ACCEL        kvm (default) or tcg.  kvm needs read/write access to
                          /dev/kvm (membership of the kvm group) and fails
                          rather than fall back.  tcg is software emulation.
  KUNIT_QEMU_SMP          guest CPUs (default: the pinned host CPUs under kvm,
                          2 under tcg)
  KUNIT_QEMU_RAW_NESTING  0 (default) builds the way the debug kernel does:
                          PROVE_RAW_LOCK_NESTING off, so lockdep stays alive
                          for the whole run.  1 leaves the checker on; that is
                          the exit gate of the minimal hard-IRQ plan.
  KUNIT_QEMU_KASAN=1      add generic KASAN (a separate, slower build)
  KUNIT_QEMU_LABEL        names the build directory (default: the branch name)
  KUNIT_QEMU_BUILD_DIR    build directory (default:
                          \$ROCK5B_WORKSPACE/build/rewrite-kunit-qemu/<label>)
  KUNIT_QEMU_ROOT         unpacked QEMU used when qemu-system-aarch64 is not on
                          PATH (default: \$ROCK5B_WORKSPACE/build/qemu-userland/root)
  ROCK5B_WORKSPACE        grouped board workspace (default: ../rock-5b)
  JOBS                    make parallelism (default: nproc)
  CCACHE_DIR              compiler cache (default: ~/Code/.ccache)

--install-qemu downloads the distribution's QEMU packages with "apt download"
and unpacks them into KUNIT_QEMU_ROOT with "dpkg -x".  It needs no root.

Under kvm the guest is pinned to the host's largest-capacity CPU cluster: a
guest CPU that migrates between unlike cores of a big.LITTLE SoC is not
supported by KVM.

Exit status: 0 when every case passes and the console is quiet; kunit.py's
status when a case fails; 3 when every case passes but the console holds a
kernel warning, lockdep report or sanitizer report; 4 when lockdep was turned
off during the run.
EOF
}

die() {
  echo "${0##*/}: $*" >&2
  exit 1
}

install_qemu() {
  local debs="$QEMU_ROOT/../debs"

  command -v dpkg >/dev/null 2>&1 || die "dpkg is required"
  mkdir -p "$debs" "$QEMU_ROOT"
  (cd "$debs" && apt download "${QEMU_PACKAGES[@]}")
  for deb in "$debs"/*.deb; do
    dpkg -x "$deb" "$QEMU_ROOT"
  done
  use_qemu_root
  qemu-system-aarch64 --version | head -n 1
  echo "installed under $QEMU_ROOT"
}

use_qemu_root() {
  export PATH="$QEMU_ROOT/usr/bin:$PATH"
  export LD_LIBRARY_PATH="$QEMU_ROOT/usr/lib/aarch64-linux-gnu:$QEMU_ROOT/lib/aarch64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  qemu_data_dir="$QEMU_ROOT/usr/share/qemu"
}

# The host CPUs with the largest capacity, as a taskset list.
big_cluster() {
  local cpu cap max=0 list=

  for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -r "$cpu/cpu_capacity" ] || continue
    cap="$(cat "$cpu/cpu_capacity")"
    if [ "$cap" -gt "$max" ]; then
      max="$cap"
      list="${cpu##*cpu}"
    elif [ "$cap" -eq "$max" ]; then
      list="$list,${cpu##*cpu}"
    fi
  done
  printf '%s\n' "$list"
}

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 2
fi
case "$1" in
-h | --help)
  usage
  exit 0
  ;;
--install-qemu)
  install_qemu
  exit 0
  ;;
esac

tree="$(cd "$1" && pwd)"
shift

qemu_data_dir=
if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
  [ -x "$QEMU_ROOT/usr/bin/qemu-system-aarch64" ] ||
    die "no qemu-system-aarch64 on PATH or under $QEMU_ROOT; run ${0##*/} --install-qemu"
  use_qemu_root
fi
git -C "$tree" rev-parse --verify HEAD >/dev/null 2>&1 ||
  die "not a git checkout: $tree"

commit="$(git -C "$tree" rev-parse --short=12 HEAD)"
label="${KUNIT_QEMU_LABEL:-$(git -C "$tree" rev-parse --abbrev-ref HEAD)}"
label="${label//[^A-Za-z0-9._-]/_}"
build_dir="${KUNIT_QEMU_BUILD_DIR:-$ROCK5B_WORKSPACE/build/rewrite-kunit-qemu/$label}"
export CCACHE_DIR="${CCACHE_DIR:-$HOME/Code/.ccache}"

pin=()
case "$ACCEL" in
kvm)
  [ -r /dev/kvm ] && [ -w /dev/kvm ] ||
    die "no read/write access to /dev/kvm; join the kvm group, or set KUNIT_QEMU_ACCEL=tcg"
  cluster="$(big_cluster)"
  if [ -n "$cluster" ]; then
    pin=(taskset -c "$cluster")
    default_smp="$(awk -F, '{ print NF }' <<<"$cluster")"
  else
    default_smp=2
  fi
  ;;
tcg)
  default_smp=2
  ;;
*)
  die "KUNIT_QEMU_ACCEL must be kvm or tcg"
  ;;
esac
smp="${KUNIT_QEMU_SMP:-$default_smp}"

# Export the committed HEAD.  A private index keeps the export incremental, so
# an unchanged file keeps its timestamp and make rebuilds only what moved; the
# checkout's own index and working tree are never touched.
src="$build_dir/src"
mkdir -p "$src"
GIT_INDEX_FILE="$build_dir/export.index" \
  git -C "$tree" --work-tree="$src" read-tree --reset -u HEAD
if [ "$RAW_NESTING" != 0 ] &&
   patch -d "$src" -p1 --reverse --dry-run --silent \
     <"$LOCKNEST_PATCH" >/dev/null 2>&1; then
  patch -d "$src" -p1 --reverse --silent <"$LOCKNEST_PATCH"
fi
[ -f "$src/tools/testing/kunit/kunit.py" ] || die "not a kernel tree: $tree"

config="$build_dir/rewrite.kunitconfig"
cat >"$config" <<'EOF'
CONFIG_KUNIT=y
CONFIG_SMP=y
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
if [ "$RAW_NESTING" = 0 ]; then
  # arm64 hides this option's prompt and forces it on; the debug kernel
  # carries the same patch for the same reason.
  # The export only rewrites files that changed between tips, so the patch
  # from an earlier run is usually still in place.
  if ! patch -d "$src" -p1 --reverse --dry-run --silent \
      <"$LOCKNEST_PATCH" >/dev/null 2>&1; then
    patch -d "$src" -p1 --forward --silent <"$LOCKNEST_PATCH" ||
      die "the locknest prompt patch does not apply to $tree @ $commit"
  fi
  echo '# CONFIG_PROVE_RAW_LOCK_NESTING is not set' >>"$config"
fi
if [ "$KASAN" = 1 ]; then
  printf 'CONFIG_KASAN=y\nCONFIG_KASAN_GENERIC=y\n' >>"$config"
fi

# Instrumentation changes the whole build, so each variant keeps its own
# output directory.
out="$build_dir/out-nest$RAW_NESTING-kasan$KASAN"
log="$build_dir/console-nest$RAW_NESTING-kasan$KASAN.log"

qemu_args="-m 2G -smp $smp"
[ -z "$qemu_data_dir" ] || qemu_args="-L $qemu_data_dir $qemu_args"

echo "source: $tree @ $commit  accel: $ACCEL  smp: $smp${pin[*]:+  pinned: ${pin[*]:2}}"
rc=0
(
  cd "$src"
  # Build on every host CPU; only the guest is pinned.
  python3 tools/testing/kunit/kunit.py build --arch=arm64 \
    --build_dir="$out" --kunitconfig="$config" --jobs="$JOBS" \
    --make_options 'CC=ccache gcc' --make_options 'HOSTCC=ccache gcc' &&
    "${pin[@]}" python3 tools/testing/kunit/kunit.py exec --arch=arm64 \
      --build_dir="$out" --timeout=3600 \
      --qemu_args="$qemu_args" --raw_output=all "$@"
) >"$log" 2>&1 || rc=$?

grep -E '^# Totals:|^(not )?ok [0-9]+ ' "$log" || true
echo "console: $log"
if [ "$rc" -ne 0 ]; then
  grep -E '^\s*not ok |error:|ERROR' "$log" | head -n 40 >&2 || true
  exit "$rc"
fi

# kunit.py lists KVM first and falls back silently; make sure it did not.
if [ "$ACCEL" = kvm ] && ! grep -q 'KVM: hypervisor services detected' "$log"; then
  die "KVM was requested but the guest did not run under it; see $log"
fi

# kunit.py reports cases, not the kernel log around them.
if grep -E 'WARNING:|BUG:|Oops|Unable to handle kernel|ODEBUG:|KASAN:|UBSAN:|refcount_t:' \
    "$log" >&2; then
  echo "kernel reports found in a passing run; see $log" >&2
  exit 3
fi
if grep -q 'DEBUG_LOCKS_WARN_ON\|lockdep is turned off\|turning off the locking correctness validator' "$log"; then
  echo "lockdep was turned off during the run; see $log" >&2
  exit 4
fi
echo "PASS: every case passed with no kernel report ($label @ $commit, $ACCEL)"
