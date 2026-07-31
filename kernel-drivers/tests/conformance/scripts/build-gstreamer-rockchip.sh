#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC="$ROOT/sources/jeffycn-gstreamer-rockchip"
BUILD_DIR=${BUILD_DIR:-"$ROOT/build/jeffycn-gstreamer-rockchip"}
PREFIX=${PREFIX:-"$ROOT/out/gstreamer-rockchip"}
MPP_PREFIX=${MPP_PREFIX:-}
PKG_SHIM=${PKG_SHIM:-}

dependency_pc_path=${PKG_CONFIG_PATH:-}
if [ -n "$PKG_SHIM" ]; then
    dependency_pc_path="$PKG_SHIM${dependency_pc_path:+:$dependency_pc_path}"
fi
if [ -n "$MPP_PREFIX" ]; then
    dependency_pc_path="$MPP_PREFIX/lib/pkgconfig${dependency_pc_path:+:$dependency_pc_path}"
fi
if [ -n "$dependency_pc_path" ]; then
    export PKG_CONFIG_PATH="$dependency_pc_path"
fi

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
