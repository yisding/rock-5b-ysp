#!/usr/bin/env bash
# Configure + build a surfaceless Panfrost Mesa for on-board reproducer/dEQP
# testing on the Rock 5B (Mali-G610), with NO X11 dependency.
#
# WHY THIS EXISTS
# ---------------
# The `build-codex-*` dirs an agent created earlier were configured with
# `--native-file=/tmp/mesa-codex-llvm22-extracted.ini` and a staged X11 dev
# sysroot under `/tmp/mesa-x11-dev-deps`. Both live in /tmp and are wiped on
# reboot, so any `ninja -C build-codex-*` then fails at the meson *regen* step
# ("No such file or directory: /tmp/mesa-codex-llvm22.ini"). This script
# reconstructs the one file we still need (the native file) and reconfigures
# the tree to surfaceless, which drops the X11 sysroot requirement entirely.
# The reproducers use GBM/EGL surfaceless + renderD128, so X11 is never needed.
#
# GOTCHAS baked in below (each cost real time to find):
#   1. meson picks `python`/`python3` from PATH. A `mise`-managed python3.14
#      shadows /usr/bin/python3 and lacks `mako`/`packaging` -> meson aborts
#      ("One of Python (3.x) packaging or distutils module is required").
#      Fix: pin python to /usr/bin/python3 in the native file AND put /usr/bin
#      first on PATH.
#   2. The build uses `-fuse-ld=lld`; ld.lld must be installed.
#   3. The llvm-config wrapper /tmp/llvm-config-22-mesa-codex is a 1-liner
#      (`exec /usr/bin/llvm-config-22 "$@"`); recreated here if missing.
set -euo pipefail

MESA=${MESA:-$HOME/Code/fdo/mesa}
BUILD=${BUILD:-$MESA/build-codex-main}
CCACHE_DIR_DEFAULT=$MESA/.codex-ccache
export CCACHE_DIR=${CCACHE_DIR:-$CCACHE_DIR_DEFAULT}
export PATH=/usr/bin:$PATH          # gotcha #1: system python before mise

# --- reconstruct the /tmp artifacts meson still references -------------------
if [ ! -x /tmp/llvm-config-22-mesa-codex ]; then
  printf '#!/bin/sh\nexec /usr/bin/llvm-config-22 "$@"\n' > /tmp/llvm-config-22-mesa-codex
  chmod +x /tmp/llvm-config-22-mesa-codex
fi
NATIVE=/tmp/mesa-codex-llvm22-extracted.ini
cat > "$NATIVE" <<'INI'
[binaries]
c = ['ccache', 'cc']
cpp = ['ccache', 'c++']
llvm-config = ['sh', '/tmp/llvm-config-22-mesa-codex']
python = '/usr/bin/python3'
python3 = '/usr/bin/python3'
INI
cp "$NATIVE" /tmp/mesa-codex-llvm22.ini   # the -gallium dir references this name

# --- (re)configure surfaceless ----------------------------------------------
# If $BUILD already exists (the codex tree) this reuses its ~28k ccache objects.
if [ -d "$BUILD" ]; then RECONF=--reconfigure; else RECONF=; fi
meson setup "$BUILD" $RECONF \
  --native-file "$NATIVE" \
  -Dgallium-drivers=panfrost -Dvulkan-drivers= \
  -Degl=enabled -Dgbm=enabled -Dglx=disabled -Dplatforms= \
  -Dllvm=enabled -Dtools=panfrost -Dbuild-tests=false \
  -Dpkg_config_path= -Dc_args= -Dcpp_args= \
  -Dc_link_args=-fuse-ld=lld -Dcpp_link_args=-fuse-ld=lld

ninja -C "$BUILD"
echo "Built: $BUILD/src/gallium/targets/dri/libgallium-*.so"
