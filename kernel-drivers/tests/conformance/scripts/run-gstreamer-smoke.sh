#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE=${PROFILE:-${1:-rewrite}}
PREFIX=${PREFIX:-"$ROOT/out/gstreamer-rockchip"}
OUT="$ROOT/logs/$PROFILE/$(date +%Y%m%d-%H%M%S)-gstreamer"

mkdir -p "$OUT"

export GST_PLUGIN_PATH="$PREFIX/lib/gstreamer-1.0:${GST_PLUGIN_PATH:-}"
export LD_LIBRARY_PATH="$ROOT/out/mpp/lib:$ROOT/sources/airockchip-librga/libs/Linux/gcc-aarch64:${LD_LIBRARY_PATH:-}"

gst-inspect-1.0 rockchipmpp > "$OUT/gst-inspect-rockchipmpp.log" 2>&1

if command -v gst-launch-1.0 >/dev/null 2>&1; then
    gst-launch-1.0 -q videotestsrc num-buffers=5 ! fakesink \
        > "$OUT/gst-launch-baseline.log" 2>&1
fi

dmesg | tail -n 300 > "$OUT/dmesg-tail.txt" 2>/dev/null || true
echo "$OUT"
