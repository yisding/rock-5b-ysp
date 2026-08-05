#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# Validate the RK3588 IEP2 forward port and exercise real deinterlacing output.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
ROCK5B_WORKSPACE="${ROCK5B_WORKSPACE:-$ROOT_DIR/../rock-5b}"
KERNEL_TREE="${KERNEL_TREE:-$ROCK5B_WORKSPACE/kernel/linux-6.18-rkvenc-av1-fwport}"
BUILD_DIR="${BUILD_DIR:-$TEST_DIR/.build/iep2-smoke}"

IEP2_VALIDATE_ONLY="${IEP2_VALIDATE_ONLY:-0}"
IEP2_VALIDATE_BUILD="${IEP2_VALIDATE_BUILD:-0}"
IEP2_REQUIRE_DMESG="${IEP2_REQUIRE_DMESG:-0}"
IEP2_LOOPS="${IEP2_LOOPS:-1}"
IEP2_WIDTH="${IEP2_WIDTH:-320}"
IEP2_HEIGHT="${IEP2_HEIGHT:-240}"
IEP2_FRAMES="${IEP2_FRAMES:-6}"
IEP2_TIMEOUT="${IEP2_TIMEOUT:-30}"
MPP_BUILD="${MPP_BUILD:-$ROCK5B_WORKSPACE/build/rockchip-conformance/build/rockchip-mpp-suite}"
MPP_LIBDIR="${MPP_LIBDIR:-}"

die() {
  echo "FAIL: $*" >&2
  exit 1
}

skip() {
  echo "SKIP: $*" >&2
  exit 77
}

require_source_match() {
  local pattern="$1"
  local path="$2"
  local description="$3"

  grep -Eq "$pattern" "$path" || die "missing $description in $path"
}

validate_source() {
  local driver="$KERNEL_TREE/drivers/video/rockchip/mpp/mpp_iep2.c"
  local regs="$KERNEL_TREE/drivers/video/rockchip/mpp/rockchip_iep2_regs.h"
  local base_dtsi="$KERNEL_TREE/arch/arm64/boot/dts/rockchip/rk3588-base.dtsi"
  local board_dtsi="$KERNEL_TREE/arch/arm64/boot/dts/rockchip/rk3588-rock-5b.dtsi"

  [[ -f "$driver" ]] || die "IEP2 driver missing: $driver"
  [[ -f "$regs" ]] || die "IEP2 register definitions missing: $regs"
  require_source_match 'ROCKCHIP_MPP_IEP2' \
    "$KERNEL_TREE/drivers/video/rockchip/mpp/Kconfig" "IEP2 Kconfig option"
  require_source_match 'ROCKCHIP_MPP_IEP2.*mpp_iep2\.o' \
    "$KERNEL_TREE/drivers/video/rockchip/mpp/Makefile" "IEP2 build wiring"
  require_source_match 'req->size != sizeof\(task->params\)' \
    "$driver" "exact parameter request-size validation"
  require_source_match 'req->size != sizeof\(task->output\)' \
    "$driver" "exact result request-size validation"
  require_source_match 'min_t\(u32, task->output.dect_osd_cnt' \
    "$driver" "hardware OSD count clamp"
  require_source_match 'IEP2 does not accept untranslated DMA addresses' \
    "$driver" "raw-IOVA rejection"
  require_source_match 'msgs->flags & MPP_FLAGS_REG_NO_OFFSET' \
    "$driver" "task-local address encoding"
  require_source_match 'span > mem_region->len - offset' \
    "$driver" "full DMA span validation"
  require_source_match 'spin_lock_irqsave\(&mpp->queue->running_lock' \
    "$driver" "current-task lifetime locking"
  require_source_match 'mpp_iommu_reserve_iova' \
    "$driver" "auxiliary IOVA reservation"
  require_source_match 'reserve_iova_exclusive' \
    "$KERNEL_TREE/drivers/video/rockchip/mpp/mpp_iommu.c" \
    "exclusive fixed-IOVA ownership"
  require_source_match 'mpp_iommu_quiesce_fault_handler' \
    "$KERNEL_TREE/drivers/video/rockchip/mpp/mpp_common.c" \
    "fault callback quiescence before device exit"
  require_source_match 'cancel_delayed_work_sync\(&mpp_task->timeout_work\)' \
    "$KERNEL_TREE/drivers/video/rockchip/mpp/mpp_common.c" \
    "timeout callback drain before task completion"
  require_source_match 'rockchip_iommu_sync_fault_handler' \
    "$KERNEL_TREE/drivers/iommu/rockchip-iommu.c" \
    "Rockchip IOMMU fault callback synchronization"
  require_source_match 'suppress_bind_attrs = true' \
    "$KERNEL_TREE/drivers/video/rockchip/mpp/mpp_service.c" \
    "MPP service hot-unbind suppression"
  require_source_match 'rockchip,iep-v2' "$base_dtsi" "RK3588 IEP2 node"
  require_source_match 'fdbb0800' "$base_dtsi" "RK3588 IEP2 IOMMU node"
  require_source_match '^&iep \{' "$board_dtsi" "ROCK 5B IEP2 enablement"
  require_source_match '^&iep_mmu \{' "$board_dtsi" "ROCK 5B IEP2 IOMMU enablement"

  echo "PASS: IEP2 source, ABI guards, and RK3588/ROCK 5B DT wiring are present"

  if [[ "$IEP2_VALIDATE_BUILD" == 1 ]]; then
    [[ -f "$KERNEL_TREE/.config" ]] || die "kernel .config missing for build validation"
    grep -qx 'CONFIG_ROCKCHIP_MPP_IEP2=y' "$KERNEL_TREE/.config" ||
      die "CONFIG_ROCKCHIP_MPP_IEP2=y is not enabled"
    "${MAKE:-make}" -C "$KERNEL_TREE" -j "${JOBS:-$(nproc)}" \
      drivers/video/rockchip/mpp/ \
      drivers/iommu/iova.o \
      drivers/iommu/rockchip-iommu.o \
      drivers/iommu/vsi-iommu.o \
      rockchip/rk3588-rock-5b.dtb
    [[ -s "$KERNEL_TREE/drivers/video/rockchip/mpp/mpp_iep2.o" ]] ||
      die "mpp_iep2.o was not built"
    ar t "$KERNEL_TREE/drivers/video/rockchip/mpp/built-in.a" |
      grep -Eq '(^|/)drivers/video/rockchip/mpp/mpp_iep2\.o$' ||
      die "mpp_iep2.o is absent from the linked MPP archive"
    echo "PASS: IEP2 object, linked MPP archive, and ROCK 5B DTB build"
  fi
}

find_iep2_test() {
  local candidate
  local candidates=(
    "${IEP2_TEST:-}"
    "$MPP_BUILD/mpp/vproc/iep2/test/iep2_test"
    "$MPP_BUILD/bin/iep2_test"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  command -v iep2_test 2>/dev/null || return 1
}

generate_input() {
  local order="$1"
  local output="$2"
  local mode

  command -v ffmpeg >/dev/null 2>&1 ||
    skip "ffmpeg is needed to generate deterministic interlaced input"
  if [[ "$order" == TFF ]]; then
    mode=interleave_top
  else
    mode=interleave_bottom
  fi
  ffmpeg -nostdin -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=${IEP2_WIDTH}x${IEP2_HEIGHT}:rate=50" \
    -vf "tinterlace=mode=$mode" -frames:v "$IEP2_FRAMES" \
    -pix_fmt yuv420p -f rawvideo -y "$output"
}

run_case() {
  local test_bin="$1"
  local order="$2"
  local input="$3"
  local iteration="$4"
  local input_size frame_size input_frames expected output_size
  local output="$BUILD_DIR/${order,,}-${iteration}.nv12"
  local log="$BUILD_DIR/${order,,}-${iteration}.log"
  local -a command_line

  frame_size=$((IEP2_WIDTH * IEP2_HEIGHT * 3 / 2))
  input_size="$(stat -c %s "$input")"
  (( input_size % frame_size == 0 )) || die "$input is not whole yuv420p frames"
  input_frames=$((input_size / frame_size))
  (( input_frames >= 3 )) || die "$input needs at least three frames"
  expected=$(((input_frames - 2) * 2 * frame_size))

  command_line=(
    "$test_bin" -w "$IEP2_WIDTH" -h "$IEP2_HEIGHT"
    -c yuv420p -i "$input" -C yuv420sp -o "$output" -f "$order"
  )
  if command -v timeout >/dev/null 2>&1; then
    command_line=(timeout "$IEP2_TIMEOUT" "${command_line[@]}")
  fi

  if [[ -n "$MPP_LIBDIR" ]]; then
    LD_LIBRARY_PATH="$MPP_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      "${command_line[@]}" >"$log" 2>&1 ||
      die "$order iteration $iteration failed; see $log"
  else
    "${command_line[@]}" >"$log" 2>&1 ||
      die "$order iteration $iteration failed; see $log"
  fi

  [[ -f "$output" ]] || die "$order iteration $iteration produced no output"
  output_size="$(stat -c %s "$output")"
  [[ "$output_size" -eq "$expected" ]] ||
    die "$order iteration $iteration output size $output_size, expected $expected"
  if cmp -n "$expected" -s "$output" /dev/zero; then
    die "$order iteration $iteration output is all zero"
  fi

  printf 'PASS: %s iteration %d output=%s sha256=%s\n' \
    "$order" "$iteration" "$output" "$(sha256sum "$output" | awk '{print $1}')"
}

validate_source
if [[ "$IEP2_VALIDATE_ONLY" == 1 ]]; then
  exit 0
fi

[[ -r /proc/device-tree/compatible ]] || skip "device-tree identity unavailable"
grep -azq 'rockchip,rk3588' /proc/device-tree/compatible || skip "not running on RK3588"
[[ -e /dev/mpp_service ]] || skip "/dev/mpp_service is absent"
[[ -r /proc/mpp_service/supports-device ]] || skip "MPP device inventory is absent"
grep -Eq 'DEVICE\[[[:space:]]*28\]:IEP2' /proc/mpp_service/supports-device ||
  skip "the booted kernel does not advertise IEP2 client 28"

for platform_device in fdbb0000.iep fdbb0800.iommu; do
  device_path="/sys/bus/platform/devices/$platform_device"
  [[ -d "$device_path" ]] || die "platform device $platform_device is missing"
  [[ -L "$device_path/driver" ]] || die "platform device $platform_device is unbound"
  echo "BOUND: $platform_device -> $(basename "$(readlink "$device_path/driver")")"
done

test_bin="$(find_iep2_test)" || skip "iep2_test was not found; set IEP2_TEST or MPP_BUILD"
mkdir -p "$BUILD_DIR"

tff_input="${IEP2_INPUT:-$BUILD_DIR/tff-${IEP2_WIDTH}x${IEP2_HEIGHT}.yuv}"
bff_input="${IEP2_BFF_INPUT:-$BUILD_DIR/bff-${IEP2_WIDTH}x${IEP2_HEIGHT}.yuv}"
[[ -n "${IEP2_INPUT:-}" ]] || generate_input TFF "$tff_input"
[[ -n "${IEP2_BFF_INPUT:-}" ]] || generate_input BFF "$bff_input"
[[ -r "$tff_input" ]] || die "TFF input is unreadable: $tff_input"
[[ -r "$bff_input" ]] || die "BFF input is unreadable: $bff_input"

kernel_log_backend=""
if dmesg --color=never >/dev/null 2>&1; then
  kernel_log_backend=dmesg
elif journalctl -k -q --no-pager >/dev/null 2>&1; then
  kernel_log_backend=journalctl
fi

capture_kernel_log() {
  case "$kernel_log_backend" in
  dmesg) dmesg --color=never ;;
  journalctl) journalctl -k -q --no-pager -o short-monotonic ;;
  *) return 1 ;;
  esac
}

dmesg_available=0
if capture_kernel_log >"$BUILD_DIR/dmesg-before.log" 2>/dev/null; then
  dmesg_available=1
  echo "KERNEL LOG: scanning via $kernel_log_backend"
elif [[ "$IEP2_REQUIRE_DMESG" == 1 ]]; then
  die "kernel log is unreadable via dmesg or journalctl; rerun with sufficient privilege"
else
  echo "DEGRADED: kernel log is unreadable; fault scanning is unavailable" >&2
fi

for ((iteration = 1; iteration <= IEP2_LOOPS; iteration++)); do
  run_case "$test_bin" TFF "$tff_input" "$iteration"
  run_case "$test_bin" BFF "$bff_input" "$iteration"
done

if [[ "$dmesg_available" == 1 ]]; then
  capture_kernel_log >"$BUILD_DIR/dmesg-after.log"
  before_lines="$(wc -l <"$BUILD_DIR/dmesg-before.log")"
  tail -n "+$((before_lines + 1))" "$BUILD_DIR/dmesg-after.log" \
    >"$BUILD_DIR/dmesg-new.log"
  fatal_re='BUG:|Oops:|kernel panic|KASAN:|use-after-free|out-of-bounds|IEP2 IOMMU fault|fault addr|rk_vcodec.*(time out|bus error)|reset recovery failed'
  if grep -Eiq "$fatal_re" "$BUILD_DIR/dmesg-new.log"; then
    grep -Ein "$fatal_re" "$BUILD_DIR/dmesg-new.log" >&2 || true
    die "kernel fault signature found; see $BUILD_DIR/dmesg-new.log"
  fi
  echo "PASS: no new IEP2/IOMMU/timeout/kernel-fatal dmesg signature"
fi

echo "PASS: RK3588 IEP2 TFF/BFF I5O2 functional smoke"
