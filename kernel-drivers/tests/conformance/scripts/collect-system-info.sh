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

unavailable() {
    printf 'unavailable=%s\n' "$1"
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

    section "cpu-frequency-and-thermal"
    if command -v lscpu >/dev/null 2>&1; then
        lscpu
    else
        unavailable lscpu
    fi
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$policy" ] || continue
        echo
        echo "[$policy]"
        for field in affected_cpus cpuinfo_min_freq cpuinfo_max_freq \
            scaling_driver scaling_governor scaling_cur_freq; do
            if [ -r "$policy/$field" ]; then
                printf '%s=' "$field"
                cat "$policy/$field"
            fi
        done
    done
    for zone in /sys/class/thermal/thermal_zone*; do
        [ -d "$zone" ] || continue
        printf '%s\ttype=' "$(basename "$zone")"
        if [ -r "$zone/type" ]; then
            tr -d '\n' < "$zone/type"
        else
            printf unknown
        fi
        printf '\ttemp_millicelsius='
        if [ -r "$zone/temp" ]; then
            cat "$zone/temp"
        else
            echo unavailable
        fi
    done

    section "memory"
    grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree|CmaTotal|CmaFree):' \
        /proc/meminfo || true

    section "storage"
    if command -v lsblk >/dev/null 2>&1; then
        lsblk --paths --output NAME,TYPE,SIZE,FSTYPE,TRAN,MOUNTPOINTS
    else
        unavailable lsblk
    fi
    if command -v findmnt >/dev/null 2>&1; then
        printf 'root='
        findmnt --noheadings --output SOURCE,FSTYPE,OPTIONS / || true
    else
        unavailable findmnt
    fi

    section "pci-and-usb"
    if command -v lspci >/dev/null 2>&1; then
        lspci -nnk
    else
        unavailable lspci
    fi
    if command -v lsusb >/dev/null 2>&1; then
        lsusb --tree
    else
        unavailable lsusb
    fi

    section "network-links-no-addresses"
    for interface_path in /sys/class/net/*; do
        [ -d "$interface_path" ] || continue
        interface=$(basename "$interface_path")
        printf '%s' "$interface"
        for field in operstate speed duplex; do
            if [ -r "$interface_path/$field" ]; then
                value=$(cat "$interface_path/$field" 2>/dev/null || true)
                if [ -n "$value" ]; then
                    printf '\t%s=%s' "$field" "$value"
                fi
            fi
        done
        if [ -L "$interface_path/device/driver" ]; then
            printf '\tdriver=%s' "$(basename "$(readlink "$interface_path/device/driver")")"
        fi
        echo
    done

    section "drm-connectors"
    found_drm_connector=0
    for status_path in /sys/class/drm/card*-*/status; do
        [ -f "$status_path" ] || continue
        found_drm_connector=1
        connector_dir=$(dirname "$status_path")
        connector=$(basename "$connector_dir")
        printf '%s\tstatus=' "$connector"
        cat "$status_path"
        if [ -s "$connector_dir/modes" ]; then
            sed 's/^/  mode=/' "$connector_dir/modes"
        fi
    done
    if [ "$found_drm_connector" -eq 0 ]; then
        echo "none-detected"
    fi

    section "sound"
    if [ -r /proc/asound/cards ]; then
        cat /proc/asound/cards
    else
        echo "no-/proc/asound/cards"
    fi
    if command -v aplay >/dev/null 2>&1; then
        aplay --list-devices 2>&1 || true
    else
        unavailable aplay
    fi

    section "camera-and-media-graphs"
    if command -v v4l2-ctl >/dev/null 2>&1; then
        v4l2_devices=$(v4l2-ctl --list-devices 2>&1 || true)
        if [ -n "$v4l2_devices" ]; then
            printf '%s\n' "$v4l2_devices"
        else
            echo "v4l2-devices=none-detected"
        fi
    else
        unavailable v4l2-ctl
    fi
    found_media_device=0
    if command -v media-ctl >/dev/null 2>&1; then
        for media_device in /dev/media*; do
            [ -e "$media_device" ] || continue
            found_media_device=1
            echo
            echo "[$media_device]"
            media-ctl --device "$media_device" --print-topology 2>&1 || true
        done
        if [ "$found_media_device" -eq 0 ]; then
            echo "media-devices=none-detected"
        fi
    else
        unavailable media-ctl
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
                $3 ~ /^ii/ && ($1 ~ /^(armbian|ffmpeg|gnome-remote-desktop|kodi|librga|librockchip|rockchip)/ ||
                    $1 ~ /^libav(codec|device|filter|format|util)/ ||
                    $1 ~ /^libsw(resample|scale)/ ||
                    $1 ~ /^(libegl-mesa|libgbm|libgl1-mesa|mesa-)/ ||
                    $1 ~ /^linux-(dtb|headers|image|u-boot)/) {
                    print $1 "\t" $2
                }
            ' | sort -u
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
    for pattern in /dev/mpp_service /dev/rga /dev/rknpu /dev/video* \
        /dev/media* /dev/dma_heap/* /dev/dri/* /dev/gpiochip* /dev/i2c-* \
        /dev/spidev*; do
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
