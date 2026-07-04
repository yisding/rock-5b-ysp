#!/usr/bin/env bash
# Build the staged airockchip/librga sample set required by librga-suite.sh.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$REPO_ROOT/../rockchip-conformance"}
SRC_ROOT=${RGA_SAMPLE_SRC:-"$CONFORMANCE_ROOT/sources/airockchip-librga/samples"}
PREFIX=${PREFIX:-"$CONFORMANCE_ROOT/out/librga-samples"}
LIBRGA_LIBDIR=${LIBRGA_LIBDIR:-"$CONFORMANCE_ROOT/sources/airockchip-librga/libs/Linux/gcc-aarch64"}
BUILD_TOOLCHAINS_PATH=${BUILD_TOOLCHAINS_PATH:-/nonexistent}
CMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE:-Release}
RGA_SOURCE_CODE_TYPE=${RGA_SOURCE_CODE_TYPE:-cpp}
JOBS=${JOBS:-$(nproc)}

if [ ! -d "$SRC_ROOT" ]; then
	echo "Missing librga sample source directory: $SRC_ROOT" >&2
	exit 2
fi

if [ -n "${BUILD_ROOT:-}" ]; then
	mkdir -p "$BUILD_ROOT"
elif [ -n "${BUILD_DIR:-}" ]; then
	BUILD_ROOT=$BUILD_DIR
	mkdir -p "$BUILD_ROOT"
else
	mkdir -p "$CONFORMANCE_ROOT/build"
	BUILD_ROOT=$(mktemp -d "$CONFORMANCE_ROOT/build/librga-samples-full.XXXXXX")
fi

TOP_BUILD_DIR=${TOP_BUILD_DIR:-"$BUILD_ROOT/top"}

if [ ! -x "$CONFORMANCE_ROOT/scripts/build-librga-samples.sh" ]; then
	echo "Missing external librga sample build script under $CONFORMANCE_ROOT" >&2
	exit 2
fi

common_cmake_args=(
	"-DCMAKE_BUILD_TYPE=$CMAKE_BUILD_TYPE"
	"-DCMAKE_INSTALL_PREFIX=$PREFIX"
	"-DLIBRGA_FILE_LIB=$LIBRGA_LIBDIR"
	"-DBUILD_TOOLCHAINS_PATH=$BUILD_TOOLCHAINS_PATH"
	"-DRGA_SOURCE_CODE_TYPE=$RGA_SOURCE_CODE_TYPE"
)

build_one()
{
	local src=$1
	local build=$2

	cmake -S "$src" -B "$build" "${common_cmake_args[@]}"
	cmake --build "$build" -j"$JOBS"
	cmake --install "$build"
}

required_cases()
{
	awk '
		/^required_cases_default="/ { in_block = 1; next }
		in_block && /^"/ { in_block = 0; next }
		in_block && NF { print }
	' "$TEST_DIR/librga-suite.sh"
}

mkdir -p "$BUILD_ROOT" "$PREFIX"

BUILD_DIR="$TOP_BUILD_DIR" \
PREFIX="$PREFIX" \
LIBRGA_LIBDIR="$LIBRGA_LIBDIR" \
BUILD_TOOLCHAINS_PATH="$BUILD_TOOLCHAINS_PATH" \
CMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" \
JOBS="$JOBS" \
	"$CONFORMANCE_ROOT/scripts/build-librga-samples.sh"

# These sample directories are present in the current airockchip/librga source
# tree but are not wired into samples/CMakeLists.txt. Build them explicitly so
# the required conformance matrix stays aligned with the rewrite ABI ledger.
for sample_dir in gauss_demo palette_demo; do
	build_one "$SRC_ROOT/$sample_dir" "$BUILD_ROOT/$sample_dir"
done

missing=0
while IFS= read -r case_name; do
	if [ "$case_name" = "ysp_librga_smoke" ]; then
		continue
	fi
	if [ ! -x "$PREFIX/bin/$case_name" ]; then
		echo "Missing required librga sample after build: $case_name" >&2
		missing=1
	fi
done < <(required_cases)

if [ "$missing" -ne 0 ]; then
	exit 1
fi

echo "full librga samples installed to $PREFIX"
