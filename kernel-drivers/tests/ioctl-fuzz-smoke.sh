#!/usr/bin/env bash
# Build and run the bounded non-submit MPP/RGA ioctl fuzzer.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
# Only for SUITE_DMESG_FATAL_RE: keep the fatal-signature set in one place. The
# private copy this replaced had drifted to a pre-2026-07 generation that missed
# every RK3588 IOMMU/RGA fault line and false-positived on the harness's own
# `rga-mmu-debug:` markers and on `pstore.backend=ramoops`.
# shellcheck source=suite-common.sh disable=SC1091
source "$TEST_DIR/suite-common.sh"

CC="${CC:-cc}"
IOCTL_FUZZ_VALIDATE_BUILD="${IOCTL_FUZZ_VALIDATE_BUILD:-0}"
IOCTL_FUZZ_FAIL_NTH_MAX="${IOCTL_FUZZ_FAIL_NTH_MAX:-0}"
IOCTL_FUZZ_OUT="${IOCTL_FUZZ_OUT:-}"
IOCTL_FUZZ_DMESG_SCAN="${IOCTL_FUZZ_DMESG_SCAN:-0}"
IOCTL_FUZZ_REQUIRE_DMESG="${IOCTL_FUZZ_REQUIRE_DMESG:-0}"
IOCTL_FUZZ_DMESG_FATAL_RE="${IOCTL_FUZZ_DMESG_FATAL_RE:-$SUITE_DMESG_FATAL_RE}"
tmp_build_dir=

if [ -z "${BUILD_DIR+x}" ]; then
	tmp_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/rkcompat-ioctl-fuzz.XXXXXX")"
	BUILD_DIR="$tmp_build_dir"
	trap 'rm -rf "$tmp_build_dir"' EXIT
fi

KERNEL_UAPI="${KERNEL_UAPI:-$ROOT_DIR/../kernel/linux-6.18-rkvenc/include/uapi}"
KERNEL_ARCH_UAPI="${KERNEL_ARCH_UAPI:-$ROOT_DIR/../kernel/linux-6.18-rkvenc/arch/arm64/include/uapi}"
LIBRGA_ROOT="${LIBRGA_ROOT:-$ROOT_DIR/../rockchip-userspace/librga-fork}"
LIBRGA_HW_INCLUDE="${LIBRGA_HW_INCLUDE:-$LIBRGA_ROOT/core/hardware}"
LIBRGA_INCLUDE="${LIBRGA_INCLUDE:-$LIBRGA_ROOT/include}"

mkdir -p "$BUILD_DIR"

"$CC" -std=gnu11 -Wall -Wextra -Wno-cpp \
  -I "$KERNEL_UAPI" \
  -I "$KERNEL_ARCH_UAPI" \
  -I "$LIBRGA_HW_INCLUDE" \
  -I "$LIBRGA_INCLUDE" \
  "$TEST_DIR/ioctl-fuzz-smoke.c" \
  -o "$BUILD_DIR/ioctl-fuzz-smoke"

if [ "$IOCTL_FUZZ_VALIDATE_BUILD" = "1" ]; then
	echo "PASS: ioctl fuzz smoke builds"
	exit 0
fi

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
		grep -aiE "$IOCTL_FUZZ_DMESG_FATAL_RE" || true
}

run_fuzzer()
{
	local label=$1
	shift
	local log_file
	local before
	local after
	local faults
	local rc

	if [ -z "$IOCTL_FUZZ_OUT" ]; then
		"$@"
		return $?
	fi

	mkdir -p "$IOCTL_FUZZ_OUT"
	log_file="$IOCTL_FUZZ_OUT/$label.log"
	before="$IOCTL_FUZZ_OUT/$label-dmesg-before.txt"
	after="$IOCTL_FUZZ_OUT/$label-dmesg-after.txt"

	if [ "$IOCTL_FUZZ_DMESG_SCAN" = "1" ] ||
	   [ "$IOCTL_FUZZ_REQUIRE_DMESG" = "1" ]; then
		snap_dmesg "$before"
	fi

	set +e
	"$@" > "$log_file" 2>&1
	rc=$?
	set -e
	cat "$log_file"

	if [ "$IOCTL_FUZZ_DMESG_SCAN" = "1" ] ||
	   [ "$IOCTL_FUZZ_REQUIRE_DMESG" = "1" ]; then
		snap_dmesg "$after"
		if [ ! -s "$before" ] || [ ! -s "$after" ]; then
			printf "dmesg unavailable for %s\n" "$label" |
				tee "$IOCTL_FUZZ_OUT/$label-dmesg-unavailable.txt"
			if [ "$IOCTL_FUZZ_REQUIRE_DMESG" = "1" ]; then
				return 1
			fi
		else
			faults=$(dmesg_faults "$before" "$after")
			if [ -n "$faults" ]; then
				printf "%s\n" "$faults" |
					tee "$IOCTL_FUZZ_OUT/$label-dmesg-fatal.txt"
				return 1
			fi
		fi
	fi

	return "$rc"
}

case "$IOCTL_FUZZ_FAIL_NTH_MAX" in
''|*[!0-9]*)
	printf "IOCTL_FUZZ_FAIL_NTH_MAX must be an unsigned integer, got '%s'\n" \
		"$IOCTL_FUZZ_FAIL_NTH_MAX" >&2
	exit 2
	;;
esac

if [ "$IOCTL_FUZZ_FAIL_NTH_MAX" -gt 0 ]; then
	rc=0
	for nth in $(seq 1 "$IOCTL_FUZZ_FAIL_NTH_MAX"); do
		printf "================= ioctl fail-nth %s =================\n" "$nth"
		run_fuzzer "fail-nth-$nth" \
			env IOCTL_FUZZ_FAIL_NTH="$nth" \
			IOCTL_FUZZ_FAIL_NTH_REQUIRE_HIT="${IOCTL_FUZZ_FAIL_NTH_REQUIRE_HIT:-1}" \
			"$BUILD_DIR/ioctl-fuzz-smoke" "$@" || rc=$?
		printf "\n"
		if [ "$rc" -ne 0 ]; then
			exit "$rc"
		fi
	done
	exit 0
fi

run_fuzzer "ioctl-fuzz" "$BUILD_DIR/ioctl-fuzz-smoke" "$@"
