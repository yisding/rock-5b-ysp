# Interpolation Probes

These reproducers isolate the Mali-G610/Panfrost varying-interpolation drift
behind the wide non-power-of-two BLIT corruption. They are deliberately kept
separate from the texture-transfer reproducers because they are not testing
Mesa's transfer path directly. They test whether a fragment shader receives an
exact per-pixel coordinate when that coordinate is carried as an interpolated
varying.

## Files

| File | Purpose |
|---|---|
| [`probe_interp.c`](probe_interp.c) | Original GBM/EGL/GLES probe. Draws a two-triangle quad with an explicit vertex attribute varying from `0` to `W`, then compares the interpolated value with `i + 0.5`. Includes `smooth`, attempted `noperspective`, and `gl_FragCoord.x` modes. |
| [`tiny_interp_probe.c`](tiny_interp_probe.c) | Minimal surfaceless EGL/GLES proof. Uses one `gl_VertexID` triangle, no texture, no TXF, no u_blitter, no GBM, and no format-changing readback. This is the canonical GL reproducer. |
| [`exact_offset_scan.c`](exact_offset_scan.c) | Bitwise baseline-vs-zero-polygon-offset scanner for the one-fullscreen-triangle GL probe. Finds which widths produce identical raw varying bits and which only remain integer-bin correct. |
| [`exact_offset_scan2d.c`](exact_offset_scan2d.c) | 2D bitwise scanner. Carries both `x + 0.5` and `y + 0.5`, supports full line scans (`Wx1`, `1xH`, `Wx2`, `2xH`), full power-of-two cross-products, and a scissored top-right sample for every `WxH` pair. |
| [`tex_interp_probe.c`](tex_interp_probe.c) | Ordinary-TEX counterpart. Carries a normalized non-integer `0→1` varying into `texture()` with `GL_NEAREST` and samples an `R32F` ramp, proving the workaround is not specific to raw varying readback or integer-coordinate TXF. |
| [`triangle_matrix_probe.c`](triangle_matrix_probe.c) | MR !43161 option matrix. Sweeps wide/tall targets, exact half-rectangle and oversized triangles, all right-angle corners, both windings, both long-axis directions, raw-varying vs normalized `texture()` sampling, and baseline vs zero-valued polygon offset. |
| [`vk_interp_probe.c`](vk_interp_probe.c) | Vulkan/panvk port of the tiny probe. Removes Gallium, u_blitter, and the GL state tracker from the stack. Uses dynamic rendering, copies raw `R32_UINT` bits back with Vulkan, and provides a zero-valued `depthBiasEnable` A/B mode. |
| [`tiny_interp_probe_arm_blob_x11.c`](tiny_interp_probe_arm_blob_x11.c) | **RK3588 proprietary ARM Mali variant — the runnable one.** Renders as a client of a running X server, so libmali never issues the kernel-crashing `SET_VERSION`. Shader/draw/readback/checker identical to the tiny probe. |
| [`tiny_interp_probe_arm_blob.c`](tiny_interp_probe_arm_blob.c) | RK3588 ARM Mali variant via a GBM display. **⚠ Crashes the Radxa 5.10 vendor kernel** (NULL-deref in `drm_setversion`); refuses to run by default. Kept for the record — use the X11 variant instead. |
| [`vk_interp_probe_arm_blob.c`](vk_interp_probe_arm_blob.c) | ARM-named Vulkan entry point for scripts/logs. It includes `vk_interp_probe.c` directly because the RK3588 libmali ICD advertises Vulkan 1.3, so no Vulkan source fork is needed. (The installed g6p0 blob ships no Vulkan ICD, so this is currently unrunnable on this board.) |
| [`arm-mali-reproducer.md`](arm-mali-reproducer.md) | **Focused, ARM-specific overview — read this first for the Mali blob.** What it measures, the GBM-crash-vs-X11 story, how to build/run, and the verified result. |
| [`README-arm-blob.md`](README-arm-blob.md) | Long source-backed ARM/RK3588 driver capability notes, exact patch map, and full step-by-step proprietary-driver runbook. |
| [`vk_interp_probe.vert`](vk_interp_probe.vert) | Vulkan vertex shader. Emits the varying `v` that should interpolate to `x + 0.5`. |
| [`vk_interp_probe.varying.frag`](vk_interp_probe.varying.frag) | Vulkan test fragment shader. Stores `floatBitsToUint(v)`. |
| [`vk_interp_probe.fragcoord.frag`](vk_interp_probe.fragcoord.frag) | Vulkan control fragment shader. Stores `floatBitsToUint(gl_FragCoord.x)`. |
| [`mr43161_size_repro.sh`](mr43161_size_repro.sh) | One-command driver for the MR !43161 size/aspect findings. Builds the probes in this directory and runs only the cases that demonstrate bit-exact baseline-vs-workaround equality for both-pow2 sizes, the `1x1`..`1500x1500` integer-bin boundary, and the first `1xN`/`Nx1` failures. |

The `*_explained.*` files are runnable teaching copies of the same reproducers.
They keep the compact reproducers untouched and add intentionally excessive
comments for a reader with ordinary programming experience but no graphics
background:

| File | Purpose |
|---|---|
| [`probe_interp_explained.c`](probe_interp_explained.c) | Comment-heavy version of the historical GBM/GLES probe, including explanations of GBM, EGL, framebuffers, vertex attributes, varyings, and the readback check. |
| [`tiny_interp_probe_explained.c`](tiny_interp_probe_explained.c) | Comment-heavy version of the canonical minimal GLES probe. This is the best first code file to read. |
| [`vk_interp_probe_explained.c`](vk_interp_probe_explained.c) | Comment-heavy Vulkan host program explaining instance/device selection, memory, render targets, pipeline setup, command buffers, barriers, copy-to-buffer, and CPU verification. |
| [`tiny_interp_probe_arm_blob_x11_explained.c`](tiny_interp_probe_arm_blob_x11_explained.c) | Comment-heavy version of the runnable X11-client ARM Mali variant. Explains X-client vs GBM, why the GBM path Oopses the kernel, and the DRI2/no-`SET_VERSION` reasoning. |
| [`tiny_interp_probe_arm_blob_explained.c`](tiny_interp_probe_arm_blob_explained.c) | Comment-heavy GBM ARM Mali variant (the crashing path). Explains the GBM display setup; kept as documentation of why that route is unusable on this kernel. |
| [`vk_interp_probe_arm_blob_explained.c`](vk_interp_probe_arm_blob_explained.c) | Comment-heavy ARM Vulkan entry point. Explains why the Vulkan ARM variant intentionally includes the canonical explained Vulkan probe instead of forking it. |
| [`vk_interp_probe_explained.vert`](vk_interp_probe_explained.vert) | Comment-heavy Vulkan vertex shader. |
| [`vk_interp_probe_explained.varying.frag`](vk_interp_probe_explained.varying.frag) | Comment-heavy Vulkan test fragment shader. |
| [`vk_interp_probe_explained.fragcoord.frag`](vk_interp_probe_explained.fragcoord.frag) | Comment-heavy Vulkan control fragment shader. |

## Environment

Run these on the ROCK 5B, or another machine with the target Mesa driver
available. From the repo root:

```bash
cd video-libraries/mesa/reproducers/interp_probe
```

For a local Mesa build, point the loaders at the build products before running:

```bash
export LD_LIBRARY_PATH=/path/to/mesa/build/src/egl:/path/to/mesa/build/src/gbm:/path/to/mesa/build/src/gallium/targets/dril
export LIBGL_DRIVERS_PATH=/path/to/mesa/build/src/gallium/targets/dril
export GBM_BACKENDS_PATH=/path/to/mesa/build/src/gbm/backends/dri
export EGL_PLATFORM=surfaceless
```

`probe_interp*.c` uses GBM and hardcodes `/dev/dri/renderD128`.
`tiny_interp_probe.c`, `tiny_interp_probe_explained.c`, `tex_interp_probe.c`,
and `triangle_matrix_probe.c` use surfaceless EGL and open no DRM node
themselves.
`tiny_interp_probe_arm_blob_x11.c` connects to a running X server and opens no
DRM node itself; `tiny_interp_probe_arm_blob.c` (GBM) defaults to
`/dev/dri/renderD128` but crashes this kernel and is gated off.
`vk_interp_probe*.c` selects a Vulkan physical device by name substring
(`Mali` by default, or pass `llvmpipe` for the software control).

For the proprietary ARM Mali stack on the same Rock 5B/RK3588 hardware, start
with [`arm-mali-reproducer.md`](arm-mali-reproducer.md) (focused overview) and
see [`README-arm-blob.md`](README-arm-blob.md) for the full runbook. The runnable
ARM GL variant is the X11-client one; the ARM Vulkan entry point intentionally
shares the canonical Vulkan source.

## Build

Build from this directory:

The ARM Mali variants link `libmali` directly (`-lmali`): the vendor
`.../mali/libEGL|libGLESv2|libgbm` files are zero-symbol forwarding stubs, so
`-lEGL -lGLESv2 -lgbm` fails to link. Use the **X11** variant to actually run —
the GBM one crashes this kernel (see
[`arm-mali-reproducer.md`](arm-mali-reproducer.md)).

```bash
cc -O2 -o probe_interp probe_interp.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o tiny_interp_probe tiny_interp_probe.c -lEGL -lGLESv2 -lm
cc -O2 -Wall -Wextra -o exact_offset_scan \
  exact_offset_scan.c -lEGL -lGLESv2 -lm
cc -O2 -Wall -Wextra -o exact_offset_scan2d \
  exact_offset_scan2d.c -lEGL -lGLESv2 -lm
cc -O2 -o tex_interp_probe tex_interp_probe.c -lEGL -lGLESv2
cc -O2 -Wall -Wextra -o triangle_matrix_probe \
  triangle_matrix_probe.c -lEGL -lGLESv2 -lm
cc -O2 -o tiny_interp_probe_arm_blob_x11 \
  tiny_interp_probe_arm_blob_x11.c -lmali -lX11 -lm
cc -O2 -o tiny_interp_probe_arm_blob \
  tiny_interp_probe_arm_blob.c -lmali -lm          # GBM: gated off, crashes kernel

glslc vk_interp_probe.vert           -o vk_interp_probe.vert.spv
glslc vk_interp_probe.varying.frag   -o vk_interp_probe.varying.frag.spv
glslc vk_interp_probe.fragcoord.frag -o vk_interp_probe.fragcoord.frag.spv
cc -O2 -o vk_interp_probe vk_interp_probe.c -lvulkan -lm
cc -O2 -o vk_interp_probe_arm_blob vk_interp_probe_arm_blob.c -lvulkan -lm
```

Build the explained copies separately:

```bash
cc -O2 -o probe_interp_explained probe_interp_explained.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o tiny_interp_probe_explained tiny_interp_probe_explained.c -lEGL -lGLESv2 -lm
cc -O2 -o tiny_interp_probe_arm_blob_x11_explained \
  tiny_interp_probe_arm_blob_x11_explained.c -lmali -lX11 -lm
cc -O2 -o tiny_interp_probe_arm_blob_explained \
  tiny_interp_probe_arm_blob_explained.c -lmali -lm   # GBM: gated off, crashes kernel

glslc vk_interp_probe_explained.vert \
  -o vk_interp_probe_explained.vert.spv
glslc vk_interp_probe_explained.varying.frag \
  -o vk_interp_probe_explained.varying.frag.spv
glslc vk_interp_probe_explained.fragcoord.frag \
  -o vk_interp_probe_explained.fragcoord.frag.spv
cc -O2 -o vk_interp_probe_explained vk_interp_probe_explained.c -lvulkan -lm
cc -O2 -o vk_interp_probe_arm_blob_explained \
  vk_interp_probe_arm_blob_explained.c -lvulkan -lm
```

The Vulkan executables open their `.spv` files by relative filename, so run
them from this directory unless you also copy the compiled `.spv` files to your
current working directory.

## Quick Runs

```bash
./probe_interp 16307 0
./probe_interp 16307 2

./tiny_interp_probe
./tiny_interp_probe 12288 fragcoord
./tiny_interp_probe 8192
./tiny_interp_probe 16307 varying
./tiny_interp_probe 12288 varying polygon-offset
./exact_offset_scan
./exact_offset_scan --details 2081
./exact_offset_scan2d --max 4096 --lines --pow2
./exact_offset_scan2d --max 4096 --sample-grid --progress 1024

./tex_interp_probe 12288 baseline
./tex_interp_probe 12288 polygon-offset
./tex_interp_probe 16307 baseline
./tex_interp_probe 16307 polygon-offset

./triangle_matrix_probe --all-sizes
./triangle_matrix_probe --summary-only --long 12288 --short 1
./triangle_matrix_probe --summary-only --long 12848 --short 14
./triangle_matrix_probe --summary-only --long 9350 --short 11
./triangle_matrix_probe --fail-only --long 16307 --short 16
./triangle_matrix_probe --summary-only --long 2080 --short 1
./triangle_matrix_probe --summary-only --long 16383 --short 96
./triangle_matrix_probe --summary-only --long 2048 --short 1 --coord-long 6144
./triangle_matrix_probe --summary-only --long 12288 --scan-short 40

# ARM Mali blob: use the X11 variant (needs a running X server; see
# arm-mali-reproducer.md). The GBM tiny_interp_probe_arm_blob crashes this kernel.
DISPLAY=:0 ./tiny_interp_probe_arm_blob_x11 8192 fragcoord
DISPLAY=:0 ./tiny_interp_probe_arm_blob_x11 12288 varying
DISPLAY=:0 ./tiny_interp_probe_arm_blob_x11 16307 varying

./vk_interp_probe
./vk_interp_probe 12288 fragcoord
./vk_interp_probe 16307 varying
./vk_interp_probe 12288 varying Mali depth-bias
./vk_interp_probe 16307 varying Mali depth-bias
./vk_interp_probe 12288 varying llvmpipe
./vk_interp_probe_arm_blob
./vk_interp_probe_arm_blob 12288 fragcoord
```

The explained copies take the same arguments:

```bash
./probe_interp_explained 16307 0
./probe_interp_explained 16307 2

./tiny_interp_probe_explained
./tiny_interp_probe_explained 12288 fragcoord
./tiny_interp_probe_explained 12288 varying polygon-offset
./tiny_interp_probe_arm_blob_explained
./tiny_interp_probe_arm_blob_explained 12288 fragcoord

./vk_interp_probe_explained
./vk_interp_probe_explained 12288 varying Mali depth-bias
./vk_interp_probe_explained 12288 varying llvmpipe
./vk_interp_probe_arm_blob_explained
./vk_interp_probe_arm_blob_explained 12288 fragcoord
```

Exit codes (for `tiny_interp_probe`, `tex_interp_probe`,
`triangle_matrix_probe`, and `vk_interp_probe`):

- `0`: every pixel produced its expected value.
- `2`: the probe ran and found at least one wrong pixel.
- `1`: usage, EGL/GL/Vulkan setup, shader compile, or readback setup error.

## What The Probes Do

All three probes draw a `W x 1` target. The test varying is constructed so that
pixel `x` should receive exactly `x + 0.5` at its center. The fragment shader
stores the raw f32 bits of that value into an integer render target. The CPU
reads the raw bits back and checks `floor(v) == x`.

That check models the failing u_blitter TXF path: if an interpolated coordinate
that should be `x + 0.5` arrives even slightly below `x`, truncation fetches the
previous texel. The probes avoid texture sampling so a failure cannot be blamed
on filtering, `texelFetch`, nearest tie-breaks, texture formats, or readback
conversion.

`probe_interp.c` is the historical GBM/EGL version. It draws a quad with a
vertex attribute named `tc` running from `0` at the left edge to `W` at the right
edge, writes `floatBitsToUint(tc)`, and reports floor mismatches plus sample
errors. Mode `0` uses a normal smooth varying. Mode `2` writes
`gl_FragCoord.x` through the otherwise same target/readback path. Mode `1`
tries `noperspective`, but GLSL ES 3.1 treats `noperspective` as a reserved word,
so this mode fails shader compilation and is not a valid data-producing run.

`tiny_interp_probe.c` removes the remaining GL-side distractions. It uses
surfaceless EGL, links `libGLESv2` directly, draws one large
`gl_VertexID`-generated triangle, stores to `R32UI`, and reads back
`GL_RED_INTEGER`/`GL_UNSIGNED_INT`. Mode `varying` is the test. Mode
`fragcoord` stores `gl_FragCoord.x` as the raster/readback control. It prints
`GL_RENDERER` and `GL_VERSION` to stderr so the driver actually used is visible.
An optional third argument, `polygon-offset`, enables `GL_POLYGON_OFFSET_FILL`
and sets `glPolygonOffset(0.0f, 0.0f)` immediately before the draw. Kusma
identified this in [Mesa MR !42679](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42679#note_3578636)
as a workaround for the confirmed hardware erratum. The default `baseline`
mode leaves the state untouched for an A/B comparison.

`exact_offset_scan.c` uses the same one-fullscreen-triangle GL draw as
`tiny_interp_probe.c`, but renders each width twice: once with baseline
rasterizer state and once with zero-valued polygon offset. It compares the raw
`R32UI` float bits for every pixel, separately checks each path against exact
`float(x + 0.5)`, and also records the weaker integer-bin condition
`floor(v) == x`. This distinguishes bit-exact interpolation from values that
are merely close enough for integer/TXF-style blit coordinates.

`exact_offset_scan2d.c` extends that exactness test to a `vec2` varying. It
renders `RG32UI` raw float bits for `x + 0.5` and `y + 0.5`. Full modes compare
every pixel for selected size families. `--sample-grid` avoids the infeasible
70T-fragment exhaustive grid by enabling scissor and rendering only the
top-right pixel (`W-1,H-1`) for each `WxH` pair; each pair maps to the same
pixel in a max-sized result texture, so the scanner does one bulk readback for
baseline and one for offset.

`tex_interp_probe.c` tests the non-integer coordinate case with an actual
ordinary texture operation. Its smooth varying runs from normalized `0` to `1`;
the fragment shader passes that coordinate to GLSL `texture()` with
`GL_NEAREST`, samples an `R32F` ramp whose texel `x` contains `float(x)`, and
stores the sampled float's raw bits in `R32UI`. Thus pixel `x` must return
`float(x)`. A compiler dump confirmed that Panfrost emits an ordinary
computed-LOD `TEX_SINGLE` instruction, not TXF. It accepts the same
`baseline|polygon-offset` A/B choice as the tiny probe.

`triangle_matrix_probe.c` tests the same hardware path as a triangle option
matrix. It draws either exact half-rectangle triangles or oversized full-target
triangles. For exact triangles, only covered pixels are checked; for oversized
triangles, full coverage is required. The four right-angle corners cover both
diagonal splits of a rectangle, and the winding option distinguishes the order
in which the same triangle reaches setup. `sample=varying` writes the raw
varying bits and checks `floor(v)`. `sample=tex` is the non-integer case: it
passes a normalized coordinate to ordinary nearest-filtered `texture()` and
checks the sampled `R32F` ramp. `--summary-only` prints aggregate failure counts;
`--fail-only` prints only the failing per-case rows plus those aggregates.
`--all-sizes` runs the known MR !43161 and local boundary sizes as full
256-case matrices. `--coord-long N` lets the destination extent and
source-coordinate range differ, which is useful for scaled-coordinate stress;
avoid interpreting ordinary `texture()` mismatches from even-integer scale
factors as erratum evidence because they can place samples exactly on nearest
tie boundaries. Raw-varying checks and odd-integer scale factors are cleaner
for scaled experiments.

`vk_interp_probe.c` ports the same test to Vulkan. It creates a `W x 1`
`VK_FORMAT_R32_UINT` color target, renders with dynamic rendering, then copies
the image to a host-visible buffer with `vkCmdCopyImageToBuffer`. The readback
is raw bits, not a format conversion. The buffer is initialized with a sentinel,
and the printed `unwritten` count is a coverage sanity check; it should be `0`.
The default physical-device substring is `Mali`; pass `llvmpipe` to run the
same binary on software. Its optional fourth argument is
`baseline|depth-bias`. `depth-bias` sets
`VkPipelineRasterizationStateCreateInfo::depthBiasEnable` to `VK_TRUE` while
leaving constant factor, clamp, and slope factor at zero. PanVK maps that state
to the same Valhall `depth_bias_enable` descriptor bit as the GL workaround.

## Expected Results

On ROCK 5B / Mali-G610, the system Mesa 26.0.3 Panfrost/panvk stack shows the
same baseline failure in GL and Vulkan. The polygon-offset workaround removes
the GL failure completely (measured 2026-07-22):

```text
$ ./tiny_interp_probe
mode=varying workaround=baseline width=12288: floor(v) != x at 11744 of 12288 pixels (first at x=529)
last pixel x=12287: v=12275.5312 expected=12287.5 relative_error=9.741e-04 (0.997 * 2^-10)

$ ./tiny_interp_probe 12288 varying polygon-offset
mode=varying workaround=polygon-offset width=12288: floor(v) != x at 0 of 12288 pixels (first at x=-1)
last pixel x=12287: v=12287.5000 expected=12287.5 relative_error=0.000e+00 (0.000 * 2^-10)

$ ./tiny_interp_probe 12288 fragcoord
mode=fragcoord workaround=baseline width=12288: floor(v) != x at 0 of 12288 pixels (first at x=-1)
last pixel x=12287: v=12287.5000 expected=12287.5 relative_error=0.000e+00 (0.000 * 2^-10)

$ ./tiny_interp_probe 8192
mode=varying workaround=baseline width=8192: floor(v) != x at 0 of 8192 pixels (first at x=-1)
last pixel x=8191: v=8191.5000 expected=8191.5 relative_error=0.000e+00 (0.000 * 2^-10)

$ ./tiny_interp_probe 16307 varying
mode=varying workaround=baseline width=16307: floor(v) != x at 15672 of 16307 pixels (first at x=623)
last pixel x=16306: v=16293.2832 expected=16306.5 relative_error=8.105e-04 (0.830 * 2^-10)

$ ./tiny_interp_probe 16307 varying polygon-offset
mode=varying workaround=polygon-offset width=16307: floor(v) != x at 0 of 16307 pixels (first at x=-1)
last pixel x=16306: v=16306.5000 expected=16306.5 relative_error=0.000e+00 (0.000 * 2^-10)
```

The exact baseline-vs-offset scanner shows that bitwise exactness is much
stricter than integer-bin correctness for the one-fullscreen-triangle GL path
(measured 2026-07-24):

```text
$ ./exact_offset_scan 4096
SUMMARY max_width=4096 same_as_offset=13 baseline_exact=13 offset_exact=13 baseline_floor_pass=3429 offset_floor_pass=4096
same-as-offset widths: 1-2,4,8,16,32,64,128,256,512,1024,2048,4096
baseline-exact widths: 1-2,4,8,16,32,64,128,256,512,1024,2048,4096
offset-exact widths: 1-2,4,8,16,32,64,128,256,512,1024,2048,4096
offset-floor-pass widths: 1-4096
```

Non-power-of-two widths are already not bit-exact at width `3`, but remain
integer-bin correct until the first one-fullscreen-triangle floor failure at
`2080`:

```text
$ ./exact_offset_scan --details 2081
2080,2079,2080,1350,32,0,1,0,0
SUMMARY max_width=2081 same_as_offset=12 baseline_exact=12 offset_exact=12 baseline_floor_pass=2080 offset_floor_pass=2081
```

The 2D scanner confirms the power-of-two exactness rule for full power-of-two
surfaces and shows directional asymmetry for thin non-power-of-two surfaces
(measured 2026-07-24):

```text
$ ./exact_offset_scan2d --max 4096 --lines --pow2
LINE-SUMMARY Wx1 max=4096 same_as_offset=13 baseline_exact=13 offset_exact=13 baseline_floor_pass=3429 offset_floor_pass=4096 floor_failing_cases=667
LINE-SUMMARY 1xH max=4096 same_as_offset=13 baseline_exact=13 offset_exact=13 baseline_floor_pass=2762 offset_floor_pass=4096 floor_failing_cases=1334
LINE-SUMMARY Wx2 max=4096 same_as_offset=13 baseline_exact=13 offset_exact=13 baseline_floor_pass=3938 offset_floor_pass=4096 floor_failing_cases=158
LINE-SUMMARY 2xH max=4096 same_as_offset=13 baseline_exact=13 offset_exact=13 baseline_floor_pass=3459 offset_floor_pass=4096 floor_failing_cases=637
POW2-SUMMARY max=4096 cases=169 same_as_offset=169 baseline_exact=169 offset_exact=169 baseline_floor_pass=169 offset_floor_pass=169 nonexact_cases=0
```

First baseline integer-bin failures in those full line scans:

| Family | First sampled/full failure | Offset floor failures |
|---|---:|---:|
| `Wx1` | `2080x1` | 0 |
| `1xH` | `1x1480` | 0 |
| `Wx2` | `2947x2` | 0 |
| `2xH` | `2x2080` | 0 |

The all-pairs sampled grid checks the top-right pixel for every size from
`1x1` through `4096x4096`. It is not a full-surface exactness proof for
non-power-of-two sizes, but it is a cheap check for whether that representative
pixel crosses the integer boundary:

```text
$ ./exact_offset_scan2d --max 4096 --sample-grid --progress 1024
SAMPLE-GRID-SUMMARY max=4096 sample=top-right pairs=16777216 same_as_offset=108346 baseline_exact=7976 offset_exact=5119056 baseline_floor_pass=16775526 offset_floor_pass=16777216 same_pred_mismatch=108177 baseline_exact_pred_mismatch=7807 offset_exact_pred_mismatch=5118887 baseline_floor_failures=1690 offset_floor_failures=0 baseline_floor_fail_width_range=1..4095 baseline_floor_fail_height_range=1..4095 baseline_floor_fail_first=2080x1 baseline_floor_fail_last=1x4095 baseline_floor_fail_h1=666 baseline_floor_fail_w1=697
```

The ordinary-TEX probe shows the same result for normalized, non-integer
coordinates:

```text
$ ./tex_interp_probe 12288 baseline
fetch=TEX filter=nearest workaround=baseline width=12288: sampled texel != x at 11744 of 12288 pixels (first at x=529, sampled=528)
last pixel x=12287: sampled=12275 expected=12287 shift=-12

$ ./tex_interp_probe 12288 polygon-offset
fetch=TEX filter=nearest workaround=polygon-offset width=12288: sampled texel != x at 0 of 12288 pixels (first at x=-1)
last pixel x=12287: sampled=12287 expected=12287 shift=+0

$ ./tex_interp_probe 16307 baseline
fetch=TEX filter=nearest workaround=baseline width=16307: sampled texel != x at 15670 of 16307 pixels (first at x=623, sampled=622)
last pixel x=16306: sampled=16293 expected=16306 shift=-13

$ ./tex_interp_probe 16307 polygon-offset
fetch=TEX filter=nearest workaround=polygon-offset width=16307: sampled texel != x at 0 of 16307 pixels (first at x=-1)
last pixel x=16306: sampled=16306 expected=16306 shift=+0
```

The triangle matrix probe answers which GL triangle choices are affected. On
ROCK 5B / Mali-G610 with system Mesa 26.0.3, all failures are baseline-only;
every zero-valued polygon-offset case passes, including the normalized
`texture()` cases:

| Case | Result |
|---|---|
| `12288x1`, full 256-case matrix | 128 failures: all baseline cases fail across wide/tall, exact/oversized, all corners, both windings, both ramps, and raw-varying plus ordinary `texture()`; all 128 polygon-offset cases pass. |
| `12848x14` (`aspect=917.714`, from Mesa MR !43161 discussion), full matrix | Same 128 baseline-only failures. |
| `9350x11` (`aspect=850.000`, from Mesa MR !43161 discussion), full matrix | Same 128 baseline-only failures. |
| `16307x15` (`aspect=1087.133`), full matrix | Same 128 baseline-only failures. |
| `16307x16` and sampled transition sizes up to `16307x63` | Exact half-rectangle triangles pass. Oversized baseline triangles still fail for specific corner/winding combinations; both ramps and both sample modes fail for those combinations, and polygon offset passes. |
| `16307x64` | Full 256-case matrix passes. |
| `16384x1` and `16384x16` | Full 256-case matrix passes despite high aspect ratio, matching the power-of-two control in the Mesa thread. |

For `16307x16` and `16307x33`, `--fail-only` printed the same failing
oversized corner/winding set:

| Axis | Failing oversized baseline corner/winding pairs |
|---|---|
| wide | `bl/cw`, `br/ccw`, `br/cw`, `tr/ccw` |
| tall | `bl/ccw`, `tl/ccw`, `tl/cw`, `tr/cw` |

The canonical oversized-triangle scans found these short-axis boundaries:

| Long extent | Failing short extents | First passing short extent |
|---:|---|---:|
| 9350 | `1..15` (`aspect` down to `623.333`) | `16` (`584.375`) |
| 12288 | `1..16` (`aspect` down to `768.000`) | `17` (`722.824`) |
| 12848 | `1..15` (`aspect` down to `856.533`) | `16` (`803.000`) |

Additional predicate probes show why a simple aspect threshold is not the
right hardware model:

| Case | Result |
|---|---|
| `2080x1` | Fails 96/256; offset fixes all. This matches the older smallest-known-width boundary in the local notes. |
| `2047x1`, `2047x1 --coord-long 6141`, `2048x1 --coord-long 6144`, `4096x1 --coord-long 12288` | Pass. Source-coordinate range alone did not trigger failures when the destination extent stayed in a passing family. |
| `10000x15` | Broad 128/256 baseline-only failure. |
| `10000x16` | Pass despite `aspect=625.000`. |
| `8191x1` | Fails 112/256; offset fixes all. |
| `8191x16` and `8191x32` | Pass despite `aspect=511.938` at `short=16`. |
| `16383x96` | Oversized-only 8/256 baseline-only failure at `aspect=170.656`. |
| `16383x100`, `16383x104`, `16383x112`, `16383x128` | Pass. |
| `16384x96` | Pass; power-of-two control still holds in this band. |

The practical Mesa predicate proposed from this is: for the Panfrost internal
fullscreen blitter path on affected Valhall generations (`arch >= 9 &&
arch < 11`), enable the zero-valued polygon-offset workaround without a size
threshold. The failure field is jagged enough that `1000`, `500`, and even a
new lower aspect threshold are policy guesses, not hardware predicates. If a
size gate is still required for performance reasons, the measured conservative
fallback is `major >= 2048 && !util_is_power_of_two_or_zero(major) &&
major >= 128 * minor`, but that intentionally applies to known-passing cases
and should be treated as a compromise rather than the right predicate.

Vulkan/panvk reproduces the GL numbers bit-for-bit at the same widths and the
equivalent zero-valued depth-bias state removes the failure:

```text
$ ./vk_interp_probe
mode=varying workaround=baseline width=12288 device=Mali-G610 MC4: floor(v) != x at 11744 of 12288 pixels (first at x=529, unwritten=0)
last pixel x=12287: v=12275.5312 expected=12287.5 relative_error=9.741e-04 (0.997 * 2^-10)

$ ./vk_interp_probe 12288 varying Mali depth-bias
mode=varying workaround=depth-bias width=12288 device=Mali-G610 MC4: floor(v) != x at 0 of 12288 pixels (first at x=-1, unwritten=0)
last pixel x=12287: v=12287.5000 expected=12287.5 relative_error=0.000e+00 (0.000 * 2^-10)

$ ./vk_interp_probe 16307 varying Mali baseline
mode=varying workaround=baseline width=16307 device=Mali-G610 MC4: floor(v) != x at 15672 of 16307 pixels (first at x=623, unwritten=0)
last pixel x=16306: v=16293.2832 expected=16306.5 relative_error=8.105e-04 (0.830 * 2^-10)

$ ./vk_interp_probe 16307 varying Mali depth-bias
mode=varying workaround=depth-bias width=16307 device=Mali-G610 MC4: floor(v) != x at 0 of 16307 pixels (first at x=-1, unwritten=0)
last pixel x=16306: v=16306.5000 expected=16306.5 relative_error=0.000e+00 (0.000 * 2^-10)

$ ./vk_interp_probe 12288 fragcoord
mode=fragcoord workaround=baseline width=12288 device=Mali-G610 MC4: floor(v) != x at 0 of 12288 pixels (first at x=-1, unwritten=0)
last pixel x=12287: v=12287.5000 expected=12287.5 relative_error=0.000e+00 (0.000 * 2^-10)

$ ./vk_interp_probe 12288 varying llvmpipe
mode=varying workaround=baseline width=12288 device=llvmpipe (LLVM 21.1.8, 128 bits): floor(v) != x at 0 of 12288 pixels (first at x=-1, unwritten=0)
```

The controls matter:

- `polygon-offset` passes at both failing widths tested (`12288` and `16307`),
  confirming the maintainer-provided hardware-erratum workaround on G610.
- Vulkan `depth-bias` passes at the same two widths with the same zero-valued
  state, confirming that the descriptor-bit workaround is API-independent.
- The same workaround also passes the ordinary-TEX probe at both widths;
  baseline fails, while the 8192-wide baseline and llvmpipe controls pass.
- `fragcoord` passes on Mali, so rasterization and readback are sound.
- Power-of-two widths such as `8192` and `16384` pass, so the failure is
  width-dependent, not a blanket "all f32 varyings are 10-bit" rule.
- `llvmpipe` passes the Vulkan binary, so the checker itself is sound.
- panvk reproduces the GL result without Gallium, u_blitter, or the GL state
  tracker, so the drift is below those layers.

Measured width behavior on this board:

- Every tested power-of-two width from `512` through `16384` is bit-exact.
- Non-power-of-two widths show a jagged relative error: exactly `2^-12` at
  `W=2080`, exactly `2^-14` at `W=16383`, and about `2^-10` at `W=12288` and
  `W=16307`.
- The smallest measured width where `floor()` fails is `2080`
  (`x=2048..2079`). Failing widths are sparse and non-monotone below roughly
  `4300`, then become dense.

The baseline result is a confirmed Mali hardware erratum in the
interpolated-varying path for large non-power-of-two extents. It is not
evidence that u_blitter, texture sampling, TXF, filtering, or readback
conversion is wrong. Enabling zero-valued polygon offset in GL or depth bias
in Vulkan selects the unaffected hardware path without moving the primitive.
