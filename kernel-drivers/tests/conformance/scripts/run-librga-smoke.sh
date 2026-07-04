#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE=${PROFILE:-${1:-rewrite}}
BIN_DIR=${RGA_BIN_DIR:-"$ROOT/out/librga-samples/bin"}
OUT="$ROOT/logs/$PROFILE/$(date +%Y%m%d-%H%M%S)-librga"

mkdir -p "$OUT"

if [ ! -d "$BIN_DIR" ]; then
    echo "Missing $BIN_DIR. Run ./scripts/build-librga-samples.sh first." >&2
    exit 1
fi

export LD_LIBRARY_PATH="$ROOT/sources/airockchip-librga/libs/Linux/gcc-aarch64:${LD_LIBRARY_PATH:-}"

cases=${RGA_CASES:-"rga_copy_demo rga_resize_demo rga_cvtcolor_demo rga_fill_demo rga_alpha_demo rga_transform_rotate_demo rga_async_demo"}

for case_name in $cases; do
    exe="$BIN_DIR/$case_name"
    if [ ! -x "$exe" ]; then
        echo "missing $case_name" > "$OUT/$case_name.status"
        continue
    fi

    set +e
    "$exe" > "$OUT/$case_name.log" 2>&1
    status=$?
    set -e
    echo "$status" > "$OUT/$case_name.status"
done

dmesg | tail -n 300 > "$OUT/dmesg-tail.txt" 2>/dev/null || true
echo "$OUT"
