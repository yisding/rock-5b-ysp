#!/usr/bin/env bash
# Build the staged Rockchip MPP library and official test programs.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$REPO_ROOT/../rockchip-conformance"}
SRC_ROOT=${MPP_SRC:-"$CONFORMANCE_ROOT/sources/rockchip-mpp"}
BUILD_DIR=${BUILD_DIR:-"$CONFORMANCE_ROOT/build/rockchip-mpp-suite"}
PREFIX=${PREFIX:-"$CONFORMANCE_ROOT/out/mpp"}
CMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE:-Release}
JOBS=${JOBS:-$(nproc)}

if [ ! -d "$SRC_ROOT" ]; then
	echo "Missing Rockchip MPP source directory: $SRC_ROOT" >&2
	exit 2
fi

cmake_args=(
	"-DCMAKE_BUILD_TYPE=$CMAKE_BUILD_TYPE"
	"-DBUILD_TEST=ON"
	"-DMPP_RUNTIME_TEST=OFF"
	"-DCMAKE_INSTALL_PREFIX=$PREFIX"
)

# CMake has no ccache auto-detection the way Meson does, so without an explicit
# launcher every rebuild of this large C++ tree compiles from scratch. Results go
# to the shared store via the host ccache config; see
# rock-5b-ysp/scripts/centralize-ccache.sh.
if command -v ccache >/dev/null 2>&1; then
	cmake_args+=(
		"-DCMAKE_C_COMPILER_LAUNCHER=ccache"
		"-DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
	)
fi

if [ -n "${CMAKE_TOOLCHAIN_FILE:-}" ]; then
	cmake_args+=("-DCMAKE_TOOLCHAIN_FILE=$CMAKE_TOOLCHAIN_FILE")
fi

mkdir -p "$BUILD_DIR" "$PREFIX"

cmake -S "$SRC_ROOT" -B "$BUILD_DIR" "${cmake_args[@]}"
cmake --build "$BUILD_DIR" -j"$JOBS"
cmake --install "$BUILD_DIR"

required_bins=(
	mpp_info_test
	mpi_dec_test
	mpi_dec_mt_test
	mpi_dec_multi_test
	mpi_enc_test
	mpi_enc_mt_test
	mpi_rc2_test
	vpu_api_test
)

missing=0
for exe in "${required_bins[@]}"; do
	if [ ! -x "$PREFIX/bin/$exe" ]; then
		echo "Missing required MPP test after build: $exe" >&2
		missing=1
	fi
done

if [ "$missing" -ne 0 ]; then
	exit 1
fi

echo "MPP installed to $PREFIX"
echo "official MPP tests installed to $PREFIX/bin"
