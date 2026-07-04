#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC="$ROOT/sources/rockchip-mpp"
BUILD_DIR=${BUILD_DIR:-"$ROOT/build/rockchip-mpp"}
PREFIX=${PREFIX:-"$ROOT/out/mpp"}

mkdir -p "$BUILD_DIR" "$PREFIX"

cmake -S "$SRC" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}" \
    -DBUILD_TEST=ON \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    ${CMAKE_TOOLCHAIN_FILE:+-DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN_FILE"}

cmake --build "$BUILD_DIR" -j"${JOBS:-$(nproc)}"
cmake --install "$BUILD_DIR"

echo "MPP installed to $PREFIX"
echo "Test binaries should be under $PREFIX/bin"
