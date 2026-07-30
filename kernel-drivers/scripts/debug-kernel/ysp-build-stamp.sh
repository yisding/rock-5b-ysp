# shellcheck shell=bash
# Armbian extension: put the REAL build time in `uname -v`.
#
# Why this exists. Armbian pins the kernel build stamp for reproducibility:
#
#   KBUILD_BUILD_TIMESTAMP=${kernel_base_revision_date}
#
# where that date is the *checked-out kernel git revision's* date, not wall
# clock (lib/functions/compilation/kernel-make.sh). Every rebuild of the same
# base therefore reports an identical `uname -v`, which is exactly the situation
# the validation runbook warns about — `uname -r` cannot distinguish a debug
# rebuild from stock, and `uname -v` could not either, so identifying a booted
# build meant comparing the vmlinuz md5 against the deb.
#
# With per-slot BRANCHes the release string already separates the four flavors;
# this makes successive builds *within* a slot self-identifying too.
#
# The trade-off, stated plainly: this deliberately breaks byte-level build
# reproducibility. SOURCE_DATE_EPOCH stays pinned (so most of the build is
# unaffected), but two builds of identical source no longer produce an identical
# vmlinux, because the timestamp string is compiled in. The md5-vs-deb identity
# check is unaffected — a given build still matches its own deb — you just lose
# "same source implies same bytes". That is the point: we want builds to be
# telling apart, and the P####-C#### pair remains the source/config identity.
#
# Appended parameters win: make applies the last assignment of a variable on the
# command line, so this overrides Armbian's earlier KBUILD_BUILD_TIMESTAMP
# without patching the Armbian tree.

function custom_kernel_make_params__ysp_real_build_stamp() {
	declare stamp
	stamp="$(LC_ALL=C date -R)"
	display_alert "ysp-build-stamp" "real build timestamp: ${stamp}" "info"
	common_make_params_quoted+=("KBUILD_BUILD_TIMESTAMP=${stamp}")
}

# Append the source commit to the release string. build-kernel.sh passes
# YSP_SOURCE_GSHA=<sha12> (the KERNEL_TREE HEAD its patch series was generated
# from); appending a later LOCALVERSION assignment overrides Armbian's
# kernel-make.sh one by the same last-assignment-wins rule as the timestamp
# above. The result (…-${BRANCH}-${LINUXFAMILY}-g<sha>) is what the ysp
# rewrite-kunit-log-check.sh identity gate parses out of `uname -r`.
function custom_kernel_make_params__ysp_source_gsha() {
	[[ -n "${YSP_SOURCE_GSHA:-}" ]] || return 0
	display_alert "ysp-build-stamp" "source identity: -g${YSP_SOURCE_GSHA}" "info"
	common_make_params_quoted+=("LOCALVERSION=-${BRANCH}-${LINUXFAMILY}-g${YSP_SOURCE_GSHA}")
}

# Make the compiler cache independent of the kernel worktree PATH.
#
# Armbian names the worktree
# cache/sources/linux-kernel-worktree/${KERNEL_MAJOR_MINOR}__${LINUXFAMILY}__${ARCH},
# the kernel compiles -g -gdwarf-5 with no -fdebug-prefix-map, and ccache's
# hash_dir defaults to true -- so the working directory is part of every object's
# cache key. Anything that moves that path (a LINUXFAMILY rename, a kernel series
# bump) silently invalidates the ENTIRE kernel half of the shared store.
# CCACHE_BASEDIR does NOT cover this: measured with -gdwarf-5, the same source
# built in two directories gets 0 hits with CCACHE_BASEDIR set, and 1 hit with
# CCACHE_NOHASHDIR=1.
#
# This is the ONLY available mitigation, not a belt-and-braces one. Pinning
# LINUXFAMILY was tried and measured not to work -- config-prepare.sh:141 resets
# it unconditionally from BOARDFAMILY after any config or command-line value, and
# LINUXSOURCEDIR at :284 is likewise an unconditional declare -g. So the worktree
# path genuinely can move out from under the cache, and nothing upstream of ccache
# can stop it.
#
# ENABLING THIS COSTS ONE FULL COLD BUILD. hash_dir is part of the key
# COMPUTATION, so every object already cached with hash_dir=true becomes
# unreachable the moment it is turned off -- measured: the same file, in the same
# directory, misses when re-compiled with NOHASHDIR against a cache populated
# without it. The benefit is entirely prospective: it starts with the build AFTER
# this one, and only pays off when a path actually moves.
#
# Trade-off, also measured. Same source built in two directories, -g -gdwarf-5,
# CCACHE_BASEDIR set in both:
#
#   default              hits=0 misses=2   b/t.o comp_dir = .../b   (correct)
#   CCACHE_NOHASHDIR=1   hits=1 misses=1   b/t.o comp_dir = .../a   (stale)
#
# So debug info can name the directory of the build that first cached the object,
# until it is rebuilt. Accepted deliberately: throwing away several GB of KASAN
# objects on every path change is the worse trade for a cache this expensive to
# refill, and the path only moves when Armbian renames something.
#
# kernel_make_config is the documented hook for this: kernel-make.sh:79-83 lists
# common_make_envs[@] as available to it, and it runs before the make command is
# assembled at :99. Envs matter because the build runs under `env -i`.
function kernel_make_config__ysp_ccache_nohashdir() {
	display_alert "ysp-build-stamp" "CCACHE_NOHASHDIR=1 (worktree-path-independent cache)" "info"
	common_make_envs+=("CCACHE_NOHASHDIR=1")
	if [[ "${YSP_CCACHE_RECACHE:-no}" == "yes" ]]; then
		display_alert "ysp-build-stamp" "CCACHE_RECACHE=1 (refreshing shared cache entries)" "info"
		common_make_envs+=("CCACHE_RECACHE=1")
	fi
	if [[ "${YSP_CCACHE_NODIRECT:-no}" == "yes" ]]; then
		display_alert "ysp-build-stamp" "CCACHE_NODIRECT=1 (preprocessor-mode cache lookup)" "info"
		common_make_envs+=("CCACHE_NODIRECT=1")
	fi
}

# Force LINUXFAMILY, which is the ONLY seam where that is possible.
#
# config-prepare.sh:141 does an unconditional LINUXFAMILY="${BOARDFAMILY}" after
# every config is sourced, so neither a userpatches config nor a compile.sh
# argument survives -- both were tried and measured failing. But this hook fires
# at :226, after that reset and BEFORE LINUXSOURCEDIR is derived at :284, and
# LINUXFAMILY is never made readonly. So a value set here reaches all three
# consumers: the worktree path, the default patch dir, and the package name.
#
# Why rockchip64: it is what rockchip64_common.inc:28-42 sets for the branches
# Armbian knows (current/edge/bleedingedge). The ysp flavors use a custom BRANCH
# as their per-slot install mechanism, fall through that case, and inherit
# BOARDFAMILY instead -- which Armbian renamed to rockchip-rk3588, silently
# moving the patch dir, the worktree and the package name at once. There is no
# mainline rockchip-rk3588 patch set, so this restores intent rather than pinning
# to something stale.
#
# PAIRED WITH CCACHE_NOHASHDIR above: changing LINUXFAMILY moves the kernel
# worktree, and the CWD is in every ccache object key unless NOHASHDIR is set.
# Enabling this hook without that one throws the whole kernel cache away.
#
# THE 010_ PREFIX IS LOAD-BEARING. Armbian sorts hook implementors by function
# name (extensions.sh:232,239), and common.conf's own
# late_family_config__common_defaults_for_mainline_kernel binds at 500_. Without
# a lower prefix ours sorts last as 500_ysp_*, and common.conf computes
# KERNEL_PATCH_ARCHIVE_BASE (and the KERNELPATCHDIR/LINUXCONFIG defaults) from the
# OLD family -- observed in a real build log as
# "after late_family_config hooks [ KERNEL_PATCH_ARCHIVE_BASE='rockchip-rk3588' ]"
# while LINUXFAMILY had already become rockchip64. Running first keeps the whole
# derived set internally consistent.
#
# build-kernel.sh passes YSP_LINUXFAMILY; unset means "leave Armbian alone".
function late_family_config__010_ysp_force_linuxfamily() {
	[[ -n "${YSP_LINUXFAMILY:-}" ]] || return 0
	[[ "${LINUXFAMILY}" == "${YSP_LINUXFAMILY}" ]] && return 0
	display_alert "ysp-build-stamp" "LINUXFAMILY ${LINUXFAMILY} -> ${YSP_LINUXFAMILY} (late_family_config)" "info"
	declare -g LINUXFAMILY="${YSP_LINUXFAMILY}"

	# Forcing rockchip64 also switches ON two out-of-tree WiFi driver harnesses:
	# drivers_network.sh:438 (rtl8852bs) and :548 (uwe5622) are gated on
	# LINUXFAMILY being spacemit/rk35xx/rockchip64, which rockchip-rk3588 does not
	# match. The seed config already carries CONFIG_RTL8852BS=m and
	# CONFIG_SPARD_WLAN_SUPPORT=y; today olddefconfig drops them because the
	# Kconfig entries do not exist, but after the rename they would exist and
	# compile -- fetching a github tree and rewriting the realtek Makefile/Kconfig
	# in the process.
	#
	# These are video-codec debug kernels. Silently gaining two out-of-tree WiFi
	# drivers is not the change being made here, and they have never been built
	# under KASAN + lockdep at 6.18.40. Skipping keeps the kernel's CONTENT
	# identical to the rockchip-rk3588 build and confines this change to the slot
	# name, which is its entire purpose. KERNEL_DRIVERS_SKIP is hashed into the
	# D#### component (drivers-harness.sh:42-43), so the decision is visible in the
	# package version. Drop these two entries to opt back in deliberately.
	declare -g -a KERNEL_DRIVERS_SKIP
	KERNEL_DRIVERS_SKIP+=(driver_rtl8852bs driver_uwe5622)
	display_alert "ysp-build-stamp" "skipping out-of-tree WiFi drivers pulled in by rockchip64" "info"
}
