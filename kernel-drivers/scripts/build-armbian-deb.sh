#!/usr/bin/env bash
# =============================================================================
# build-armbian-deb.sh
#
# Build an Armbian "current" (rockchip64, Rock 5B) kernel .deb that carries the
# RK3588 vendor MPP + RGA + *AV1 decoder* forward-port from THIS git tree, on
# top of the *currently shipping* Armbian kernel base (6.18.37 / 26.08.0-trunk).
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
#   1. Regenerate the port patches from git:  git format-patch v6.18..HEAD
#   2. Stage them as Armbian userpatches (replacing any prior port patches;
#      leaving unrelated userpatches such as rk806-* untouched).
#   3. Disable the two colliding Armbian core media patches.
#   4. Run ./compile.sh with USE_CCACHE passed as an ARGUMENT (see below).
#   5. Print the new P####-C#### hash and the deb paths.
#
# THE ccache GOTCHA (inherited from rock-5b-ysp): USE_CCACHE must be a compile.sh
# command-line ARGUMENT, never a shell env var -- Armbian relaunches the build
# inside Docker and silently drops bare env vars, so ccache would stay OFF.
#
# PREREQS: Docker running + you in the `docker` group; ~25 GB free; the Armbian
# build tree (ARMBIAN_BUILD) already cloned. Cold build ~80-90 min; warm ~10-15.
#
# USAGE
#   bash build-armbian-deb.sh
#   nohup bash build-armbian-deb.sh >build.log 2>&1 &   # long build
#   ARMBIAN_BUILD=/path/to/armbian-build bash build-armbian-deb.sh
#   bash build-armbian-deb.sh KERNEL_CONFIGURE=yes      # extra args pass through
#
# Reverse the media-patch disable later with:  --restore  (does nothing else)
# =============================================================================
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
# ARMBIAN_BUILD = the Armbian build tree that produced the shipping 6.18.37 deb.
ARMBIAN_BUILD="${ARMBIAN_BUILD:-$WORKSPACE/armbian-build}"
BASE_TAG="${BASE_TAG:-v6.18}"                 # port patches are v6.18..HEAD
KBRANCH="${KBRANCH:-rockchip64-6.18}"         # Armbian kernel patch archive branch
PATCH_PREFIX="rk3588-av1-fwport"              # our userpatch filename prefix
STAGING="${STAGING:-$WORKSPACE/forward-port/patches}"   # inspectable copy of generated patches

# Armbian core patches that collide with this tree's self-contained DT.
DISABLE_PATCHES=(
	"media-0001-Add-rkvdec-Support-v5.patch"
	"media-0007-add-verisilicon-AV1-iommu-driver.patch"
)

UP_DIR="$ARMBIAN_BUILD/userpatches/kernel/archive/$KBRANCH"
CORE_DIR="$ARMBIAN_BUILD/patch/kernel/archive/$KBRANCH"
DEBS="$ARMBIAN_BUILD/output/debs"

say() { printf '>>> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

restore_media() {
	say "Restoring Armbian core media patches (removing .disabled)"
	for p in "${DISABLE_PATCHES[@]}"; do
		if [ -f "$CORE_DIR/$p.disabled" ]; then
			mv -v "$CORE_DIR/$p.disabled" "$CORE_DIR/$p"
		fi
	done
}

# --- --restore mode --------------------------------------------------------
if [ "${1:-}" = "--restore" ]; then
	restore_media
	exit 0
fi

# --- Sanity ----------------------------------------------------------------
git -C "$KERNEL_TREE" rev-parse --git-dir >/dev/null 2>&1 || die "$KERNEL_TREE is not a git tree"
git -C "$KERNEL_TREE" rev-parse "$BASE_TAG" >/dev/null 2>&1 || die "base tag '$BASE_TAG' not found in $KERNEL_TREE"
[ -x "$ARMBIAN_BUILD/compile.sh" ] || die "Armbian build tree not found: $ARMBIAN_BUILD (set ARMBIAN_BUILD=)"
[ -d "$CORE_DIR" ] || die "Armbian kernel patch archive not found: $CORE_DIR (wrong KBRANCH?)"

# =============================================================================
say "STEP 1: regenerate port patches from git ($BASE_TAG..HEAD)"
NCOMMITS=$(git -C "$KERNEL_TREE" rev-list --count "$BASE_TAG"..HEAD)
say "  $NCOMMITS commits on top of $BASE_TAG:"
git -C "$KERNEL_TREE" log --oneline "$BASE_TAG"..HEAD | sed 's/^/      /'
rm -rf "$STAGING"; mkdir -p "$STAGING"
git -C "$KERNEL_TREE" format-patch --no-signature -o "$STAGING" "$BASE_TAG"..HEAD >/dev/null
# Prefix so they sort after Armbian's media-* patches (proven-good order) and
# are clearly distinct from the old rk3588-rkvenc2-* set.
for f in "$STAGING"/0*.patch; do
	base=$(basename "$f")
	mv "$f" "$STAGING/$PATCH_PREFIX-$base"
done
say "  generated $(ls "$STAGING"/$PATCH_PREFIX-*.patch | wc -l) patches into $STAGING"

# =============================================================================
say "STEP 2: stage them as Armbian userpatches in $UP_DIR"
mkdir -p "$UP_DIR"
# Remove prior *port* userpatches only (ours + the superseded rkvenc2 pair);
# leave anything else (e.g. rk806-log-reset-status.patch) in place.
rm -fv "$UP_DIR/$PATCH_PREFIX-"*.patch "$UP_DIR"/rk3588-rkvenc2-*.patch 2>/dev/null || true
cp -v "$STAGING"/$PATCH_PREFIX-*.patch "$UP_DIR"/ | sed 's/^/      /'
say "  userpatches now:"; ls "$UP_DIR" | sed 's/^/      /'

# =============================================================================
say "STEP 3: disable colliding Armbian core patches (self-contained DT owns these nodes)"
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
say "STEP 4: build (ccache ON, as a compile.sh ARGUMENT so it reaches Docker)"
say "  ccache dir before: $(du -sh "$ARMBIAN_BUILD/cache/ccache" 2>/dev/null | cut -f1 || echo n/a)"
cd "$ARMBIAN_BUILD"
./compile.sh kernel \
	BOARD=rock-5b \
	BRANCH=current \
	KERNEL_CONFIGURE=no \
	USE_CCACHE=yes \
	"$@"

# =============================================================================
say "STEP 5: results"
say "  ccache dir after:  $(du -sh "$ARMBIAN_BUILD/cache/ccache" 2>/dev/null | cut -f1 || echo n/a)  (grew = ccache engaged)"
say "  newest current-rockchip64 debs:"
ls -t "$DEBS"/linux-image-current-rockchip64_*.deb "$DEBS"/linux-dtb-current-rockchip64_*.deb \
	"$DEBS"/linux-headers-current-rockchip64_*.deb 2>/dev/null | head -3 | sed 's/^/      /'
NEW=$(ls -t "$DEBS"/linux-image-current-rockchip64_*.deb 2>/dev/null | head -1)
PH=$(basename "$NEW" 2>/dev/null | grep -oE 'P[0-9a-f]{4,}-C[0-9a-f]{4,}' || true)
[ -n "$PH" ] && say "This build's hash: $PH"
say "DONE. Install with:  sudo PHASH='$PH' bash $HERE/install-combined-kernel.sh"
