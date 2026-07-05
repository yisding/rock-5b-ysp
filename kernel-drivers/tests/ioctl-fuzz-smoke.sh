#!/usr/bin/env bash
# Build and run the bounded non-submit MPP/RGA ioctl fuzzer.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"

CC="${CC:-cc}"
BUILD_DIR="${BUILD_DIR:-/tmp/rkcompat-ioctl-fuzz}"
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

exec "$BUILD_DIR/ioctl-fuzz-smoke" "$@"
