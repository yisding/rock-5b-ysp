#!/usr/bin/env bash
# =============================================================================
# build-combined-kernel.sh
#
# Builds the combined RK3588 (Radxa Rock 5B) kernel with all three vendor
# accelerators (VEPU580 encoder + rkvdec2 decoder + RGA), with ccache ENABLED.
#
# WHY THIS WRAPPER EXISTS -- the ccache gotcha:
#   USE_CCACHE must be passed as a compile.sh *ARGUMENT* (KEY=VALUE), never as a
#   shell environment variable. Armbian may relaunch through Docker (preferred
#   when available) or sudo (native Armbian/Ubuntu Noble); command-line
#   KEY=VALUE args survive either path. A bare env var was observed being
#   dropped by the Docker relaunch, leaving ccache OFF without warning
#   (`hit=0 miss=0`, ~89 min). Passed as an arg (as below), it propagates
#   correctly and Armbian prints a real hit/miss summary at the end.
#
# COLD vs WARM:
#   The first build with an empty cache is full-speed (~80-90 min) and POPULATES
#   ccache (~5 GB under armbian-build/cache/ccache). Subsequent builds that only
#   change a patch hit the content-addressed cache (survives the re-patch mtime
#   churn that defeats Armbian's worktree-incremental) and finish in ~10-15 min.
#
# PREREQUISITE: an Armbian build tree at $WORKSPACE/armbian-build:
#   `bash kernel-drivers/scripts/bootstrap-workspaces.sh`
#   with the port patches staged as userpatches -- see ../../install.md and
#   ../../packaging/docs/armbian-packaging.md. Debs land in
#   $WORKSPACE/armbian-build/output/debs, which is also where
#   install-combined-kernel.sh looks by default when WORKSPACE matches.
#
# USAGE:
#   bash build-combined-kernel.sh                 # build, ccache on
#   nohup bash build-combined-kernel.sh &         # background (long build)
#   bash build-combined-kernel.sh KERNEL_CONFIGURE=yes   # extra args pass through
#
# After it finishes, point install-combined-kernel.sh (same directory) PHASH at
# the new P####-C#### hash printed below, then install + reboot + validate.
# =============================================================================
# shellcheck disable=SC2012 # Armbian-generated deb names cannot contain whitespace.
set -euo pipefail

# The Armbian build tree lives in the external build workspace (rock5b-kernel-build);
# bootstrap-workspaces.sh clones it there. Override WORKSPACE / ARMBIAN_BUILD for
# another layout. The friendly error below fires (not a cryptic cd failure) if absent.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE="$(cd "$HERE/../../.." && pwd)"                       # ~/Code
WORKSPACE="${WORKSPACE:-$CODE/kernel/rock5b-kernel-build}"
BUILD_DIR="${ARMBIAN_BUILD:-$WORKSPACE/armbian-build}"
DEBS="$BUILD_DIR/output/debs"

[ -x "$BUILD_DIR/compile.sh" ] || { echo "Missing Armbian build tree: $BUILD_DIR -- run bootstrap-workspaces.sh first (see install.md)" >&2; exit 1; }
cd "$BUILD_DIR"

echo ">>> Building combined Rock 5B kernel (ccache ON) in: $BUILD_DIR"
echo ">>> ccache dir before: $(du -sh cache/ccache 2>/dev/null | cut -f1 || echo 'n/a')"
echo

# USE_CCACHE=yes is an ARGUMENT so it survives the Docker or sudo relaunch.
./compile.sh kernel \
	BOARD=rock-5b \
	BRANCH=current \
	KERNEL_CONFIGURE=no \
	USE_CCACHE=yes \
	"$@"

echo
echo ">>> ccache dir after:  $(du -sh cache/ccache 2>/dev/null | cut -f1 || echo 'n/a')  (grows = ccache engaged)"
echo ">>> Newest current-rockchip64 kernel debs:"
ls -t "$DEBS"/linux-image-current-rockchip64_*.deb "$DEBS"/linux-dtb-current-rockchip64_*.deb \
	"$DEBS"/linux-headers-current-rockchip64_*.deb 2>/dev/null | head -3 | sed 's/^/    /'
NEW=$(ls -t "$DEBS"/linux-image-current-rockchip64_*.deb 2>/dev/null | head -1)
PH=$(basename "$NEW" 2>/dev/null | grep -oE 'P[0-9a-f]{4,}-C[0-9a-f]{4,}' || true)
[ -n "$PH" ] && echo ">>> This build's hash: $PH  -- set install-combined-kernel.sh PHASH='$PH'"
