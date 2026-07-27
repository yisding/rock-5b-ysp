#!/usr/bin/env bash
# Build and run the RGA session-close force-free reproducer.
#
# WARNING: mode "cross" deliberately provokes a kernel use-after-free on
# vulnerable kernels and can crash the machine. Run only on a disposable test
# board, ideally a KASAN debug build. See
# ../../findings/2026-07-17-rga-session-close-uaf.md and
# ./rga-session-uaf.md.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"

CC="${CC:-cc}"
BUILD_DIR="${BUILD_DIR:-$TEST_DIR/.build/rga-session-uaf}"
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
  "$TEST_DIR/rga-session-uaf.c" \
  -o "$BUILD_DIR/rga-session-uaf"

exec "$BUILD_DIR/rga-session-uaf" "$@"
