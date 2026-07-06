#!/usr/bin/env bash
# =============================================================================
# iommu-machinery-fuzz.sh -- exercise the WHOLE RK3588 IOMMU surface and check
# it stays correct under stress. Not just RGA Route B: it drives both IOMMU
# providers on the SoC at once.
#
#   * rockchip-iommu.c  masters: RGA3 (scattered userptr / Route B), and the
#                        RKVDEC/VP9/H26x video-codec cores via MPP.
#   * vsi-iommu.c        master: the standalone AV1 decoder (verisilicon IOMMU).
#
# Each phase pairs a CORRECTNESS ORACLE with FAULT/LEAK monitoring:
#   A) RGA   -- rga-iommu-fuzz forces scattered userptr (Route B) and checks the
#               result byte-for-byte (absolute for copy, differential for the rest).
#   B) DECODE-- decode-differential.sh: HW decode vs SW reference, PASS iff PSNR=inf
#               (bit-exact) for H264/H265/VP9/AV1. AV1 is the vsi-iommu path.
#   C) CONCURRENT -- run A and a multi-instance AV1 decode together so both IOMMU
#               providers are mapping/unmapping simultaneously (cross-domain races).
#
# Every phase brackets dmesg + available debugfs counters; the run FAILS on any
# IOMMU page fault, correctness mismatch, or leaked mapping (active gauge not
# back to baseline). Rewrite kernels expose MPP/RGA aggregate counters and Route
# B gauges; some forward-port debug builds also expose provider-level counters.
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
# shellcheck source=debugfs-counters.sh disable=SC1091
source "$TEST_DIR/debugfs-counters.sh"

CONFORMANCE_ROOT="${CONFORMANCE_ROOT:-$REPO_ROOT/../rockchip-conformance}"
LRGA="${LRGA:-$CONFORMANCE_ROOT/sources/airockchip-librga}"
LIBRGA_LIBDIR="${LIBRGA_LIBDIR:-$LRGA/libs/Linux/gcc-aarch64}"
MPP_BUILD="${MPP_BUILD:-$CONFORMANCE_ROOT/out/mpp}"
AV1_IVF="${AV1_IVF:-$CONFORMANCE_ROOT/assets/test_av1.ivf}"
CXX="${CXX:-g++}"
IOMMU_FUZZ_VALIDATE_BUILD="${IOMMU_FUZZ_VALIDATE_BUILD:-0}"
IOMMU_FUZZ_REQUIRE_ROUTE_B_COUNTERS="${IOMMU_FUZZ_REQUIRE_ROUTE_B_COUNTERS:-0}"
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

if [ "${EUID:-$(id -u)}" -eq 0 ]; then SUDO_CMD=(); else SUDO_CMD=(${SUDO-sudo}); fi
mkdir -p "$OUT"
FUZZ="$OUT/rga-iommu-fuzz"

if [ "$IOMMU_FUZZ_VALIDATE_BUILD" = "1" ]; then
  "$CXX" -std=gnu++17 -O2 -Wall -Wextra \
      -I"$LRGA/include" \
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
  rga_rewrite_route_b  /sys/kernel/debug/rk_rga_rewrite/route_b
  rkrga_route_b        /sys/kernel/debug/rkrga/route_b
  rk_iommu_debug       /sys/kernel/debug/rockchip-iommu
  vsi_iommu_debug      /sys/kernel/debug/vsi-iommu
)
# dmesg lines that indicate a real IOMMU/DMA/decode fault (vs benign probe noise).
FAULT_RE='rk_iommu|vsi.?iommu|Page fault|iommu.*fault|DMA-API|swiotlb.*(full|buffer is full)|rga_job_err|RGA_INT|hardware error|mpp.*(error|timeout)|rkvdec.*error|av1.*error'
BENIGN_RE='deferred probe|driver is not ready|not registered'

log() { echo "$@"; }
snap_dmesg() { "${SUDO_CMD[@]}" dmesg 2>/dev/null > "$1" || : ; }
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
route_b_counter_rows() {
  awk -F'\t' 'NR > 1 && $1 ~ /route_b/ { n++ } END { print n + 0 }' "$1"
}
counter_row_count() { # delta-file counter-name [component-regex]
  local file="$1" counter="$2" component_re="${3:-.*}"
  awk -F'\t' -v c="$counter" -v re="$component_re" '
    NR > 1 && $1 ~ re && $2 == c { n++ }
    END { print n + 0 }
  ' "$file"
}
check_route_b_coverage() { # counters-delta.tsv
  local delta_file="$1"
  local rows attempt_delta ok_delta active_after active_rows failures

  case "$PHASES" in
    *A*|*C*) ;;
    *) return 0 ;;
  esac

  rows=$(route_b_counter_rows "$delta_file")
  if [ "$rows" -eq 0 ]; then
    if [ "$IOMMU_FUZZ_REQUIRE_ROUTE_B_COUNTERS" = "1" ]; then
      log "  !! Route B counters required but no route_b debugfs counters were captured"
      overall=1
    else
      log "  (no Route B counters captured; RGA correctness+dmesg checks passed, but fallback attribution is indirect)"
    fi
    return 0
  fi

  attempt_delta=$(counter_delta_sum "$delta_file" attempt 'route_b')
  ok_delta=$(counter_delta_sum "$delta_file" ok 'route_b')
  active_after=$(counter_after_sum "$delta_file" active 'route_b')
  active_rows=$(counter_row_count "$delta_file" active 'route_b')
  failures=$((attempt_delta - ok_delta))

  if [ "$attempt_delta" -le 0 ]; then
    log "  !! Route B counters present but attempt did not increase"
    overall=1
  fi
  if [ "$ok_delta" -le 0 ]; then
    log "  !! Route B counters present but ok did not increase"
    overall=1
  fi
  if [ "$failures" -ne 0 ]; then
    log "  !! Route B failures recorded: attempt_delta=$attempt_delta ok_delta=$ok_delta"
    overall=1
  fi
  if [ "$active_rows" -le 0 ]; then
    log "  !! Route B counters present but active gauge was not captured"
    overall=1
  fi
  if [ "$active_after" -ne 0 ]; then
    log "  !! Route B active mappings remain after run: active=$active_after"
    overall=1
  fi
  if [ "$attempt_delta" -gt 0 ] && [ "$ok_delta" -gt 0 ] &&
     [ "$failures" -eq 0 ] && [ "$active_rows" -gt 0 ] &&
     [ "$active_after" -eq 0 ]; then
    log "  Route B attribution: attempt_delta=$attempt_delta ok_delta=$ok_delta active=$active_after"
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
  log "  Route B: present (rga_dma_check_iova_span in kallsyms)"
else
  log "  Route B: NOT DETECTED in running kernel symbols -- RGA scatter phase may fail closed"
fi
for f in /dev/rga /dev/mpp_service; do [ -e "$f" ] && log "  $f: ok" || log "  $f: MISSING"; done

# Build the RGA fuzzer.
if [ ! -x "$FUZZ" ] || [ "$TEST_DIR/rga-iommu-fuzz.cpp" -nt "$FUZZ" ]; then
  log "  building rga-iommu-fuzz ..."
  "$CXX" -std=gnu++17 -O2 -Wall -I"$LRGA/include" "$TEST_DIR/rga-iommu-fuzz.cpp" \
      -L"$LIBRGA_LIBDIR" -Wl,-rpath,"$LIBRGA_LIBDIR" -lrga -lpthread -o "$FUZZ" \
      2> "$OUT/fuzz-build.log" || { log "  BUILD FAILED (see $OUT/fuzz-build.log)"; exit 1; }
fi
export LD_LIBRARY_PATH="$LIBRGA_LIBDIR:${LD_LIBRARY_PATH:-}"

# ---------------------------------------------------------------- baseline ----
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
  ( LD_LIBRARY_PATH="$MPP_BUILD/lib" "$DEC" -i "$AV1_IVF" -t 16777224 -w 640 -h 480 \
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
  check_route_b_coverage "$OUT/counters-delta.tsv"
else
  # No counters in the delta. Three very different causes -- don't conflate them:
  #   (1) ran non-root: /sys/kernel/debug is 0700 root, so the snapshot read nothing
  #       (the per-command $SUDO is only used for dmesg, NOT the debugfs snapshot).
  #   (2) root, dirs exist, genuinely zero deltas (unlikely after phase A).
  #   (3) root but dirs absent: no rewrite or optional provider debugfs counters.
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log "  (no counters read -- /sys/kernel/debug is root-only; run the WHOLE script as root:"
    log "     sudo $0 ${*:-}   -- per-command sudo does NOT expose the debugfs snapshot)"
  elif "${SUDO_CMD[@]}" test -d /sys/kernel/debug/rkrga/route_b 2>/dev/null ||
       "${SUDO_CMD[@]}" test -d /sys/kernel/debug/rk_rga_rewrite/route_b 2>/dev/null; then
    log "  (instrumentation present but no counter deltas this run)"
  else
    log "  (no debugfs counters in this kernel. Correctness+dmesg-fault checks still valid;"
    log "     provider-level counters are optional forward-port debug instrumentation.)"
  fi
  if [ "$IOMMU_FUZZ_REQUIRE_ROUTE_B_COUNTERS" = "1" ] &&
     { [[ "$PHASES" == *A* ]] || [[ "$PHASES" == *C* ]]; }; then
    log "  !! Route B counters required but no counter deltas were captured"
    overall=1
  fi
fi
grep -E 'MemFree|MemAvailable|Slab' /proc/meminfo > "$OUT/meminfo-after.txt"

log "================= result ================="
log "  logs: $OUT"
[ $overall -eq 0 ] && log "  ALL PHASES CLEAN (correct output, no IOMMU faults, no leaks)" \
                   || log "  FAILURES DETECTED -- inspect faults-*.txt / *.log above"
exit $overall
