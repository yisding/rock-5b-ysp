#!/usr/bin/env bash
# Build and run the MPP/RGA query/no-op ABI probe.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"

CC="${CC:-cc}"
BUILD_DIR="${BUILD_DIR:-/tmp/rkcompat-abi-probe}"
KERNEL_UAPI="${KERNEL_UAPI:-$ROOT_DIR/../linux-6.18-rkvenc/include/uapi}"
KERNEL_ARCH_UAPI="${KERNEL_ARCH_UAPI:-$ROOT_DIR/../linux-6.18-rkvenc/arch/arm64/include/uapi}"
LIBRGA_HW_INCLUDE="${LIBRGA_HW_INCLUDE:-$ROOT_DIR/../librga-src/core/hardware}"
LIBRGA_INCLUDE="${LIBRGA_INCLUDE:-$ROOT_DIR/../librga-src/include}"

mkdir -p "$BUILD_DIR"

"$CC" -std=gnu11 -Wall -Wextra -Wno-cpp \
  -I "$KERNEL_UAPI" \
  -I "$KERNEL_ARCH_UAPI" \
  -I "$LIBRGA_HW_INCLUDE" \
  -I "$LIBRGA_INCLUDE" \
  "$TEST_DIR/abi-probe.c" \
  -o "$BUILD_DIR/abi-probe"

exec "$BUILD_DIR/abi-probe" "$@"
