# shellcheck shell=bash disable=SC2034
# Debug rebuild for the ROCK 5B current Armbian FORWARD-PORT kernel
# (build-kernel.sh flavor: forward-port-debug).
#
# This config intentionally starts from userpatches/linux-rockchip64-current.config,
# which is copied from /boot/config-$(uname -r) by build-kernel.sh. The heavy
# KASAN/lockdep/DMA-debug instrumentation lives in the shared
# ysp-debug-instrumentation.conf.sh fragment (staged alongside), so the
# forward-port and rewrite debug kernels stay byte-identical in debug config.

BOARD="rock-5b"
BRANCH="current"
RELEASE="resolute"
BUILD_DESKTOP="no"
BUILD_MINIMAL="no"
INSTALL_HEADERS="yes"
SHARE_LOGS="no"

# Pin the exact Armbian stable-branch commit used by the installed forward-port
# 6.18.38 package. build-kernel.sh stages the forward-port patches on top.
KERNELBRANCH="commit:e46dc0adfe39724bcf52cea47b8f9c9aed86a394"

# Keep full DWARF/BTF debug data. Armbian may otherwise disable this when RAM
# looks tight, but this box has enough memory and debug symbols are useful.
KERNEL_BTF="yes"

# Defines custom_kernel_config__rock5b_hard_reboot_debug (KASAN, lockdep,
# DMA-API debug, fault injection, pstore, detectors).
# shellcheck source=./ysp-debug-instrumentation.conf.sh
source "$(dirname "${BASH_SOURCE[0]}")/ysp-debug-instrumentation.conf.sh"
