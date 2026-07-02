#!/usr/bin/env bash
# =============================================================================
# build-combined-kernel.sh
#
# Builds the combined RK3588 (Radxa Rock 5B) kernel with all three vendor
# accelerators (VEPU580 encoder + rkvdec2 decoder + RGA), with ccache ENABLED.
#
# WHY THIS WRAPPER EXISTS -- the ccache gotcha:
#   USE_CCACHE must be passed as a compile.sh *ARGUMENT* (KEY=VALUE), never as a
#   shell environment variable. Armbian relaunches the whole build inside Docker
#   and only forwards command-line KEY=VALUE args into the container -- a bare
#   `USE_CCACHE=yes ./compile.sh ...` env var is silently dropped, the container
#   falls back to USE_CCACHE=no, and ccache stays OFF without warning. A build
#   done the env-var way reported `Ccache result: hit=0 miss=0 (0%)` and took the
#   full ~89 min. Passed as an arg (as below) it propagates correctly; Armbian
#   prints `using CCACHE` and a real hit/miss summary at the end.
#
# COLD vs WARM:
#   The first build with an empty cache is full-speed (~80-90 min) and POPULATES
#   ccache (~5 GB under armbian-build/cache/ccache). Subsequent builds that only
#   change a patch hit the content-addressed cache (survives the re-patch mtime
#   churn that defeats Armbian's worktree-incremental) and finish in ~10-15 min.
#
# PREREQUISITE: an Armbian build tree at <repo>/armbian-build:
#   `git clone https://github.com/armbian/build <repo>/armbian-build`
#   with the port patches in place -- see ../../install.md and
#   ../../packaging/docs/armbian-packaging.md. Debs land in
#   <repo>/armbian-build/output/debs, which is also where
#   install-combined-kernel.sh looks by default.
#
# USAGE:
#   bash build-combined-kernel.sh                 # build, ccache on
#   nohup bash build-combined-kernel.sh &         # background (long build)
#   bash build-combined-kernel.sh KERNEL_CONFIGURE=yes   # extra args pass through
#
# After it finishes, point install-combined-kernel.sh (same directory) PHASH at
# the new P####-C#### hash printed below, then install + reboot + validate.
# =============================================================================
set -euo pipefail

# <repo>/armbian-build -- resolved relative to this script so the friendly
# error below (not a cryptic `cd` failure under set -e) fires when it's absent.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$REPO/armbian-build"
DEBS="$BUILD_DIR/output/debs"

[ -x "$BUILD_DIR/compile.sh" ] || { echo "Missing Armbian build tree: $BUILD_DIR -- clone https://github.com/armbian/build there (see install.md)" >&2; exit 1; }
cd "$BUILD_DIR"

echo ">>> Building combined Rock 5B kernel (ccache ON) in: $BUILD_DIR"
echo ">>> ccache dir before: $(du -sh cache/ccache 2>/dev/null | cut -f1 || echo 'n/a')"
echo

# USE_CCACHE=yes is an ARGUMENT (not an env var) so it reaches the Docker container.
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
