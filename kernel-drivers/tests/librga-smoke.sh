#!/usr/bin/env bash
# Build and run a small librga/im2d smoke test against /dev/rga.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)

CXX="${CXX:-c++}"
BUILD_DIR="${BUILD_DIR:-/tmp/rkcompat-librga-smoke}"
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$REPO_ROOT/../rockchip-conformance"}
STAGE="${STAGE:-$REPO_ROOT/../kernel/rock5b-kernel-build/ffmpeg-stack}"
PKG_CONFIG="${PKG_CONFIG:-pkg-config}"
PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-$STAGE/lib/pkgconfig}"
LIBRGA_SRC=${LIBRGA_SRC:-"$CONFORMANCE_ROOT/sources/airockchip-librga"}
LIBRGA_LIBDIR=${LIBRGA_LIBDIR:-"$LIBRGA_SRC/libs/Linux/gcc-aarch64"}

if [ ! -e /dev/rga ]; then
  echo "SKIP: /dev/rga is absent on this boot"
  exit 77
fi

mkdir -p "$BUILD_DIR"

LIBRGA_FLAGS=()
RPATH_DIR=
LD_DIR=
if PKG_CONFIG_PATH="$PKG_CONFIG_PATH" "$PKG_CONFIG" --exists librga; then
  read -r -a LIBRGA_FLAGS <<< "$(PKG_CONFIG_PATH="$PKG_CONFIG_PATH" "$PKG_CONFIG" --cflags --libs librga)"
  RPATH_DIR="$STAGE/lib"
  LD_DIR="$STAGE/lib"
elif [ -f "$LIBRGA_SRC/include/im2d.h" ] && [ -f "$LIBRGA_LIBDIR/librga.so" ]; then
  LIBRGA_FLAGS=(-I"$LIBRGA_SRC/include" -L"$LIBRGA_LIBDIR" -lrga)
  RPATH_DIR="$LIBRGA_LIBDIR"
  LD_DIR="$LIBRGA_LIBDIR"
else
  echo "Missing librga.pc or staged librga source/lib. Set STAGE, PKG_CONFIG_PATH, LIBRGA_SRC, or LIBRGA_LIBDIR." >&2
  exit 2
fi

PKG_CONFIG_PATH="$PKG_CONFIG_PATH" "$CXX" -std=gnu++17 -Wall -Wextra \
  "$TEST_DIR/librga-smoke.cpp" \
  "${LIBRGA_FLAGS[@]}" \
  -Wl,-rpath,"$RPATH_DIR" \
  -o "$BUILD_DIR/librga-smoke"

LD_LIBRARY_PATH="$LD_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  exec "$BUILD_DIR/librga-smoke"
