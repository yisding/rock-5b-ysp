#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: MIT
# Build and run the MPP/RGA query/no-op ABI probe.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
ROCK5B_WORKSPACE="${ROCK5B_WORKSPACE:-$ROOT_DIR/../rock-5b}"

CC="${CC:-cc}"
BUILD_DIR="${BUILD_DIR:-$TEST_DIR/.build/abi-probe}"
KERNEL_UAPI="${KERNEL_UAPI:-$ROCK5B_WORKSPACE/kernel/linux-6.18-rkvenc/include/uapi}"
KERNEL_ARCH_UAPI="${KERNEL_ARCH_UAPI:-$ROCK5B_WORKSPACE/kernel/linux-6.18-rkvenc/arch/arm64/include/uapi}"
LIBRGA_ROOT="${LIBRGA_ROOT:-$ROCK5B_WORKSPACE/rockchip-userspace/librga-fork}"
LIBRGA_HW_INCLUDE="${LIBRGA_HW_INCLUDE:-$LIBRGA_ROOT/core/hardware}"
LIBRGA_INCLUDE="${LIBRGA_INCLUDE:-$LIBRGA_ROOT/include}"

mkdir -p "$BUILD_DIR"

"$CC" -std=gnu11 -Wall -Wextra -Wno-cpp \
  -I "$KERNEL_UAPI" \
  -I "$KERNEL_ARCH_UAPI" \
  -I "$LIBRGA_HW_INCLUDE" \
  -I "$LIBRGA_INCLUDE" \
  "$TEST_DIR/abi-probe.c" \
  -o "$BUILD_DIR/abi-probe"

exec "$BUILD_DIR/abi-probe" "$@"
