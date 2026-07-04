#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE=${PROFILE:-${1:-rewrite}}
OUT="$ROOT/logs/$PROFILE/$(date +%Y%m%d-%H%M%S)-system"

mkdir -p "$OUT"

{
    echo "profile=$PROFILE"
    echo "date=$(date -Is)"
    echo "uname=$(uname -a)"
    echo
    if [ -r /etc/os-release ]; then
        cat /etc/os-release
        echo
    fi

    echo "[devices]"
    for pattern in /dev/mpp_service /dev/rga /dev/video* /dev/dma_heap/* /dev/dri/*; do
        for node in $pattern; do
            [ -e "$node" ] && ls -l "$node"
        done
    done
    echo

    echo "[rga-version]"
    for path in /sys/kernel/debug/rkrga/driver_version /proc/rkrga/driver_version; do
        if [ -r "$path" ]; then
            echo "$path:"
            cat "$path"
        fi
    done
    echo

    echo "[mpp-proc-debug]"
    for path in /proc/mpp_service /proc/mpp_service/* /sys/kernel/debug/mpp_service/*; do
        if [ -r "$path" ]; then
            echo "----- $path"
            cat "$path" || true
        fi
    done
    echo

    echo "[loaded-rockchip-modules]"
    lsmod 2>/dev/null | grep -Ei 'rga|mpp|vcodec|vpu|rkv|rockchip' || true
} > "$OUT/system.txt"

dmesg > "$OUT/dmesg.txt" 2>/dev/null || true
dmesg | tail -n 300 > "$OUT/dmesg-tail.txt" 2>/dev/null || true

echo "$OUT"
