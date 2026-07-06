# Reproducers

These are the standalone C programs used while debugging Panfrost texture
transfers on ROCK 5B / Mali-G610, plus the archived Mesa patch needed to
rebuild the failing BLIT configuration. They use GBM/EGL and GLES 3.x
directly (one, `vk_interp_probe.c`, uses Vulkan/panvk instead), so run them
on the board with a Mesa build that includes Panfrost.

| File | One-liner |
|---|---|
| [`0001-panfrost-advertise-transfer-blit-and-compute.patch`](../patches/0001-panfrost-advertise-transfer-blit-and-compute.patch) | `format-patch` archive of the BLIT-advertising commit (`e8cf2ae6daa`); apply to a Mesa tree to reproduce the BLIT failure and the BLIT column of the timing table — reproduction-only, not for merging; full provenance in its annotation block |
| [`u_blitter-review2-txf-fragcoord-cleanups.patch`](../patches/u_blitter-review2-txf-fragcoord-cleanups.patch) | Second `/code-review` round (2026-07-03) of `panfrost-blit-transfers`: two behavior-preserving `u_blitter` cleanups — a shared `blitter_target_supports_txf()` predicate (#2) and threading the chosen `use_txf_fragcoord` out of the four texfetch helpers via an out-param instead of recomputing it in `util_blitter_blit_generic` (#3). Revalidated 0-regression on device (reproducers + dEQP + piglit); see `../docs/rebuild-and-test.md` |
| [`repro_blit.c`](repro_blit.c) | End-to-end failure repro: RG32UI→RGBA32UI `glReadPixels` through the u_blitter TXF staging blit |
| [`repro_blit_off.c`](repro_blit_off.c) | Non-zero-offset variant: subregion readback at `x = X0`, exercising the blit affine's offset term in the fragcoord fix |
| [`repro_blit_float.c`](repro_blit_float.c) | RG32F→RGBA32F float variant — the counter-example that disqualifies the integer-only state-tracker fallback |
| [`repro_blit_flip.c`](repro_blit_flip.c) | Flipped `glBlitFramebuffer` probe (negative scale); caught the pixel-center-convention bug, revealed the power-of-two-extent exactness, and proved shipped drivers corrupt wide non-pow2 blits |
| [`repro_blit_scissor.c`](repro_blit_scissor.c) | Scissored wide identity blit: verifies clipping doesn't shift the fragcoord mapping and untouched texels keep their sentinel |
| [`repro_blit_array.c`](repro_blit_array.c) | 2D-array-layer readback: found the array regression (15672/16307), now exact via the series' single-layer view commit |
| [`probe_interp.c`](probe_interp.c) | Isolates varying interpolation from texture fetch (smooth / noperspective / gl_FragCoord modes) |
| [`tiny_interp_probe.c`](tiny_interp_probe.c) | Smallest varying-only probe: no u_blitter, no texture, no TXF, no window system; measures the width-dependent non-power-of-two varying drift directly (~2^-10 at the blit-bug widths) and shows powers of two are exact |
| [`vk_interp_probe.c`](vk_interp_probe.c) (+ [`vk_interp_probe.vert`](vk_interp_probe.vert), [`vk_interp_probe.varying.frag`](vk_interp_probe.varying.frag), [`vk_interp_probe.fragcoord.frag`](vk_interp_probe.fragcoord.frag)) | Vulkan port of the tiny probe on panvk — no Gallium, no u_blitter, no GL state tracker in the stack — reproducing the varying drift bit-for-bit; the same binary passes on llvmpipe |
| [`probe_const.c`](probe_const.c) | Constant-varying exactness probe: shows all-vertices-equal smooth varyings interpolate bit-exactly at every magnitude |
| [`probe_wcorr.c`](probe_wcorr.c) | Shader-side recovery probe: disproves `gl_FragCoord.w` and `dFdx`-based correction |
| [`repro_afbc.c`](repro_afbc.c) | Scoped negative result: the AFBC CPU-map staging path is clean on unfixed drivers (direct wide blits are NOT — see `repro_blit_flip.c`) |
| [`bench_transfer.c`](bench_transfer.c) | BLIT-vs-COMPUTE timing microbenchmark for the same readback shape |
| [`mr42563-comment-failures.txt`](mr42563-comment-failures.txt) | The exact 25 dEQP-GLES3 case names from the MR !42563 review comment, rerun locally after the COMPUTE switch |

The older probes load all GL entrypoints via `eglGetProcAddress` specifically
to bypass glvnd and guarantee the locally built Mesa driver is exercised.
`tiny_interp_probe.c` instead links `libGLESv2` directly (glvnd dispatches via
the current EGL context); its stderr `GL_RENDERER`/`GL_VERSION` lines confirm
which driver actually ran.

## Build

```bash
cc -O2 -o repro_blit repro_blit.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o repro_blit_off repro_blit_off.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o repro_blit_float repro_blit_float.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o repro_blit_flip repro_blit_flip.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o repro_blit_scissor repro_blit_scissor.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o repro_blit_array repro_blit_array.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o probe_interp probe_interp.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o tiny_interp_probe tiny_interp_probe.c -lEGL -lGLESv2 -lm
glslc vk_interp_probe.vert           -o vk_interp_probe.vert.spv
glslc vk_interp_probe.varying.frag   -o vk_interp_probe.varying.frag.spv
glslc vk_interp_probe.fragcoord.frag -o vk_interp_probe.fragcoord.frag.spv
cc -O2 -o vk_interp_probe vk_interp_probe.c -lvulkan -lm
cc -O2 -o probe_const probe_const.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o probe_wcorr probe_wcorr.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o repro_afbc repro_afbc.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o bench_transfer bench_transfer.c -lEGL -lGLESv2 -lgbm -lm
```

If testing a local Mesa build, point the loader at the built DRI target, for
example:

```bash
export LD_LIBRARY_PATH=/path/to/mesa/build/src/egl:/path/to/mesa/build/src/gbm:/path/to/mesa/build/src/gallium/targets/dril
export LIBGL_DRIVERS_PATH=/path/to/mesa/build/src/gallium/targets/dril
export GBM_BACKENDS_PATH=/path/to/mesa/build/src/gbm/backends/dri
export EGL_PLATFORM=surfaceless
```

`GBM_BACKENDS_PATH` is required as well as `LD_LIBRARY_PATH`: the build's
`libgbm` otherwise searches only its configured prefix for `dri_gbm.so`
(`MESA-LOADER: failed to open dri: ... (search paths /usr/local/lib/...gbm)`)
and `gbm_create_device()` fails — observed on the board 2026-07-01 when the
previously used `/usr/local` Mesa prefix had been removed.

The programs default to `/dev/dri/renderD128`. `repro_blit.c` and
`bench_transfer.c` also honor:

```bash
REPRO_NODE=/dev/dri/renderD128
```

(`repro_blit_off.c` and `repro_blit_float.c` honor it too; `probe_interp.c`,
`probe_wcorr.c`, `probe_const.c`, and `repro_afbc.c` hardcode `renderD128`.
`tiny_interp_probe.c` uses the surfaceless EGL platform and opens no DRM node
itself. `vk_interp_probe.c` picks its physical device through the Vulkan
loader by device-name substring.)

## `0001-panfrost-advertise-transfer-blit-and-compute.patch`

The BLIT-vs-COMPUTE comparison needs a Mesa build whose default transfer path
is the sampled BLIT — a configuration no upstream tree will ship once the MR
lands in any form. This patch is the pristine `git format-patch` export of
local commit `e8cf2ae6daa` ("panfrost: enable blit-based texture transfers",
branch `panfrost-transfer-blit` of `github.com/yisding/mesa`).

- It advertises `PIPE_TEXTURE_TRANSFER_BLIT` **only**; no local commit ever
  advertised `BLIT|COMPUTE`. The COMPUTE side of every comparison was forced
  on the same build with `MESA_COMPUTE_PBO=1`.
- Apply it on top of the shader-image mask fix ("panfrost: clear shader image
  mask on trailing unbinds", `Fixes: 72ff66c3d73`) — local `950d19686d8`, on
  Mesa main `c05334058d5` (2026-06-22). `git apply --check` also passes
  against later 26.2-devel trees that still carry
  `caps->texture_transfer_modes = 0;` (verified 2026-07-01).
- The annotation block between the commit message and the diff (ignored by
  `git am`) records the full provenance and the
  `BIFROST_MESA_DEBUG=shaders` disassembly-capture method behind the asm
  listings in [`../docs/blit-precision.md`](../docs/blit-precision.md).

## `repro_blit.c`

Minimal reproducer for the format-changing integer readback path.

It creates an `RG32UI` texture where `source[i] = {i, i}`, attaches it to an FBO,
then reads it back as `RGBA_INTEGER`/`UNSIGNED_INT`. With the sampled BLIT
transfer path, Mesa stages this through a `u_blitter` TXF shader.

Run:

```bash
./repro_blit 16307
```

Observed BLIT failure on Mali-G610:

```text
W=16307  mismatches=15672 / 16307
i=1024   sampled=1023
i=8192   sampled=8185
i=16306  sampled=16293
```

Expected with COMPUTE or CPU fallback:

```text
mismatches=0/16307
```

## `repro_blit_off.c`

Non-zero-offset variant of `repro_blit` (added 2026-07-01). Same `RG32UI`
texture, but reads back the subregion `glReadPixels(X0, 0, W - X0, 1, ...)`,
so the staging blit runs with `src_x1 = X0`, `dst_x1 = 0` — i.e. a large
`offset` term in the fragcoord fix's `src = gl_FragCoord * scale + offset`
affine, which the original repro (offset 0) never exercised.

Run:

```bash
./repro_blit_off 16307 8000     # W X0
```

Observed on the `panfrost-transfer-fragcoord-blit` branch
(`git-2f6e8a6afc`, 2026-07-01): **0 mismatches at X0 = 1, 623, 8000, 16000**.

## `repro_blit_float.c`

Float variant of `repro_blit` (added 2026-07-01) — **the counter-example that
disqualified the integer-only state-tracker fallback** (local branch
`panfrost-transfer-targeted-fallback`, `6a292503585`).

The interpolation drift affects every wide sampled TXF blit regardless of
format; pure-integer transfers were merely the only case dEQP could detect
bit-exactly. This repro builds an `RG32F` texture with `source[i] = {i, i}`
and reads it back as `GL_RGBA` + `GL_FLOAT` (valid for float color buffers
under `EXT_color_buffer_float`). That is a format-changing
(`RG32F -> RGBA32F` staging) but **non-pure-integer** readback, so the
fallback branch's `util_format_is_pure_integer` gate does not catch it.

Run:

```bash
./repro_blit_float 16307
```

Observed on Mali-G610 (2026-07-01):

```text
targeted-fallback build git-6a29250358:  mismatches=15672/16307 (96.1%)
                                         first_mismatch=623   <- original bug signature
fragcoord build git-2f6e8a6afc:          mismatches=0/16307
```

The integer control (`repro_blit`) passes on both builds, so the fallback's
gate works as written — it is simply under-inclusive. Widening it to "any
format change" would effectively disable the transfer blit, which is why the
fallback direction was dropped rather than patched.

## `probe_interp.c`

Interpolation precision probe.

It renders a `W x 1` quad with a varying that runs from `0` to `W` across the
quad and writes the interpolated f32 bit pattern to an integer render target
(`R32UI` read back as `GL_RED_INTEGER` — same-format, so the readback itself
never takes the staging blit and the probe stays valid even on a broken-BLIT
build).

Modes:

```text
0 = smooth/perspective varying
1 = noperspective varying
2 = gl_FragCoord.x
```

Run:

```bash
./probe_interp 16307 0
./probe_interp 16307 2
```

Observed result (re-verified on the ROCK 5B 2026-07-01, Mesa 26.2-devel local
build, kernel 6.18.37-current-rockchip64 #7):

```text
mode=SMOOTH      floor(interp) != i : 15672 / 16307   max_rel_err=5.751e-02
  i=16306 interp=16293.2832 ideal=16306.5 err=-13.2168
mode=FRAGCOORD.x floor(interp) != i : 0 / 16307       max_rel_err=0
```

This isolates the problem to the varying path. `gl_FragCoord.x` is exact.

**Mode 1 (`noperspective`) cannot produce a count**: `noperspective` is a
reserved word in GLSL ES, and the probe compiles its shaders as
`#version 310 es`, so mode 1 fails at shader compile time
(`illegal use of reserved word 'noperspective'` — observed 2026-07-01). The
"noperspective is not exact on Mali" claim in
[`../docs/blit-precision.md`](../docs/blit-precision.md) rests on the Panfrost lowering
(`pan_nir_lower_noperspective.c` routes it through the same perspective
machinery) and on the compiler-level `prefer_persp = false` experiment, not
on this probe.

## `tiny_interp_probe.c`

Smallest varying-only repro (added 2026-07-06). It exists to answer the
upstream review argument "the hardware docs say the varying interpolator is
full 32-bit, so the ~2^-10 error must be u_blitter misusing varyings (e.g.
nearest-sample tie-breakers)". The probe removes everything except varying
interpolation itself: no `u_blitter`, no source texture, no `texelFetch`, no
filtering, no format-changing readback, no window system, no GBM (surfaceless
EGL). One `gl_VertexID`-generated triangle covers a `W x 1` `R32UI` render
target; the vertex shader computes a varying that must interpolate to exactly
`x + 0.5` at the center of pixel `x`; the fragment shader stores the raw
float bits (`floatBitsToUint`); the CPU reads the same bits back with a
format-matching `glReadPixels(GL_RED_INTEGER)` and checks `floor(v) == x`.
Mode `fragcoord` writes `gl_FragCoord.x` through the otherwise identical
pipeline as the control. The default width `12288` (`3 * 4096`) was chosen
because the drift there is almost exactly `2^-10`.

Non-graphics model: this is a ruler test. The GPU is given the numbers at the
two ends of the ruler and must fill in the number at every pixel center. Pixel
`x` should see `x + 0.5`. If the filled-in number is slightly too low, a real
blit shader that truncates it to an integer fetches the previous texel.

Build and run (exit 0 = every pixel exact, 2 = any `floor(v) != x` failure,
1 = usage or EGL/GL setup error):

```bash
cc -O2 -o tiny_interp_probe tiny_interp_probe.c -lEGL -lGLESv2 -lm
./tiny_interp_probe                  # 12288 x 1, varying — fails on G610
./tiny_interp_probe 12288 fragcoord  # control — passes
./tiny_interp_probe 8192             # pow2 control — passes
./tiny_interp_probe 16307 varying    # width from the original bug reports
```

Verbatim output on ROCK 5B / Mali-G610, system Mesa (every run first prints
`GL_RENDERER=Mali-G610 MC4 (Panfrost)` and `GL_VERSION=OpenGL ES 3.1 Mesa
26.0.3-1ubuntu1` to stderr):

```text
$ ./tiny_interp_probe                  # exit 2
mode=varying width=12288: floor(v) != x at 11744 of 12288 pixels (first at x=529)
last pixel x=12287: v=12275.5312 expected=12287.5 relative_error=9.741e-04 (0.997 * 2^-10)

$ ./tiny_interp_probe 12288 fragcoord  # exit 0
mode=fragcoord width=12288: floor(v) != x at 0 of 12288 pixels (first at x=-1)
last pixel x=12287: v=12287.5000 expected=12287.5 relative_error=0.000e+00 (0.000 * 2^-10)

$ ./tiny_interp_probe 8192             # exit 0; 16384 likewise
mode=varying width=8192: floor(v) != x at 0 of 8192 pixels (first at x=-1)
last pixel x=8191: v=8191.5000 expected=8191.5 relative_error=0.000e+00 (0.000 * 2^-10)

$ ./tiny_interp_probe 16307 varying    # exit 2
mode=varying width=16307: floor(v) != x at 15672 of 16307 pixels (first at x=623)
last pixel x=16306: v=16293.2832 expected=16306.5 relative_error=8.105e-04 (0.830 * 2^-10)

$ ./tiny_interp_probe 2080             # exit 2 — smallest failing width
mode=varying width=2080: floor(v) != x at 32 of 2080 pixels (first at x=2048)
last pixel x=2079: v=2078.9922 expected=2079.5 relative_error=2.442e-04 (0.250 * 2^-10)
```

Width dependence, measured 2026-07-06 on this board:

- Every power-of-two width tested (512, 1024, 2048, 4096, 8192, 16384) is
  **bit-exact**.
- Non-power-of-two widths show a jagged, width-dependent relative error from
  ~`1.25e-5` (`W=640`) to ~`1.24e-3` (`W=16300`) that quantizes to
  power-of-two-ish values per width: exactly `2^-12` at `W=2080`, exactly
  `2^-14` at `W=16383`, ~`2^-10` at `W=12288` and `W=16307`. So "~2^-10" is
  the signature of specific widths — including the ones the blit bug was
  found at — not a universal constant.
- The smallest width where `floor()` fails is `2080` (pixels `x=2048..2079`).
  Failing widths are sparse and non-monotone up to ~4300 (`W=5000` fails,
  `W=6000` passes), dense above.

Three cross-checks close the remaining escape hatches:

- The `fragcoord` control is bit-exact through the identical pipeline, so
  rasterization and readback are fine; only the varying value is off.
- An `R32F` render target + `glReadPixels(GL_RED, GL_FLOAT)` variant returns
  bit-identical values to the `R32UI` path (verified via hex-float compare),
  ruling out readback conversion as the source of the drift. `R32UI` stays
  canonical because integer readback is spec-guaranteed conversion-free.
- An earlier revision drew the same varying plane as a two-triangle quad;
  results were bit-identical to the single triangle, ruling out the diagonal
  split (and u_blitter's `use_index_buffer`/`use_single_triangle` toggles) as
  causes.

Two 2026-07-06 follow-ups extend the same result:

- **The drift reproduces bit-for-bit through Vulkan/panvk** — a stack with no
  Gallium, no u_blitter, and no GL state tracker anywhere — see
  [`vk_interp_probe.c`](#vk_interp_probec) below. A source-level and gdb audit
  additionally proves the GL probe's own frame contains no u_blitter or
  internal-blit work — see
  [`../docs/blit-precision.md` § The Probe Frame Contains No u_blitter Work](../docs/blit-precision.md).
- **The drift persists, bit-identically, on the fixed upstream MR stack** —
  as expected, since the fix reroutes u_blitter's TXF coordinates around
  varyings; it does not (and cannot) repair varying interpolation itself.
  Verbatim GL-probe run on a debug build of the corrected !42614 stack
  (2026-07-06), exit 2:

  ```text
  GL_RENDERER=Mali-G610 MC4 (Panfrost)
  GL_VERSION=OpenGL ES 3.1 Mesa 26.2.0-devel (git-60eb35d6ee)
  mode=varying width=12288: floor(v) != x at 11744 of 12288 pixels (first at x=529)
  last pixel x=12287: v=12275.5312 expected=12287.5 relative_error=9.741e-04 (0.997 * 2^-10)
  ```

  The `fragcoord` and `8192` controls on the same build report 0 bad pixels
  and exit 0.

Since the probe has no texture sample at all and compares directly against
pixel centers (`x + 0.5`), nearest-sample tie-breakers and texel-centering
cannot explain the failure. The `W=16307` numbers reproduce the original bug
signature exactly (`15672/16307` wrong, first at `x=623`, relative error
`8.105e-04`), so the earlier `repro_blit`/`probe_interp` history stays
comparable; the last-pixel relative error replaces the older least-squares
fit as the headline statistic.

The power-of-two exactness is consistent with the interpolator ALU being full
precision while the plane/coefficient setup for non-power-of-two
render-target widths loses precision. Whether that setup error lives in the
hardware or in the varying descriptors the drivers program is open — see
[`../docs/blit-precision.md`](../docs/blit-precision.md).

## `vk_interp_probe.c`

Vulkan port of `tiny_interp_probe` (added 2026-07-06), run on **panvk**,
Mesa's Vulkan driver for Mali. The point: the panvk stack contains **no
Gallium, no u_blitter, and no GL state tracker anywhere**, and it reproduces
the varying drift **bit-for-bit identically** to the GL probe. That makes the
"u_blitter misuses varyings" hypothesis untenable — u_blitter does not exist
in this stack — and turns the result into two independent driver stacks
programming the same hardware interpolation and reading back the same wrong
bits.

Same shape as the GL probe: one triangle covers a `W x 1` `R32_UINT` render
target via dynamic rendering; the vertex shader
([`vk_interp_probe.vert`](vk_interp_probe.vert)) emits a varying that must
interpolate to `x + 0.5` at the center of pixel `x`; the fragment shader
([`vk_interp_probe.varying.frag`](vk_interp_probe.varying.frag)) stores
`floatBitsToUint(v)`; readback is `vkCmdCopyImageToBuffer` into host-visible
memory (raw bits, no format conversion); the CPU checks `floor(v) == x`.
Mode `fragcoord` ([`vk_interp_probe.fragcoord.frag`](vk_interp_probe.fragcoord.frag))
writes `gl_FragCoord.x` through the identical pipeline as the control. The
physical device is chosen by substring of
`VkPhysicalDeviceProperties::deviceName` (default `Mali`); passing `llvmpipe`
runs the identical binary on a software implementation as a
checker-soundness control. The readback buffer is prefilled with a sentinel;
the `unwritten` count in the output is a rasterization-coverage self-check
(0 in every run below).

Build and run (exit 0 = every pixel satisfies `floor(v) == x`, 2 =
mismatches, 1 = setup error):

```bash
glslc vk_interp_probe.vert           -o vk_interp_probe.vert.spv
glslc vk_interp_probe.varying.frag   -o vk_interp_probe.varying.frag.spv
glslc vk_interp_probe.fragcoord.frag -o vk_interp_probe.fragcoord.frag.spv
cc -O2 -o vk_interp_probe vk_interp_probe.c -lvulkan -lm
./vk_interp_probe [width] [varying|fragcoord] [device-substring]   # defaults: 12288 varying Mali
```

Every run prints `device=... apiVersion=... driverVersion=...` to stderr; on
this board panvk (Mesa 26.0.3-1ubuntu1) reports `apiVersion=1.4.335` — panvk
claims Vulkan 1.4 conformance on this device, so this is not an experimental
half-driver being exercised off its supported path.

Verbatim output (recorded 2026-07-06):

```text
$ ./vk_interp_probe                          # exit 2
mode=varying width=12288 device=Mali-G610 MC4: floor(v) != x at 11744 of 12288 pixels (first at x=529, unwritten=0)
last pixel x=12287: v=12275.5312 expected=12287.5 relative_error=9.741e-04 (0.997 * 2^-10)

$ ./vk_interp_probe 12288 fragcoord          # exit 0
mode=fragcoord width=12288 device=Mali-G610 MC4: floor(v) != x at 0 of 12288 pixels (first at x=-1, unwritten=0)
last pixel x=12287: v=12287.5000 expected=12287.5 relative_error=0.000e+00 (0.000 * 2^-10)

$ ./vk_interp_probe 16307 varying            # exit 2
mode=varying width=16307 device=Mali-G610 MC4: floor(v) != x at 15672 of 16307 pixels (first at x=623, unwritten=0)
last pixel x=16306: v=16293.2832 expected=16306.5 relative_error=8.105e-04 (0.830 * 2^-10)

$ ./vk_interp_probe 12288 varying llvmpipe   # exit 0
mode=varying width=12288 device=llvmpipe (LLVM 21.1.8, 128 bits): floor(v) != x at 0 of 12288 pixels (first at x=-1, unwritten=0)
```

`./vk_interp_probe 8192` (power-of-two control) likewise exits 0 with 0 of
8192 pixels bad.

The numbers to hold against the GL probe's output above: **11744 of 12288
bad, first at x=529, last-pixel v=12275.5312** — identical, bit for bit,
through a driver stack that shares no GL/Gallium code with the GL probe. At
`W=16307` both stacks also reproduce the original blit-bug signature
(15672/16307, first at x=623, `0.830 * 2^-10`). The llvmpipe run passes with
the same binary, so the checker is sound; the fragcoord control passes on
Mali, so rasterization and readback are sound. panvk's compiled fragment
shader is instruction-for-instruction identical to the GL one — see
[`../docs/blit-precision.md` § Low-Level Tiny-Probe Shader](../docs/blit-precision.md).

## `repro_blit_flip.c`

Flipped-blit probe (added 2026-07-01). `glBlitFramebuffer` with flipped
coordinates is an unscaled nearest blit, so u_blitter takes the TXF path
with **scale = -1** on the flipped axis — the one affine case the other
repros never exercise. Renders `{x, y}` into `RG32UI` via `gl_FragCoord`,
blits identity / Y-flip / X-flip / XY-flip, verifies every texel.

Run:

```bash
./repro_blit_flip 16307 8     # W H
```

Two findings came out of this probe (both 2026-07-01, Mali-G610):

1. **Pixel-center-convention bug in the first fragcoord branch.** Panfrost's
   TGSI position system value yields the *integer pixel index*, not
   `x + 0.5`. With a positive scale the missing half texel is hidden by the
   truncating `f2i`; with a negative scale every fetch lands one texel off
   and row/column 0 goes out of bounds (all flip modes returned
   identity-looking/garbage data). Fixed by making the shader
   convention-independent: `src = floor(pos) * scale + (offset + 0.5*scale)`.
2. **The drift only occurs for non-power-of-two primitive extents.**
   Unfixed-path 1-row identity blits: `W=8192` and `W=16384` are bit-exact,
   while `W=5000/7000/8191/8193/12000/16307` all drift (`W=16307`:
   15672/16307 wrong, first at x=623; `W=3000` and below exact — onset
   between 3000 and 5000). The interpolator's plane-equation reciprocal is
   exact for powers of two. Height does not matter (H=2..8 identical). This
   is why common (pow2 or small) blit sizes never showed the bug, and why
   any regression test must use a large non-pow2 width.

Shipped-driver result (Mesa 26.0.3, no series patches): 16307x2 RG32UI
returns **29498/32614 wrong texels** (first at x=1539, fetched 1538) in all
four orientations — the corruption is reachable through plain
`glBlitFramebuffer` today, independent of `texture_transfer_modes`. Verified
on the final series build: all four modes exact at 12000x8 and 16307x2.

## `repro_blit_scissor.c`

Scissored wide-blit probe (added 2026-07-01). `glScissor` applies to
`glBlitFramebuffer`; u_blitter forwards it as scissor state while the
fragcoord path derives source texels purely from fragment position, so
clipping must not shift the mapping. Identity blit of 16307x8 RG32UI with
scissor `(5435,2 8153x4)`, destination pre-filled with a sentinel.

Observed on the series build (2026-07-01): inside scissor **0/32612**
mismatches; outside scissor **0/97844** sentinel overwrites.

## `repro_blit_array.c`

Array-target gating probe (added 2026-07-01). The fragcoord fix is gated to
1D/2D/RECT; array targets stay on the interpolated-varying TXF path. This
reads back a wide `RG32UI` **2D-array layer** (`glFramebufferTextureLayer`)
through the format-changing staging blit.

Observed at W=16307 (2026-07-01):

```text
series build (BLIT transfers on):  15672/16307 corrupt, first at 623
system driver (transfer modes 0):      0/16307 (CPU path, exact)
```

This was a **correctness regression vs. the CPU path** that no dEQP/piglit
case covers. **RESOLVED the same day**, finally by generalizing the
fragcoord mechanism to all single-sample TXF targets (1D/2D/RECT, arrays
single- and multi-layer, 3D) with a sign-bits/layer/offsets attribute
encoding — an interim single-layer-view commit was superseded. After the
fix this probe reports **0/16307**, and the u_tests case grew to seven
checks across 2D/flip/array/3D. Extending the mechanism also exposed a
second bug in the earlier branch revision: the draw-side gate did not
exclude **MSAA** sources (`fbo.msaa.*` 62/70 Fail -> 0 Fail after gating
on `nr_samples <= 1`). The *pre-existing* `glBlitFramebuffer` corruption
from wide array-layer attachments is fixed by the same mechanism.

## `probe_const.c`

Constant-varying exactness probe (added 2026-07-01). The fragcoord u_blitter
fix passes the blit affine (`scale.xy`, `offset.zw`) through the ordinary
smooth-interpolated vertex attribute — the same varying unit that is ~2^-10
lossy for values that vary. This probe answers whether a varying that is
**constant across the primitive** (all vertices equal) survives that path
bit-exactly, even at large magnitudes.

It renders a `W x 1` quad with a smooth `float` varying set to `K` at all
vertices and writes `floatBitsToUint(v_k)` to an `R32UI` target.

Run:

```bash
./probe_const 16307 16000.25    # W K
```

Observed on Mali-G610 (`git-2f6e8a6afc`, 2026-07-01):

```text
K = 1.0, 100.5, 1000.25, 10000.25, 16000.25, 16306.5
bit_mismatches = 0 / 16307 at every K
```

So only varyings that actually *vary* accumulate the ~2^-10 relative error;
per-draw constants are safe through the smooth path at any magnitude. This
removed the one numerical design risk in the fragcoord branch (a large
`offset` from a subregion blit) without needing flat interpolation, and it
means extending the fix to array layers (layer = another per-draw constant)
is numerically safe too.

## `probe_wcorr.c`

Shader-side recovery probe.

This checks whether the fragment shader can recover an exact coordinate using
local information such as derivatives. It could not; the derivative-based
candidate was worse than using the raw varying:

```text
raw floor(tc)!=i        : 15672 / 16307
dFdx reconstruction     : 16187 / 16307
```

The file name is historical. Earlier variants checked whether
`gl_FragCoord.w` carried a useful correction term — it does not:
`gl_FragCoord.w` is exactly `1.0` in this draw, so dividing by it changes
nothing (identical 15672/16307).

## `repro_afbc.c`

Negative-result probe (added 2026-07-01): does the interpolation drift
already corrupt **shipped** drivers through the pre-existing AFBC CPU-map
staging path (`pan_blit_to_staging` in `pan_resource.c`, used because
Panfrost has no software AFBC codec)?

It renders an x-index pattern into a wide `RGBA8` texture with `gl_FragCoord`
(exact), then reads it back with `glReadPixels` in the **matching** format so
the state tracker takes the CPU fallback, which maps the resource — for an
AFBC layout that goes through the u_blitter staging blit.

Run (also try `PAN_MESA_DEBUG=forcepack`):

```bash
./repro_afbc 4096 16     # W H
```

Observed 2026-07-01: **0 mismatches** on both the unfixed system driver
(Mesa 26.0.3) and the fragcoord branch build. So *this particular path* is
clean in shipped drivers (the FBO texture likely never takes an AFBC layout
here, or the map demotes it first). NOTE: this negative result initially led
to a too-broad "shipped drivers are unaffected" conclusion — later
`repro_blit_flip.c` testing showed direct wide non-pow2 `glBlitFramebuffer`
**is** corrupt on shipped Mesa 26.0.3 (see that probe's section).

## `bench_transfer.c`

Microbenchmark for the same `RG32UI -> RGBA32UI` readback shape.

Comparative mode needs a build that takes the BLIT path by default — i.e. a
tree with
[`0001-panfrost-advertise-transfer-blit-and-compute.patch`](../patches/0001-panfrost-advertise-transfer-blit-and-compute.patch)
applied. The default path then selects BLIT while `MESA_COMPUTE_PBO=1` forces
COMPUTE:

```bash
ST_DEBUG=noreadpixcache ./bench_transfer 16307 1 80 10
ST_DEBUG=noreadpixcache MESA_COMPUTE_PBO=1 ./bench_transfer 16307 1 80 10
```

Useful dimensions from the local timing pass:

```bash
./bench_transfer 16307 1
./bench_transfer 16000 1
./bench_transfer 16384 1
./bench_transfer 1024 1024
./bench_transfer 4096 256
```

Recorded medians are in [`../docs/validation.md`](../docs/validation.md).

## `mr42563-comment-failures.txt`

The exact 25 dEQP cases from the MR !42563 review comment that were rerun
locally after switching the MR direction to COMPUTE (result: 24/25 Pass, 1
pre-existing QualityWarning — [`../docs/validation.md`](../docs/validation.md), which
also records the exact dEQP invocation).

## Rebuild + re-run harness

[`../scripts/`](../scripts) has a one-command rebuild
(`build-mesa-surfaceless.sh`), the runtime env (`mesa-panfrost-env.sh`), and
runners for the reproducers (`run-repro.sh`) and the dEQP cluster
(`run-deqp.sh` + `deqp-gles3-transfer-cases.txt`). The environment gotchas
(wiped `/tmp` build state, `mise` python shadowing) and the latest on-device
results are in [`../docs/rebuild-and-test.md`](../docs/rebuild-and-test.md).
