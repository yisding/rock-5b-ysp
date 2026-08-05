# shellcheck shell=bash disable=SC2034
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# Debug rebuild for the ROCK 5B current Armbian FORWARD-PORT kernel
# (build-kernel.sh flavor: forward-port-debug).
#
# This config intentionally starts from userpatches/linux-rockchip64-current.config,
# which is copied from /boot/config-$(uname -r) by build-kernel.sh. The heavy
# KASAN/lockdep/DMA-debug instrumentation lives in the shared
# ysp-debug-instrumentation.conf.sh fragment (staged alongside), so the
# forward-port and rewrite debug kernels stay byte-identical in debug config.

BOARD="rock-5b"
BRANCH="video-port-kasan"

# Load-bearing: rockchip64_common.inc only sets these for the branches it knows
# (current/edge/bleedingedge). A custom slot name falls through its case and the
# build aborts with "BAD config, missing KERNEL_MAJOR_MINOR", so declare them here.
declare -g KERNEL_MAJOR_MINOR="6.18"
declare -g LINUXFAMILY="rockchip64"
declare -g LINUXCONFIG="linux-rockchip64-video-port-kasan"
RELEASE="resolute"
BUILD_DESKTOP="no"
BUILD_MINIMAL="no"
INSTALL_HEADERS="yes"
SHARE_LOGS="no"

# No KERNELBRANCH pin: inherit Armbian's default for a mainline family, which
# config/sources/mainline-kernel.conf.sh resolves to
# "branch:linux-${KERNEL_MAJOR_MINOR}.y" -- the rolling 6.18 stable branch. This
# matches config-rock5b-video-port.conf.sh so the KASAN kernel and the production
# kernel share a base. The built kernel therefore tracks stable and will change
# version between rebuilds; pass ARMBIAN_KERNELBRANCH=commit:<sha> (or pin
# "tag:v6.18.NN" here) when a build has to be reproducible.

# Keep full DWARF/BTF debug data. Armbian may otherwise disable this when RAM
# looks tight, but this box has enough memory and debug symbols are useful.
KERNEL_BTF="yes"

# Defines custom_kernel_config__rock5b_hard_reboot_debug (KASAN, lockdep,
# DMA-API debug, fault injection, pstore, detectors).
# shellcheck source=./ysp-debug-instrumentation.conf.sh
source "$(dirname "${BASH_SOURCE[0]}")/ysp-debug-instrumentation.conf.sh"
