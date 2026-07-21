#!/usr/bin/env bash
# Narrowed KASAN reproduction of the 2026-07-17 forward-port preflight Oops:
# ABI replay (MPP/RGA session churn, including MPP_CMD_RESET_SESSION) followed
# by a one-shot recursive /proc/mpp_service snapshot. On the KASAN+ramoops debug
# kernel this isolates the reset-session double-free (finding
# 2026-07-18-mpp-reset-session-dma-double-free-kasan.md, fixed by forward-port
# patch 0042). Pass = empty kernel-log-flags.txt.
#
# Must run on the KASAN/ramoops debug kernel; see
# kernel-drivers/docs/debug-kernel.md.
set -uo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
# shellcheck source=kasan-scan.sh disable=SC1091
source "$TEST_DIR/kasan-scan.sh"

CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$REPO_ROOT/../rockchip-conformance"}
PROFILE=${PROFILE:-"$(uname -r)"}
TS=$(date +%Y%m%d-%H%M%S)
OUT=${OUT:-"$CONFORMANCE_ROOT/logs/forward-port/$TS-kasan-narrowed"}

log() { printf '%s %s\n' "$(date +%T)" "$*"; }

kasan_scan_begin "$OUT"

log "phase=abi-replay start"
set +e
PROFILE="kasan-narrowed-$TS" bash "$TEST_DIR/abi-replay.sh" \
	> "$OUT/abi-replay.log" 2>&1
abi_status=$?
set -e
log "phase=abi-replay done status=$abi_status (a non-zero ABI contract result is not itself a memory finding)"

# Flush everything before the operation that crashed the original run.
sync
log "phase=procfs-snapshot start (risky step on an unfixed kernel)"
snap="$OUT/mpp-procfs-snapshot.txt"
: > "$snap"
find /proc/mpp_service -maxdepth 2 -type f 2>/dev/null | sort | while IFS= read -r f; do
	printf -- "-- %s --\n" "$f" >> "$snap"
	cat "$f" >> "$snap" 2>/dev/null || true
done
log "phase=procfs-snapshot done"

flags=$(kasan_scan_end "$OUT") && clean=1 || clean=0
log "phase=scan done flagged_kernel_lines=$flags clean=$clean"
echo "RESULT abi_status=$abi_status flagged_kernel_lines=$flags clean=$clean out=$OUT"

[ "$clean" -eq 1 ] || exit 1
