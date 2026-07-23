# shellcheck shell=bash disable=SC2034
# KASAN debug rebuild of the clean-room REWRITE kernel for the ROCK 5B
# (build-kernel.sh flavor: rewrite-debug).
#
# Same heavy-debug instrumentation as the forward-port debug kernel (validation
# plan "Kernel A", shared ysp-debug-instrumentation.conf.sh fragment), but the
# built drivers are the MPP/RGA rewrite: the rewrite + KUnit options are forced
# on and the conflicting vendor forward-port drivers are forced off, mirroring
# the validated rewrite package config
# (packaging/ppa/kernel-rewrite-alpha-6.18/debian/config). KUNIT is promoted to
# =y so the 208 built-in rewrite KUnit cases run at boot under KASAN and can be
# persisted via rewrite-kunit-log-check.sh.
#
# This config intentionally starts from userpatches/linux-rockchip64-current.config,
# which is copied from /boot/config-$(uname -r) by build-kernel.sh.

BOARD="rock-5b"
BRANCH="current"
RELEASE="resolute"
BUILD_DESKTOP="no"
BUILD_MINIMAL="no"
INSTALL_HEADERS="yes"
SHARE_LOGS="no"

# Pin the exact Armbian stable-branch commit used by the installed forward-port
# 6.18.38 package. build-kernel.sh stages the rewrite series
# (rk3588-rewrite-6.18 tip of linux-6.18-rkvenc) on top.
KERNELBRANCH="commit:e46dc0adfe39724bcf52cea47b8f9c9aed86a394"

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
	# drops its rkvdec2/rkvenc2/AV1 sub-options.
	opts_n+=(
		"ROCKCHIP_MPP_SERVICE"
		"ROCKCHIP_MULTI_RGA"
		"VIDEO_ROCKCHIP_RGA"
	)
}

# Defines custom_kernel_config__rock5b_hard_reboot_debug (KASAN, lockdep,
# DMA-API debug, fault injection, pstore, detectors).
# shellcheck source=./ysp-debug-instrumentation.conf.sh
source "$(dirname "${BASH_SOURCE[0]}")/ysp-debug-instrumentation.conf.sh"
