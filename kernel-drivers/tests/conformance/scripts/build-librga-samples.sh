#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC="$ROOT/sources/airockchip-librga/samples"
BUILD_DIR=${BUILD_DIR:-"$ROOT/build/librga-samples"}
PREFIX=${PREFIX:-"$ROOT/out/librga-samples"}
LIBRGA_LIBDIR=${LIBRGA_LIBDIR:-"$ROOT/sources/airockchip-librga/libs/Linux/gcc-aarch64"}

# The vendored sample CMake caches RGA_SAMPLES_UTILS_COMPILED; on a *reconfigure*
# of an existing build dir that cached var makes every demo skip creating the
# utils_obj target -> "utils.h: No such file" for the whole suite. Always start
# from a clean build dir so configure recreates utils_obj.
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$PREFIX"

# The build dir is wiped above, so Kbuild-style incremental reuse is impossible
# here by design and ccache is the only thing that keeps a rebuild cheap. CMake
# has no ccache auto-detection the way Meson does, hence the explicit launcher;
# see rock-5b-ysp/scripts/centralize-ccache.sh.
ccache_args=()
if command -v ccache >/dev/null 2>&1; then
    ccache_args=(
        -DCMAKE_C_COMPILER_LAUNCHER=ccache
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
    )
fi

cmake -S "$SRC" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DLIBRGA_FILE_LIB="$LIBRGA_LIBDIR" \
    "${ccache_args[@]}" \
    -DBUILD_TOOLCHAINS_PATH="${BUILD_TOOLCHAINS_PATH:-/nonexistent}"

cmake --build "$BUILD_DIR" -j"${JOBS:-$(nproc)}"
cmake --install "$BUILD_DIR"

echo "librga samples installed to $PREFIX"
