#!/usr/bin/env bash
# Build and run the bounded non-submit MPP/RGA ioctl fuzzer.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"

CC="${CC:-cc}"
IOCTL_FUZZ_VALIDATE_BUILD="${IOCTL_FUZZ_VALIDATE_BUILD:-0}"
IOCTL_FUZZ_FAIL_NTH_MAX="${IOCTL_FUZZ_FAIL_NTH_MAX:-0}"
tmp_build_dir=

if [ "$IOCTL_FUZZ_VALIDATE_BUILD" = "1" ] &&
   [ -z "${BUILD_DIR+x}" ]; then
	tmp_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/rkcompat-ioctl-fuzz.XXXXXX")"
	BUILD_DIR="$tmp_build_dir"
	trap 'rm -rf "$tmp_build_dir"' EXIT
else
	BUILD_DIR="${BUILD_DIR:-/tmp/rkcompat-ioctl-fuzz}"
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

exec "$BUILD_DIR/ioctl-fuzz-smoke" "$@"
