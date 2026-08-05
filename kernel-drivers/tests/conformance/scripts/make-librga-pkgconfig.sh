#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PC_DIR=${PC_DIR:-"$ROOT/out/pkgconfig"}
LIBRGA_ROOT="$ROOT/sources/airockchip-librga"
LIBRGA_LIBDIR=${LIBRGA_LIBDIR:-"$LIBRGA_ROOT/libs/Linux/gcc-aarch64"}
LIBRGA_INCLUDEDIR=${LIBRGA_INCLUDEDIR:-"$LIBRGA_ROOT/include"}

mkdir -p "$PC_DIR"

cat > "$PC_DIR/librga.pc" <<EOF
prefix=$LIBRGA_ROOT
exec_prefix=\${prefix}
libdir=$LIBRGA_LIBDIR
includedir=$LIBRGA_INCLUDEDIR

Name: librga
Description: Rockchip RGA userspace library from conformance bundle
Version: 1.10.6
Libs: -L\${libdir} -lrga
Cflags: -I\${includedir}
EOF

echo "$PC_DIR/librga.pc"
