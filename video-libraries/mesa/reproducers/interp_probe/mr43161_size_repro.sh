#!/usr/bin/env bash
# Focused reproducer for the Mesa MR !43161 size/aspect findings.
#
# It builds the existing EGL/GLES probes in this directory and runs only the
# cases needed to demonstrate:
#   * bit-exact baseline-vs-workaround equality only for both dimensions pow2;
#   * full integer-bin safety/failure boundary for 1x1..1500x1500;
#   * first 1xN/Nx1 integer-bin failures;
#   * aspect-ratio failures down into the 100s;
#   * ordinary TEX is separate from the integer/TXF-style floor proof.
#
# On affected Panfrost systems, run for example:
#   MESA_LOADER_DRIVER_OVERRIDE=panfrost EGL_PLATFORM=surfaceless ./mr43161_size_repro.sh
#
# By default this runs the exhaustive 1x1..1500x1500 integer-bin scan.
# Use --quick to skip the exhaustive scan.
# Use --sweep N to choose a different exhaustive 1x1..NxN scan.

set -euo pipefail

usage() {
   printf 'usage: %s [--quick|--sweep N]\n' "$0" >&2
}

full_grid_max=1500

case "${1:-}" in
"" )
   if (($# != 0)); then
      usage
      exit 1
   fi
   ;;
"--quick" )
   if (($# != 1)); then
      usage
      exit 1
   fi
   full_grid_max=0
   ;;
"--sweep" )
   if (($# != 2)); then
      usage
      exit 1
   fi
   full_grid_max=$2
   if ! [[ $full_grid_max =~ ^[0-9]+$ ]] || ((full_grid_max < 1)); then
      printf 'sweep size must be a positive integer, got %s\n' \
         "$full_grid_max" >&2
      exit 1
   fi
   ;;
"-h" | "--help" )
   if (($# != 1)); then
      usage
      exit 1
   fi
   usage
   exit 0
   ;;
* )
   usage
   exit 1
   ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$script_dir"

export EGL_PLATFORM="${EGL_PLATFORM:-surfaceless}"

cc_bin=${CC:-cc}
read -r -a cflags <<< "${CFLAGS:--O2 -Wall -Wextra -Werror}"

build_probe() {
   local name=$1
   local src="${name}.c"

   if [[ ! -x $name || $src -nt $name ]]; then
      printf 'building %s\n' "$name" >&2
      "$cc_bin" "${cflags[@]}" -o "$name" "$src" -lEGL -lGLESv2 -lm
   fi
}

run_probe() {
   local rc

   printf '\n##'
   printf ' %q' "$@"
   printf '\n'

   set +e
   "$@"
   rc=$?
   set -e

   if ((rc != 0 && rc != 2)); then
      printf 'unexpected exit status %d from:' "$rc" >&2
      printf ' %q' "$@" >&2
      printf '\n' >&2
      exit "$rc"
   fi
}

build_probe exact_offset_scan2d
build_probe triangle_matrix_probe
build_probe tex_interp_probe

printf 'Renderer should be Mali/Panfrost for the failure cases. llvmpipe is a control and will not reproduce the hardware failures.\n'

printf '\n# 1. Bit-exact baseline-vs-workaround equality\n'
run_probe ./exact_offset_scan2d --main-results --progress 0

printf '\n# 2. Integer/TXF-style boundary around the first 1xN/Nx1 failures\n'
run_probe ./exact_offset_scan2d --case 2079 1 --progress 0
run_probe ./exact_offset_scan2d --case 2080 1 --progress 0
run_probe ./exact_offset_scan2d --case 1 1479 --progress 0
run_probe ./exact_offset_scan2d --case 1 1480 --progress 0

if ((full_grid_max)); then
   printf '\n# 3. Exhaustive 1x1..%dx%d integer-bin scan\n' \
      "$full_grid_max" "$full_grid_max"
   progress_step=50
   if ((full_grid_max > 1024)); then
      progress_step=150
   elif ((full_grid_max > 500)); then
      progress_step=128
   fi
   run_probe ./exact_offset_scan2d --full-grid-floor --max "$full_grid_max" \
      --progress "$progress_step"
else
   printf '\n# 3. Exhaustive 1x1..1500x1500 integer-bin scan skipped by --quick\n'
fi

printf '\n# 4. Aspect-ratio failures and power-of-two control\n'
run_probe ./triangle_matrix_probe --summary-only --long 9350 --short 11
run_probe ./triangle_matrix_probe --summary-only --long 12848 --short 14
run_probe ./triangle_matrix_probe --summary-only --long 16383 --short 96
run_probe ./triangle_matrix_probe --fail-only --long 16383 --short 127 \
   --axis wide --shape oversized --corner bl --winding cw \
   --ramp both --sample varying --offset both
run_probe ./triangle_matrix_probe --summary-only --long 16384 --short 96

printf '\n# 5. Ordinary non-integer TEX is not covered by the integer full-grid proof\n'
run_probe ./tex_interp_probe 12288 baseline
run_probe ./tex_interp_probe 12288 polygon-offset
