#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# Graceful Coccinelle gate for the rewrite-driver owning-module rules.
#
# Runs the .cocci files in kernel-drivers/tests/coccinelle/ against the
# current rewrite sources. If spatch is not installed or no kernel trees are
# available, prints the bootstrap command and exits 0 (degraded mode) so the
# main check-repo.sh gate does not spuriously fail on a tooling gap.
# CI with --strict turns missing-tool into a hard failure.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
ROCK5B_WORKSPACE="${ROCK5B_WORKSPACE:-$ROOT_DIR/../rock-5b}"
STRICT="${STRICT:-0}"

COCCI_DIR="$TEST_DIR/coccinelle"
KERNEL_6_18="${KERNEL_6_18:-$ROCK5B_WORKSPACE/kernel/linux-6.18-rkvenc}"
KERNEL_MAINLINE="${KERNEL_MAINLINE:-$ROCK5B_WORKSPACE/kernel/linux}"

fail=0

if ! command -v spatch >/dev/null 2>&1; then
  echo "note: spatch (coccinelle) not installed -- skipping semantic-patch checks" >&2
  echo "      bootstrap: sudo apt install coccinelle   (both packaged on this arm64 release)" >&2
  echo "      smatch (separate lane) needs a pinned source build that bundles its own sparse" >&2
  if [ "$STRICT" = 1 ]; then
    echo "STRICT=1: treating missing spatch as failure" >&2
    exit 1
  fi
  exit 0
fi

for tree in "$KERNEL_6_18" "$KERNEL_MAINLINE"; do
  if [ ! -d "$tree" ]; then
    echo "skip: kernel tree not found: $tree" >&2
    continue
  fi
  echo "=== coccinelle checks: $tree ==="
  for cocci in "$COCCI_DIR"/*.cocci; do
    [ -e "$cocci" ] || continue
    name="$(basename "$cocci")"
    echo "--- $name ---"
    # spatch --no-includes --very-quiet, only report on rewrite sources to keep output small
    if ! spatch --no-includes --very-quiet \
         --cocci-file "$cocci" \
         --dir "$tree/drivers/video/rockchip/mpp-rewrite" \
         --dir "$tree/drivers/video/rockchip/rga-rewrite" 2>&1; then
      echo "FAIL: $name reported findings" >&2
      fail=1
    fi
  done
done

if [ "$fail" != 0 ]; then
  echo "FAIL: one or more coccinelle rules reported findings" >&2
  exit 1
fi
echo "PASS: coccinelle owning-module rules (or degraded-mode skip)"
