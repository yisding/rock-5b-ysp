#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
export LC_ALL=C

PPA="ppa:yi-ding/ubuntu-rock-5b"
EXPECTED_CODENAME="resolute"

FFMPEG_VERSION="7:8.0.3+rockchip+git20260729.33a651a55b-0ubuntu1~rk1"
GRD_VERSION="50.2+rkmpp+git20260729.15.c4ef3c9-0ubuntu1~rk2"
MPP_VERSION="1.5.0+git20260805.a8b19653+ds-0ubuntu1~rk1"
CODEC_UDEV_VERSION="1.1"

# ---------------------------------------------------------------------------
# KERNEL + LIBRGA MUST BE BUMPED TOGETHER.
#
# Forward-port patch 0072 changed 10-bit RGA `vir_w` to a byte stride, patch
# 0074 completed the matching UV-plane offset, and librga 26a50ef applies the
# byte convention to both RASTER and TILE. Mixing either side with an older
# convention does not fail loudly -- it produces wrong chroma. The current
# pair passed the direct P010/P210 raster and compact NV15 raster/TILE hardware
# gates plus the 2026-08-04 production campaign. See status.md W13 and the
# production-validation finding.
# Keep the versions and allowlist entry in one commit whenever either side moves.
# ---------------------------------------------------------------------------
LIBRGA_VERSION="2.2.0+git20260725.26a50ef-0ubuntu1~rk1"
KERNEL_VERSION="6.18.42+rk3588av1fwport20260804-0ubuntu1~rk1"

# Fail closed on any kernel/librga pair that has not been validated together.
# An allowlist, not version arithmetic: "both sides post-0072" is NOT sufficient,
# because a forward-port kernel carrying 0072 without 0074 leaves the UV plane
# offset pixel-scaled even when the stride is byte-literal -- measured on-board
# as silent wrong chroma. Add a row here only with the run that validated it.
SAFE_10BIT_PAIRS=(
    # KERNEL_VERSION|LIBRGA_VERSION|evidence
    "6.18.42+rk3588av1fwport20260804-0ubuntu1~rk1|2.2.0+git20260725.26a50ef-0ubuntu1~rk1|P010/P210 raster + compact NV15 raster/TILE gates; production RGA campaign, on-board 2026-08-04"
)

assert_10bit_pair_is_safe() {
    local entry pair_kernel pair_librga
    for entry in "${SAFE_10BIT_PAIRS[@]}"; do
        IFS='|' read -r pair_kernel pair_librga _ <<< "$entry"
        if [ "$KERNEL_VERSION" = "$pair_kernel" ] &&
           [ "$LIBRGA_VERSION" = "$pair_librga" ]; then
            return 0
        fi
    done
    echo "REFUSING to install: this kernel/librga pair is not on the validated list." >&2
    echo "  KERNEL_VERSION=$KERNEL_VERSION" >&2
    echo "  LIBRGA_VERSION=$LIBRGA_VERSION" >&2
    echo "Since patch 0072 the 10-bit RGA vir_w is a byte stride and librga was" >&2
    echo "changed to match. A straddling pair does not fail loudly -- it produces" >&2
    echo "silent wrong chroma. A kernel with 0072/0073 but without 0074 pairs safely" >&2
    echo "with nothing at all. Validated pairs:" >&2
    for entry in "${SAFE_10BIT_PAIRS[@]}"; do
        IFS='|' read -r pair_kernel pair_librga pair_note <<< "$entry"
        printf '  %s + %s (%s)\n' "$pair_kernel" "$pair_librga" "$pair_note" >&2
    done
    exit 2
}
assert_10bit_pair_is_safe

INCOMPATIBLE_PPAS=(
    ubuntu-rock-5b-experimental
    rock5b-ffmpeg81-upstream
    rock5b-ffmpeg81-rockchip
    rock5b-kernel618-rewrite
    rock5b-kernel72rc2-rewrite
)

# These packages are private/experimental alternatives or audio-stack
# conflicts. Remove them if present so test commands cannot accidentally use a
# private FFmpeg/rewrite kernel or leave applications on standalone PulseAudio
# while GRD captures native PipeWire sinks.
CONFLICT_PACKAGES=(
    ffmpeg-rockchip81
    ffmpeg-rockchip-81
    gnome-remote-desktop-ffmpeg-rk
    gnome-remote-desktop-ffmpeg-mainline
    pulseaudio
    pulseaudio-module-bluetooth
    rockchip-codec-libs
    linux-image-ysp-alpha-6.18-rockchip64
    linux-dtb-ysp-alpha-6.18-rockchip64
    linux-headers-ysp-alpha-6.18-rockchip64
    linux-image-ysp-alpha-7.2-rc2-rockchip64
    linux-dtb-ysp-alpha-7.2-rc2-rockchip64
    linux-headers-ysp-alpha-7.2-rc2-rockchip64
    linux-image-ysp-alpha-7.2-rc3-rockchip64
    linux-dtb-ysp-alpha-7.2-rc3-rockchip64
    linux-headers-ysp-alpha-7.2-rc3-rockchip64
)

# Distro packages required by the integrated stack but intentionally not pinned
# to this PPA. pipewire-audio replaces standalone PulseAudio with
# pipewire-pulse, placing desktop applications and GRD in the same graph.
DISTRO_PACKAGES=(
    pipewire-audio
)

TARGET_PACKAGES=(
    rk3588-codec-udev
    librockchip-mpp1
    librockchip-mpp-dev
    rockchip-mpp-demos
    librga2
    librga-dev
    ffmpeg
    gnome-remote-desktop
    linux-image-ysp-rockchip64
    linux-dtb-ysp-rockchip64
    linux-headers-ysp-rockchip64
)

declare -A TARGET_VERSIONS=(
    [rk3588-codec-udev]="$CODEC_UDEV_VERSION"
    [librockchip-mpp1]="$MPP_VERSION"
    [librockchip-mpp-dev]="$MPP_VERSION"
    [rockchip-mpp-demos]="$MPP_VERSION"
    [librga2]="$LIBRGA_VERSION"
    [librga-dev]="$LIBRGA_VERSION"
    [ffmpeg]="$FFMPEG_VERSION"
    [gnome-remote-desktop]="$GRD_VERSION"
    [linux-image-ysp-rockchip64]="$KERNEL_VERSION"
    [linux-dtb-ysp-rockchip64]="$KERNEL_VERSION"
    [linux-headers-ysp-rockchip64]="$KERNEL_VERSION"
)

ASSUME_YES=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [--yes]

Replace incompatible Rock 5B test packages with the exact system-stack
versions from $PPA. The script:

  * verifies every target version is published before removing old PPA sources;
  * removes the experimental/split PPA sources from APT;
  * removes private FFmpeg, private GRD, rewrite-kernel alternatives, and the
    standalone PulseAudio daemon;
  * safely downgrades the installed FFmpeg 8.1 binary set to FFmpeg 8.0.3;
  * installs MPP, librga, patched GRD, codec permissions, the complete PipeWire
    desktop-audio stack, and the forward-port kernel image, DTBs, and headers;
  * verifies exact installed versions and the h264_rkmpp encoder from
    /usr/bin/ffmpeg, independent of PATH;
  * leaves the current Armbian kernel installed as a recovery option.

Options:
  -y, --yes  Do not ask for confirmation after the APT simulation
  -h, --help Show this help
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        -y|--yes)
            ASSUME_YES=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
    shift
done

for command in apt-cache apt-get apt-mark awk dpkg dpkg-query grep id tr uname usermod; do
    command -v "$command" >/dev/null 2>&1 || die "required command not found: $command"
done

ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "arm64" ]] || die "this PPA stack is published for arm64 only"

# shellcheck disable=SC1091
. /etc/os-release
codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
[[ "$codename" == "$EXPECTED_CODENAME" ]] ||
    die "expected Ubuntu $EXPECTED_CODENAME, found ${codename:-unknown}"

if ((EUID == 0)); then
    SUDO=()
else
    command -v sudo >/dev/null 2>&1 || die "run as root or install sudo"
    SUDO=(sudo)
fi

if ! command -v add-apt-repository >/dev/null 2>&1; then
    "${SUDO[@]}" apt-get update
    "${SUDO[@]}" apt-get install -y software-properties-common
fi

package_has_state() {
    local package=$1
    local state

    state="$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)"
    [[ -n "$state" && "$state" != "un " ]]
}

package_is_installed() {
    local package=$1
    [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)" == "ii " ]]
}

version_is_available() {
    local package=$1
    local version=$2

    apt-cache madison "$package" | awk '{print $3}' | grep -Fqx -- "$version"
}

candidate_is_available() {
    local package=$1
    local candidate

    candidate="$(apt-cache policy "$package" | awk '/Candidate:/ { print $2; exit }')"
    [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

source_is_configured() {
    local slug=$1
    local -a source_paths=(/etc/apt/sources.list.d)

    if [[ -f /etc/apt/sources.list ]]; then
        source_paths+=(/etc/apt/sources.list)
    fi
    grep -Rqs --include='*.list' --include='*.sources' \
        "ppa.launchpadcontent.net/yi-ding/$slug/ubuntu" \
        "${source_paths[@]}" 2>/dev/null
}

running_kernel_uses_package() {
    local package=$1
    local running_kernel=$2

    dpkg-query -L "$package" 2>/dev/null |
        grep -Eq "^/boot/(vmlinuz|Image)-${running_kernel}$|^/lib/modules/${running_kernel}(/|$)"
}

echo "Adding $PPA and checking the complete target set..."
"${SUDO[@]}" add-apt-repository -y -n "$PPA"
"${SUDO[@]}" apt-get update

# Do not remove or replace anything until the complete target set can be
# resolved. This is especially important while a newly recreated PPA is still
# publishing its indexes.
missing_versions=()
for package in "${TARGET_PACKAGES[@]}"; do
    version=${TARGET_VERSIONS[$package]}
    if ! version_is_available "$package" "$version"; then
        missing_versions+=("$package=$version")
    fi
done

missing_packages=()
for package in "${DISTRO_PACKAGES[@]}"; do
    if ! candidate_is_available "$package"; then
        missing_packages+=("$package")
    fi
done

if ((${#missing_versions[@]} || ${#missing_packages[@]})); then
    echo "No existing PPA source was removed and no package was changed." >&2
    if ((${#missing_versions[@]})); then
        echo "These exact versions are not currently available from APT:" >&2
        printf '  %s\n' "${missing_versions[@]}" >&2
    fi
    if ((${#missing_packages[@]})); then
        echo "These distro packages have no install candidate:" >&2
        printf '  %s\n' "${missing_packages[@]}" >&2
    fi
    echo "Wait for the fresh PPA to finish publishing, then run this script again." >&2
    exit 1
fi

echo "The complete target set is available; removing incompatible PPA sources..."
sources_removed=0
for slug in "${INCOMPATIBLE_PPAS[@]}"; do
    if source_is_configured "$slug"; then
        echo "Removing PPA source: ppa:yi-ding/$slug"
        "${SUDO[@]}" add-apt-repository -y -n --remove "ppa:yi-ding/$slug"
        sources_removed=1
    fi
done
if ((sources_removed)); then
    "${SUDO[@]}" apt-get update
fi

declare -a installed_ffmpeg_packages=()
mapfile -t installed_ffmpeg_packages < <(
    dpkg-query -W -f='${binary:Package}\t${source:Package}\t${db:Status-Abbrev}\n' |
        awk -F '\t' -v arch="$ARCH" '
            $2 == "ffmpeg" && $3 == "ii " &&
            ($1 !~ /:/ || $1 ~ (":" arch "$") ) { print $1 }
        '
)

declare -a purge_packages=()
for package in "${CONFLICT_PACKAGES[@]}"; do
    if package_has_state "$package"; then
        purge_packages+=("$package")
    fi
done

# An FFmpeg 8.1 Rockchip build may have introduced ABI-63/61 package names
# that FFmpeg 8.0.3 does not produce. Purge those old-ABI binaries; downgrade
# every shared binary name that exists in both releases in place.
declare -a ffmpeg_downgrade_packages=()
for package in "${installed_ffmpeg_packages[@]}"; do
    if version_is_available "$package" "$FFMPEG_VERSION"; then
        ffmpeg_downgrade_packages+=("$package")
    else
        purge_packages+=("$package")
    fi
done

running_kernel="$(uname -r)"
for package in "${purge_packages[@]}"; do
    if [[ "$package" == linux-image-* ]] && package_is_installed "$package" &&
        running_kernel_uses_package "$package" "$running_kernel"; then
        die "$package owns the running kernel $running_kernel; boot a retained Armbian kernel and rerun"
    fi
done

declare -A install_seen=()
declare -a apt_actions=()
add_install_action() {
    local package=$1
    local version=${2:-}

    if [[ -z "${install_seen[$package]+set}" ]]; then
        if [[ -n "$version" ]]; then
            apt_actions+=("$package=$version")
        else
            apt_actions+=("$package")
        fi
        install_seen[$package]=1
    fi
}

for package in "${ffmpeg_downgrade_packages[@]}"; do
    add_install_action "$package" "$FFMPEG_VERSION"
done
for package in "${TARGET_PACKAGES[@]}"; do
    add_install_action "$package" "${TARGET_VERSIONS[$package]}"
done
for package in "${DISTRO_PACKAGES[@]}"; do
    add_install_action "$package"
done
for package in "${purge_packages[@]}"; do
    apt_actions+=("$package-")
done

held_targets=()
while IFS= read -r package; do
    [[ -n "$package" ]] || continue
    if [[ -n "${install_seen[$package]+set}" ]]; then
        held_targets+=("$package")
    fi
done < <(apt-mark showhold)
if ((${#held_targets[@]})); then
    printf 'error: unhold these target packages before continuing: %s\n' \
        "${held_targets[*]}" >&2
    exit 1
fi

echo
echo "APT simulation (no packages changed yet):"
simulation_output="$(
    "${SUDO[@]}" apt-get -s install --allow-downgrades --reinstall --purge \
        "${apt_actions[@]}"
)"
printf '%s\n' "$simulation_output"

# apt may remove reverse-dependencies while satisfying an explicit purge. Do
# not rely on an operator noticing that in the simulation, especially with
# --yes: only packages already selected above as conflicts may be removed.
declare -A allowed_removals=()
for package in "${purge_packages[@]}"; do
    allowed_removals["${package%%:*}"]=1
done

declare -A unexpected_removal_seen=()
declare -a unexpected_removals=()
while read -r action package _; do
    [[ "$action" == "Remv" || "$action" == "Purg" ]] || continue
    package=${package%%:*}
    if [[ -z "${allowed_removals[$package]+set}" &&
        -z "${unexpected_removal_seen[$package]+set}" ]]; then
        unexpected_removals+=("$package")
        unexpected_removal_seen[$package]=1
    fi
done <<< "$simulation_output"

if ((${#unexpected_removals[@]})); then
    echo "error: APT would remove packages outside the explicit conflict list:" >&2
    printf '  %s\n' "${unexpected_removals[@]}" >&2
    echo "No package changes were applied. Resolve these dependencies manually." >&2
    exit 1
fi

echo
echo "The transaction will install the exact FFmpeg 8.0.3/GRD system stack"
echo "and replace standalone PulseAudio with the PipeWire desktop-audio stack."
if ((${#purge_packages[@]})); then
    echo "It will purge these incompatible alternatives:"
    printf '  %s\n' "${purge_packages[@]}"
fi
echo "Existing distro/Armbian kernels are intentionally retained for recovery."

if ((ASSUME_YES == 0)); then
    [[ -t 0 ]] || die "confirmation requires a terminal; rerun with --yes"
    read -r -p "Apply this transaction? [y/N] " answer
    [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] || {
        echo "Cancelled; no packages were changed."
        exit 0
    }
fi

"${SUDO[@]}" apt-get install -y --allow-downgrades --reinstall --purge \
    "${apt_actions[@]}"

echo
echo "Verifying installed versions..."
verification_failed=0
for package in "${TARGET_PACKAGES[@]}"; do
    expected=${TARGET_VERSIONS[$package]}
    installed="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)"
    if [[ "$installed" != "$expected" ]]; then
        echo "error: $package is $installed; expected $expected" >&2
        verification_failed=1
    fi
done
for package in "${DISTRO_PACKAGES[@]}"; do
    if ! package_is_installed "$package"; then
        echo "error: required distro package $package is not installed" >&2
        verification_failed=1
    fi
done
for package in "${ffmpeg_downgrade_packages[@]}"; do
    installed="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)"
    if [[ "$installed" != "$FFMPEG_VERSION" ]]; then
        echo "error: $package is $installed; expected $FFMPEG_VERSION" >&2
        verification_failed=1
    fi
done
((verification_failed == 0)) || exit 1

[[ -x /usr/bin/ffmpeg ]] || die "the PPA ffmpeg executable is missing from /usr/bin"
if ! /usr/bin/ffmpeg -hide_banner -encoders 2>/dev/null |
    grep -Eq '[[:space:]]h264_rkmpp([[:space:]]|$)'; then
    die "the PPA /usr/bin/ffmpeg does not advertise the h264_rkmpp encoder"
fi

login_user="${SUDO_USER:-}"
if [[ -z "$login_user" ]] && ((EUID != 0)); then
    login_user="${USER:-}"
fi
if [[ -n "$login_user" ]] &&
    ! id -nG "$login_user" | tr ' ' '\n' | grep -qx video; then
    "${SUDO[@]}" usermod -aG video "$login_user"
    echo "Added $login_user to the video group."
fi

echo
echo "Clean Rock 5B system-stack installation completed successfully."
echo "FFmpeg: $FFMPEG_VERSION"
echo "GNOME Remote Desktop: $GRD_VERSION"
echo "Forward-port kernel: $KERNEL_VERSION"
echo "Reboot, select the YSP kernel, and retain the Armbian entry for recovery."
