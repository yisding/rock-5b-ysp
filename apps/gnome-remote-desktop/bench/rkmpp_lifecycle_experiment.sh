#!/usr/bin/env bash
# Build and run the GRD-compatible RKMPP lifecycle A/B experiment while
# sampling interrupts, wait channels, and kernel logs. Artifacts default under
# ~/Code/rkmpp-lifecycle-runs, never /tmp.
set -euo pipefail

BENCH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$BENCH_DIR/../../.." && pwd)
CODE_ROOT=$(cd "$REPO_ROOT/.." && pwd)
SOURCE="$BENCH_DIR/rkmpp_lifecycle_bench.c"
BUILD_DIR=${RKMPP_LIFECYCLE_BUILD_DIR:-"$CODE_ROOT/rkmpp-lifecycle-build"}
OUT_ROOT=${RKMPP_LIFECYCLE_OUT_ROOT:-"$CODE_ROOT/rkmpp-lifecycle-runs"}
CC=${CC:-/usr/bin/cc}
PKG_CONFIG=${PKG_CONFIG:-/usr/bin/pkg-config}
SAMPLE_MS=${RKMPP_LIFECYCLE_SAMPLE_MS:-50}
FULL_SAMPLE_MS=${RKMPP_LIFECYCLE_FULL_SAMPLE_MS:-250}
ALLOW_LIVE_GRD=${RKMPP_LIFECYCLE_ALLOW_LIVE_GRD:-0}
MPP_ENC_DEBUG_MASK=${RKMPP_LIFECYCLE_MPP_ENC_DEBUG:-}

usage()
{
	cat <<EOF
Usage: ${0##*/} [runner options] [compare|reuse|churn|exp2] [bench options]

Build rkmpp_lifecycle_bench, run one lifecycle mode (or the reuse/churn A/B),
and capture RKVENC interrupts, process wait channels, and kernel logs around
the run. The sampler deliberately does not read /proc/mpp_service: vulnerable
drivers can race those procfs reads against session teardown.

Runner options:
  -o DIR          artifact directory (default: $OUT_ROOT/TIMESTAMP)
  --sample-ms N   state sampling period (default: $SAMPLE_MS)
  --full-sample-ms N
                  task status/stack sampling period (default: $FULL_SAMPLE_MS)
  --mpp-enc-debug MASK
                  set libmpp's mpp_enc_debug mask for the worker
  --allow-live-grd
                  run despite a detected gnome-remote-desktop process
  -h, --help      show this help

All remaining options are passed to the C bench. Examples:
  ${0##*/} compare --iterations 1000
  ${0##*/} churn --iterations 10000 --stall-ms 500
  ${0##*/} exp2 --iterations 1000

WARNING: churn and exp2 intentionally stress MPP teardown. They can wedge the
encoder on a vulnerable stack. The watchdog limits the userspace wait, but run
them only with no live RDP session. Root is optional, but provides kernel stacks
and complete dmesg capture.
EOF
}

die()
{
	printf 'ERROR: %s\n' "$*" >&2
	exit 2
}

is_uint()
{
	case "$1" in
	''|*[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

out=
mode=compare
while [ "$#" -gt 0 ]; do
	case "$1" in
	-o)
		[ "$#" -ge 2 ] || die '-o requires a directory'
		out=$2
		shift 2
		;;
	--sample-ms)
		[ "$#" -ge 2 ] || die '--sample-ms requires a value'
		SAMPLE_MS=$2
		shift 2
		;;
	--full-sample-ms)
		[ "$#" -ge 2 ] || die '--full-sample-ms requires a value'
		FULL_SAMPLE_MS=$2
		shift 2
		;;
	--mpp-enc-debug)
		[ "$#" -ge 2 ] || die '--mpp-enc-debug requires a value'
		MPP_ENC_DEBUG_MASK=$2
		shift 2
		;;
	--allow-live-grd)
		ALLOW_LIVE_GRD=1
		shift
		;;
	-h|--help)
		usage
		exit 0
		;;
	compare|reuse|churn|exp2)
		mode=$1
		shift
		break
		;;
	--)
		shift
		break
		;;
	-*)
		break
		;;
	*)
		die "unknown mode: $1"
		;;
	esac
done
bench_args=("$@")

is_uint "$SAMPLE_MS" || die "invalid sample interval: $SAMPLE_MS"
[ "$SAMPLE_MS" -gt 0 ] || die 'sample interval must be positive'
is_uint "$FULL_SAMPLE_MS" || die "invalid full sample interval: $FULL_SAMPLE_MS"
[ "$FULL_SAMPLE_MS" -gt 0 ] || die 'full sample interval must be positive'
if [ -z "$out" ]; then
	out="$OUT_ROOT/$(date +%Y%m%d-%H%M%S)"
fi

active_grd_session()
{
	local line pid args

	while IFS= read -r line; do
		[ -n "$line" ] || continue
		pid=${line%% *}
		args=${line#* }
		case "$args" in
		*' --handover'*) return 0 ;;
		esac
		if find "/proc/$pid/fd" -maxdepth 1 -type l -lname '*mpp_service*' \
			-print -quit 2>/dev/null | grep -q .; then
			return 0
		fi
	done < <(pgrep -af '(^|/)(gnome-remote-desktop(-daemon)?|grd-daemon)([[:space:]]|$)' 2>/dev/null || :)

	if command -v ss >/dev/null 2>&1 &&
		ss -Htn state established 2>/dev/null |
		awk '$4 ~ /:3389$/ || $5 ~ /:3389$/ { found = 1 } END { exit !found }'; then
		return 0
	fi
	return 1
}

if [ "$ALLOW_LIVE_GRD" != 1 ] && active_grd_session; then
	die 'an active RDP/GRD encoder session was detected; disconnect it or pass --allow-live-grd after accepting the risk'
fi

[ -x "$CC" ] || die "compiler not found: $CC"
[ -x "$PKG_CONFIG" ] || die "pkg-config not found: $PKG_CONFIG"
"$PKG_CONFIG" --exists libavcodec libavutil libdrm ||
	die 'install libavcodec-dev, libavutil-dev, and libdrm-dev'

mkdir -p "$BUILD_DIR" "$out"
read -r -a compile_flags <<<"$("$PKG_CONFIG" --cflags libavcodec libavutil libdrm)"
read -r -a link_flags <<<"$("$PKG_CONFIG" --libs libavcodec libavutil libdrm)"
"$CC" -std=gnu11 -O2 -g -Wall -Wextra -Wformat=2 \
	"${compile_flags[@]}" "$SOURCE" -o "$BUILD_DIR/rkmpp_lifecycle_bench" \
	"${link_flags[@]}"

snapshot_tasks()
{
	local parent_pid=$1
	local pid task
	local pids=("$parent_pid")

	while IFS= read -r pid; do
		[ -n "$pid" ] && pids+=("$pid")
	done < <(pgrep -P "$parent_pid" 2>/dev/null || :)

	for pid in "${pids[@]}"; do
		[ -d "/proc/$pid" ] || continue
		printf -- '-- process %s --\n' "$pid"
		awk '/^(Name|State|Pid|PPid|Threads):/' "/proc/$pid/status" 2>/dev/null || :
		for task in /proc/"$pid"/task/*; do
			[ -d "$task" ] || continue
			printf 'tid=%s comm=' "${task##*/}"
			cat "$task/comm" 2>/dev/null || printf '?\n'
			printf 'wchan='
			cat "$task/wchan" 2>/dev/null || printf 'unavailable\n'
			if [ -r "$task/stack" ]; then
				printf 'stack:\n'
				cat "$task/stack" 2>/dev/null || :
			fi
		done
		printf 'mpp fds:\n'
		find "/proc/$pid/fd" -maxdepth 1 -type l -lname '*mpp_service*' \
			-printf '%f -> %l\n' 2>/dev/null || :
	done
}

snapshot_fast_tasks()
{
	local parent_pid=$1
	local pid task
	local pids=("$parent_pid")

	while IFS= read -r pid; do
		[ -n "$pid" ] && pids+=("$pid")
	done < <(pgrep -P "$parent_pid" 2>/dev/null || :)

	for pid in "${pids[@]}"; do
		[ -d "/proc/$pid/task" ] || continue
		printf 'pid=%s' "$pid"
		for task in /proc/"$pid"/task/*; do
			[ -d "$task" ] || continue
			printf ' tid=%s:' "${task##*/}"
			tr -d '\n' 2>/dev/null < "$task/comm" || printf '?'
			printf ':'
			tr -d '\n' 2>/dev/null < "$task/wchan" || printf '?'
		done
		printf '\n'
	done
}

sample_fast_state()
{
	local parent_pid=$1
	local target=$2
	local interval_s
	local sample=0

	interval_s=$(awk -v ms="$SAMPLE_MS" 'BEGIN { printf "%.3f", ms / 1000 }')
	while kill -0 "$parent_pid" 2>/dev/null; do
		{
			printf '\n===== sample=%u realtime=%s uptime=' "$sample" "$(date --iso-8601=ns)"
			cut -d' ' -f1 /proc/uptime 2>/dev/null || printf 'unknown\n'
			printf -- '-- rkvenc interrupts --\n'
			awk 'BEGIN { IGNORECASE=1 } /rkvenc|vepu|mpp/ { print }' /proc/interrupts 2>/dev/null || :
			snapshot_fast_tasks "$parent_pid"
		} >> "$target"
		sample=$((sample + 1))
		sleep "$interval_s"
	done
	{
		printf '\n===== final-sample realtime=%s =====\n' "$(date --iso-8601=ns)"
		snapshot_fast_tasks "$parent_pid"
	} >> "$target"
}

sample_full_state()
{
	local parent_pid=$1
	local target=$2
	local interval_s
	local sample=0

	interval_s=$(awk -v ms="$FULL_SAMPLE_MS" 'BEGIN { printf "%.3f", ms / 1000 }')
	while kill -0 "$parent_pid" 2>/dev/null; do
		{
			printf '\n===== full-sample=%u realtime=%s uptime=' "$sample" "$(date --iso-8601=ns)"
			cut -d' ' -f1 /proc/uptime 2>/dev/null || printf 'unknown\n'
			snapshot_tasks "$parent_pid"
		} >> "$target"
		sample=$((sample + 1))
		sleep "$interval_s"
	done
}

capture_metadata()
{
	{
		printf 'captured_at=%s\n' "$(date --iso-8601=seconds)"
		printf 'repo=%s\n' "$REPO_ROOT"
		printf 'repo_commit=%s\n' "$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"
		printf 'kernel=%s\n' "$(uname -a)"
		printf 'uid=%s\n' "$(id -u)"
		printf 'sample_ms=%s\n' "$SAMPLE_MS"
		printf 'full_sample_ms=%s\n' "$FULL_SAMPLE_MS"
		printf 'mpp_enc_debug=%s\n' "${MPP_ENC_DEBUG_MASK:-0}"
		printf 'binary=%s\n' "$BUILD_DIR/rkmpp_lifecycle_bench"
		printf '\n# packages\n'
		dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' \
			ffmpeg libavcodec62 libavcodec-dev librockchip-mpp1 \
			gnome-remote-desktop 2>&1 || :
		printf '\n# devices\n'
		ls -l /dev/mpp_service /dev/dma_heap/system /dev/dri/renderD* 2>&1 || :
		printf '\n# h264_rkmpp registration\n'
		ffmpeg -hide_banner -encoders 2>/dev/null | awk '/h264_rkmpp/ { print }' || :
		printf '\n# linked libraries\n'
		ldd "$BUILD_DIR/rkmpp_lifecycle_bench" 2>&1 || :
	} > "$out/metadata.txt"
}

run_one()
{
	local run_mode=$1
	local run_dir="$out/$run_mode"
	local bench_pid fast_sampler_pid full_sampler_pid journal_pid=
	local rc

	[ ! -e "$run_dir" ] || die "artifact run directory already exists: $run_dir"
	mkdir -p "$run_dir"
	awk 'BEGIN { IGNORECASE=1 } /rkvenc|vepu|mpp/ { print }' /proc/interrupts \
		> "$run_dir/interrupts-before.txt" 2>/dev/null || :

	journalctl -k -f --since now --no-pager > "$run_dir/kernel-follow.log" 2>&1 &
	journal_pid=$!

	set +e
	env ${MPP_ENC_DEBUG_MASK:+mpp_enc_debug="$MPP_ENC_DEBUG_MASK"} \
		"$BUILD_DIR/rkmpp_lifecycle_bench" --mode "$run_mode" \
		"${bench_args[@]}" > "$run_dir/events.jsonl" \
		2> "$run_dir/ffmpeg.log" &
	bench_pid=$!
	sample_fast_state "$bench_pid" "$run_dir/state-timeline.txt" &
	fast_sampler_pid=$!
	sample_full_state "$bench_pid" "$run_dir/state-full-timeline.txt" &
	full_sampler_pid=$!
	wait "$bench_pid"
	rc=$?
	wait "$fast_sampler_pid" 2>/dev/null || :
	wait "$full_sampler_pid" 2>/dev/null || :
	kill "$journal_pid" 2>/dev/null || :
	wait "$journal_pid" 2>/dev/null || :
	set -e

	printf '%s\n' "$rc" > "$run_dir/exit-status.txt"
	awk 'BEGIN { IGNORECASE=1 } /rkvenc|vepu|mpp/ { print }' /proc/interrupts \
		> "$run_dir/interrupts-after.txt" 2>/dev/null || :
	if dmesg --time-format iso > "$run_dir/dmesg-after.txt" 2> "$run_dir/dmesg.error.txt"; then
		rm -f "$run_dir/dmesg.error.txt"
	fi

	awk -v mode="$run_mode" -v rc="$rc" '
		BEGIN { completed = 0; watchdog = 0 }
		/"event":"iteration_end"/ && /"result":0/ { completed++ }
		/"event":"watchdog_timeout"/ { watchdog++ }
		END {
			printf "%s\t%d\t%d\t%d\n", mode, rc, completed, watchdog
		}
	' "$run_dir/events.jsonl" >> "$out/summary.tsv"

	printf '%s: exit=%s artifacts=%s\n' "$run_mode" "$rc" "$run_dir"
	return "$rc"
}

capture_metadata
printf 'mode\texit\tcompleted_iterations\twatchdog_timeouts\n' > "$out/summary.tsv"

case "$mode" in
compare)
	if ! run_one reuse; then
		printf 'reuse failed; not starting churn on potentially unhealthy hardware\n' >&2
		exit 1
	fi
	sleep 1
	run_one churn || exit $?
	;;
reuse|churn|exp2)
	run_one "$mode" || exit $?
	;;
esac

printf 'experiment complete: %s\n' "$out"
