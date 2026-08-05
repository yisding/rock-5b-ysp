#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE=${PROFILE:-${1:-rewrite}}
PREFIX=${PREFIX:-"$ROOT/out/gstreamer-rockchip"}
OUT="$ROOT/logs/$PROFILE/$(date +%Y%m%d-%H%M%S)-gstreamer"
MPP_LIBDIR=${MPP_LIBDIR:-}
LIBRGA_LIBDIR=${LIBRGA_LIBDIR:-}

mkdir -p "$OUT"

export GST_PLUGIN_PATH="$PREFIX/lib/gstreamer-1.0:${GST_PLUGIN_PATH:-}"
runtime_library_path=${LD_LIBRARY_PATH:-}
if [ -n "$LIBRGA_LIBDIR" ]; then
    runtime_library_path="$LIBRGA_LIBDIR${runtime_library_path:+:$runtime_library_path}"
fi
if [ -n "$MPP_LIBDIR" ]; then
    runtime_library_path="$MPP_LIBDIR${runtime_library_path:+:$runtime_library_path}"
fi
if [ -n "$runtime_library_path" ]; then
    export LD_LIBRARY_PATH="$runtime_library_path"
fi

gst-inspect-1.0 rockchipmpp > "$OUT/gst-inspect-rockchipmpp.log" 2>&1

if command -v gst-launch-1.0 >/dev/null 2>&1; then
    gst-launch-1.0 -q videotestsrc num-buffers=5 ! fakesink \
        > "$OUT/gst-launch-baseline.log" 2>&1
fi

dmesg | tail -n 300 > "$OUT/dmesg-tail.txt" 2>/dev/null || true
echo "$OUT"
