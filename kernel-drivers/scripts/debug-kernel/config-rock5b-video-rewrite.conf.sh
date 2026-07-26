# shellcheck shell=bash disable=SC2034
# Production clean-room REWRITE kernel for the ROCK 5B
# (build-kernel.sh flavor: rewrite) — slot `video-rewrite-rockchip64`.
#
# The three `declare -g` lines below are load-bearing. Armbian's
# config/sources/families/include/rockchip64_common.inc sets KERNEL_MAJOR_MINOR,
# LINUXFAMILY and LINUXCONFIG from a `case $BRANCH in current|edge|bleedingedge`
# — a branch it does not know falls straight through, and the build then aborts
# with "BAD config, missing KERNEL_MAJOR_MINOR". Declaring them here is what
# makes a custom slot name work without patching the Armbian tree.
#
# KERNELPATCHDIR DOES need an override, and build-kernel.sh passes one. This
# comment used to claim otherwise -- that common.conf derives
# archive/${KERNEL_PATCH_ARCHIVE_BASE}-${KERNEL_MAJOR_MINOR} and lands on
# rockchip64-6.18 anyway. It does not: KERNEL_PATCH_ARCHIVE_BASE defaults to
# LINUXFAMILY, which for a custom BRANCH falls through rockchip64_common.inc's
# case and inherits BOARDFAMILY (now rockchip-rk3588). Believing this comment is
# exactly how a build once applied ZERO patches and still shipped installable
# debs. See findings/2026-07-25-armbian-linuxfamily-rename-silent-patch-free-kernel.md.

BOARD="rock-5b"
BRANCH="video-rewrite"
RELEASE="resolute"
BUILD_DESKTOP="no"
BUILD_MINIMAL="no"
INSTALL_HEADERS="yes"
SHARE_LOGS="no"

declare -g KERNEL_MAJOR_MINOR="6.18"
declare -g LINUXFAMILY="rockchip64"
# LINUXCONFIG deliberately does NOT follow the slot. It names the kernel
# *config file* Armbian reads, not the slot, and the production build input is
# unchanged from before the re-slot: Armbian's own stock production config.
# Pointing it at a slot-named file would silently change C#### -- seeding one
# from /boot/config-$(uname -r) (which is what the debug flavors do on purpose)
# swaps in the running PPA kernel's configuration and moved C#### b831 -> 435e.
declare -g LINUXCONFIG="linux-rockchip64-current"

# Pin the exact Armbian stable-branch commit
# the rewrite series is built against; build-kernel.sh stages the patches on top.
KERNELBRANCH="commit:e46dc0adfe39724bcf52cea47b8f9c9aed86a394"

KERNEL_BTF="yes"
