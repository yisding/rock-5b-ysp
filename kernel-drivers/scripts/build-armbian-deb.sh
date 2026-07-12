#!/usr/bin/env bash
# =============================================================================
# build-armbian-deb.sh
#
# Build an Armbian "current" (rockchip64, Rock 5B) kernel .deb that carries the
# RK3588 vendor MPP + RGA + *AV1 decoder* forward-port from THIS git tree, on
# top of the selected Armbian `current` kernel base. This wrapper was validated
# against 6.18.37 / 26.08.0-trunk; re-check its skip list and core patch names
# when the Armbian base moves.
#
# It differs from rock-5b-ysp's build-combined-kernel.sh in one load-bearing way:
# this tree's device tree is SELF-CONTAINED. Commit "add decoder/AV1 IOMMUs,
# SRAM and node wiring" adds the vdec0/vdec1 decoder nodes, their IOMMUs+SRAM,
# and the av1d / vsi-iommu nodes directly into rk3588-base.dtsi. Armbian's core
# patches media-0001 (rkvdec) and media-0007 (verisilicon AV1 iommu) add the
# *same* nodes / the same new file (drivers/iommu/vsi-iommu.c) -> hard collision.
# So this script DISABLES those two Armbian core patches (rename .patch ->
# .patch.disabled; Armbian's patcher only picks files ending in .patch).
# rock-5b-ysp's convert-in-place patch, by contrast, *needed* media-0001 present.
#
# WHAT IT DOES
#   1. Regenerate the port patches from git:  git format-patch v6.18..HEAD,
#      excluding commits already carried by the shipping Armbian kernel base.
#   2. Reset Armbian patch state: restore/clean the built-in archive and clear
#      generated userpatches for this kernel archive.
#   3. Stage the generated patch set.
#   4. Disable the two colliding Armbian core media patches.
#   5. Run ./compile.sh with USE_CCACHE passed as an ARGUMENT (see below).
#   6. Print the new P####-C#### hash and the deb paths.
#
# THE ccache GOTCHA (inherited from rock-5b-ysp): USE_CCACHE must be a compile.sh
# command-line ARGUMENT, never a shell env var. Armbian can relaunch through
# Docker or sudo; arguments survive both, while the Docker path was observed
# silently dropping a bare env var and leaving ccache OFF.
#
# PREREQS: either Docker-capable Linux (default mode) or a supported native
# Armbian/Ubuntu Noble host (`PREFER_DOCKER=no`); ~8 GB RAM, ~50 GB free; the
# Armbian build tree (ARMBIAN_BUILD) already cloned. Cold build ~80-90 min;
# warm ~10-15. See ../../install.md §2.
#
# USAGE
#   bash build-armbian-deb.sh
#   nohup bash build-armbian-deb.sh >build.log 2>&1 &   # long build
#   ARMBIAN_BUILD=/path/to/armbian-build bash build-armbian-deb.sh
#   KERNEL_TREE=/path/to/other-kernel PATCH_PREFIX=rk3588-rewrite bash build-armbian-deb.sh
#   bash build-armbian-deb.sh KERNEL_CONFIGURE=yes      # extra args pass through
#   IOMMU_DEBUG=yes bash build-armbian-deb.sh            # + DMA_API/KALLSYMS/IOMMU_DEBUGFS debug config
#
# Reset the built-in patch archive and generated userpatches without building
# with:  --restore
# =============================================================================
# shellcheck disable=SC2012
set -euo pipefail

# --- Locations -------------------------------------------------------------
# This script lives in the ysp (kernel-drivers/scripts/) but drives an EXTERNAL
# build workspace. Defaults assume the dev-box layout ~/Code/{rock-5b-ysp,kernel/*};
# override KERNEL_TREE / ARMBIAN_BUILD / STAGING for any other layout.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # kernel-drivers/scripts
CODE="$(cd "$HERE/../../.." && pwd)"                    # ~/Code (ysp is <CODE>/rock-5b-ysp)
WORKSPACE="${WORKSPACE:-$CODE/kernel/rock5b-kernel-build}"  # build scratch (armbian-build + outputs)
# KERNEL_TREE = the kernel git tree carrying the forward-port commits (git format-patch source).
KERNEL_TREE="${KERNEL_TREE:-$CODE/kernel/linux-6.18-rkvenc-av1-fwport}"
# ARMBIAN_BUILD = the selected Armbian build tree.
ARMBIAN_BUILD="${ARMBIAN_BUILD:-$WORKSPACE/armbian-build}"
BASE_TAG="${BASE_TAG:-v6.18}"                 # port patches are v6.18..HEAD
KBRANCH="${KBRANCH:-rockchip64-6.18}"         # Armbian kernel patch archive branch
PATCH_PREFIX="${PATCH_PREFIX:-rk3588-av1-fwport}"  # generated userpatch filename prefix
STAGING="${STAGING:-$WORKSPACE/forward-port/patches}"   # inspectable copy of generated patches
# Commit(s) present in this forward-port tree only because the local branch
# tracks fixes that the validated Armbian 6.18.37 source base already carries.
# Keep them out of generated userpatches or Armbian will reject them as reversed.
SKIP_COMMITS="${SKIP_COMMITS:-e059aad8d68b}"

# Armbian core patches that collide with this tree's self-contained DT.
DISABLE_PATCHES=(
	"media-0001-Add-rkvdec-Support-v5.patch"
	"media-0007-add-verisilicon-AV1-iommu-driver.patch"
)

UP_DIR="$ARMBIAN_BUILD/userpatches/kernel/archive/$KBRANCH"
CORE_DIR="$ARMBIAN_BUILD/patch/kernel/archive/$KBRANCH"
DEBS="$ARMBIAN_BUILD/output/debs"

# Opt-in IOMMU/DMA debug observability. OFF by default so normal debs stay clean.
# IOMMU_DEBUG=yes stages an Armbian EXTENSION (userpatches/extensions/ysp-iommu-debug.sh)
# whose custom_kernel_config hook enables DMA_API_DEBUG / KALLSYMS_ALL /
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
YSP_DEBUG_MARKER="ysp-iommu-debug (generated by build-armbian-deb.sh)"

say() { printf '>>> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

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
stage_debug_config() {
	mkdir -p "$EXT_DIR"
	# Sweep any leftover from the old, broken lib.config approach (ours only).
	if [ -f "$LEGACY_LIBCONFIG" ] && grep -qF "$YSP_DEBUG_MARKER" "$LEGACY_LIBCONFIG"; then
		rm -v "$LEGACY_LIBCONFIG" | sed 's/^/      removed stale /'
	fi
	if [ -f "$DEBUG_EXT" ] && ! grep -qF "$YSP_DEBUG_MARKER" "$DEBUG_EXT"; then
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

# --- --restore mode --------------------------------------------------------
if [ "${1:-}" = "--restore" ]; then
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

# =============================================================================
reset_core_patches

# =============================================================================
say "STEP 1: regenerate port patches from git ($BASE_TAG..HEAD)"
NCOMMITS=$(git -C "$KERNEL_TREE" rev-list --count "$BASE_TAG"..HEAD)
say "  $NCOMMITS commits on top of $BASE_TAG:"
git -C "$KERNEL_TREE" log --oneline "$BASE_TAG"..HEAD | sed 's/^/      /'
rm -rf "$STAGING"; mkdir -p "$STAGING"
git -C "$KERNEL_TREE" format-patch --no-signature -o "$STAGING" "$BASE_TAG"..HEAD >/dev/null
for commit in $SKIP_COMMITS; do
	subject=$(git -C "$KERNEL_TREE" show -s --format=%f "$commit" 2>/dev/null || true)
	if [ -z "$subject" ]; then
		say "  WARNING: SKIP_COMMITS entry not found in kernel tree: $commit"
		continue
	fi
	for f in "$STAGING"/[0-9][0-9][0-9][0-9]-"$subject".patch; do
		[ -e "$f" ] || continue
		say "  skipping Armbian-base commit: $(basename "$f")"
		rm -f "$f"
	done
done
# Prefix so they sort after Armbian's media-* patches (proven-good order) and
# are clearly distinct from the old rk3588-rkvenc2-* set.
for f in "$STAGING"/0*.patch; do
	base=$(basename "$f")
	mv "$f" "$STAGING/$PATCH_PREFIX-$base"
done
say "  generated $(ls "$STAGING"/"$PATCH_PREFIX"-*.patch | wc -l) patches into $STAGING"

# =============================================================================
say "STEP 2: reset Armbian userpatches in $UP_DIR"
# This archive directory is generated state for these kernel builds. Reset all
# top-level patches so switching between AV1/rewrite/other generated kernels
# cannot leave stale patches behind.
reset_userpatches

# =============================================================================
say "STEP 3: stage generated userpatches"
cp -v "$STAGING"/"$PATCH_PREFIX"-*.patch "$UP_DIR"/ | sed 's/^/      /'
say "  userpatches now:"; ls "$UP_DIR" | sed 's/^/      /'

# =============================================================================
say "STEP 3b: IOMMU debug config hook (IOMMU_DEBUG=$IOMMU_DEBUG)"
stage_debug_config

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
say "STEP 5: build (ccache ON as a compile.sh ARGUMENT across Docker/sudo relaunch)"
say "  ccache dir before: $(du -sh "$ARMBIAN_BUILD/cache/ccache" 2>/dev/null | cut -f1 || echo n/a)"
cd "$ARMBIAN_BUILD"
# Enable our debug extension only for IOMMU_DEBUG=yes builds; the extension
# manager loads userpatches/extensions/$DEBUG_EXT_NAME.sh and runs its
# custom_kernel_config hook (see stage_debug_config). Empty-array-safe under set -u.
EXTRA_ARGS=()
[ "$IOMMU_DEBUG" = "yes" ] && EXTRA_ARGS+=("ENABLE_EXTENSIONS=$DEBUG_EXT_NAME")
./compile.sh kernel \
	BOARD=rock-5b \
	BRANCH=current \
	KERNEL_CONFIGURE=no \
	USE_CCACHE=yes \
	${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
	"$@"

# =============================================================================
say "STEP 6: results"
say "  ccache dir after:  $(du -sh "$ARMBIAN_BUILD/cache/ccache" 2>/dev/null | cut -f1 || echo n/a)  (grew = ccache engaged)"
say "  newest current-rockchip64 debs:"
ls -t "$DEBS"/linux-image-current-rockchip64_*.deb "$DEBS"/linux-dtb-current-rockchip64_*.deb \
	"$DEBS"/linux-headers-current-rockchip64_*.deb 2>/dev/null | head -3 | sed 's/^/      /'
NEW=$(ls -t "$DEBS"/linux-image-current-rockchip64_*.deb 2>/dev/null | head -1)
PH=$(basename "$NEW" 2>/dev/null | grep -oE 'P[0-9a-f]{4,}-C[0-9a-f]{4,}' || true)
[ -n "$PH" ] && say "This build's hash: $PH"
say "DONE. After install.md recovery prep, install with:"
say "  sudo RECOVERY_READY=1 PHASH='$PH' bash $HERE/install-combined-kernel.sh"
