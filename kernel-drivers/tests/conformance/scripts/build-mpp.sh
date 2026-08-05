#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC="$ROOT/sources/rockchip-mpp"
BUILD_DIR=${BUILD_DIR:-"$ROOT/build/rockchip-mpp"}
PREFIX=${PREFIX:-"$ROOT/out/mpp"}

mkdir -p "$BUILD_DIR" "$PREFIX"

# CMake has no ccache auto-detection the way Meson does, so without an explicit
# launcher every conformance run recompiles this large C++ tree from scratch.
# Results go to the shared store via the host ccache config; see
# rock-5b-ysp/scripts/centralize-ccache.sh.
ccache_args=()
if command -v ccache >/dev/null 2>&1; then
    ccache_args=(
        -DCMAKE_C_COMPILER_LAUNCHER=ccache
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
    )
fi

cmake -S "$SRC" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}" \
    -DBUILD_TEST=ON \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    "${ccache_args[@]}" \
    ${CMAKE_TOOLCHAIN_FILE:+-DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN_FILE"}

cmake --build "$BUILD_DIR" -j"${JOBS:-$(nproc)}"
cmake --install "$BUILD_DIR"

echo "MPP installed to $PREFIX"
echo "Test binaries should be under $PREFIX/bin"
