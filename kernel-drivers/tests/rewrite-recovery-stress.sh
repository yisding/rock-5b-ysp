#!/usr/bin/env bash
# Exercise rewrite reset/recovery boundaries around real userspace workloads.
#
# This harness is intentionally orchestration-only: it does not invent synthetic
# register jobs. Point RECOVERY_WORKLOAD_CMD at an MPP/RGA workload that is known
# to keep hardware busy on the target board, then run close/kill, reset-opener,
# and optionally unbind/rebind cycles around it.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
# shellcheck source=suite-common.sh disable=SC1091
source "$TEST_DIR/suite-common.sh"
# shellcheck source=debugfs-counters.sh disable=SC1091
source "$TEST_DIR/debugfs-counters.sh"

CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$REPO_ROOT/../rockchip-conformance"}
PROFILE=${PROFILE:-rewrite}
RUN_ID=${RUN_ID:-$(date +%Y%m%d-%H%M%S)}
OUT=${OUT:-"$CONFORMANCE_ROOT/logs/$PROFILE/$RUN_ID-recovery-stress"}
RECOVERY_VALIDATE_ONLY=${RECOVERY_VALIDATE_ONLY:-0}
RECOVERY_CASES=${RECOVERY_CASES:-kill}
RECOVERY_LOOPS=${RECOVERY_LOOPS:-3}
RECOVERY_GRACE_S=${RECOVERY_GRACE_S:-2}
RECOVERY_TERM_GRACE_S=${RECOVERY_TERM_GRACE_S:-2}
RECOVERY_CASE_TIMEOUT=${RECOVERY_CASE_TIMEOUT:-300}
# Expand PROFILE/TEST_DIR inside the child bash that runs each configured command.
# shellcheck disable=SC2016
RECOVERY_WORKLOAD_CMD=${RECOVERY_WORKLOAD_CMD:-'PROFILE="$PROFILE" RUN_SYSTEM_INFO=0 RUN_ABI_REPLAY=0 RUN_COMPARE=0 bash "$TEST_DIR/rewrite-conformance-run.sh"'}
# shellcheck disable=SC2016
RECOVERY_RECHECK_CMD=${RECOVERY_RECHECK_CMD:-'bash "$TEST_DIR/abi-probe.sh"'}
# shellcheck disable=SC2016
RECOVERY_RESET_CMD=${RECOVERY_RESET_CMD:-'IOCTL_FUZZ_ITERS=16 IOCTL_FUZZ_TIMEOUT=30 bash "$TEST_DIR/ioctl-fuzz-smoke.sh"'}
RECOVERY_UNBIND_TARGETS=${RECOVERY_UNBIND_TARGETS:-}
RECOVERY_LIST_BINDINGS=${RECOVERY_LIST_BINDINGS:-0}
RECOVERY_DMESG_FATAL_RE=${RECOVERY_DMESG_FATAL_RE:-'KASAN|BUG:|kernel BUG|Oops|Unable to handle kernel|use-after-free|slab-out-of-bounds|general protection fault|hung task|blocked for more than|RCU stall|lockdep|DMA-API.*(error|WARNING)'}

export TEST_DIR REPO_ROOT CONFORMANCE_ROOT PROFILE

usage()
{
	cat <<EOF
Usage: RECOVERY_WORKLOAD_CMD='<busy workload>' bash $0

Environment:
  RECOVERY_VALIDATE_ONLY=1       device-free script/config validation
  RECOVERY_CASES="kill reset"    cases: kill, reset, unbind, list-bindings
  RECOVERY_WORKLOAD_CMD=...      busy workload command run in its own process group
  RECOVERY_RECHECK_CMD=...       post-case liveness command, default abi-probe.sh
  RECOVERY_RESET_CMD=...         command run while workload is active for reset-opener stress
  RECOVERY_UNBIND_TARGETS=...    space-separated driver:device specs, opt-in only
  RECOVERY_LOOPS=3               iterations per selected case
  OUT=...                        log directory

Examples:
  RECOVERY_WORKLOAD_CMD='PROFILE=rewrite RUN_COUNTER_CHECKS=1 bash "$TEST_DIR/rewrite-conformance-run.sh"' bash $0
  RECOVERY_CASES='list-bindings' bash $0
  RECOVERY_CASES='unbind' RECOVERY_UNBIND_TARGETS='rockchip-rga-rewrite:fdb70000.rga' bash $0
EOF
}

log()
{
	printf "%s\n" "$*"
}

have_device_nodes()
{
	[ -e /dev/mpp_service ] || [ -e /dev/rga ]
}

validate_uint()
{
	local name=$1
	local value=$2

	case "$value" in
	''|*[!0-9]*)
		printf "%s must be an unsigned integer, got '%s'\n" \
			"$name" "$value" >&2
		return 1
		;;
	esac
}

validate_cases()
{
	local case_name

	validate_uint RECOVERY_LOOPS "$RECOVERY_LOOPS" || return 1
	validate_uint RECOVERY_CASE_TIMEOUT "$RECOVERY_CASE_TIMEOUT" || return 1

	for case_name in $RECOVERY_CASES; do
		case "$case_name" in
		kill|reset|unbind|list-bindings)
			;;
		*)
			printf "unknown RECOVERY_CASES entry '%s'\n" "$case_name" >&2
			return 1
			;;
		esac
	done

	return 0
}

driver_dir()
{
	printf "/sys/bus/platform/drivers/%s" "$1"
}

list_bindings()
{
	local driver
	local dir
	local entry
	local name

	for driver in rk-mpp-rewrite-hw rockchip-rga-rewrite; do
		dir=$(driver_dir "$driver")
		[ -d "$dir" ] || continue
		for entry in "$dir"/*; do
			[ -e "$entry" ] || continue
			name=$(basename "$entry")
			case "$name" in
			bind|unbind|uevent|module)
				continue
				;;
			esac
			[ -e "$entry/driver" ] || continue
			printf "%s:%s\n" "$driver" "$name"
		done
	done
}

snap_dmesg()
{
	local target=$1

	dmesg > "$target" 2>/dev/null || :
}

dmesg_faults()
{
	local before=$1
	local after=$2

	comm -13 <(sort "$before") <(sort "$after") 2>/dev/null |
		grep -aiE "$RECOVERY_DMESG_FATAL_RE" || true
}

run_shell_cmd()
{
	local name=$1
	local cmd=$2
	local log_file=$3
	local rc

	timeout "$RECOVERY_CASE_TIMEOUT" bash -c "$cmd" > "$log_file" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ]; then
		log "  $name rc=$rc log=$log_file"
		tail -n 12 "$log_file" | sed 's/^/    /'
	fi
	return "$rc"
}

start_workload()
{
	local log_file=$1
	local pid_file=$2

	setsid bash -c "$RECOVERY_WORKLOAD_CMD" > "$log_file" 2>&1 &
	local pid=$!
	printf "%s\n" "$pid" > "$pid_file"
}

terminate_workload()
{
	local pid=$1
	local rc

	if ! kill -0 "$pid" 2>/dev/null; then
		wait "$pid"
		rc=$?
		return "$rc"
	fi

	kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
	sleep "$RECOVERY_TERM_GRACE_S"
	if kill -0 "$pid" 2>/dev/null; then
		kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
	fi
	wait "$pid"
	rc=$?
	return "$rc"
}

run_recheck()
{
	local case_dir=$1

	run_shell_cmd "post-case recheck" "$RECOVERY_RECHECK_CMD" \
		"$case_dir/recheck.log"
}

run_kill_case()
{
	local case_dir=$1
	local pid
	local rc

	start_workload "$case_dir/workload.log" "$case_dir/workload.pid"
	pid=$(cat "$case_dir/workload.pid")
	sleep "$RECOVERY_GRACE_S"
	terminate_workload "$pid"
	rc=$?
	printf "%s\n" "$rc" > "$case_dir/workload.status"

	case "$rc" in
	0)
		log "  workload exited before kill; increase RECOVERY_GRACE_S or use a longer workload"
		return 1
		;;
	143|137|130|124)
		return 0
		;;
	*)
		# Shells encode signal exits as 128+signo, but a workload may report a
		# private shutdown code after SIGTERM. Keep the log and let recheck/dmesg
		# decide whether recovery succeeded.
		log "  workload terminated with rc=$rc"
		return 0
		;;
	esac
}

run_reset_case()
{
	local case_dir=$1
	local pid
	local reset_rc

	start_workload "$case_dir/workload.log" "$case_dir/workload.pid"
	pid=$(cat "$case_dir/workload.pid")
	sleep "$RECOVERY_GRACE_S"
	run_shell_cmd "reset-opener stress" "$RECOVERY_RESET_CMD" \
		"$case_dir/reset.log"
	reset_rc=$?
	terminate_workload "$pid"
	printf "%s\n" "$reset_rc" > "$case_dir/reset.status"
	return "$reset_rc"
}

unbind_one()
{
	local spec=$1
	local driver=${spec%%:*}
	local device=${spec#*:}
	local dir

	if [ "$driver" = "$spec" ] || [ -z "$driver" ] || [ -z "$device" ]; then
		printf "invalid unbind target '%s'; expected driver:device\n" "$spec" >&2
		return 2
	fi

	dir=$(driver_dir "$driver")
	if [ ! -w "$dir/unbind" ] || [ ! -w "$dir/bind" ]; then
		printf "missing writable bind/unbind for %s\n" "$driver" >&2
		return 2
	fi
	if [ ! -e "$dir/$device" ]; then
		printf "device %s is not bound to %s\n" "$device" "$driver" >&2
		return 2
	fi

	printf "%s" "$device" > "$dir/unbind"
	sleep "$RECOVERY_GRACE_S"
	printf "%s" "$device" > "$dir/bind"
}

run_unbind_case()
{
	local case_dir=$1
	local pid
	local spec
	local ret=0

	if [ -z "$RECOVERY_UNBIND_TARGETS" ]; then
		log "  no RECOVERY_UNBIND_TARGETS set; available bindings:"
		list_bindings | sed 's/^/    /'
		return 2
	fi

	start_workload "$case_dir/workload.log" "$case_dir/workload.pid"
	pid=$(cat "$case_dir/workload.pid")
	sleep "$RECOVERY_GRACE_S"
	for spec in $RECOVERY_UNBIND_TARGETS; do
		log "  unbind/rebind $spec"
		if ! unbind_one "$spec" > "$case_dir/unbind-${spec//[:\/]/_}.log" 2>&1; then
			ret=1
			cat "$case_dir/unbind-${spec//[:\/]/_}.log" >&2
		fi
	done
	terminate_workload "$pid"
	return "$ret"
}

run_case_once()
{
	local case_name=$1
	local loop=$2
	local case_dir="$OUT/$case_name-$loop"
	local before="$case_dir/dmesg-before.txt"
	local after="$case_dir/dmesg-after.txt"
	local faults
	local start
	local end
	local rc=0
	local recheck_rc=0

	mkdir -p "$case_dir"
	log "================= $case_name loop $loop ================="
	snap_dmesg "$before"
	start=$(suite_now_ns)

	case "$case_name" in
	kill)
		run_kill_case "$case_dir" || rc=$?
		;;
	reset)
		run_reset_case "$case_dir" || rc=$?
		;;
	unbind)
		run_unbind_case "$case_dir" || rc=$?
		;;
	esac

	run_recheck "$case_dir" || recheck_rc=$?
	end=$(suite_now_ns)
	snap_dmesg "$after"
	faults=$(dmesg_faults "$before" "$after")
	if [ -n "$faults" ]; then
		printf "%s\n" "$faults" > "$case_dir/dmesg-fatal.txt"
		log "  fatal dmesg signatures:"
		printf "%s\n" "$faults" | sed 's/^/    /' | head -n 20
		rc=1
	fi

	log "  elapsed=$(suite_elapsed_s "$start" "$end")s rc=$rc recheck_rc=$recheck_rc"
	if [ "$recheck_rc" -ne 0 ]; then
		rc=1
	fi
	printf "%s\n" "$rc" > "$case_dir/result.status"
	return "$rc"
}

if [ "$#" -gt 0 ]; then
	case "$1" in
	-h|--help)
		usage
		exit 0
		;;
	esac
fi

validate_cases || exit 2

if [ "$RECOVERY_VALIDATE_ONLY" = "1" ]; then
	log "recovery stress validation passed"
	log "cases	$RECOVERY_CASES"
	log "workload	$RECOVERY_WORKLOAD_CMD"
	log "recheck	$RECOVERY_RECHECK_CMD"
	log "reset	$RECOVERY_RESET_CMD"
	exit 0
fi

if [ "$RECOVERY_LIST_BINDINGS" = "1" ] ||
   [ "$RECOVERY_CASES" = "list-bindings" ]; then
	list_bindings
	exit 0
fi

if ! have_device_nodes; then
	log "SKIP: /dev/mpp_service and /dev/rga are absent on this boot"
	exit 77
fi

mkdir -p "$OUT"
debugfs_counter_snapshot "$OUT/counters-before.tsv" \
	mpp /sys/kernel/debug/rk_mpp_rewrite \
	rga /sys/kernel/debug/rk_rga_rewrite \
	rga_userptr_iommu /sys/kernel/debug/rk_rga_rewrite/route_b

overall=0
for loop in $(seq 1 "$RECOVERY_LOOPS"); do
	for case_name in $RECOVERY_CASES; do
		case "$case_name" in
		list-bindings)
			list_bindings | tee "$OUT/bindings.txt"
			;;
		*)
			run_case_once "$case_name" "$loop" || overall=1
			;;
		esac
	done
done

debugfs_counter_snapshot "$OUT/counters-after.tsv" \
	mpp /sys/kernel/debug/rk_mpp_rewrite \
	rga /sys/kernel/debug/rk_rga_rewrite \
	rga_userptr_iommu /sys/kernel/debug/rk_rga_rewrite/route_b
debugfs_counter_delta "$OUT/counters-before.tsv" "$OUT/counters-after.tsv" \
	"$OUT/counters-delta.tsv"
dmesg | tail -n 500 > "$OUT/dmesg-tail.txt" 2>/dev/null || true

log "================= result ================="
log "logs: $OUT"
if [ "$overall" -eq 0 ]; then
	log "recovery stress cases passed"
else
	log "recovery stress cases failed"
fi
exit "$overall"
