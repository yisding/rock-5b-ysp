#!/usr/bin/env bash
# Run the consumer-facing RK3588 codec/RGA smoke suite against the driver that
# currently owns /dev/mpp_service and /dev/rga.
#
# This is the acceptance gate for the clean-room rewrite track: boot a kernel
# with ROCKCHIP_MPP_REWRITE + ROCKCHIP_RGA_REWRITE enabled, then run this script
# with the same MPP/ffmpeg artifacts used for the forward-port validation.
#
# Exit 0  = all selected consumer workloads passed
# Exit 77 = hardware driver nodes are not present on this boot
# Exit 1+ = environment or workload failure
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
ROCK5B_WORKSPACE=${ROCK5B_WORKSPACE:-"$REPO_ROOT/../rock-5b"}
CONFORMANCE_ROOT="${CONFORMANCE_ROOT:-$ROCK5B_WORKSPACE/rockchip-conformance}"

RUN_DECODE="${RUN_DECODE:-1}"
RUN_ENCODE="${RUN_ENCODE:-1}"
RUN_TRANSCODE="${RUN_TRANSCODE:-1}"
RUN_ABI="${RUN_ABI:-1}"
RUN_LIBRGA="${RUN_LIBRGA:-0}"
RUN_GSTREAMER="${RUN_GSTREAMER:-0}"
MPP_BUILD="${MPP_BUILD:-$CONFORMANCE_ROOT/out/mpp}"
FFDIR="${FFDIR:-$ROCK5B_WORKSPACE/ffmpeg/ffmpeg-rockchip}"
STAGE="${STAGE:-/usr}"
IN="${IN:-$CONFORMANCE_ROOT/assets/ffmpeg-generated/ffmpeg-h264-1920x1080-30fps-2s.h264}"
H264_IN="${H264_IN:-$CONFORMANCE_ROOT/assets/gstreamer-generated/generated-input-h264-320x240-30_1-30.h264}"
H265_IN="${H265_IN:-$CONFORMANCE_ROOT/assets/gstreamer-generated/generated-input-h265-320x240-30_1-30.h265}"
export MPP_BUILD FFDIR STAGE IN H264_IN H265_IN

ok() { printf '  OK   %s\n' "$*"; }
no() { printf '  MISS %s\n' "$*"; }

have_node() {
  [ -c "$1" ]
}

print_counter_dir() {
  local label="$1" dir="$2"
  local file

  [ -d "$dir" ] || return 0

  echo "  ${label}: $dir"
  for file in "$dir"/*; do
    [ -f "$file" ] || continue
    case "$(basename "$file")" in
      *_count|hw_support|hw_total_ns*|hw_max_ns*)
        printf '    %-24s %s\n' "$(basename "$file"):" "$(cat "$file" 2>/dev/null || echo '?')"
        ;;
    esac
  done
}

print_driver_snapshot() {
  local phase="$1"

  echo "================= driver snapshot: ${phase} ================="
  echo "  kernel: $(uname -r)"

  if [ -d /sys/kernel/debug/rk_mpp_rewrite ] ||
     [ -d /sys/kernel/debug/rk_rga_rewrite ]; then
    echo "  rewrite debugfs counters:"
    print_counter_dir "mpp" /sys/kernel/debug/rk_mpp_rewrite
    print_counter_dir "rga" /sys/kernel/debug/rk_rga_rewrite
  else
    echo "  rewrite debugfs counters: not present"
  fi

  if [ -d /proc/mpp_service ]; then
    echo "  /proc/mpp_service:"
    find /proc/mpp_service -maxdepth 1 -mindepth 1 -printf '    %f\n' 2>/dev/null | sort
  else
    echo "  /proc/mpp_service: not present"
  fi

  if [ -e /sys/kernel/debug/rkrga/load ]; then
    echo "  forward-port rkrga load:"
    sed 's/^/    /' /sys/kernel/debug/rkrga/load 2>/dev/null | head -5
  fi
  echo
}

preflight_devices() {
  local missing=0

  echo "================= device preflight ================="
  if have_node /dev/mpp_service; then ok "/dev/mpp_service"; else no "/dev/mpp_service"; missing=1; fi
  if have_node /dev/rga; then ok "/dev/rga"; else no "/dev/rga"; missing=1; fi
  echo

  if [ "$missing" -ne 0 ]; then
    echo "SKIP: codec/RGA device nodes are absent on this boot."
    echo "      Boot a forward-port kernel or a rewrite-enabled kernel, then rerun:"
    echo "      sudo MPP_BUILD=<mpp-build> FFDIR=<ffmpeg-rockchip> STAGE=<stage> bash $0"
    exit 77
  fi
}

preflight_artifacts() {
  local fail=0
  local mpp_lib="$MPP_BUILD/lib"
  local mpp_dec="$MPP_BUILD/bin/mpi_dec_test"
  local mpp_enc="$MPP_BUILD/bin/mpi_enc_test"

  echo "================= artifact preflight ================="
  if [ "$RUN_DECODE" = 1 ] || [ "$RUN_ENCODE" = 1 ]; then
    [ -d "$mpp_lib" ] || mpp_lib="$MPP_BUILD/mpp"
    [ -x "$mpp_dec" ] || mpp_dec="$MPP_BUILD/test/mpi_dec_test"
    [ -x "$mpp_enc" ] || mpp_enc="$MPP_BUILD/test/mpi_enc_test"
    if [ -x "$mpp_dec" ]; then ok "$mpp_dec"; else no "$mpp_dec"; fail=1; fi
    if [ -x "$mpp_enc" ]; then ok "$mpp_enc"; else no "$mpp_enc"; fail=1; fi
    if [ -d "$mpp_lib" ]; then ok "$mpp_lib"; else no "$mpp_lib"; fail=1; fi
    if [ "$RUN_DECODE" = 1 ]; then
      if [ -f "$H264_IN" ]; then ok "$H264_IN"; else no "$H264_IN"; fail=1; fi
      if [ -f "$H265_IN" ]; then ok "$H265_IN"; else no "$H265_IN"; fail=1; fi
    fi
  fi

  if [ "$RUN_TRANSCODE" = 1 ]; then
    if [ -x "$FFDIR/ffmpeg" ]; then ok "$FFDIR/ffmpeg"; else no "$FFDIR/ffmpeg"; fail=1; fi
    if [ -x "$FFDIR/ffprobe" ]; then ok "$FFDIR/ffprobe"; else no "$FFDIR/ffprobe"; fail=1; fi
    if [ -f "$IN" ]; then ok "$IN"; else no "$IN"; fail=1; fi
  fi
  echo

  [ "$fail" -eq 0 ] || {
    echo "Missing userspace artifacts. Build/stage MPP and ffmpeg-rockchip first."
    exit 1
  }
}

run_step() {
  local name="$1"
  shift

  echo "================= ${name} ================="
  "$@"
  local rc=$?
  echo
  if [ "$rc" -ne 0 ]; then
    echo "${name} FAILED with exit code ${rc}"
    exit "$rc"
  fi
}

preflight_devices

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root for the full gate; encode/transcode need dmesg and device access."
  exit 1
fi

preflight_artifacts
print_driver_snapshot "before"

[ "$RUN_ABI" = 1 ] && run_step "ABI: non-submit ioctl/session/import/config probe" bash "$TEST_DIR/abi-probe.sh"
[ "$RUN_LIBRGA" = 1 ] && run_step "librga: im2d copy/resize/fill" bash "$TEST_DIR/librga-smoke.sh"
[ "$RUN_GSTREAMER" = 1 ] && run_step "gstreamer: mpp/rga plugin pipelines" bash "$TEST_DIR/gstreamer-suite.sh"
[ "$RUN_DECODE" = 1 ] && run_step "decode: mpi_dec_test" bash "$TEST_DIR/test-decode.sh"
[ "$RUN_ENCODE" = 1 ] && run_step "encode: mpi_enc_test" bash "$TEST_DIR/encode-test-tiny.sh"
[ "$RUN_TRANSCODE" = 1 ] && run_step "transcode: ffmpeg-rockchip + scale_rkrga" bash "$TEST_DIR/transcode-test.sh"

print_driver_snapshot "after"

echo "ALL SELECTED REWRITE/FORWARD-PORT CONSUMER SMOKE TESTS PASSED"
