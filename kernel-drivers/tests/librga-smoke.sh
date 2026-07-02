#!/usr/bin/env bash
# Build and run a small librga/im2d smoke test against /dev/rga.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"

CXX="${CXX:-c++}"
BUILD_DIR="${BUILD_DIR:-/tmp/rkcompat-librga-smoke}"
STAGE="${STAGE:-/home/yi/Code/rock5b-kernel-debug/ffmpeg-stack}"
PKG_CONFIG="${PKG_CONFIG:-pkg-config}"
PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-$STAGE/lib/pkgconfig}"

if [ ! -e /dev/rga ]; then
  echo "SKIP: /dev/rga is absent on this boot"
  exit 77
fi

if ! PKG_CONFIG_PATH="$PKG_CONFIG_PATH" "$PKG_CONFIG" --exists librga; then
  echo "Missing librga.pc. Set STAGE or PKG_CONFIG_PATH to a staged librga install." >&2
  exit 2
fi

mkdir -p "$BUILD_DIR"

PKG_CONFIG_PATH="$PKG_CONFIG_PATH" "$CXX" -std=gnu++17 -Wall -Wextra \
  "$TEST_DIR/librga-smoke.cpp" \
  $(PKG_CONFIG_PATH="$PKG_CONFIG_PATH" "$PKG_CONFIG" --cflags --libs librga) \
  -Wl,-rpath,"$STAGE/lib" \
  -o "$BUILD_DIR/librga-smoke"

LD_LIBRARY_PATH="$STAGE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  exec "$BUILD_DIR/librga-smoke"
