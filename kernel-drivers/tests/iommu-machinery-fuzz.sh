#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# =============================================================================
# iommu-machinery-fuzz.sh -- exercise the WHOLE RK3588 IOMMU surface and check
# it stays correct under stress. Not just the RGA userptr-IOMMU fallback: it
# drives both IOMMU providers on the SoC at once.
#
#   * rockchip-iommu.c  masters: RGA3 scattered userptr, and the
#                        RKVDEC/VP9/H26x video-codec cores via MPP.
#   * vsi-iommu.c        master: the standalone AV1 decoder (verisilicon IOMMU).
#
# Each phase pairs a CORRECTNESS ORACLE with FAULT/LEAK monitoring:
#   A) RGA   -- rga-iommu-fuzz forces scattered userptr so the driver-owned
#               IOMMU remap path runs, then checks the result byte-for-byte.
#   B) DECODE-- decode-differential.sh: HW decode vs SW reference, PASS iff PSNR=inf
#               (bit-exact) for H264/H265/VP9/AV1. AV1 is the vsi-iommu path.
#   C) CONCURRENT -- run A and a multi-instance AV1 decode together so both IOMMU
#               providers are mapping/unmapping simultaneously (cross-domain races).
#
# Every phase brackets dmesg + available debugfs counters; the run FAILS on any
# IOMMU page fault, correctness mismatch, or leaked mapping (active gauge not
# back to baseline). Rewrite kernels expose MPP/RGA aggregate counters and RGA
# userptr-IOMMU gauges; some forward-port debug builds also expose provider-level counters.
# Without counters the dmesg fault scan is the backstop.
#
# Usage: iommu-machinery-fuzz.sh [-n rga_iters] [-L loops] [-p A|B|C|ABC]
#   env: RGA_ITERS, DECODE_LOOPS, PHASES, OUT, SUDO
# =============================================================================
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
# shellcheck source=suite-common.sh disable=SC1091
source "$TEST_DIR/suite-common.sh"
: "${SUITE_DMESG_FATAL_RE:?suite-common.sh did not load; the kernel-log fatal scan would be silently blind}"
# shellcheck source=debugfs-counters.sh disable=SC1091
source "$TEST_DIR/debugfs-counters.sh"
: "${DEBUGFS_COUNTERS_LOADED:?debugfs-counters.sh did not load; the counter/leak check would be silently absent}"

ROCK5B_WORKSPACE=${ROCK5B_WORKSPACE:-"$REPO_ROOT/../rock-5b"}
CONFORMANCE_ROOT="${CONFORMANCE_ROOT:-$ROCK5B_WORKSPACE/build/rockchip-conformance}"
LRGA="${LRGA:-$CONFORMANCE_ROOT/sources/airockchip-librga}"
LIBRGA_LIBDIR="${LIBRGA_LIBDIR:-}"
MPP_BUILD="${MPP_BUILD:-/usr}"
AV1_IVF="${AV1_IVF:-$CONFORMANCE_ROOT/assets/test_av1.ivf}"
CXX="${CXX:-g++}"
PKG_CONFIG="${PKG_CONFIG:-pkg-config}"
IOMMU_FUZZ_VALIDATE_BUILD="${IOMMU_FUZZ_VALIDATE_BUILD:-0}"
IOMMU_FUZZ_REQUIRE_RGA_USERPTR_IOMMU_COUNTERS="${IOMMU_FUZZ_REQUIRE_RGA_USERPTR_IOMMU_COUNTERS:-${IOMMU_FUZZ_REQUIRE_ROUTE_B_COUNTERS:-0}}"
tmp_out=
if [ "$IOMMU_FUZZ_VALIDATE_BUILD" = "1" ] &&
   [ -z "${OUT+x}" ]; then
  tmp_out="$(mktemp -d "${TMPDIR:-/tmp}/rkcompat-iommu-fuzz.XXXXXX")"
  OUT="$tmp_out"
  trap 'rm -rf "$tmp_out"' EXIT
else
  OUT="${OUT:-$CONFORMANCE_ROOT/logs/iommu-machinery/$(date +%Y%m%d-%H%M%S)}"
fi
RGA_ITERS="${RGA_ITERS:-64}"
DECODE_LOOPS="${DECODE_LOOPS:-1}"
PHASES="${PHASES:-ABC}"

while [ "$#" -gt 0 ]; do case "$1" in
  -n) RGA_ITERS="$2"; shift 2;; -L) DECODE_LOOPS="$2"; shift 2;;
  -p) PHASES="$2"; shift 2;; *) echo "unknown arg: $1"; exit 2;; esac; done

# `-p Z` selected no phase, ran nothing, and printed "ALL PHASES CLEAN" with exit
# 0. Phases are matched by glob below, so an unrecognised letter is silently inert.
if [ -z "${PHASES//[ABC]/}" ] && [ -n "$PHASES" ]; then
  :
else
  echo "PHASES must be a non-empty subset of A, B, C -- got '$PHASES'" >&2
  exit 2
fi

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  SUDO_CMD=()
elif [[ -v SUDO ]]; then
  read -r -a SUDO_CMD <<< "$SUDO"
else
  SUDO_CMD=(sudo)
fi
mkdir -p "$OUT"
FUZZ="$OUT/rga-iommu-fuzz"

LIBRGA_CFLAGS=()
LIBRGA_LIBS=()
if [ -n "$LIBRGA_LIBDIR" ]; then
  LIBRGA_CFLAGS=(-I"$LRGA/include")
  LIBRGA_LIBS=(-L"$LIBRGA_LIBDIR" "-Wl,-rpath,$LIBRGA_LIBDIR" -lrga)
elif "$PKG_CONFIG" --exists librga; then
  read -r -a LIBRGA_CFLAGS <<< "$("$PKG_CONFIG" --cflags librga)"
  read -r -a LIBRGA_LIBS <<< "$("$PKG_CONFIG" --libs librga)"
elif [ "$IOMMU_FUZZ_VALIDATE_BUILD" = "1" ]; then
  # Device-free repository validation needs only the public headers.
  LIBRGA_CFLAGS=(-I"$LRGA/include")
else
  echo "Missing installed librga development package; install librga-dev or set LIBRGA_LIBDIR." >&2
  exit 2
fi

if [ "$IOMMU_FUZZ_VALIDATE_BUILD" = "1" ]; then
  "$CXX" -std=gnu++17 -O2 -Wall -Wextra \
      "${LIBRGA_CFLAGS[@]}" \
      -c "$TEST_DIR/rga-iommu-fuzz.cpp" \
      -o "$OUT/rga-iommu-fuzz.o" \
      2> "$OUT/rga-iommu-fuzz-build.log" || {
        cat "$OUT/rga-iommu-fuzz-build.log" >&2
        exit 1
      }
  echo "PASS: RGA IOMMU fuzzer builds"
  exit 0
fi

# Debugfs dirs that hold rewrite counters and optional forward-port debug counters.
COUNTER_DIRS=(
  mpp_rewrite          /sys/kernel/debug/rk_mpp_rewrite
  rga_rewrite          /sys/kernel/debug/rk_rga_rewrite
  rga_rewrite_userptr_iommu         /sys/kernel/debug/rk_rga_rewrite/userptr_iommu
  rga_rewrite_userptr_iommu_legacy  /sys/kernel/debug/rk_rga_rewrite/route_b
  rkrga_userptr_iommu               /sys/kernel/debug/rkrga/userptr_iommu
  rkrga_userptr_iommu_legacy        /sys/kernel/debug/rkrga/route_b
  rk_iommu_debug       /sys/kernel/debug/rockchip-iommu
  vsi_iommu_debug      /sys/kernel/debug/vsi-iommu
)
# dmesg lines that indicate a real IOMMU/DMA/decode fault (vs benign probe noise).
# Canonical fatal set (sourced above) plus the harness-specific alternatives this
# fuzzer needs. The generic terms this replaced ("iommu.*fault", bare "DMA-API")
# were simultaneously blind to KASAN and to "RGA current status: bus error", and
# matched benign binding lines such as "iommu: Default domain type: Translated".
FAULT_RE="$SUITE_DMESG_FATAL_RE|vsi.?iommu|swiotlb.*(full|buffer is full)|rga_job_err|RGA_INT|hardware error|mpp.*(error|timeout)|rkvdec.*error|av1.*error"
BENIGN_RE='deferred probe|driver is not ready|not registered'

log() { echo "$@"; }
# Swallowing dmesg failure made both snapshots empty, so `comm -13` found nothing
# and every phase reported "no IOMMU/DMA faults in dmesg delta" -- while this
# script's header promises the run FAILS on any IOMMU page fault and calls the
# dmesg scan "the backstop". Readability is asserted once, up front, instead.
snap_dmesg() { "${SUDO_CMD[@]}" dmesg 2>/dev/null > "$1" || : ; }
require_readable_dmesg() {
  local probe
  probe=$(mktemp)
  if ! "${SUDO_CMD[@]}" dmesg > "$probe" 2>/dev/null || [ ! -s "$probe" ]; then
    rm -f "$probe"
    log "  FATAL: cannot read dmesg (kernel.dmesg_restrict?), so the fault backstop"
    log "  would scan an empty delta and report every phase clean. Run under sudo."
    exit 1
  fi
  rm -f "$probe"
}
dmesg_faults() { # before after -> prints offending lines (0 = clean)
  local b="$1" a="$2"
  comm -13 <(sort "$b") <(sort "$a") 2>/dev/null \
    | grep -aiE "$FAULT_RE" | grep -aivE "$BENIGN_RE" || true
}
counter_delta_sum() { # delta-file counter-name [component-regex]
  local file="$1" counter="$2" component_re="${3:-.*}"
  awk -F'\t' -v c="$counter" -v re="$component_re" '
    NR > 1 && $1 ~ re && $2 == c && $5 ~ /^-?[0-9]+$/ {
      sum += $5; seen = 1
    }
    END { print seen ? sum : 0 }
  ' "$file"
}
counter_after_sum() { # delta-file counter-name [component-regex]
  local file="$1" counter="$2" component_re="${3:-.*}"
  awk -F'\t' -v c="$counter" -v re="$component_re" '
    NR > 1 && $1 ~ re && $2 == c && $4 ~ /^-?[0-9]+$/ {
      sum += $4; seen = 1
    }
    END { print seen ? sum : 0 }
  ' "$file"
}
rga_userptr_iommu_counter_rows() {
  awk -F'\t' 'NR > 1 && $1 ~ /(route_b|userptr_iommu)/ { n++ } END { print n + 0 }' "$1"
}
counter_row_count() { # delta-file counter-name [component-regex]
  local file="$1" counter="$2" component_re="${3:-.*}"
  awk -F'\t' -v c="$counter" -v re="$component_re" '
    NR > 1 && $1 ~ re && $2 == c { n++ }
    END { print n + 0 }
  ' "$file"
}
rga_userptr_iommu_counter_filter='(route_b|userptr_iommu)'

check_rga_userptr_iommu_coverage() { # counters-delta.tsv
  local delta_file="$1"
  local rows attempt_delta ok_delta active_after active_rows failures

  case "$PHASES" in
    *A*|*C*) ;;
    *) return 0 ;;
  esac

  rows=$(rga_userptr_iommu_counter_rows "$delta_file")
  if [ "$rows" -eq 0 ]; then
    if [ "$IOMMU_FUZZ_REQUIRE_RGA_USERPTR_IOMMU_COUNTERS" = "1" ]; then
      log "  !! RGA userptr-IOMMU counters required but no debugfs counters were captured"
      overall=1
    else
      log "  (no RGA userptr-IOMMU counters captured; RGA correctness+dmesg checks passed, but fallback attribution is indirect)"
    fi
    return 0
  fi

  attempt_delta=$(counter_delta_sum "$delta_file" attempt "$rga_userptr_iommu_counter_filter")
  ok_delta=$(counter_delta_sum "$delta_file" ok "$rga_userptr_iommu_counter_filter")
  active_after=$(counter_after_sum "$delta_file" active "$rga_userptr_iommu_counter_filter")
  active_rows=$(counter_row_count "$delta_file" active "$rga_userptr_iommu_counter_filter")
  failures=$((attempt_delta - ok_delta))

  if [ "$attempt_delta" -le 0 ]; then
    log "  !! RGA userptr-IOMMU counters present but attempt did not increase"
    overall=1
  fi
  if [ "$ok_delta" -le 0 ]; then
    log "  !! RGA userptr-IOMMU counters present but ok did not increase"
    overall=1
  fi
  if [ "$failures" -ne 0 ]; then
    log "  !! RGA userptr-IOMMU failures recorded: attempt_delta=$attempt_delta ok_delta=$ok_delta"
    overall=1
  fi
  if [ "$active_rows" -le 0 ]; then
    log "  !! RGA userptr-IOMMU counters present but active gauge was not captured"
    overall=1
  fi
  if [ "$active_after" -ne 0 ]; then
    log "  !! RGA userptr-IOMMU active mappings remain after run: active=$active_after"
    overall=1
  fi
  if [ "$attempt_delta" -gt 0 ] && [ "$ok_delta" -gt 0 ] &&
     [ "$failures" -eq 0 ] && [ "$active_rows" -gt 0 ] &&
     [ "$active_after" -eq 0 ]; then
    log "  RGA userptr-IOMMU attribution: attempt_delta=$attempt_delta ok_delta=$ok_delta active=$active_after"
  fi
}

check_rga_shadow_coverage() { # counters-delta.tsv
  local delta_file="$1"
  local rows head_after tail_after failures copy_to copy_from

  case "$PHASES" in
    *A*|*C*) ;;
    *) return 0 ;;
  esac

  rows=$(counter_row_count "$delta_file" shadow_copy_to_bytes '^rga_rewrite$')
  [ "$rows" -gt 0 ] || return 0

  head_after=$(counter_after_sum "$delta_file" shadow_head_active_count '^rga_rewrite$')
  tail_after=$(counter_after_sum "$delta_file" shadow_tail_active_count '^rga_rewrite$')
  failures=$(counter_delta_sum "$delta_file" shadow_setup_failure_count '^rga_rewrite$')
  copy_to=$(counter_delta_sum "$delta_file" shadow_copy_to_bytes '^rga_rewrite$')
  copy_from=$(counter_delta_sum "$delta_file" shadow_copy_from_bytes '^rga_rewrite$')

  if [ "$copy_to" -le 0 ] || [ "$copy_from" -le 0 ]; then
    log "  !! RGA shadow counters present but boundary copies were not exercised: to=$copy_to from=$copy_from"
    overall=1
  fi
  if [ "$head_after" -ne 0 ] || [ "$tail_after" -ne 0 ]; then
    log "  !! RGA shadow views remain active: head=$head_after tail=$tail_after"
    overall=1
  fi
  if [ "$failures" -ne 0 ]; then
    log "  !! RGA shadow setup failures recorded: delta=$failures"
    overall=1
  fi
  if [ "$copy_to" -gt 0 ] && [ "$copy_from" -gt 0 ] &&
     [ "$head_after" -eq 0 ] && [ "$tail_after" -eq 0 ] &&
     [ "$failures" -eq 0 ]; then
    log "  RGA shadow attribution: copy_to=$copy_to copy_from=$copy_from head=$head_after tail=$tail_after failures=$failures"
  fi
}

# ---------------------------------------------------------------- preflight ---
log "================= preflight ================="
log "  kernel: $(uname -r) $(uname -v | grep -oE '#[0-9]+')"
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  log "  NOTE: not root -- dmesg fault scan uses '$([ "${#SUDO_CMD[@]}" -gt 0 ] && echo "${SUDO_CMD[*]}" || echo none)', but the"
  log "        debugfs counter/leak snapshot is read directly and needs root. For full"
  log "        coverage+leak signal, run the whole script as root: sudo $0 $*"
fi
if grep -qm1 'rga_dma_check_iova_span' /proc/kallsyms 2>/dev/null; then
  log "  RGA userptr-IOMMU fallback: present (rga_dma_check_iova_span in kallsyms)"
else
  log "  RGA userptr-IOMMU fallback: NOT DETECTED in running kernel symbols -- RGA scatter phase may fail closed"
fi
for f in /dev/rga /dev/mpp_service; do [ -e "$f" ] && log "  $f: ok" || log "  $f: MISSING"; done

# Build the RGA fuzzer.
if [ ! -x "$FUZZ" ] || [ "$TEST_DIR/rga-iommu-fuzz.cpp" -nt "$FUZZ" ]; then
  log "  building rga-iommu-fuzz ..."
  "$CXX" -std=gnu++17 -O2 -Wall "${LIBRGA_CFLAGS[@]}" \
      "$TEST_DIR/rga-iommu-fuzz.cpp" \
      "${LIBRGA_LIBS[@]}" -lpthread -o "$FUZZ" \
      2> "$OUT/fuzz-build.log" || { log "  BUILD FAILED (see $OUT/fuzz-build.log)"; exit 1; }
fi
if [ -n "$LIBRGA_LIBDIR" ]; then
  export LD_LIBRARY_PATH="$LIBRGA_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# ---------------------------------------------------------------- baseline ----
require_readable_dmesg
debugfs_counter_snapshot "$OUT/counters-before.tsv" "${COUNTER_DIRS[@]}"
grep -E 'MemFree|MemAvailable|Slab' /proc/meminfo > "$OUT/meminfo-before.txt"
"${SUDO_CMD[@]}" sh -c 'ls -d /sys/kernel/iommu_groups/*/devices/* 2>/dev/null' \
  > "$OUT/iommu-topology.txt" 2>/dev/null || true

overall=0
run_phase() { # name  logfile  cmd...
  local name="$1" lf="$2"; shift 2
  local b="$OUT/dmesg-$name-before.txt" a="$OUT/dmesg-$name-after.txt"
  log "================= phase $name ================="
  snap_dmesg "$b"
  local t0 t1; t0=$(suite_now_ns)
  "$@" > "$lf" 2>&1; local rc=$?
  t1=$(suite_now_ns)
  snap_dmesg "$a"
  local faults; faults=$(dmesg_faults "$b" "$a")
  log "  cmd rc=$rc  elapsed=$(suite_elapsed_s "$t0" "$t1")s  log=$lf"
  if [ -n "$faults" ]; then
    log "  !! IOMMU/DMA FAULTS during $name:"; echo "$faults" | sed 's/^/     /' | head -20
    echo "$faults" > "$OUT/faults-$name.txt"; overall=1
  else
    log "  no IOMMU/DMA faults in dmesg delta"
  fi
  [ $rc -eq 0 ] || { log "  phase $name FAILED (rc=$rc) -- tail:"; tail -8 "$lf" | sed 's/^/     /'; overall=1; }
  return 0
}

# ---------------------------------------------------------------- phase A ----
if [[ "$PHASES" == *A* ]]; then
  run_phase A-rga-scatter "$OUT/A-rga.log" \
    "$FUZZ" -n "$RGA_ITERS" -o all -t both -s 1
fi

# ---------------------------------------------------------------- phase B ----
# decode-differential.sh writes to its own $OUT; scope that override to the child
# so it doesn't clobber the orchestrator's $OUT (used for dmesg brackets).
decode_once() { OUT="$1" MPP_BUILD="$MPP_BUILD" bash "$TEST_DIR/decode-differential.sh"; }
if [[ "$PHASES" == *B* ]]; then
  for l in $(seq 1 "$DECODE_LOOPS"); do
    mkdir -p "$OUT/decode-$l"
    run_phase "B-decode-$l" "$OUT/B-decode-$l.log" decode_once "$OUT/decode-$l"
  done
fi

# ---------------------------------------------------------------- phase C ----
# Cross-domain: RGA scatter (rockchip-iommu) + multi-instance AV1 (vsi-iommu) together.
if [[ "$PHASES" == *C* ]]; then
  log "================= phase C (concurrent cross-domain) ================="
  cb="$OUT/dmesg-C-before.txt"; ca="$OUT/dmesg-C-after.txt"; snap_dmesg "$cb"
  # mpi_dec_test loops the input to reach -n frames -> sustained AV1 (vsi-iommu)
  # load running concurrently with RGA scattered maps (rockchip-iommu).
  DEC="$MPP_BUILD/bin/mpi_dec_test"
  ( "$FUZZ" -n "$((RGA_ITERS * 2))" -o all -t both -s 7 > "$OUT/C-rga.log" 2>&1 ) & p1=$!
  ( "$DEC" -i "$AV1_IVF" -t 16777224 -w 640 -h 480 \
      -n 600 -o /dev/null > "$OUT/C-av1.log" 2>&1 ) & p2=$!
  wait $p1; rc1=$?; wait $p2; rc2=$?
  snap_dmesg "$ca"
  cf=$(dmesg_faults "$cb" "$ca")
  log "  rga rc=$rc1  av1 rc=$rc2"
  [ $rc1 -eq 0 ] || { log "  concurrent RGA FAILED"; tail -6 "$OUT/C-rga.log" | sed 's/^/     /'; overall=1; }
  [ $rc2 -eq 0 ] || { log "  concurrent AV1 FAILED"; tail -6 "$OUT/C-av1.log" | sed 's/^/     /'; overall=1; }
  if [ -n "$cf" ]; then log "  !! FAULTS during concurrent phase:"; echo "$cf" | sed 's/^/     /' | head
    echo "$cf" > "$OUT/faults-C.txt"; overall=1; else log "  no IOMMU/DMA faults in dmesg delta"; fi
fi

# ---------------------------------------------------------------- teardown ---
log "================= post: counters + leak check ================="
debugfs_counter_snapshot "$OUT/counters-after.tsv" "${COUNTER_DIRS[@]}"
debugfs_counter_delta "$OUT/counters-before.tsv" "$OUT/counters-after.tsv" "$OUT/counters-delta.tsv"
if [ "$(wc -l < "$OUT/counters-delta.tsv" 2>/dev/null || echo 0)" -gt 1 ]; then
  log "  counter deltas (instrumented kernel):"; sed 's/^/    /' "$OUT/counters-delta.tsv"
  # active gauges must return to baseline (delta 0) -> otherwise a mapping leaked.
  leaked=$(awk -F'\t' 'NR>1 && $2 ~ /active/ && $5 != 0 && $5 != "" {print}' "$OUT/counters-delta.tsv")
  [ -z "$leaked" ] || { log "  !! LEAKED MAPPINGS (active gauge != baseline):"; echo "$leaked" | sed 's/^/     /'; overall=1; }
  check_rga_userptr_iommu_coverage "$OUT/counters-delta.tsv"
  check_rga_shadow_coverage "$OUT/counters-delta.tsv"
else
  # No counters in the delta. Three very different causes -- don't conflate them:
  #   (1) ran non-root: /sys/kernel/debug is 0700 root, so the snapshot read nothing
  #       (the per-command $SUDO is only used for dmesg, NOT the debugfs snapshot).
  #   (2) root, dirs exist, genuinely zero deltas (unlikely after phase A).
  #   (3) root but dirs absent: no rewrite or optional provider debugfs counters.
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log "  (no counters read -- /sys/kernel/debug is root-only; run the WHOLE script as root:"
    log "     sudo $0 ${*:-}   -- per-command sudo does NOT expose the debugfs snapshot)"
  elif "${SUDO_CMD[@]}" test -d /sys/kernel/debug/rkrga/userptr_iommu 2>/dev/null ||
       "${SUDO_CMD[@]}" test -d /sys/kernel/debug/rk_rga_rewrite/userptr_iommu 2>/dev/null ||
       "${SUDO_CMD[@]}" test -d /sys/kernel/debug/rkrga/route_b 2>/dev/null ||
       "${SUDO_CMD[@]}" test -d /sys/kernel/debug/rk_rga_rewrite/route_b 2>/dev/null; then
    log "  (instrumentation present but no counter deltas this run)"
  else
    log "  (no debugfs counters in this kernel. Correctness+dmesg-fault checks still valid;"
    log "     provider-level counters are optional forward-port debug instrumentation.)"
  fi
  if [ "$IOMMU_FUZZ_REQUIRE_RGA_USERPTR_IOMMU_COUNTERS" = "1" ] &&
     { [[ "$PHASES" == *A* ]] || [[ "$PHASES" == *C* ]]; }; then
    log "  !! RGA userptr-IOMMU counters required but no counter deltas were captured"
    overall=1
  fi
fi
grep -E 'MemFree|MemAvailable|Slab' /proc/meminfo > "$OUT/meminfo-after.txt"

log "================= result ================="
log "  logs: $OUT"
[ $overall -eq 0 ] && log "  ALL PHASES CLEAN (correct output, no IOMMU faults, no leaks)" \
                   || log "  FAILURES DETECTED -- inspect faults-*.txt / *.log above"
exit $overall
