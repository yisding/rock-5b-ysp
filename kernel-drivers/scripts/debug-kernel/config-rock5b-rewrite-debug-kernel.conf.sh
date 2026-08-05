# shellcheck shell=bash disable=SC2034
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# KASAN debug rebuild of the clean-room REWRITE kernel for the ROCK 5B
# (build-kernel.sh flavor: rewrite-debug).
#
# Same heavy-debug instrumentation as the forward-port debug kernel (validation
# plan "Kernel A", shared ysp-debug-instrumentation.conf.sh fragment), but the
# built drivers are the MPP/RGA rewrite: the rewrite + KUnit options are forced
# on and the conflicting vendor forward-port drivers are forced off, mirroring
# the validated rewrite package config
# (packaging/ppa/kernel-rewrite-alpha-6.18/debian/config). KUNIT is promoted to
# =y so the 232 built-in rewrite KUnit cases run at boot under KASAN and can be
# persisted via rewrite-kunit-log-check.sh.
#
# This config intentionally starts from userpatches/linux-rockchip64-current.config,
# which is copied from /boot/config-$(uname -r) by build-kernel.sh.

BOARD="rock-5b"
BRANCH="video-rewrite-kasan"

# Load-bearing: rockchip64_common.inc only sets these for the branches it knows
# (current/edge/bleedingedge). A custom slot name falls through its case and the
# build aborts with "BAD config, missing KERNEL_MAJOR_MINOR", so declare them here.
declare -g KERNEL_MAJOR_MINOR="6.18"
declare -g LINUXFAMILY="rockchip64"
declare -g LINUXCONFIG="linux-rockchip64-video-rewrite-kasan"
RELEASE="resolute"
BUILD_DESKTOP="no"
BUILD_MINIMAL="no"
INSTALL_HEADERS="yes"
SHARE_LOGS="no"

# No KERNELBRANCH pin: inherit Armbian's default for a mainline family, which
# config/sources/mainline-kernel.conf.sh resolves to
# "branch:linux-${KERNEL_MAJOR_MINOR}.y" -- the rolling 6.18 stable branch.
# The built kernel therefore tracks stable and will change version between
# rebuilds; pass ARMBIAN_KERNELBRANCH=commit:<sha> to build-kernel.sh when a
# build has to be reproducible.

# Keep full DWARF/BTF debug data. Armbian may otherwise disable this when RAM
# looks tight, but this box has enough memory and debug symbols are useful.
KERNEL_BTF="yes"

function custom_kernel_config__rock5b_rewrite_drivers() {
	# The rewrite drivers own /dev/mpp_service and /dev/rga; KUnit suites are
	# built in so they run during boot on this debug kernel.
	opts_y+=(
		"KUNIT"
		"ROCKCHIP_MPP_REWRITE"
		"ROCKCHIP_MPP_REWRITE_KUNIT_TEST"
		"ROCKCHIP_RGA_REWRITE"
		"ROCKCHIP_RGA_REWRITE_KUNIT_TEST"
	)
	# Mutually exclusive vendor forward-port drivers (Kconfig makes the tracks
	# exclusive per device node) plus the V4L2 RGA driver, all off in the
	# validated rewrite package config. Disabling ROCKCHIP_MPP_SERVICE also
	# drops its rkvdec2/rkvenc2/AV1 sub-options. The optional DWC PCIe PMU is
	# also disabled for qualification builds because its probe warning is
	# unrelated to the rewrite drivers and obscures warning-clean KUnit boots.
	opts_n+=(
		"DWC_PCIE_PMU"
		"ROCKCHIP_MPP_SERVICE"
		"ROCKCHIP_MULTI_RGA"
		"VIDEO_ROCKCHIP_RGA"
	)
}

# Defines custom_kernel_config__rock5b_hard_reboot_debug (KASAN, lockdep,
# DMA-API debug, fault injection, pstore, detectors).
# shellcheck source=./ysp-debug-instrumentation.conf.sh
source "$(dirname "${BASH_SOURCE[0]}")/ysp-debug-instrumentation.conf.sh"
