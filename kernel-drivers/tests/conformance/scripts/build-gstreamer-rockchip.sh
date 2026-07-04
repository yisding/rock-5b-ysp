#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC="$ROOT/sources/jeffycn-gstreamer-rockchip"
BUILD_DIR=${BUILD_DIR:-"$ROOT/build/jeffycn-gstreamer-rockchip"}
PREFIX=${PREFIX:-"$ROOT/out/gstreamer-rockchip"}
MPP_PREFIX=${MPP_PREFIX:-"$ROOT/out/mpp"}
PKG_SHIM="$ROOT/out/pkgconfig"

export PKG_CONFIG_PATH="$MPP_PREFIX/lib/pkgconfig:$PKG_SHIM:${PKG_CONFIG_PATH:-}"

setup_args=()
if [ -d "$BUILD_DIR" ]; then
    setup_args+=(--wipe)
fi

meson setup "$BUILD_DIR" "$SRC" \
    --prefix "$PREFIX" \
    -Drockchipmpp="${ROCKCHIPMPP_FEATURE:-enabled}" \
    -Drga="${RGA_FEATURE:-auto}" \
    -Drkximage="${RKXIMAGE_FEATURE:-auto}" \
    -Dkmssrc="${KMSSRC_FEATURE:-auto}" \
    "${setup_args[@]}"

ninja -C "$BUILD_DIR"
ninja -C "$BUILD_DIR" install

echo "GStreamer Rockchip plugins installed to $PREFIX"
echo "Use: export GST_PLUGIN_PATH=$PREFIX/lib/gstreamer-1.0"
