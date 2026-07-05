#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
# shellcheck source=suite-common.sh disable=SC1091
source "$TEST_DIR/suite-common.sh"

CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$REPO_ROOT/../rockchip-conformance"}
BIN_DIR=${RGA_BIN_DIR:-"$CONFORMANCE_ROOT/out/librga-samples/bin"}
LIBRGA_LIBDIR=${LIBRGA_LIBDIR:-"$CONFORMANCE_ROOT/sources/airockchip-librga/libs/Linux/gcc-aarch64"}
OUT=${OUT:-"$CONFORMANCE_ROOT/logs/rga-mmu-debug/$(date +%Y%m%d-%H%M%S)"}
RGA_DEBUGFS=${RGA_DEBUGFS:-/sys/kernel/debug/rkrga}
RGA_CASES=${RGA_CASES:-"rga_copy_demo rga_resize_rect_demo rga_transform_rotate_demo"}
RGA_DEBUG_FLAGS=${RGA_DEBUG_FLAGS:-"reg msg int mm time"}
# The librga demos read/write raw fixtures under a base dir that upstream hardcodes
# to the Android "/data" path (absent + unwritable on Armbian). Our patched librga
# utils honor $RGA_SAMPLE_DATA_DIR; point it at a user-writable dir and stage the
# fixtures the copy/resize/rotate cases consume.
RGA_SAMPLE_DATA_DIR=${RGA_SAMPLE_DATA_DIR:-"$CONFORMANCE_ROOT/assets/rga-fixtures"}
RGA_RESTORE_DEBUG=${RGA_RESTORE_DEBUG:-1}
RGA_FAIL_ON_CASE_FAILURE=${RGA_FAIL_ON_CASE_FAILURE:-0}

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
	SUDO_CMD=()
else
	# Override with SUDO= if the user has already arranged debugfs/dmesg access.
	# shellcheck disable=SC2206
	SUDO_CMD=(${SUDO-sudo})
fi

declare -A DEBUG_LABELS=(
	[reg]=REG
	[msg]=MSG
	[time]=TIME
	[int]=INT
	[mm]=MM
	[check]=CHECK
	[intl]=INTL
)
declare -A ORIGINAL_DEBUG_STATE=()

usage()
{
	cat <<EOF
Usage: sudo [env ...] bash kernel-drivers/tests/rga-mmu-debug.sh

Collect RGA MMU interrupt diagnostics around selected librga sample cases.

Environment:
  CONFORMANCE_ROOT        default: $CONFORMANCE_ROOT
  RGA_BIN_DIR            default: $BIN_DIR
  LIBRGA_LIBDIR          default: $LIBRGA_LIBDIR
  OUT                    default: $OUT
  RGA_DEBUGFS            default: $RGA_DEBUGFS
  RGA_CASES              default: $RGA_CASES
  RGA_DEBUG_FLAGS        default: $RGA_DEBUG_FLAGS
  RGA_RESTORE_DEBUG      restore debug flags on exit, default: $RGA_RESTORE_DEBUG
  RGA_FAIL_ON_CASE_FAILURE exit nonzero if a sample fails, default: $RGA_FAIL_ON_CASE_FAILURE
EOF
}

sudo_run()
{
	"${SUDO_CMD[@]}" "$@"
}

debugfs_read()
{
	local path=$1

	sudo_run cat "$path"
}

debugfs_write_flag()
{
	local flag=$1

	printf "%s\n" "$flag" | sudo_run tee "$RGA_DEBUGFS/debug" >/dev/null
}

debug_state()
{
	local flag=$1
	local label=${DEBUG_LABELS[$flag]:-}

	if [ -z "$label" ]; then
		printf "UNKNOWN\n"
		return
	fi

	# shellcheck disable=SC2016
	sudo_run awk -v label="$label" '
		$1 == label {
			state = $2;
			gsub(/[][]/, "", state);
			print state;
			found = 1;
		}
		END {
			if (!found)
				exit 1;
		}
	' "$RGA_DEBUGFS/debug" 2>/dev/null || printf "UNKNOWN\n"
}

enable_debug_flag()
{
	local flag=$1
	local state

	state=$(debug_state "$flag")
	ORIGINAL_DEBUG_STATE[$flag]=$state

	case "$state" in
	DIS)
		debugfs_write_flag "$flag"
		;;
	EN | UNKNOWN)
		;;
	*)
		printf "WARN: unexpected debug state for %s: %s\n" "$flag" "$state" >&2
		;;
	esac
}

restore_debug_flags()
{
	local flag
	local before
	local current

	if [ "$RGA_RESTORE_DEBUG" != "1" ]; then
		return
	fi

	for flag in "${!ORIGINAL_DEBUG_STATE[@]}"; do
		before=${ORIGINAL_DEBUG_STATE[$flag]}
		current=$(debug_state "$flag")
		if [ "$before" != "UNKNOWN" ] && [ "$current" != "UNKNOWN" ] &&
			[ "$before" != "$current" ]; then
			debugfs_write_flag "$flag" || true
		fi
	done
}

kmsg_marker()
{
	local message=$1

	printf "rock-5b-ysp rga-mmu-debug: %s\n" "$message" |
		sudo_run tee /dev/kmsg >/dev/null 2>&1 || true
}

capture_dmesg()
{
	local target=$1

	sudo_run dmesg --time-format iso > "$target" 2>&1 || true
}

filter_dmesg()
{
	local source=$1
	local target=$2

	grep -Ei 'rga|iommu|io-?va|page fault|bus_error|mmu|intr|RGA3_core' \
		"$source" > "$target" 2>/dev/null || true
}

snapshot_debugfs()
{
	local label=$1
	local target=$2
	local file

	{
		printf "== %s (%s) ==\n" "$RGA_DEBUGFS" "$label"
		sudo_run find "$RGA_DEBUGFS" -maxdepth 1 -type f -print | sort |
			while IFS= read -r file; do
				printf "\n-- %s --\n" "$file"
				debugfs_read "$file" 2>&1 || true
			done
	} > "$target" 2>&1 || true
}

write_metadata()
{
	local target=$1

	{
		printf "date: "
		date -Is
		printf "uname: "
		uname -a
		printf "repo_root: %s\n" "$REPO_ROOT"
		printf "conformance_root: %s\n" "$CONFORMANCE_ROOT"
		printf "bin_dir: %s\n" "$BIN_DIR"
		printf "librga_libdir: %s\n" "$LIBRGA_LIBDIR"
		printf "sample_data_dir: %s\n" "$RGA_SAMPLE_DATA_DIR"
		printf "debugfs: %s\n" "$RGA_DEBUGFS"
		printf "cases: %s\n" "$RGA_CASES"
		printf "debug_flags: %s\n" "$RGA_DEBUG_FLAGS"
		printf "\n== /proc/cmdline ==\n"
		cat /proc/cmdline 2>/dev/null || true
		printf "\n== /dev/rga ==\n"
		ls -l /dev/rga 2>&1 || true
		printf "\n== debugfs listing ==\n"
		sudo_run ls -la "$RGA_DEBUGFS" 2>&1 || true
	} > "$target"
}

stage_rga_fixtures()
{
	# The demos read/write raw planar fixtures named in<idx>w<W>-h<H>-<fmt>.bin /
	# out<...>.bin under $RGA_SAMPLE_DATA_DIR. copy/resize/rotate all consume a
	# 1280x720 RGBA8888 source at index 0. Materialize it deterministically if
	# missing (content is irrelevant to the MMU/DMA datapath check; byte size must
	# equal W*H*bpp exactly). head-then-tr keeps exit codes clean under pipefail.
	mkdir -p "$RGA_SAMPLE_DATA_DIR"
	local src="$RGA_SAMPLE_DATA_DIR/in0w1280-h720-rgba8888.bin"
	local want=$((1280 * 720 * 4))
	local have
	have=$(stat -c '%s' "$src" 2>/dev/null || echo 0)
	if [ ! -f "$src" ] || [ "$have" != "$want" ]; then
		head -c "$want" /dev/zero | tr '\0' '\252' > "$src"
		printf "staged fixture: %s (%s bytes)\n" "$src" "$want"
	fi
}

run_case()
{
	local case_name=$1
	local exe="$BIN_DIR/$case_name"
	local case_dir="$OUT/cases/$case_name"
	local start
	local end
	local elapsed
	local status
	local result

	mkdir -p "$case_dir"

	snapshot_debugfs "$case_name before" "$case_dir/debugfs-before.txt"
	capture_dmesg "$case_dir/dmesg-before.txt"
	filter_dmesg "$case_dir/dmesg-before.txt" "$case_dir/dmesg-rga-iommu-before.txt"

	kmsg_marker "BEGIN $case_name"
	start=$(suite_now_ns)
	set +e
	"$exe" > "$case_dir/stdout-stderr.log" 2>&1
	status=$?
	set -e
	end=$(suite_now_ns)
	elapsed=$(suite_elapsed_s "$start" "$end")
	kmsg_marker "END $case_name status=$status elapsed_s=$elapsed"

	capture_dmesg "$case_dir/dmesg-after.txt"
	filter_dmesg "$case_dir/dmesg-after.txt" "$case_dir/dmesg-rga-iommu-after.txt"
	tail -n 300 "$case_dir/dmesg-after.txt" > "$case_dir/dmesg-tail.txt" 2>/dev/null || true
	snapshot_debugfs "$case_name after" "$case_dir/debugfs-after.txt"

	# These RK im2d demos return an IM_STATUS_* code as the *process* exit code, and
	# IM_STATUS_SUCCESS == 1 -- so rga_resize_rect_demo exits 1 on full success while
	# copy/rotate exit 0. The raw exit code is therefore NOT a reliable pass/fail
	# signal (it is still recorded in the TSV for forensics). Judge instead on:
	#   fail-output    the demo hit a read/import/submit error in stdout
	#   fail-hw        this case's dmesg window shows an MMU fault / "failed N>0"
	#   fail-nosuccess the demo never printed its "running success" line
	local had_error had_success had_hwfault
	grep -Eiq 'running failed|Fatal error|Failed to call RockChipRga interface|request commit failed|submit failed|importbuffer failed|src image read err|Could not open' \
		"$case_dir/stdout-stderr.log" && had_error=1 || had_error=0
	grep -Eiq 'running success' "$case_dir/stdout-stderr.log" && had_success=1 || had_success=0
	if comm -13 <(sort "$case_dir/dmesg-rga-iommu-before.txt") <(sort "$case_dir/dmesg-rga-iommu-after.txt") 2>/dev/null \
		| grep -Eiq 'page fault|bus error|finished [0-9]+ failed [1-9]|INTR\[0x2\]'; then
		had_hwfault=1
	else
		had_hwfault=0
	fi

	result=pass
	if [ "$had_error" = 1 ]; then
		result=fail-output
	elif [ "$had_hwfault" = 1 ]; then
		result=fail-hw
	elif [ "$had_success" = 0 ]; then
		result=fail-nosuccess
	fi

	printf "%s\t%s\t%s\t%s\t%s\n" \
		"$case_name" "$status" "$result" "$elapsed" "$case_dir" >> "$OUT/summary.tsv"

	[ "$result" = "pass" ]
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	usage
	exit 0
fi

if [ ! -e /dev/rga ]; then
	echo "SKIP: /dev/rga is absent on this boot"
	exit 77
fi

if ! sudo_run test -d "$RGA_DEBUGFS"; then
	echo "SKIP: $RGA_DEBUGFS is absent. Mount debugfs or boot a kernel with RGA debugfs." >&2
	exit 77
fi

if ! sudo_run test -f "$RGA_DEBUGFS/debug"; then
	echo "SKIP: $RGA_DEBUGFS/debug is absent." >&2
	exit 77
fi

if [ ! -d "$BIN_DIR" ]; then
	echo "Missing $BIN_DIR. Run ../rockchip-conformance/scripts/build-librga-samples.sh first." >&2
	exit 2
fi

missing=0
for case_name in $RGA_CASES; do
	if [ ! -x "$BIN_DIR/$case_name" ]; then
		echo "Missing executable: $BIN_DIR/$case_name" >&2
		missing=1
	fi
done
if [ "$missing" -ne 0 ]; then
	exit 2
fi

mkdir -p "$OUT/cases"
printf "case\texit_status\tresult\telapsed_s\tcase_dir\n" > "$OUT/summary.tsv"
write_metadata "$OUT/metadata.txt"

export LD_LIBRARY_PATH="$LIBRGA_LIBDIR:${LD_LIBRARY_PATH:-}"
export RGA_SAMPLE_DATA_DIR
stage_rga_fixtures

trap restore_debug_flags EXIT
snapshot_debugfs "initial" "$OUT/debugfs-initial.txt"
for flag in $RGA_DEBUG_FLAGS; do
	enable_debug_flag "$flag"
done
snapshot_debugfs "after debug enable" "$OUT/debugfs-after-debug-enable.txt"

failed=0
for case_name in $RGA_CASES; do
	if ! run_case "$case_name"; then
		failed=$((failed + 1))
	fi
done

snapshot_debugfs "final before restore" "$OUT/debugfs-final-before-restore.txt"

echo "RGA MMU debug artifacts: $OUT"
echo
cat "$OUT/summary.tsv"

if [ "$failed" -ne 0 ]; then
	echo
	echo "$failed case(s) failed or reported fatal output. With the IOMMU/DMA forward-port fix"
	echo "in place and fixtures staged, a failure here is a real regression -- inspect the case"
	echo "dir's dmesg-rga-iommu-after.txt for an MMU/page-fault signature."
	if [ "$RGA_FAIL_ON_CASE_FAILURE" = "1" ]; then
		exit 1
	fi
fi
