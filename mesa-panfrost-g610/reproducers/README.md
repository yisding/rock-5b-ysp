# Reproducers

These are the standalone C programs used while debugging Panfrost texture
transfers on ROCK 5B / Mali-G610, plus the archived Mesa patch needed to
rebuild the failing BLIT configuration. They use GBM/EGL and GLES 3.x
directly, so run them on the board with a Mesa build that includes Panfrost.

| File | One-liner |
|---|---|
| [`0001-panfrost-advertise-transfer-blit-and-compute.patch`](0001-panfrost-advertise-transfer-blit-and-compute.patch) | `format-patch` archive of the BLIT-advertising commit (`e8cf2ae6daa`); apply to a Mesa tree to reproduce the BLIT failure and the BLIT column of the timing table — reproduction-only, not for merging; full provenance in its annotation block |
| [`repro_blit.c`](repro_blit.c) | End-to-end failure repro: RG32UI→RGBA32UI `glReadPixels` through the u_blitter TXF staging blit |
| [`repro_blit_off.c`](repro_blit_off.c) | Non-zero-offset variant: subregion readback at `x = X0`, exercising the blit affine's offset term in the fragcoord fix |
| [`repro_blit_float.c`](repro_blit_float.c) | RG32F→RGBA32F float variant — the counter-example that disqualifies the integer-only state-tracker fallback |
| [`repro_blit_flip.c`](repro_blit_flip.c) | Flipped `glBlitFramebuffer` probe (negative scale); caught the pixel-center-convention bug and revealed the power-of-two-extent exactness |
| [`probe_interp.c`](probe_interp.c) | Isolates varying interpolation from texture fetch (smooth / noperspective / gl_FragCoord modes) |
| [`probe_const.c`](probe_const.c) | Constant-varying exactness probe: shows all-vertices-equal smooth varyings interpolate bit-exactly at every magnitude |
| [`probe_wcorr.c`](probe_wcorr.c) | Shader-side recovery probe: disproves `gl_FragCoord.w` and `dFdx`-based correction |
| [`repro_afbc.c`](repro_afbc.c) | Negative-result probe: wide RGBA8 FBO readback via the AFBC CPU-map staging path shows NO pre-existing corruption on unfixed drivers |
| [`bench_transfer.c`](bench_transfer.c) | BLIT-vs-COMPUTE timing microbenchmark for the same readback shape |
| [`mr42563-comment-failures.txt`](mr42563-comment-failures.txt) | The exact 25 dEQP-GLES3 case names from the MR !42563 review comment, rerun locally after the COMPUTE switch |

All GL entrypoints are loaded via `eglGetProcAddress` specifically to bypass
glvnd and guarantee the locally built Mesa driver is exercised.

## Build

```bash
cc -O2 -o repro_blit repro_blit.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o repro_blit_off repro_blit_off.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o repro_blit_float repro_blit_float.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o repro_blit_flip repro_blit_flip.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o probe_interp probe_interp.c -lEGL -lGLESv2 -lgbm -lm
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
`probe_wcorr.c`, `probe_const.c`, and `repro_afbc.c` hardcode `renderD128`.)

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
  listings in [`../blit-precision.md`](../docs/blit-precision.md).

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
[`../blit-precision.md`](../docs/blit-precision.md) rests on the Panfrost lowering
(`pan_nir_lower_noperspective.c` routes it through the same perspective
machinery) and on the compiler-level `prefer_persp = false` experiment, not
on this probe.

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

Verified on the final series build: all four modes exact at 12000x8 and
16307x2.

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
(Mesa 26.0.3) and the fragcoord branch build. So there is no evidence of
pre-existing corruption in shipped drivers via this path (the FBO texture
likely never takes an AFBC layout here, or the map demotes it first), and the
fragcoord fix should be pitched as "unblocks `PIPE_TEXTURE_TRANSFER_BLIT`",
**not** as a stable-branch repair.

## `bench_transfer.c`

Microbenchmark for the same `RG32UI -> RGBA32UI` readback shape.

Comparative mode needs a build that takes the BLIT path by default — i.e. a
tree with
[`0001-panfrost-advertise-transfer-blit-and-compute.patch`](0001-panfrost-advertise-transfer-blit-and-compute.patch)
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

Recorded medians are in [`../validation.md`](../docs/validation.md).

## `mr42563-comment-failures.txt`

The exact 25 dEQP cases from the MR !42563 review comment that were rerun
locally after switching the MR direction to COMPUTE (result: 24/25 Pass, 1
pre-existing QualityWarning — [`../validation.md`](../docs/validation.md), which
also records the exact dEQP invocation).
