#!/usr/bin/env bash
# =============================================================================
# build-kernel.sh — unified entry point for every ROCK 5B ysp kernel build
#
# One front-end, explicit flavors. Local flavors drive the external Armbian
# build tree to produce installable .debs; ppa-* flavors delegate to the
# source-package exporter; maxline-* flavors delegate to the pinned upstream
# 7.2-rc3 packaging build. The per-flavor map (source tree, patch prefix,
# config, install path) is documented in
# ../docs/kernel-builds.md — read that first.
#
#   Local Armbian .debs (engine below, ex build-armbian-deb.sh):
#     forward-port         production forward-port kernel (AV1/MPP/RGA vendor port)
#     forward-port-debug   KASAN/lockdep debug build of the forward-port kernel
#     rewrite              production clean-room rewrite kernel (untested flavor)
#     rewrite-debug        KASAN/lockdep debug build of the clean-room rewrite kernel
#
#   Each local flavor installs into its OWN package slot (Armbian BRANCH), so
#   the four kernels coexist: video-port / video-port-kasan / video-rewrite /
#   video-rewrite-kasan, all -rockchip64. `current-rockchip64` is Armbian's own
#   kernel and `ysp-rockchip64` is the PPA lineage; this script writes neither.
#
#   Delegated:
#     ppa-forward-port     unsigned source package (packaging/ppa/build-source-packages.sh kernel)
#     ppa-rewrite-6.18     unsigned source package (… kernel-alpha-6.18)
#     ppa-rewrite-7.2-rc3  unsigned source package (… kernel-alpha-7.2-rc3)
#     ppa-rewrite-7.2-rc5  unsigned source package (… kernel-alpha-7.2-rc5)
#     maxline-public       pinned 7.2-rc3 maxline package (packaging/ppa/kernel-maxline/build-kernel.sh public)
#     maxline-wip          pinned 7.2-rc3 maxline package (… wip)
#
# USAGE
#   bash build-kernel.sh <flavor>                  # build
#   bash build-kernel.sh <flavor> --stage-only     # local flavors: prepare patches/config only
#   bash build-kernel.sh --restore                 # reset Armbian patch archive + generated userpatches
#   bash build-kernel.sh <flavor> --install-deps   # debug flavors: apt-install missing host deps first
#   bash build-kernel.sh forward-port KERNEL_CONFIGURE=yes   # extra args pass through to compile.sh
#   IOMMU_DEBUG=yes bash build-kernel.sh forward-port        # + DMA_API/KALLSYMS/IOMMU_DEBUGFS config
#   ARMBIAN_USE_CCACHE=no bash build-kernel.sh forward-port  # clean retry after config-class changes
#   ARMBIAN_CLEAN_LEVEL=make-kernel bash build-kernel.sh …   # discard all Kbuild metadata
#   KERNEL_TREE=/path PATCH_PREFIX=my-series bash build-kernel.sh forward-port  # expert override
#
# LOCAL-FLAVOR MECHANICS (validated against Armbian 6.18.37/26.08.0-trunk;
# re-check the skip list and core patch names when the Armbian base moves):
#   1. Regenerate the flavor's patch series from its git tree (format-patch
#      BASE_TAG..HEAD, minus SKIP_COMMITS already carried by the Armbian base).
#   2. Reset Armbian patch state; stage the generated series as userpatches.
#   3. Debug flavors: stage the ramoops DT patch, the flavor's Armbian config
#      (which sources the shared debug-instrumentation fragment), and seed the
#      base .config from the running /boot/config-$(uname -r).
#   4. Disable the two Armbian core media patches that collide with this
#      tree's self-contained DT (media-0001 rkvdec, media-0007 vsi AV1 iommu).
#   5. Run ./compile.sh with USE_CCACHE and USE_TMPFS passed as ARGUMENTS
#      (see below).
#   6. Print the new P####-C#### hash and the deb paths.
#
# THE ccache GOTCHA: USE_CCACHE must be a compile.sh command-line ARGUMENT,
# never a shell env var. Armbian can relaunch through Docker or sudo;
# arguments survive both, while the Docker path was observed silently dropping
# a bare env var and leaving ccache OFF. USE_TMPFS is passed the same way for
# the same reason -- and it matters more, because a dropped USE_TMPFS silently
# restores the 99%-of-RAM tmpfs this board cannot survive (see below).
#
# PREREQS: either Docker-capable Linux (default mode) or a supported native
# Armbian/Ubuntu Noble host (`PREFER_DOCKER=no`); ~8 GB RAM, ~50 GB free; the
# Armbian build tree (ARMBIAN_BUILD) already cloned. Cold build ~80-90 min;
# warm ~10-15 (debug flavors longer). See ../../install.md §2.
# =============================================================================
# shellcheck disable=SC2012
set -euo pipefail

# --- Locations -------------------------------------------------------------
# This script lives in the ysp (kernel-drivers/scripts/) but drives EXTERNAL
# workspaces. Defaults assume the grouped dev-box layout
# ~/Code/{rock-5b-ysp,rock-5b/kernel/*}; override ROCK5B_WORKSPACE,
# KERNEL_TREE, ARMBIAN_BUILD, or STAGING for another layout.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # kernel-drivers/scripts
ROOT="$(cd "$HERE/../.." && pwd)"                       # the ysp repository
CODE="$(cd "$ROOT/.." && pwd)"                          # ~/Code (ysp is <CODE>/rock-5b-ysp)
ROCK5B_WORKSPACE="${ROCK5B_WORKSPACE:-$CODE/rock-5b}"
WORKSPACE="${WORKSPACE:-$ROCK5B_WORKSPACE/kernel/rock5b-kernel-build}"  # build scratch (armbian-build + outputs)
ARMBIAN_BUILD="${ARMBIAN_BUILD:-$WORKSPACE/armbian-build}"
BASE_TAG="${BASE_TAG:-v6.18}"                 # local-flavor patches are BASE_TAG..HEAD
# LINUXFAMILY: settable, but ONLY from a late_family_config extension hook.
#
# A compile.sh argument does NOT work and was measured failing:
# config-prepare.sh:141 does an unconditional LINUXFAMILY="${BOARDFAMILY}" after
# configs are sourced, so it clobbers config values and command-line values
# alike. Armbian's own comment on that line concedes it ("this... shouldn't
# happen, extensions might change it too"). A build run with the argument logged
# it applied early, then "already set" after config, and still produced the
# artifact kernel-rockchip-rk3588-video-port-kasan.
#
# The reachable seam is call_extension_method "late_family_config" at :226 --
# after the :141 reset, and before LINUXSOURCEDIR is computed at :284.
# LINUXFAMILY is never made readonly. So the hook lands in time to move all three
# derived values together:
#
#   worktree path  cache/sources/linux-kernel-worktree/${KERNEL_MAJOR_MINOR}__${LINUXFAMILY}__${ARCH}
#   patch dir      archive/${LINUXFAMILY}-${KERNEL_MAJOR_MINOR}
#   package name   linux-image-${BRANCH}-${LINUXFAMILY}
#
# rockchip64 is the value Armbian itself uses for a mainline branch
# (rockchip64_common.inc:28-42, for current/edge/bleedingedge); these flavors use
# a custom BRANCH as their install-slot mechanism, fall through that case, and so
# inherit BOARDFAMILY instead. Forcing it back also realigns the install slot with
# what install-kernel.sh and the docs describe.
#
# Moving the worktree normally costs the entire kernel ccache, because hash_dir
# puts the CWD in every object key -- that is why the extension also sets
# CCACHE_NOHASHDIR=1. The two changes are a pair; do not adopt one without the
# other.
#
# EXPECT THE FIRST BUILD AFTER THIS TO BE FULLY COLD. NOHASHDIR is not a rescue
# for the cache that already exists: hash_dir participates in the key
# computation, so flipping it strands every object stored under the old scheme.
# Measured -- the same file in the same directory misses when rebuilt with
# NOHASHDIR against a cache populated without it. The benefit begins with the
# build after that, and only when a path actually moves.
#
# Forcing the family also enables two out-of-tree WiFi driver harnesses that only
# rockchip64 pulls in; the extension adds them to KERNEL_DRIVERS_SKIP so kernel
# CONTENT stays identical and this change stays confined to the slot name. See
# the hook for the reasoning.
#
# Set ARMBIAN_LINUXFAMILY= (empty) to leave Armbian's value alone.
ARMBIAN_LINUXFAMILY="${ARMBIAN_LINUXFAMILY-rockchip64}"

# The family the produced debs will actually carry, used only for the STEP 6
# result glob: what we force, or -- when the override is disabled -- whatever
# Armbian would default to from the board config.
ARMBIAN_BOARD_CONF="$ARMBIAN_BUILD/config/boards/rock-5b.conf"
if [ -n "$ARMBIAN_LINUXFAMILY" ]; then
	SLOT_FAMILY="$ARMBIAN_LINUXFAMILY"
else
	SLOT_FAMILY="$(sed -n 's/^BOARDFAMILY="\([^"]*\)".*/\1/p' "$ARMBIAN_BOARD_CONF" 2>/dev/null | head -1)"
fi
# Not die(): that is defined further down, and this runs first.
[ -n "$SLOT_FAMILY" ] || {
	printf 'ERROR: could not determine LINUXFAMILY (BOARDFAMILY unreadable in %s)\n' "$ARMBIAN_BOARD_CONF" >&2
	exit 1
}

# Armbian kernel patch archive branch. Deliberately NOT derived from the family
# above: the family is whatever Armbian currently says, while this names the
# directory that actually exists and holds the 177 core patches this tree has
# always built against. Names BOTH the directory this script stages into and the
# one Armbian reads from -- see ARMBIAN_KERNELPATCHDIR below.
KBRANCH="${KBRANCH:-rockchip64-6.18}"

# THE SILENT-NO-OP GOTCHA: Armbian derives KERNELPATCHDIR as
# "archive/${LINUXFAMILY}-${KERNEL_MAJOR_MINOR}" (config/sources/common.conf) and
# these flavors use a custom BRANCH that falls through the family config's case,
# so the value follows whatever family the Armbian tree currently assigns the
# board. When Armbian renamed rock-5b's BOARDFAMILY rockchip64 ->
# rockchip-rk3588, Armbian started reading archive/rockchip-rk3588-6.18 while
# this script kept staging into archive/rockchip64-6.18. That directory does not
# exist, so BOTH the core patches and all 75 generated userpatches were skipped
# -- with no error. The build succeeded and produced installable debs containing
# a stock kernel with none of the vendor video port in it.
#
# Passing KERNELPATCHDIR explicitly makes this script authoritative: Armbian only
# defaults it when unset, so an explicit value always wins and cannot drift with
# the board's family again. Pass it as an ARGUMENT for the same reason
# USE_CCACHE is one -- arguments survive the Docker relaunch.
ARMBIAN_KERNELPATCHDIR="${ARMBIAN_KERNELPATCHDIR:-archive/$KBRANCH}"
# Empty by default, so each flavor's Armbian config owns its kernel base rather
# than this script overriding all four. Local flavor configs carry no pin by
# default and therefore follow Armbian's rolling
# linux-${KERNEL_MAJOR_MINOR}.y stable branch.
#
# The tradeoff is deliberate: a rebuild can now pick up a newer stable base and
# turn a two-patch change into an unrelated stable rebase. Pin explicitly when a
# build has to be reproducible or comparable to an earlier one:
#   ARMBIAN_KERNELBRANCH=commit:<sha> bash build-kernel.sh forward-port-debug
ARMBIAN_KERNELBRANCH="${ARMBIAN_KERNELBRANCH:-}"
ARMBIAN_USE_CCACHE="${ARMBIAN_USE_CCACHE:-yes}"
ARMBIAN_CLEAN_LEVEL="${ARMBIAN_CLEAN_LEVEL:-}"
# Armbian's prepare_tmpfs_for() mounts BOTH WORKDIR and LOGDIR as tmpfs at
# size=99% -- observed live as two mounts of 16021764k each on a board with
# 16183596k of RAM. It is opt-out only (USE_TMPFS=no); there is no size knob.
# tmpfs is unreclaimable in the way that matters here: pages can only be pushed
# to swap, never dropped like page cache, and they outlive the process that
# wrote them, so an OOM daemon cannot recover from a tmpfs fill -- it just kills
# victims while the memory stays gone. On this 16 GB board with zram-backed
# swap that is a wedge risk, and WORKDIR artifacts land on NVMe anyway.
# Override with ARMBIAN_USE_TMPFS=yes only on a host with RAM to spare.
ARMBIAN_USE_TMPFS="${ARMBIAN_USE_TMPFS:-no}"
# Commit(s) present in the ported trees only because the local branches track
# fixes that the validated Armbian source base already carries. Keep them out
# of generated userpatches or Armbian will reject them as reversed.
SKIP_COMMITS="${SKIP_COMMITS:-e059aad8d68b}"
# Subject fallback for the same class of skip. Rebasing the rewrite stack can
# rewrite a commit SHA while preserving the duplicate already-carried patch.
SKIP_SUBJECTS="${SKIP_SUBJECTS:-tools: libbpf: make kallsyms helpers const-correct}"

# Armbian core patches that collide with the trees' self-contained DT.
DISABLE_PATCHES=(
	"media-0001-Add-rkvdec-Support-v5.patch"
	"media-0007-add-verisilicon-AV1-iommu-driver.patch"
)

UP_DIR="$ARMBIAN_BUILD/userpatches/kernel/archive/$KBRANCH"
CORE_DIR="$ARMBIAN_BUILD/patch/kernel/archive/$KBRANCH"
DEBS="$ARMBIAN_BUILD/output/debs"

# Opt-in IOMMU/DMA debug observability for the production forward-port flavor.
# OFF by default so normal debs stay clean. IOMMU_DEBUG=yes stages an Armbian
# EXTENSION (userpatches/extensions/ysp-iommu-debug.sh) whose
# custom_kernel_config hook enables DMA_API_DEBUG / KALLSYMS_ALL /
# IOMMU_DEBUGFS etc., and passes ENABLE_EXTENSIONS on the compile.sh line so the
# extension manager actually loads it. NOTE: userpatches/lib.config does NOT work
# for this -- Armbian sources it AFTER extension-manager init, so hook functions
# defined there are never registered ("wishful hooking"; see main-config.sh). The
# stock config path applies no user .config and userpatches are regenerated each
# build, so the extension has to be (re)staged here rather than dropped in by hand.
IOMMU_DEBUG="${IOMMU_DEBUG:-no}"
USERPATCHES_DIR="$ARMBIAN_BUILD/userpatches"
EXT_DIR="$USERPATCHES_DIR/extensions"
DEBUG_EXT_NAME="ysp-iommu-debug"
DEBUG_EXT="$EXT_DIR/$DEBUG_EXT_NAME.sh"
DEBUG_HOOK_SRC="$HERE/../patches/iommu-debug/extensions/$DEBUG_EXT_NAME.sh"
LEGACY_LIBCONFIG="$USERPATCHES_DIR/lib.config"   # removed if present (old broken path)
YSP_DEBUG_MARKER="ysp-iommu-debug (staged by the ysp kernel build tooling)"
YSP_DEBUG_MARKER_LEGACY="ysp-iommu-debug (generated by build-armbian-deb.sh)"

# Heavy-debug config machinery shared by the *-debug flavors. Both tracked
# Armbian configs source the same instrumentation fragment; the sweep below
# recognizes every tracked pair so a leftover debug config never silently
# shapes a production build.
DEBUG_KERNEL_DIR="$HERE/debug-kernel"
DEBUG_FRAGMENT_NAME="ysp-debug-instrumentation.conf.sh"
# Armbian resolves LINUXCONFIG as linux-${LINUXFAMILY}-${BRANCH}, so the staged
# user config has to follow the slot. Set after flavor selection.
USER_KERNEL_CONFIG=""
STAMP_EXT_NAME="ysp-build-stamp"
RAMOOPS_PATCH_SOURCE="$HERE/../patches/debug-kernel/0001-arm64-dts-rockchip-add-persistent-ramoops-to-rock-5b.patch"
RAMOOPS_PATCH_DEST="$UP_DIR/zz-rock5b-debug-ramoops.patch"

say() { printf '>>> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
	sed -n '2,/^# LOCAL-FLAVOR MECHANICS/p' "${BASH_SOURCE[0]}" |
		sed '$d' | sed 's/^# \{0,1\}//'
}

# --- flavor + mode selection ------------------------------------------------
FLAVOR=""
MODE="build"
install_deps=no
PASSTHROUGH=()
for arg in "$@"; do
	case "$arg" in
		--restore) MODE="restore" ;;
		--stage-only) MODE="stage-only" ;;
		--install-deps) install_deps=yes ;;
		-h|--help) usage; exit 0 ;;
		-*) die "unknown option: $arg" ;;
		*)
			if [ -z "$FLAVOR" ]; then FLAVOR="$arg"; else PASSTHROUGH+=("$arg"); fi
			;;
	esac
done

# --- delegated flavors ------------------------------------------------------
case "$FLAVOR" in
	ppa-forward-port|ppa-rewrite-6.18|ppa-rewrite-7.2-rc3|ppa-rewrite-7.2-rc5)
		[ "$MODE" = "build" ] || die "$FLAVOR does not support --$MODE"
		case "$FLAVOR" in
			ppa-forward-port)    target="kernel" ;;
			ppa-rewrite-6.18)    target="kernel-alpha-6.18" ;;
			ppa-rewrite-7.2-rc3) target="kernel-alpha-7.2-rc3" ;;
			ppa-rewrite-7.2-rc5) target="kernel-alpha-7.2-rc5" ;;
		esac
		say "delegating to packaging/ppa/build-source-packages.sh $target"
		exec bash "$ROOT/packaging/ppa/build-source-packages.sh" "$target" \
			${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
		;;
	maxline-public|maxline-wip)
		[ "$MODE" = "build" ] || die "$FLAVOR does not support --$MODE"
		say "delegating to packaging/ppa/kernel-maxline/build-kernel.sh ${FLAVOR#maxline-}"
		exec bash "$ROOT/packaging/ppa/kernel-maxline/build-kernel.sh" "${FLAVOR#maxline-}" \
			${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
		;;
esac

# --- local flavor table -----------------------------------------------------
# KERNEL_TREE = the kernel git tree carrying the flavor's commits
# (format-patch source). PATCH_PREFIX names the generated userpatches so they
# sort after Armbian's media-* patches (proven-good order) and switching
# flavors cannot leave ambiguous leftovers.
# FLAVOR_BRANCH is the Armbian BRANCH, and it is the whole slot mechanism:
# Armbian derives BOTH the package name (linux-image-${BRANCH}-${LINUXFAMILY})
# and the kernel release string (LOCALVERSION=-${BRANCH}-${LINUXFAMILY}, so
# /boot/vmlinuz-*, /lib/modules/* and the headers dir) from it. Giving every
# flavor its own BRANCH is what keeps four kernels installable side by side.
#
#   flavor              slot (package + release suffix)
#   forward-port        video-port-rockchip64
#   forward-port-debug  video-port-kasan-rockchip64
#   rewrite             video-rewrite-rockchip64
#   rewrite-debug       video-rewrite-kasan-rockchip64
#
# `current-rockchip64` is left to Armbian's own stock kernel and is never
# written by this script. The PPA packages are a separate lineage entirely and
# keep their own `ysp-rockchip64` slot (packaging/ppa/kernel-forward-port).
FLAVOR_CONFIG_NAME=""     # Armbian named config; every local flavor has one
FLAVOR_IS_DEBUG=0         # 1 for the KASAN/lockdep flavors only
FLAVOR_BRANCH=""          # Armbian BRANCH == our slot name
FLAVOR_BRANCH_GUARD=""    # required checked-out branch of KERNEL_TREE, if any
FLAVOR_VERIFY_CONFIGS="${FLAVOR_VERIFY_CONFIGS:-}"  # required symbols in the packaged config
case "$FLAVOR" in
	forward-port)
		KERNEL_TREE="${KERNEL_TREE:-$ROCK5B_WORKSPACE/kernel/linux-6.18-rkvenc-av1-fwport}"
		PATCH_PREFIX="${PATCH_PREFIX:-rk3588-av1-fwport}"
		STAGING="${STAGING:-$WORKSPACE/forward-port/patches}"
		FLAVOR_CONFIG_NAME="rock5b-video-port"
		FLAVOR_BRANCH="video-port"
		FLAVOR_VERIFY_CONFIGS="${FLAVOR_VERIFY_CONFIGS:-CONFIG_ROCKCHIP_MPP_RKVDEC2}"
		;;
	forward-port-debug)
		KERNEL_TREE="${KERNEL_TREE:-$ROCK5B_WORKSPACE/kernel/linux-6.18-rkvenc-av1-fwport}"
		PATCH_PREFIX="${PATCH_PREFIX:-rk3588-av1-fwport}"
		STAGING="${STAGING:-$WORKSPACE/forward-port/patches}"
		FLAVOR_CONFIG_NAME="rock5b-debug-kernel"
		FLAVOR_IS_DEBUG=1
		FLAVOR_BRANCH="video-port-kasan"
		FLAVOR_VERIFY_CONFIGS="${FLAVOR_VERIFY_CONFIGS:-CONFIG_ROCKCHIP_MPP_RKVDEC2}"
		;;
	rewrite)
		KERNEL_TREE="${KERNEL_TREE:-$ROCK5B_WORKSPACE/kernel/linux-6.18-rkvenc}"
		PATCH_PREFIX="${PATCH_PREFIX:-rk3588-rewrite}"
		STAGING="${STAGING:-$WORKSPACE/rewrite/patches}"
		FLAVOR_CONFIG_NAME="rock5b-video-rewrite"
		FLAVOR_BRANCH="video-rewrite"
		FLAVOR_BRANCH_GUARD="rk3588-rewrite-6.18"
		FLAVOR_VERIFY_CONFIGS="${FLAVOR_VERIFY_CONFIGS:-CONFIG_ROCKCHIP_MPP_REWRITE CONFIG_ROCKCHIP_RGA_REWRITE}"
		;;
	rewrite-debug)
		KERNEL_TREE="${KERNEL_TREE:-$ROCK5B_WORKSPACE/kernel/linux-6.18-rkvenc}"
		PATCH_PREFIX="${PATCH_PREFIX:-rk3588-rewrite}"
		STAGING="${STAGING:-$WORKSPACE/rewrite/patches}"
		FLAVOR_CONFIG_NAME="rock5b-rewrite-debug-kernel"
		FLAVOR_IS_DEBUG=1
		FLAVOR_BRANCH="video-rewrite-kasan"
		FLAVOR_BRANCH_GUARD="rk3588-rewrite-6.18"
		FLAVOR_VERIFY_CONFIGS="${FLAVOR_VERIFY_CONFIGS:-CONFIG_ROCKCHIP_MPP_REWRITE CONFIG_ROCKCHIP_RGA_REWRITE}"
		;;
	"")
		[ "$MODE" = "restore" ] || { usage >&2; exit 2; }
		;;
	*)
		die "unknown flavor: $FLAVOR (see --help)"
		;;
esac

# Only the debug flavors stage a user config (seeded from /boot, then given
# KASAN/lockdep). Production flavors read Armbian's stock config, so a
# production C#### stays comparable across the re-slot.
if [ "$FLAVOR_IS_DEBUG" = 1 ]; then
	USER_KERNEL_CONFIG="$USERPATCHES_DIR/linux-rockchip64-$FLAVOR_BRANCH.config"
fi

# The build-stamp extension is flavor-independent: it puts the real wall-clock
# build time in `uname -v` (Armbian otherwise pins it to the kernel git revision
# date, making successive builds indistinguishable). See its header for the
# reproducibility trade-off.
stage_build_stamp_extension() {
	install -D -m 0644 "$DEBUG_KERNEL_DIR/$STAMP_EXT_NAME.sh" \
		"$USERPATCHES_DIR/extensions/$STAMP_EXT_NAME.sh"
}

reset_core_patches() {
	local rel_core_dir="patch/kernel/archive/$KBRANCH"

	say "STEP 0: reset Armbian built-in patch archive in $CORE_DIR"
	[ -d "$CORE_DIR" ] || die "Armbian kernel patch archive not found: $CORE_DIR (wrong KBRANCH?)"
	if git -C "$ARMBIAN_BUILD" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "$ARMBIAN_BUILD" checkout -- "$rel_core_dir"
		git -C "$ARMBIAN_BUILD" clean -f -- "$rel_core_dir" | sed 's/^/      /'
	else
		say "  WARNING: $ARMBIAN_BUILD is not a git tree; only restoring *.patch.disabled files"
		find "$CORE_DIR" -maxdepth 1 -type f -name '*.patch.disabled' -print |
			while IFS= read -r disabled; do
				mv -v "$disabled" "${disabled%.disabled}"
			done | sed 's/^/      /'
	fi
}

reset_userpatches() {
	say "  clear generated Armbian userpatches in $UP_DIR"
	mkdir -p "$UP_DIR"
	find "$UP_DIR" -maxdepth 1 -type f -name '*.patch' -print -delete |
		sed 's/^/      removed /'
}

# Stage (or remove) the IOMMU/DMA debug extension. Idempotent and authoritative
# each run: IOMMU_DEBUG=yes installs it, anything else removes our copy so a debug
# build never silently leaks into the next production build. Guards against
# clobbering a hand-written extension that isn't ours. The matching
# ENABLE_EXTENSIONS=$DEBUG_EXT_NAME arg is added to compile.sh below.
ours_debug_ext() {
	grep -qF "$YSP_DEBUG_MARKER" "$1" || grep -qF "$YSP_DEBUG_MARKER_LEGACY" "$1"
}
stage_debug_config() {
	mkdir -p "$EXT_DIR"
	# Sweep any leftover from the old, broken lib.config approach (ours only).
	if [ -f "$LEGACY_LIBCONFIG" ] && ours_debug_ext "$LEGACY_LIBCONFIG"; then
		rm -v "$LEGACY_LIBCONFIG" | sed 's/^/      removed stale /'
	fi
	if [ -f "$DEBUG_EXT" ] && ! ours_debug_ext "$DEBUG_EXT"; then
		die "$DEBUG_EXT exists and is not ours; remove or merge from $DEBUG_HOOK_SRC by hand"
	fi
	if [ "$IOMMU_DEBUG" = "yes" ]; then
		[ -f "$DEBUG_HOOK_SRC" ] || die "IOMMU_DEBUG=yes but extension not found: $DEBUG_HOOK_SRC"
		cp -v "$DEBUG_HOOK_SRC" "$DEBUG_EXT" | sed 's/^/      /'
		say "  IOMMU_DEBUG=yes -> extension '$DEBUG_EXT_NAME' will enable DMA_API_DEBUG/KALLSYMS_ALL/IOMMU_DEBUGFS"
	elif [ -f "$DEBUG_EXT" ]; then
		rm -v "$DEBUG_EXT" | sed 's/^/      removed /'
	fi
}

# Historically every flavor built on BRANCH=current, so all four shared one
# userpatches config name (linux-rockchip64-current.config). A debug flavor
# seeded it from /boot, and Armbian gives a userpatch config precedence over its
# own, so a leftover seed could silently carry a debug C#### into a production
# build. That hazard is gone: each slot now has its own BRANCH and therefore its
# own config filename, so a debug slot's seed cannot be read by a production
# one. What remains is housekeeping -- drop the stale shared-slot artefacts from
# the old scheme, and the debug fragment when it is ours.
reset_debug_kernel_config() {
	local fragment legacy
	fragment="$USERPATCHES_DIR/$DEBUG_FRAGMENT_NAME"
	if [ -f "$fragment" ] && [ -f "$DEBUG_KERNEL_DIR/$DEBUG_FRAGMENT_NAME" ] &&
	   cmp -s "$DEBUG_KERNEL_DIR/$DEBUG_FRAGMENT_NAME" "$fragment"; then
		rm -v "$fragment" | sed 's/^/      removed stale debug fragment /'
	fi

	# `current-rockchip64` belongs to Armbian's own kernel now; nothing this
	# script builds may leave a config sitting in that slot.
	legacy="$USERPATCHES_DIR/linux-rockchip64-current.config"
	if [ -f "$legacy" ]; then
		rm -v "$legacy" |
			sed 's/^/      removed pre-slot shared kernel config /'
		if [ -z "$ARMBIAN_CLEAN_LEVEL" ]; then
			ARMBIAN_CLEAN_LEVEL="make-kernel"
			say "  forcing CLEAN_LEVEL=make-kernel to discard pre-slot Kbuild metadata"
		fi
	fi
}

# Debug flavors: stage the ramoops DT patch, the flavor's tracked Armbian
# config plus the shared instrumentation fragment it sources, and seed the
# base .config from the running kernel.
stage_flavor_debug_files() {
	# Reinstalled unconditionally on purpose: STEP 2+3's rsync --delete drops this
	# patch (it is not part of the generated series), and that deletion is what
	# keeps it OFF production builds, which have no counterpart that removes it.
	install -D -m 0644 "$RAMOOPS_PATCH_SOURCE" "$RAMOOPS_PATCH_DEST"
	install -D -m 0644 "$DEBUG_KERNEL_DIR/config-$FLAVOR_CONFIG_NAME.conf.sh" \
		"$USERPATCHES_DIR/config-$FLAVOR_CONFIG_NAME.conf.sh"
	install -D -m 0644 "$DEBUG_KERNEL_DIR/$DEBUG_FRAGMENT_NAME" \
		"$USERPATCHES_DIR/$DEBUG_FRAGMENT_NAME"

	# STICKY SEED. This used to re-copy /boot/config-$(uname -r) on every build,
	# which is both a cache and a correctness hazard:
	#
	#   - Every kernel TU force-includes include/linux/kconfig.h, which includes
	#     generated/autoconf.h, so ONE changed CONFIG symbol changes the hash of
	#     EVERY object. A drifting seed costs 100% of the kernel ccache, not "a
	#     few misses".
	#   - It is a feedback loop: boot the KASAN kernel this builds, and the next
	#     debug build seeds from a KASAN kernel's own config (KASAN, lockdep and
	#     ramoops already enabled) instead of a production one. The C#### hash
	#     moving b831 -> 435e in config-rock5b-video-port.conf.sh is this effect.
	#
	# So capture it once and then leave it alone. Refresh deliberately with
	# RESEED_CONFIG=1 when the intent really is to track the running kernel.
	local running_config
	running_config="/boot/config-$(uname -r)"
	if [ -s "$USER_KERNEL_CONFIG" ] && [ "${RESEED_CONFIG:-0}" != 1 ]; then
		say "  reusing captured seed config $USER_KERNEL_CONFIG"
		say "    (sha256 $(sha256sum "$USER_KERNEL_CONFIG" | cut -c1-16)…; RESEED_CONFIG=1 to refresh from $running_config)"
	elif [ -r "$running_config" ]; then
		cp -v "$running_config" "$USER_KERNEL_CONFIG" | sed 's/^/      /'
		say "    captured seed sha256 $(sha256sum "$USER_KERNEL_CONFIG" | cut -c1-16)…"
	else
		die "no seed config: $USER_KERNEL_CONFIG is absent and $running_config is unreadable"
	fi
}

verify_flavor_debug_files() {
	[ -s "$USERPATCHES_DIR/config-$FLAVOR_CONFIG_NAME.conf.sh" ] ||
		die "debug Armbian config missing after staging: $USERPATCHES_DIR/config-$FLAVOR_CONFIG_NAME.conf.sh"
	[ -s "$USERPATCHES_DIR/$DEBUG_FRAGMENT_NAME" ] ||
		die "debug instrumentation fragment missing after staging: $USERPATCHES_DIR/$DEBUG_FRAGMENT_NAME"
	[ -s "$USER_KERNEL_CONFIG" ] ||
		die "debug seed kernel config missing after staging: $USER_KERNEL_CONFIG"
}

check_debug_build_deps() {
	local missing=() pkg
	for pkg in \
		build-essential bc bison flex libssl-dev libelf-dev fakeroot rsync git pahole \
		device-tree-compiler python3 python3-pip python3-setuptools swig libncurses-dev; do
		if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
			missing+=("$pkg")
		fi
	done
	if ((${#missing[@]})); then
		printf 'Missing build packages: %s\n' "${missing[*]}" >&2
		if [ "$install_deps" = yes ]; then
			sudo apt-get update
			sudo apt-get install -y "${missing[@]}"
		else
			printf 'Install them with:\n' >&2
			printf '  sudo apt-get update\n' >&2
			printf '  sudo apt-get install -y %s\n' "${missing[*]}" >&2
			printf '\nThen rerun, or rerun with --install-deps.\n' >&2
			exit 2
		fi
	fi
}

if [ "$MODE" = "restore" ]; then
	[ ${#PASSTHROUGH[@]} -eq 0 ] || die "--restore does not accept compile arguments"
	reset_core_patches
	reset_userpatches
	IOMMU_DEBUG=no stage_debug_config
	exit 0
fi

# --- Sanity ----------------------------------------------------------------
git -C "$KERNEL_TREE" rev-parse --git-dir >/dev/null 2>&1 || die "$KERNEL_TREE is not a git tree"
git -C "$KERNEL_TREE" rev-parse "$BASE_TAG" >/dev/null 2>&1 || die "base tag '$BASE_TAG' not found in $KERNEL_TREE"
[ -x "$ARMBIAN_BUILD/compile.sh" ] || die "Armbian build tree not found: $ARMBIAN_BUILD (set ARMBIAN_BUILD=)"
[ -d "$CORE_DIR" ] || die "Armbian kernel patch archive not found: $CORE_DIR (wrong KBRANCH?)"

if [ -n "$FLAVOR_BRANCH_GUARD" ]; then
	# This tree is shared with other work (forward-port/audit branches); the
	# series is format-patched from HEAD, so fail closed on the wrong branch
	# or a dirty tree.
	head_branch="$(git -C "$KERNEL_TREE" symbolic-ref --short -q HEAD || true)"
	[ "$head_branch" = "$FLAVOR_BRANCH_GUARD" ] ||
		die "$KERNEL_TREE is on branch '${head_branch:-<detached>}', expected '$FLAVOR_BRANCH_GUARD'; check it out first"
	[ -z "$(git -C "$KERNEL_TREE" status --porcelain)" ] ||
		die "$KERNEL_TREE has uncommitted changes; commit or stash before building"
fi

# =============================================================================
reset_core_patches

# =============================================================================
say "STEP 1: regenerate $FLAVOR patches from git ($BASE_TAG..HEAD)"
NCOMMITS=$(git -C "$KERNEL_TREE" rev-list --count "$BASE_TAG"..HEAD)
say "  $NCOMMITS commits on top of $BASE_TAG:"
git -C "$KERNEL_TREE" log --oneline "$BASE_TAG"..HEAD | sed 's/^/      /'
rm -rf "$STAGING"; mkdir -p "$STAGING"
git -C "$KERNEL_TREE" format-patch --no-signature -o "$STAGING" "$BASE_TAG"..HEAD >/dev/null
# Match on the full sha in the patch BODY, not on a filename built from %f.
# git truncates generated FILENAMES at format.filenameMaxLength (default 64) but
# does NOT truncate %f, so any commit whose subject exceeds ~52 characters could
# never match -- and `[ -e "$f" ] || continue` made that miss completely silent.
# Several commits in this tree are already over that limit. A skip that silently
# does nothing leaves an already-carried patch in the series, and Armbian then
# aborts with "Patching error" from patch -N, naming nothing useful.
for commit in $SKIP_COMMITS; do
	sha=$(git -C "$KERNEL_TREE" rev-parse --verify "$commit^{commit}" 2>/dev/null || true)
	if [ -z "$sha" ]; then
		say "  WARNING: SKIP_COMMITS entry not found in kernel tree: $commit"
		continue
	fi
	if ! git -C "$KERNEL_TREE" merge-base --is-ancestor "$sha" HEAD ||
	   git -C "$KERNEL_TREE" merge-base --is-ancestor "$sha" "$BASE_TAG"; then
		say "  skip entry not in generated range: $commit"
		continue
	fi
	matched=0
	while IFS= read -r f; do
		matched=1
		say "  skipping Armbian-base commit: $(basename "$f")"
		rm -f "$f"
	done < <(grep -l "^From $sha " "$STAGING"/*.patch 2>/dev/null || true)
	((matched)) || say "  WARNING: SKIP_COMMITS $commit ($sha) generated no patch to skip"
done
while IFS= read -r subject; do
	[ -n "$subject" ] || continue
	while IFS= read -r f; do
		say "  skipping Armbian-base subject: $(basename "$f")"
		rm -f "$f"
	done < <(grep -l -F "$subject" "$STAGING"/*.patch 2>/dev/null || true)
done <<< "$SKIP_SUBJECTS"
# Prefix so they sort after Armbian's media-* patches (proven-good order) and
# are clearly distinct across flavors and from the old rk3588-rkvenc2-* set.
for f in "$STAGING"/0*.patch; do
	base=$(basename "$f")
	mv "$f" "$STAGING/$PATCH_PREFIX-$base"
done
say "  generated $(ls "$STAGING"/"$PATCH_PREFIX"-*.patch | wc -l) patches into $STAGING"

# =============================================================================
say "STEP 2+3: sync generated userpatches into $UP_DIR"
# This archive directory is generated state for these kernel builds, and the end
# state is exactly the flavor's generated series: --delete still drops patches a
# different flavor left behind, which is what the old reset-then-copy achieved.
#
# The difference is -c (compare by CHECKSUM, not size+mtime): a rebuild whose
# series is unchanged rewrites nothing, so the patch files keep their mtimes
# instead of every file looking brand new to everything downstream. The previous
# unconditional `reset_userpatches` + `cp` guaranteed churn on all 75 patches on
# every single build, even a no-op rebuild.
#
# format-patch output is deterministic for a fixed commit range (--no-signature,
# and the From: date is git's fixed sentinel), so byte-comparison is meaningful.
# -d, not -r: rsync REFUSES --delete without one of them ("--delete does not work
# without --recursive (-r) or --dirs (-d)"), which is a hard usage error, not a
# warning. -d is the right one here -- $STAGING is flat, and -d cannot descend
# into an unexpected subdirectory. --exclude='*' then protects everything in
# $UP_DIR that is not a *.patch, including Armbian's branch_*/board_*/target_*
# subdirectories and the *.patch.disabled files STEP 4 creates.
command -v rsync >/dev/null || die "rsync is required to stage userpatches"
mkdir -p "$UP_DIR"
rsync -cd --delete --itemize-changes \
	--include='*.patch' --exclude='*' \
	"$STAGING"/ "$UP_DIR"/ | sed 's/^/      /'
say "  userpatches now:"; ls "$UP_DIR" | sed 's/^/      /'

# =============================================================================
say "STEP 3b: IOMMU debug config hook (IOMMU_DEBUG=$IOMMU_DEBUG)"
stage_debug_config

say "STEP 3c: sweep stale heavy-debug kernel config"
reset_debug_kernel_config

stage_build_stamp_extension

if [ "$FLAVOR_IS_DEBUG" = 1 ]; then
	say "STEP 3d: stage $FLAVOR debug config + ramoops DT patch"
	stage_flavor_debug_files
	verify_flavor_debug_files
elif [ -n "$FLAVOR_CONFIG_NAME" ]; then
	say "STEP 3d: stage $FLAVOR Armbian config (slot $FLAVOR_BRANCH)"
	install -D -m 0644 "$DEBUG_KERNEL_DIR/config-$FLAVOR_CONFIG_NAME.conf.sh" \
		"$USERPATCHES_DIR/config-$FLAVOR_CONFIG_NAME.conf.sh"
	# No kernel config is staged: production flavors use Armbian's stock
	# config (see LINUXCONFIG in the flavor's conf.sh). Drop a slot-named
	# leftover so it cannot shadow it.
	stale="$USERPATCHES_DIR/linux-rockchip64-$FLAVOR_BRANCH.config"
	[ -f "$stale" ] && rm -v "$stale" |
		sed 's/^/      removed slot kernel config (production uses Armbian stock) /'
fi

# =============================================================================
say "STEP 4: disable colliding Armbian core patches (self-contained DT owns these nodes)"
for p in "${DISABLE_PATCHES[@]}"; do
	if [ -f "$CORE_DIR/$p" ]; then
		mv -v "$CORE_DIR/$p" "$CORE_DIR/$p.disabled"
	elif [ -f "$CORE_DIR/$p.disabled" ]; then
		say "  already disabled: $p"
	else
		say "  WARNING: expected core patch not found (Armbian moved it?): $p"
	fi
done

# =============================================================================
if [ "$MODE" = "stage-only" ]; then
	[ ${#PASSTHROUGH[@]} -eq 0 ] || die "--stage-only does not accept compile arguments"
	say "STAGED. $FLAVOR userpatches and core-patch exclusions are ready; compile was not run."
	exit 0
fi

# =============================================================================
say "STEP 5: build $FLAVOR (ccache=$ARMBIAN_USE_CCACHE; tmpfs=$ARMBIAN_USE_TMPFS; clean=${ARMBIAN_CLEAN_LEVEL:-incremental})"
# -L: the cache path is a symlink into the shared store, and du reports 0 for a
# symlink unless told to follow it, which would silently flatten this diagnostic.
say "  ccache dir before: $(du -shL "$ARMBIAN_BUILD/cache/ccache" 2>/dev/null | cut -f1 || echo n/a)"
cd "$ARMBIAN_BUILD"

# Pre-flight, for BOTH branches below. The directory we tell Armbian to read must
# be the one we staged into, and it must actually contain patches -- otherwise a
# family rename downstream silently yields a patch-free kernel that still
# packages. Deliberately hoisted above the if/else: the two compile.sh call sites
# having separate argument lists is exactly how KERNELPATCHDIR got applied to
# only one flavor the first time this was fixed.
[ -d "$UP_DIR" ] || die "userpatch dir missing after staging: $UP_DIR"
# find, not ls: under `set -o pipefail` a no-match ls aborts the script before the
# explanatory die below can run.
staged_count=$(find "$UP_DIR" -maxdepth 1 -name '*.patch' | wc -l)
[ "$staged_count" -gt 0 ] || die "no patches staged in $UP_DIR; refusing to build a patch-free kernel"
# die, not a note: staging into one directory and telling Armbian to read another
# is precisely the failure this whole pre-flight exists to prevent, and counting
# patches in the dir we staged into proves nothing about the dir Armbian reads.
# ARMBIAN_KERNELPATCHDIR_FORCE=1 opts out for a deliberate experiment.
if [ "$ARMBIAN_KERNELPATCHDIR" != "archive/$KBRANCH" ] && [ "${ARMBIAN_KERNELPATCHDIR_FORCE:-0}" != 1 ]; then
	die "KERNELPATCHDIR ($ARMBIAN_KERNELPATCHDIR) is not the directory this script staged into (archive/$KBRANCH).
    Armbian would read patches from somewhere this script never wrote.
    Set ARMBIAN_KERNELPATCHDIR_FORCE=1 if that is genuinely intended."
fi
say "  family: $SLOT_FAMILY${ARMBIAN_LINUXFAMILY:+ (forced via late_family_config)}   patch dir: $ARMBIAN_KERNELPATCHDIR ($staged_count userpatches staged)"

# Marker so STEP 6 judges THIS build's output. Without it the result check reads
# whatever deb is newest, including a stale one from a previous failed run.
# Deliberately NOT mktemp -t: /tmp is tmpfs on this board, and this repo's
# convention is to keep scratch off it. The workspace is on disk.
BUILD_MARKER="$(mktemp "$WORKSPACE/.ysp-build-marker.XXXXXX")"
trap 'rm -f "$BUILD_MARKER"' EXIT

if [ "$FLAVOR_IS_DEBUG" = 1 ]; then
	check_debug_build_deps
	say "  kernel tip: $(git -C "$KERNEL_TREE" log -1 --format='%h %s' HEAD)"
	say "  this is a heavy KASAN/lockdep build and can take a while on the board"
	# USE_CCACHE as ARGUMENT (see header). Most debug objects are shared across
	# the *-debug flavors, so ccache keeps flavor switches from being cold.
	PREFER_DOCKER="${PREFER_DOCKER:-yes}" ./compile.sh "$FLAVOR_CONFIG_NAME" kernel \
		USE_CCACHE="$ARMBIAN_USE_CCACHE" \
		USE_TMPFS="$ARMBIAN_USE_TMPFS" \
		ENABLE_EXTENSIONS="$STAMP_EXT_NAME" \
		KERNELPATCHDIR="$ARMBIAN_KERNELPATCHDIR" \
		${ARMBIAN_LINUXFAMILY:+YSP_LINUXFAMILY="$ARMBIAN_LINUXFAMILY"} \
		${ARMBIAN_KERNELBRANCH:+KERNELBRANCH="$ARMBIAN_KERNELBRANCH"} \
		${ARMBIAN_CLEAN_LEVEL:+CLEAN_LEVEL="$ARMBIAN_CLEAN_LEVEL"} \
		${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
else
	# Enable our debug extension only for IOMMU_DEBUG=yes builds; the extension
	# manager loads userpatches/extensions/$DEBUG_EXT_NAME.sh and runs its
	# custom_kernel_config hook (see stage_debug_config). The build-stamp
	# extension is always on (see stage_build_stamp_extension).
	# Empty-array-safe under set -u.
	EXTS="$STAMP_EXT_NAME"
	[ "$IOMMU_DEBUG" = "yes" ] && EXTS="$EXTS,$DEBUG_EXT_NAME"
	EXTRA_ARGS=("ENABLE_EXTENSIONS=$EXTS")
	[ -n "$ARMBIAN_CLEAN_LEVEL" ] && EXTRA_ARGS+=("CLEAN_LEVEL=$ARMBIAN_CLEAN_LEVEL")
	# Only override the base when explicitly asked; otherwise the flavor's own
	# Armbian config decides (see ARMBIAN_KERNELBRANCH above).
	[ -n "$ARMBIAN_KERNELBRANCH" ] && EXTRA_ARGS+=("KERNELBRANCH=$ARMBIAN_KERNELBRANCH")
	# Must match the debug branch above; see the pre-flight note about the two
	# call sites drifting apart.
	EXTRA_ARGS+=("KERNELPATCHDIR=$ARMBIAN_KERNELPATCHDIR")
	[ -n "$ARMBIAN_LINUXFAMILY" ] && EXTRA_ARGS+=("YSP_LINUXFAMILY=$ARMBIAN_LINUXFAMILY")
	./compile.sh "$FLAVOR_CONFIG_NAME" kernel \
		KERNEL_CONFIGURE=no \
		USE_CCACHE="$ARMBIAN_USE_CCACHE" \
		USE_TMPFS="$ARMBIAN_USE_TMPFS" \
		${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
		${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
fi

# =============================================================================
say "STEP 6: results"
# This is the size of the SHARED store (Mesa/MPP/librga/FFmpeg all write to it),
# so growth is suggestive, not proof, and it stops growing entirely once the
# store reaches max_size while still working perfectly. The authoritative signal
# is Armbian's own "Ccache result [ hit=... miss=... ]" line.
say "  shared ccache store: $(du -shL "$ARMBIAN_BUILD/cache/ccache" 2>/dev/null | cut -f1 || echo n/a)"
# find, not ls: with `set -o pipefail` a no-match glob makes ls exit 2 and kills
# the script HERE, skipping every post-flight check below -- after printing a
# partial list that looks like success. The family is pinned, so the full
# BRANCH-FAMILY name is knowable and avoids matching the sibling debug slot
# (linux-image-video-port-* would otherwise also match video-port-kasan-*).
SLOT="${FLAVOR_BRANCH}-${SLOT_FAMILY}"
say "  newest ${SLOT} debs:"
find "$DEBS" -maxdepth 1 \( -name "linux-image-$SLOT""_*.deb" -o -name "linux-dtb-$SLOT""_*.deb" \
	-o -name "linux-headers-$SLOT""_*.deb" \) -printf '%T@ %p\n' 2>/dev/null |
	sort -rn | head -3 | cut -d' ' -f2- | sed 's/^/      /'
# -newer "$BUILD_MARKER": only consider debs this run produced. A stale deb from
# a previous failed run would otherwise be reported as "this build's hash".
# Sort by mtime and take the newest: find emits in directory order, so a bare
# `head -1` would pick an arbitrary deb when more than one matches, and could
# report another build's hash as this one's.
NEW=$(find "$DEBS" -maxdepth 1 -name "linux-image-$SLOT""_*.deb" \
	-newer "$BUILD_MARKER" -printf '%T@ %p\n' 2>/dev/null |
	sort -rn | head -1 | cut -d' ' -f2-)
PH=$(basename "$NEW" 2>/dev/null | grep -oE 'P[0-9a-f]{4,}-C[0-9a-f]{4,}' || true)
[ -n "$PH" ] && say "This build's hash: $PH"

if [ -z "$NEW" ]; then
	die "no linux-image deb was produced for $SLOT by this run."
fi

# Post-flight: prove the flavor's drivers are actually IN the kernel we just
# packaged. Do NOT test the deb's P#### hash for 0000 -- that was tried and is
# useless: Armbian hashes the UNION of patch/kernel/$KERNELPATCHDIR (356 core
# patches) and userpatches/kernel/$KERNELPATCHDIR, and returns 16 zeros only when
# the COMBINED list is empty (hash-files.sh:66-69). With KERNELPATCHDIR pinned the
# core dir is never empty, so P0000 became unreachable while the dangerous case
# -- core patches applied, zero vendor patches -- still hashes non-zero and looks
# healthy. The only honest check is the built artifact's own config.
#
# Each flavor proves itself with symbols that exist only when its driver series
# actually reached Kconfig. Forward-port uses the vendor MPP service; rewrite
# intentionally disables that service and registers its clean-room replacements.
# FLAVOR_VERIFY_CONFIG remains as a single-symbol compatibility override.
VERIFY_CONFIGS="${FLAVOR_VERIFY_CONFIG:-$FLAVOR_VERIFY_CONFIGS}"
[ -n "$VERIFY_CONFIGS" ] || VERIFY_CONFIGS="CONFIG_ROCKCHIP_MPP_RKVDEC2"
say "  verifying packaged kernel config contains: $VERIFY_CONFIGS"
for VERIFY_SYM in $VERIFY_CONFIGS; do
	# Do not use grep -q here. A successful early exit closes the pipe while
	# tar is still writing the 270 KiB config; with pipefail, tar's SIGPIPE
	# then turns a present symbol into a false "MISSING" verdict.
	if ! dpkg-deb --fsys-tarfile "$NEW" 2>/dev/null |
		tar -xO --wildcards './boot/config-*' 2>/dev/null |
		grep "^$VERIFY_SYM=" >/dev/null; then
		die "$VERIFY_SYM is MISSING from $(basename "$NEW")
    The kernel built WITHOUT this flavor's driver series and must not be installed.
    This is what a patch-dir mismatch looks like: the build succeeds and produces
    correctly-named, installable debs containing a stock kernel.
    Check that Armbian's 'Using kernel patch dir' matches archive/$KBRANCH."
	fi
done
if [ "$FLAVOR_IS_DEBUG" = 1 ]; then
	say "DONE. After install.md recovery prep, install with:"
	say "  sudo RECOVERY_READY=1 PHASH='$PH' bash $HERE/install-kernel.sh"
else
	say "DONE. After install.md recovery prep, install with:"
	say "  sudo RECOVERY_READY=1 PHASH='$PH' bash $HERE/install-kernel.sh"
fi
