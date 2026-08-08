#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: LGPL-2.1-or-later
# Delegate to the maintained plugin builder so every build stages the pinned
# JeffyCN source with the maintained conformance patches applied. This used to
# be a standalone patchless meson build; rebuilding the canonical prefix
# through it dropped the H.26x encoder DMABuf caps patch and regressed the
# required dmabuf transcode cases on 2026-08-07. Keep exactly one real
# builder: kernel-drivers/tests/build-gstreamer-rockchip.sh.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

candidates=(
    "${YSP_GST_BUILDER:-}"
    "$ROOT/../build-gstreamer-rockchip.sh"
    "$ROOT/../../../rock-5b-ysp/kernel-drivers/tests/build-gstreamer-rockchip.sh"
)

for builder in "${candidates[@]}"; do
    [ -n "$builder" ] && [ -f "$builder" ] || continue
    if [ -z "${CONFORMANCE_ROOT:-}" ] && [ -d "$ROOT/sources" ]; then
        export CONFORMANCE_ROOT="$ROOT"
    fi
    exec bash "$builder" "$@"
done

echo "Cannot find the maintained builder kernel-drivers/tests/build-gstreamer-rockchip.sh" >&2
echo "relative to $ROOT; run it from the rock-5b-ysp tree or set YSP_GST_BUILDER." >&2
exit 2
