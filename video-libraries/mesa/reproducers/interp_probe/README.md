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
| [`tex_interp_probe.c`](tex_interp_probe.c) | Ordinary-TEX counterpart. Carries a normalized non-integer `0→1` varying into `texture()` with `GL_NEAREST` and samples an `R32F` ramp, proving the workaround is not specific to raw varying readback or integer-coordinate TXF. |
| [`vk_interp_probe.c`](vk_interp_probe.c) | Vulkan/panvk port of the tiny probe. Removes Gallium, u_blitter, and the GL state tracker from the stack. Uses dynamic rendering, copies raw `R32_UINT` bits back with Vulkan, and provides a zero-valued `depthBiasEnable` A/B mode. |
| [`tiny_interp_probe_arm_blob_x11.c`](tiny_interp_probe_arm_blob_x11.c) | **RK3588 proprietary ARM Mali variant — the runnable one.** Renders as a client of a running X server, so libmali never issues the kernel-crashing `SET_VERSION`. Shader/draw/readback/checker identical to the tiny probe. |
| [`tiny_interp_probe_arm_blob.c`](tiny_interp_probe_arm_blob.c) | RK3588 ARM Mali variant via a GBM display. **⚠ Crashes the Radxa 5.10 vendor kernel** (NULL-deref in `drm_setversion`); refuses to run by default. Kept for the record — use the X11 variant instead. |
| [`vk_interp_probe_arm_blob.c`](vk_interp_probe_arm_blob.c) | ARM-named Vulkan entry point for scripts/logs. It includes `vk_interp_probe.c` directly because the RK3588 libmali ICD advertises Vulkan 1.3, so no Vulkan source fork is needed. (The installed g6p0 blob ships no Vulkan ICD, so this is currently unrunnable on this board.) |
| [`arm-mali-reproducer.md`](arm-mali-reproducer.md) | **Focused, ARM-specific overview — read this first for the Mali blob.** What it measures, the GBM-crash-vs-X11 story, how to build/run, and the verified result. |
| [`README-arm-blob.md`](README-arm-blob.md) | Long source-backed ARM/RK3588 driver capability notes, exact patch map, and full step-by-step proprietary-driver runbook. |
| [`vk_interp_probe.vert`](vk_interp_probe.vert) | Vulkan vertex shader. Emits the varying `v` that should interpolate to `x + 0.5`. |
| [`vk_interp_probe.varying.frag`](vk_interp_probe.varying.frag) | Vulkan test fragment shader. Stores `floatBitsToUint(v)`. |
| [`vk_interp_probe.fragcoord.frag`](vk_interp_probe.fragcoord.frag) | Vulkan control fragment shader. Stores `floatBitsToUint(gl_FragCoord.x)`. |

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
`tiny_interp_probe.c`, `tiny_interp_probe_explained.c`, and
`tex_interp_probe.c` use surfaceless EGL and open no DRM node themselves.
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
cc -O2 -o tex_interp_probe tex_interp_probe.c -lEGL -lGLESv2
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

./tex_interp_probe 12288 baseline
./tex_interp_probe 12288 polygon-offset
./tex_interp_probe 16307 baseline
./tex_interp_probe 16307 polygon-offset

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

Exit codes (for `tiny_interp_probe`, `tex_interp_probe`, and
`vk_interp_probe`):

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

`tex_interp_probe.c` tests the non-integer coordinate case with an actual
ordinary texture operation. Its smooth varying runs from normalized `0` to `1`;
the fragment shader passes that coordinate to GLSL `texture()` with
`GL_NEAREST`, samples an `R32F` ramp whose texel `x` contains `float(x)`, and
stores the sampled float's raw bits in `R32UI`. Thus pixel `x` must return
`float(x)`. A compiler dump confirmed that Panfrost emits an ordinary
computed-LOD `TEX_SINGLE` instruction, not TXF. It accepts the same
`baseline|polygon-offset` A/B choice as the tiny probe.

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
