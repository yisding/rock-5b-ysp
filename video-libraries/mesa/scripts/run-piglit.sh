#!/bin/bash
# Run a piglit subset against a Panfrost Mesa build, via the glvnd EGL-vendor
# mechanism (NOT LD_LIBRARY_PATH override — see the big gotcha below).
#
#   MESA_PREFIX=/home/yi/Code/fdo/mesa/install-glvnd \
#   PIGLIT=/home/yi/Code/fdo/piglit \
#   ./run-piglit.sh RESULTDIR -t getteximage -t '@pbo' -t readpixels -t fbo-blit ...
#
# THE GOTCHA (cost real time):
#   piglit's GL test binaries link against **glvnd** (libGLdispatch/libGLX +
#   glvnd libGL/libEGL). If you point them at a Mesa build by prepending a
#   *non-glvnd* libEGL on LD_LIBRARY_PATH (as the reproducers do), every test
#   SIGSEGVs at context creation (ABI mismatch vs glvnd libGLdispatch).
#   Loading a *version-skewed* driver via the system glvnd libEGL also crashes
#   (26.0.3 loader + 26.2 megadriver).
#   => Build Mesa with `-Dglvnd=enabled`, `meson install` to a PREFIX, and
#      select it as the glvnd EGL vendor via __EGL_VENDOR_LIBRARY_FILENAMES.
#      System glvnd libGL/libEGL stay in place and dispatch to our vendor.
#
#   Also: piglit finds test binaries at <PIGLIT>/bin. For an out-of-tree cmake
#   build (build/bin), symlink it: `ln -sfn build/bin <PIGLIT>/bin`.
set -euo pipefail
: "${MESA_PREFIX:=$HOME/Code/fdo/mesa/install-glvnd}"
: "${PIGLIT:=$HOME/Code/fdo/piglit}"
RES=${1:?usage: run-piglit.sh RESULTDIR [piglit run args...]}; shift || true
LIBDIR="$MESA_PREFIX/lib/aarch64-linux-gnu"

export __EGL_VENDOR_LIBRARY_FILENAMES="$MESA_PREFIX/share/glvnd/egl_vendor.d/50_mesa.json"
export LD_LIBRARY_PATH="$LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"   # libEGL_mesa, libgbm — NOT libEGL.so.1
export LIBGL_DRIVERS_PATH="$LIBDIR/dri"
export GBM_BACKENDS_PATH="$LIBDIR/gbm"
export MESA_LOADER_DRIVER_OVERRIDE=panfrost
export PIGLIT_PLATFORM=gbm PIGLIT_NO_WINDOW=1

[ -e "$PIGLIT/bin" ] || ln -sfn build/bin "$PIGLIT/bin"
cd "$PIGLIT"
./piglit run -o --jobs "${JOBS:-6}" "$@" tests/gpu.py "$RES"
./piglit summary console "$RES" | tail -14
