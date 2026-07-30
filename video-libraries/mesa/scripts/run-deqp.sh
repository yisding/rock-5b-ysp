#!/usr/bin/env bash
# Run a dEQP-GLES3 caselist against a surfaceless Panfrost build.
#
#   MESA_BUILD=/home/yi/Code/rock-5b/fdo/mesa/build-codex-main \
#   DEQP=/tmp/deqp-gles-ci/modules/gles3/deqp-gles3 \
#   ./run-deqp.sh cases.txt
#
# NOTES / gotchas found on this box:
#  - Run from a *writable* cwd; the deqp module dir is root-owned so the .qpa
#    log can't be written there. We cd to a temp dir and log to $OUT.
#  - `--deqp-caselist="...*"` (wildcards) is rejected ("Illegal character").
#    Full `--deqp-runmode=txt-caselist` enumeration got OOM-killed here, so
#    build explicit lists instead (e.g. grep a mustpass file):
#      MP=/tmp/deqp-gles-ci/external/openglcts/modules/gl_cts/data/mustpass/gles/aosp_mustpass/main/gles3-main.txt
#      grep '^dEQP-GLES3.functional.fbo.msaa.' "$MP" > msaa.txt
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
YSP_ROOT=$(cd "$HERE/../../.." && pwd)
: "${ROCK5B_WORKSPACE:=$YSP_ROOT/../rock-5b}"
: "${MESA_BUILD:=$ROCK5B_WORKSPACE/fdo/mesa/build-codex-main}"
: "${DEQP:=/tmp/deqp-gles-ci/modules/gles3/deqp-gles3}"
CASES=${1:?usage: run-deqp.sh <caselist.txt>}
CASES=$(readlink -f "$CASES")
OUT=${OUT:-$(mktemp -d)}

. "$HERE/mesa-panfrost-env.sh"
cd "$(dirname "$DEQP")"
"$DEQP" \
  --deqp-surface-type=pbuffer --deqp-gl-config-name=rgba8888d24s8ms0 \
  --deqp-surface-width=256 --deqp-surface-height=256 \
  --deqp-caselist-file="$CASES" \
  --deqp-log-filename="$OUT/out.qpa" | tee "$OUT/out.stdout"
echo "--- log: $OUT/out.qpa ---"
grep -E "Passed|Failed|Not supported|Warnings" "$OUT/out.stdout" | tail -4
