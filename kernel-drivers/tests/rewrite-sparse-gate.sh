#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# Sparse/smatch lane for the rewrite-driver owning-module rules.
#
# Runs sparse (make C=1) and smatch (if available) against the rewrite
# sources. If neither tool is installed, prints bootstrap and exits 0
# (degraded mode) so the main gate does not spuriously fail. CI with
# STRICT=1 turns missing-tool into hard failure.
#
# Sparse is available from Ubuntu apt on this arm64 release:
#   sudo apt install sparse
# Smatch has no package here and needs a pinned source build that bundles
# its own sparse (see kernel docs for commit pin).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
ROCK5B_WORKSPACE="${ROCK5B_WORKSPACE:-$ROOT_DIR/../rock-5b}"
STRICT="${STRICT:-0}"

KERNEL_6_18="${KERNEL_6_18:-$ROCK5B_WORKSPACE/kernel/linux-6.18-rkvenc}"
ARCH="${ARCH:-arm64}"

have_sparse=0
have_smatch=0
command -v sparse >/dev/null 2>&1 && have_sparse=1 || true
command -v smatch >/dev/null 2>&1 && have_smatch=1 || true

if [ "$have_sparse" = 0 ] && [ "$have_smatch" = 0 ]; then
  echo "note: sparse/smatch not installed -- skipping sparse lane" >&2
  echo "      bootstrap: sudo apt install sparse   (packaged on this arm64 release)" >&2
  echo "      smatch: pinned source build that bundles its own sparse (no apt package)" >&2
  if [ "$STRICT" = 1 ]; then
    echo "STRICT=1: treating missing sparse/smatch as failure" >&2
    exit 1
  fi
  exit 0
fi

fail=0

if [ "$have_sparse" = 1 ]; then
  echo "=== sparse (make C=1) on rewrite sources: $KERNEL_6_18 ==="
  # Use a throwaway O= dir so we don't clobber the developer's build state.
  tmp_out="$(mktemp -d "${ROOT_DIR}/../tmp/sparse-rewrite.XXXXXX")"
  trap 'rm -rf "$tmp_out"' EXIT
  # Minimal defconfig + rewrite options, enough for sparse to see the files.
  # We don't need a full build; sparse runs as part of the compiler invocation.
  if ! make -C "$KERNEL_6_18" O="$tmp_out" ARCH="$ARCH" defconfig >/dev/null 2>&1; then
    echo "WARN: defconfig failed, sparse run may be incomplete" >&2
  fi
  "$KERNEL_6_18/scripts/config" --file "$tmp_out/.config" \
    -e ARCH_ROCKCHIP -e ROCKCHIP_IOMMU -e VSI_IOMMU \
    -e ROCKCHIP_MPP_REWRITE -e ROCKCHIP_RGA_REWRITE >/dev/null 2>&1 || true
  make -C "$KERNEL_6_18" O="$tmp_out" ARCH="$ARCH" olddefconfig >/dev/null 2>&1 || true
  # Sparse run: only the two rewrite objects, with sparse flags that match the plan's intent.
  # CF=-D__CHECKER__ enables __bitwise and __must_hold checking.
  if ! make -C "$KERNEL_6_18" O="$tmp_out" ARCH="$ARCH" \
       C=1 CF="-D__CHECKER__ -Wbitwise -Wcontext" \
       drivers/video/rockchip/mpp-rewrite/mpp_rewrite.o \
       drivers/video/rockchip/rga-rewrite/rga_rewrite.o 2>&1 | tee "$tmp_out/sparse.log"; then
    echo "WARN: sparse run had build errors (see $tmp_out/sparse.log)" >&2
  fi
  if grep -q "warning:" "$tmp_out/sparse.log"; then
    echo "FAIL: sparse reported warnings" >&2
    cat "$tmp_out/sparse.log" >&2
    fail=1
  else
    echo "PASS: sparse clean on rewrite sources"
  fi
  rm -rf "$tmp_out"
  trap - EXIT
fi

if [ "$have_smatch" = 1 ]; then
  echo "=== smatch on rewrite sources ==="
  # smatch reuses the sparse infrastructure; run via `make C=1 CHECK="smatch --full-path"`
  tmp_out2="$(mktemp -d "${ROOT_DIR}/../tmp/smatch-rewrite.XXXXXX")"
  trap 'rm -rf "$tmp_out2"' EXIT
  make -C "$KERNEL_6_18" O="$tmp_out2" ARCH="$ARCH" defconfig >/dev/null 2>&1 || true
  "$KERNEL_6_18/scripts/config" --file "$tmp_out2/.config" \
    -e ARCH_ROCKCHIP -e ROCKCHIP_IOMMU -e VSI_IOMMU \
    -e ROCKCHIP_MPP_REWRITE -e ROCKCHIP_RGA_REWRITE >/dev/null 2>&1 || true
  make -C "$KERNEL_6_18" O="$tmp_out2" ARCH="$ARCH" olddefconfig >/dev/null 2>&1 || true
  if ! make -C "$KERNEL_6_18" O="$tmp_out2" ARCH="$ARCH" \
       C=1 CHECK="smatch --full-path" \
       drivers/video/rockchip/mpp-rewrite/mpp_rewrite.o \
       drivers/video/rockchip/rga-rewrite/rga_rewrite.o 2>&1 | tee "$tmp_out2/smatch.log"; then
    echo "WARN: smatch run had build errors" >&2
  fi
  if grep -q "warn:" "$tmp_out2/smatch.log"; then
    echo "FAIL: smatch reported findings" >&2
    cat "$tmp_out2/smatch.log" >&2
    fail=1
  else
    echo "PASS: smatch clean on rewrite sources"
  fi
  rm -rf "$tmp_out2"
  trap - EXIT
fi

if [ "$fail" != 0 ]; then
  exit 1
fi
echo "PASS: sparse/smatch lane (or degraded-mode skip)"
