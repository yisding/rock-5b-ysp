#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

PPA="ppa:yi-ding/ubuntu-rock-5b"
EXPECTED_CODENAME="resolute"

if [[ "$(dpkg --print-architecture)" != "arm64" ]]; then
    echo "error: this PPA stack is published for arm64 only" >&2
    exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release
codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
if [[ "$codename" != "$EXPECTED_CODENAME" ]]; then
    echo "error: expected Ubuntu $EXPECTED_CODENAME, found ${codename:-unknown}" >&2
    exit 1
fi

if (( EUID == 0 )); then
    SUDO=()
else
    SUDO=(sudo)
fi

"${SUDO[@]}" apt-get update
"${SUDO[@]}" apt-get install -y software-properties-common
"${SUDO[@]}" add-apt-repository -y "$PPA"
"${SUDO[@]}" apt-get update
"${SUDO[@]}" apt-get install -y \
    rk3588-codec-udev \
    librockchip-mpp1 \
    librockchip-mpp-dev \
    rockchip-mpp-demos \
    librga2 \
    librga-dev \
    ffmpeg \
    gnome-remote-desktop \
    pipewire-audio \
    linux-image-ysp-rockchip64 \
    linux-dtb-ysp-rockchip64 \
    linux-headers-ysp-rockchip64

login_user="${SUDO_USER:-}"
if [[ -z "$login_user" ]] && (( EUID != 0 )); then
    login_user="${USER:-}"
fi
if [[ -n "$login_user" ]] && ! id -nG "$login_user" | tr ' ' '\n' | grep -qx video; then
    "${SUDO[@]}" usermod -aG video "$login_user"
    echo "Added $login_user to the video group; log out and back in before testing."
fi

echo
echo "Installed the Rock 5B system stack from $PPA with PipeWire desktop audio."
echo "Verify the selected boot entry before rebooting into the YSP kernel."
