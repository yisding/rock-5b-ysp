# shellcheck shell=bash
# SPDX-License-Identifier: MIT
# Runtime env for an uninstalled *surfaceless* Panfrost Mesa build (Rock 5B / Mali-G610).
#
# Usage:
#   MESA_BUILD=/home/yi/Code/rock-5b/build/mesa/build-codex-main . mesa-panfrost-env.sh
#   ./repro_blit           # now runs against the just-built driver
#
# Confirm you got the right driver: every reproducer prints GL_RENDERER /
# GL_VERSION on the first line. If LIBGL_DRIVERS_PATH is wrong the loader
# silently falls back to the *installed* system Mesa (see the version string).
__MESA_YSP_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
: "${ROCK5B_WORKSPACE:=$__MESA_YSP_ROOT/../rock-5b}"
unset __MESA_YSP_ROOT
: "${MESA_BUILD:=$ROCK5B_WORKSPACE/build/mesa/build-codex-main}"

export LIBGL_DRIVERS_PATH="$MESA_BUILD/src/gallium/targets/dri"
export LD_LIBRARY_PATH="$MESA_BUILD/src/gallium/targets/dri:$MESA_BUILD/src/gbm:$MESA_BUILD/src/egl:${LD_LIBRARY_PATH:-}"
export GBM_BACKENDS_PATH="$MESA_BUILD/src/gbm/backends/dri"
export MESA_LOADER_DRIVER_OVERRIDE=panfrost
export EGL_PLATFORM=surfaceless
export REPRO_NODE="${REPRO_NODE:-/dev/dri/renderD128}"
