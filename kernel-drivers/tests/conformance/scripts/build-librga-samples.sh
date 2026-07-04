#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC="$ROOT/sources/airockchip-librga/samples"
BUILD_DIR=${BUILD_DIR:-"$ROOT/build/librga-samples"}
PREFIX=${PREFIX:-"$ROOT/out/librga-samples"}
LIBRGA_LIBDIR=${LIBRGA_LIBDIR:-"$ROOT/sources/airockchip-librga/libs/Linux/gcc-aarch64"}

mkdir -p "$BUILD_DIR" "$PREFIX"

cmake -S "$SRC" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DLIBRGA_FILE_LIB="$LIBRGA_LIBDIR" \
    -DBUILD_TOOLCHAINS_PATH="${BUILD_TOOLCHAINS_PATH:-/nonexistent}"

cmake --build "$BUILD_DIR" -j"${JOBS:-$(nproc)}"
cmake --install "$BUILD_DIR"

echo "librga samples installed to $PREFIX"
