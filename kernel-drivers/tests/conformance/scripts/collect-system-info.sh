#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE=${PROFILE:-${1:-rewrite}}
OUT="$ROOT/logs/$PROFILE/$(date +%Y%m%d-%H%M%S)-system"
KERNEL_CONFIG="/boot/config-$(uname -r)"

mkdir -p "$OUT"

section() {
    printf '\n[%s]\n' "$1"
}

redact_boot_ids() {
    sed -E \
        -e 's/(root|resume)=[^ ]+/\1=<redacted>/g' \
        -e 's/^(rootdev=).*/\1<redacted>/'
}

{
    echo "profile=$PROFILE"
    echo "date=$(date -Is)"
    echo "uname=$(uname -a)"
    echo "architecture=$(dpkg --print-architecture 2>/dev/null || uname -m)"

    section "board"
    if [ -r /proc/device-tree/model ]; then
        printf 'model='
        tr -d '\0' < /proc/device-tree/model
        echo
    fi
    if [ -r /proc/device-tree/compatible ]; then
        printf 'compatible='
        tr '\0' ',' < /proc/device-tree/compatible | sed 's/,$//'
        echo
    fi

    section "operating-system"
    if [ -r /etc/os-release ]; then
        cat /etc/os-release
    fi
    if [ -r /etc/armbian-release ]; then
        echo
        echo "[/etc/armbian-release]"
        cat /etc/armbian-release
    fi

    section "boot-profile-redacted"
    if [ -r /proc/cmdline ]; then
        redact_boot_ids < /proc/cmdline
    fi
    if [ -r /boot/armbianEnv.txt ]; then
        echo
        echo "[/boot/armbianEnv.txt selected keys]"
        grep -E \
            '^(verbosity|bootlogo|console|overlay_prefix|overlays|user_overlays|fdtfile|rootdev|rootfstype|extraargs)=' \
            /boot/armbianEnv.txt | redact_boot_ids || true
    fi

    section "installed-support-packages"
    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' \
            2>/dev/null |
            awk -F '\t' '
                $3 ~ /^ii/ &&
                $1 ~ /^(armbian|ffmpeg|gnome-remote-desktop|kodi|libav|librga|librockchip|linux-(dtb|headers|image|u-boot)|rockchip)/ {
                    print $1 "\t" $2
                }
            ' | sort
    fi

    section "ffmpeg-runtime"
    if command -v ffmpeg >/dev/null 2>&1; then
        echo "path=$(command -v ffmpeg)"
        ffmpeg -hide_banner -version 2>&1 | sed -n '1,4p'
        echo
        echo "[rockchip decoders/encoders/filters]"
        ffmpeg -hide_banner -decoders 2>/dev/null | grep -Ei 'rkmpp|rockchip' || true
        ffmpeg -hide_banner -encoders 2>/dev/null | grep -Ei 'rkmpp|rockchip' || true
        ffmpeg -hide_banner -filters 2>/dev/null | grep -Ei 'rkrga|rockchip' || true
    fi

    section "relevant-kernel-config"
    if [ -r "$KERNEL_CONFIG" ]; then
        echo "source=$KERNEL_CONFIG"
        grep -E \
            '^CONFIG_(DMABUF_HEAPS|DRM_PANFROST|DRM_PANTHOR|ROCKCHIP_IOMMU|ROCKCHIP_MPP|ROCKCHIP_RGA|SYNC_FILE|VIDEO_HANTRO|VIDEO_ROCKCHIP)' \
            "$KERNEL_CONFIG" || true
    else
        echo "unavailable=$KERNEL_CONFIG"
    fi

    section "devices"
    id
    for pattern in /dev/mpp_service /dev/rga /dev/video* /dev/dma_heap/* /dev/dri/*; do
        for node in $pattern; do
            [ -e "$node" ] && ls -l "$node"
        done
    done

    section "rga-version"
    for path in /sys/kernel/debug/rkrga/driver_version /proc/rkrga/driver_version; do
        if [ -r "$path" ]; then
            echo "$path:"
            cat "$path"
        fi
    done

    section "mpp-proc-debug"
    for path in /proc/mpp_service /proc/mpp_service/* /sys/kernel/debug/mpp_service/*; do
        if [ -f "$path" ] && [ -r "$path" ]; then
            echo "----- $path"
            cat "$path" || true
        fi
    done

    section "loaded-rockchip-modules"
    lsmod 2>/dev/null | grep -Ei 'rga|mpp|vcodec|vpu|rkv|rockchip' || true
} > "$OUT/system.txt"

dmesg > "$OUT/dmesg.txt" 2>/dev/null || true
dmesg | tail -n 300 > "$OUT/dmesg-tail.txt" 2>/dev/null || true

echo "$OUT"
