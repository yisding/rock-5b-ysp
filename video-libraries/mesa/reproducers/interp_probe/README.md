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
| [`vk_interp_probe.c`](vk_interp_probe.c) | Vulkan/panvk port of the tiny probe. Removes Gallium, u_blitter, and the GL state tracker from the stack. Uses dynamic rendering and copies raw `R32_UINT` bits back with Vulkan. |
| [`tiny_interp_probe_arm_blob.c`](tiny_interp_probe_arm_blob.c) | RK3588 proprietary ARM Mali variant of the tiny GL reproducer. Keeps the shader/draw/readback/checker identical, but swaps Mesa's surfaceless platform for a GBM display plus `EGL_NO_SURFACE`. |
| [`vk_interp_probe_arm_blob.c`](vk_interp_probe_arm_blob.c) | ARM-named Vulkan entry point for scripts/logs. It includes `vk_interp_probe.c` directly because the RK3588 libmali ICD advertises Vulkan 1.3, so no Vulkan source fork is needed. |
| [`README-arm-blob.md`](README-arm-blob.md) | Source-backed ARM/RK3588 driver capability notes, exact patch map, and proprietary-driver build/run instructions. |
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
| [`tiny_interp_probe_arm_blob_explained.c`](tiny_interp_probe_arm_blob_explained.c) | Comment-heavy RK3588 proprietary ARM Mali GLES variant. Explains why Mesa's surfaceless platform is replaced with a GBM display while `EGL_NO_SURFACE` is preserved. |
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
`tiny_interp_probe.c` and `tiny_interp_probe_explained.c` use surfaceless EGL
and open no DRM node themselves.
`tiny_interp_probe_arm_blob.c` uses GBM and defaults to `/dev/dri/renderD128`.
`vk_interp_probe*.c` selects a Vulkan physical device by name substring
(`Mali` by default, or pass `llvmpipe` for the software control).

For the proprietary ARM Mali stack on the same Rock 5B/RK3588 hardware, use
[`README-arm-blob.md`](README-arm-blob.md). The ARM GL variant uses GBM instead
of Mesa surfaceless EGL; the ARM Vulkan entry point intentionally shares the
canonical Vulkan source.

## Build

Build from this directory:

```bash
cc -O2 -o probe_interp probe_interp.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o tiny_interp_probe tiny_interp_probe.c -lEGL -lGLESv2 -lm
cc -O2 -o tiny_interp_probe_arm_blob \
  tiny_interp_probe_arm_blob.c -lEGL -lGLESv2 -lgbm -lm

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
cc -O2 -o tiny_interp_probe_arm_blob_explained \
  tiny_interp_probe_arm_blob_explained.c -lEGL -lGLESv2 -lgbm -lm

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
./tiny_interp_probe_arm_blob
./tiny_interp_probe_arm_blob 12288 fragcoord
./tiny_interp_probe_arm_blob 16307 varying /dev/dri/renderD128

./vk_interp_probe
./vk_interp_probe 12288 fragcoord
./vk_interp_probe 16307 varying
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
./tiny_interp_probe_arm_blob_explained
./tiny_interp_probe_arm_blob_explained 12288 fragcoord

./vk_interp_probe_explained
./vk_interp_probe_explained 12288 varying llvmpipe
./vk_interp_probe_arm_blob_explained
./vk_interp_probe_arm_blob_explained 12288 fragcoord
```

Exit codes:

- `0`: every pixel satisfies `floor(v) == x`.
- `2`: the probe ran and found at least one pixel where `floor(v) != x`.
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

`vk_interp_probe.c` ports the same test to Vulkan. It creates a `W x 1`
`VK_FORMAT_R32_UINT` color target, renders with dynamic rendering, then copies
the image to a host-visible buffer with `vkCmdCopyImageToBuffer`. The readback
is raw bits, not a format conversion. The buffer is initialized with a sentinel,
and the printed `unwritten` count is a coverage sanity check; it should be `0`.
The default physical-device substring is `Mali`; pass `llvmpipe` to run the
same binary on software.

## Expected Results

On ROCK 5B / Mali-G610, the system Mesa 26.0.3 Panfrost/panvk stack shows the
same failure in GL and Vulkan:

```text
$ ./tiny_interp_probe
mode=varying width=12288: floor(v) != x at 11744 of 12288 pixels (first at x=529)
last pixel x=12287: v=12275.5312 expected=12287.5 relative_error=9.741e-04 (0.997 * 2^-10)

$ ./tiny_interp_probe 12288 fragcoord
mode=fragcoord width=12288: floor(v) != x at 0 of 12288 pixels (first at x=-1)
last pixel x=12287: v=12287.5000 expected=12287.5 relative_error=0.000e+00 (0.000 * 2^-10)

$ ./tiny_interp_probe 8192
mode=varying width=8192: floor(v) != x at 0 of 8192 pixels (first at x=-1)
last pixel x=8191: v=8191.5000 expected=8191.5 relative_error=0.000e+00 (0.000 * 2^-10)

$ ./tiny_interp_probe 16307 varying
mode=varying width=16307: floor(v) != x at 15672 of 16307 pixels (first at x=623)
last pixel x=16306: v=16293.2832 expected=16306.5 relative_error=8.105e-04 (0.830 * 2^-10)
```

Vulkan/panvk reproduces the GL numbers bit-for-bit at the same widths:

```text
$ ./vk_interp_probe
mode=varying width=12288 device=Mali-G610 MC4: floor(v) != x at 11744 of 12288 pixels (first at x=529, unwritten=0)
last pixel x=12287: v=12275.5312 expected=12287.5 relative_error=9.741e-04 (0.997 * 2^-10)

$ ./vk_interp_probe 12288 fragcoord
mode=fragcoord width=12288 device=Mali-G610 MC4: floor(v) != x at 0 of 12288 pixels (first at x=-1, unwritten=0)
last pixel x=12287: v=12287.5000 expected=12287.5 relative_error=0.000e+00 (0.000 * 2^-10)

$ ./vk_interp_probe 12288 varying llvmpipe
mode=varying width=12288 device=llvmpipe (LLVM 21.1.8, 128 bits): floor(v) != x at 0 of 12288 pixels (first at x=-1, unwritten=0)
```

The controls matter:

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

The result is consistent with the interpolated-varying path losing precision
for large non-power-of-two extents. It is not evidence that u_blitter, texture
sampling, TXF, filtering, or readback conversion is wrong.
