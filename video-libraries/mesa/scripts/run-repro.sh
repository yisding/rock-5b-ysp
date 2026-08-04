#!/usr/bin/env bash
# Compile (if needed) and run the Panfrost blit reproducers, summarizing
# pass/fail. Point MESA_BUILD at a surfaceless build (see build-mesa-surfaceless.sh).
#
#   MESA_BUILD=/home/yi/Code/rock-5b/build/mesa/build-codex-main \
#   REPRO_SRC=/home/yi/Code/rock-5b-ysp/mesa-panfrost-g610/reproducers \
#   ./run-repro.sh
#
# A "PASS" means the reproducer reported 0 mismatches. Cross-check the printed
# GL_VERSION is your build, not the installed system Mesa.
# Aggregating harness: a failing reproducer is the result being reported, not a
# reason to abort the run, so -e stays off (see CONTRIBUTING.md).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
YSP_ROOT=$(cd "$HERE/../../.." && pwd)
: "${ROCK5B_WORKSPACE:=$YSP_ROOT/../rock-5b}"
: "${MESA_BUILD:=$ROCK5B_WORKSPACE/build/mesa/build-codex-main}"
: "${REPRO_SRC:=$HERE/../reproducers}"
BIN=${BIN:-$(mktemp -d)/repro-bin}; mkdir -p "$BIN"

. "$HERE/mesa-panfrost-env.sh"

for c in repro_blit repro_blit_off repro_blit_float repro_blit_flip \
         repro_blit_scissor repro_blit_array repro_afbc probe_const; do
  [ -x "$BIN/$c" ] || cc -O2 -o "$BIN/$c" "$REPRO_SRC/$c.c" -lEGL -lgbm -lm || { echo "compile fail: $c"; continue; }
done

echo "GL: $("$BIN/repro_blit" 2>&1 | grep -oE 'GL_RENDERER=.*')"
run() {
  local name="$1"; shift
  local out rc; out=$(timeout 120 "$BIN/$name" "$@" 2>&1); rc=$?
  local mm; mm=$(echo "$out" | grep -oE "mismatches=[0-9]+ */ *[0-9]+" | head -1)
  local v="CHECK"
  if [ $rc -ne 0 ]; then v="ERROR(rc=$rc)"
  elif echo "$out" | grep -qE "mismatches=[1-9]"; then v="FAIL"
  elif echo "$out" | grep -qE "mismatches=0 |0 mismatches|0 inside|= pass"; then v="PASS"; fi
  printf "%-20s %-11s %s\n" "$name" "$v" "${mm:-}"
}
run repro_blit
run repro_blit_off
run repro_blit_float
run repro_blit_flip
run repro_blit_scissor
run repro_blit_array
run repro_afbc
run probe_const
