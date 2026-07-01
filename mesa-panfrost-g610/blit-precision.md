# BLIT Precision Root Cause

This is the detailed chain from "Panfrost should enable texture transfers" to
"enable COMPUTE, not BLIT" for Mali-G610.

## Starting Point

The first attempted change was:

```c
caps->texture_transfer_modes = PIPE_TEXTURE_TRANSFER_BLIT;
```

That made Mesa's state tracker prefer GPU blits for some texture-transfer and
readback paths instead of CPU fallback. CI and MR review pointed at failures in
GLES3 dEQP shader precision cases, especially:

```text
dEQP-GLES3.functional.shaders.builtin_functions.precision.*
```

The surprising part was that these shader precision tests were exposing a
readback path, not a wrong GLSL builtin. Instrumenting `st_ReadPixels` showed the
key shape:

```text
st_ReadPixels: xy=0,0 wh=16307x1 glfmt=GL_RGBA_INTEGER type=GL_UNSIGNED_INT
               rb=r32g32_uint src=r32g32_uint dst=r32g32b32a32_uint
               pbo=0 path: blit dst_xy=0,0
```

The test rendered into an `R32G32_UINT` renderbuffer and read it as
`GL_RGBA_INTEGER` + `GL_UNSIGNED_INT`. Mesa staged this as
`R32G32B32A32_UINT`, then used a `u_blitter` sampled TXF fragment shader to
expand `RG32UI` to `RGBA32UI`.

The CPU fallback was correct. The sampled blit was wrong.

## Reproducer Symptom

The standalone reproducer in
[`reproducers/repro_blit.c`](reproducers/repro_blit.c) builds an `R32G32_UINT`
texture with:

```text
source[i] = { i, i }
```

It attaches that texture to an FBO and calls:

```c
glReadPixels(0, 0, W, 1, GL_RGBA_INTEGER, GL_UNSIGNED_INT, dst);
```

That reproduces the same staging-blit path. Any spatial shift shows up as
`dst[i].r != i`.

Observed on ROCK 5B / Mali-G610:

```text
W=16307  mismatches=15672 / 16307 (96.1%)  first_mismatch=623
i=1024   sampled=1023   shift=-1
i=8192   sampled=8185   shift=-7
i=16306  sampled=16293  shift=-13
```

The shift is not constant. It grows with position. The implied scale is around
`0.9992`, approximately `1 - 2^-10`, which points at a relative precision loss
rather than an off-by-half-pixel convention.

## The Generated Shader Was Sensible

The relevant Valhall instruction sequence for the blit fragment shader was:

```asm
LD_VAR_IMM.slot0.v4.f32.center.store.wait0 @r0:r1:r2:r3, r61^, table:0x1, index:0x0
F32_TO_S32.rtz.discard r2, r3^
IADD_IMM.i32 r3, 0x0, #0xFF
CSEL.u32.lt r2, r2^, r3^, r2^, r3^
MKVEC.v2i8 r2, 0x0.b0, r2^.b0, 0x0
MKVEC.v2i8 r2, 0x0.b0, 0x0.b0, r2^
F32_TO_S32.rtz r1, r1^
F32_TO_S32.rtz r0, r0^
IADD_IMM.i32 r3, 0x0, #0x20001800
MOV.i32 r4, r3^
MOV.i32 r5, 0x0
TEX_FETCH.slot1.reserved.32.2d.texel_offset.wait0126 @r0:r1:r2:r3, @r0:r1:r2, [r4^:r5^]
```

That is a plausible lowering of the high-level operation:

1. Load the interpolated coordinate as f32.
2. Truncate to signed integer.
3. Do an integer texel fetch.

The problem is not an obvious `TEX_FETCH` or instruction-selection bug. The
input coordinate arriving from `LD_VAR_IMM` is already imprecise enough that
truncation can select the previous texel.

## Interpolation Probe

[`reproducers/probe_interp.c`](reproducers/probe_interp.c) isolates interpolation
from texture fetch. It renders a `W x 1` quad with a varying that runs from
`0` to `W` across the quad, then writes the interpolated value bit-exactly using
`floatBitsToUint`.

Observed:

```text
mode=SMOOTH W=16307
floor(interp)!=i count = 15672 / 16307
  i=256    interp=256.3200    ideal=256.5    err=-0.1800
  i=16306  interp=16293.2803  ideal=16306.5  err=-13.2197

mode=FRAGCOORD.x W=16307
floor(interp)!=i count = 0 / 16307
  i=16306  interp=16306.5000  ideal=16306.5  err=+0.0000
```

That points at the varying interpolator. `gl_FragCoord.x` is exact because it is
generated from the rasterizer's pixel coordinate instead of loaded through the
varying unit.

## What The `2^-10` Means

For normal texture coordinates, a relative error around `2^-10` is often
tolerable. For an integer texel-address path it is not.

At x around 16000:

```text
16000 * 2^-10 ~= 15.6
```

The observed right-edge error was about 13 texels. After
`F32_TO_S32.rtz`, that turns directly into fetching an earlier texel. This is
why a small relative interpolation error becomes a large integer readback
failure.

## Why `noperspective` Did Not Fix It

Mali does not expose a precise screen-linear varying interpolation instruction.
Panfrost's lowering reflects that: Mali has instructions for flat and
perspective-correct varying fetches, and `noperspective` is lowered through the
same perspective machinery.

The useful options in the fragment shader are:

- `LD_VAR_IMM` / `LD_VAR_BUF` style interpolated varying fetches: per-pixel but
  subject to the same perspective interpolation precision.
- `LD_VAR_FLAT`: exact, but constant across the primitive.
- `gl_FragCoord`: exact screen-space pixel coordinate, but not a general varying.

So there is no compiler flag that makes the existing `u_blitter` varying exact.
The fix has to avoid the varying path or rewrite the blit to derive coordinates
from `gl_FragCoord` plus the source/destination affine.

## Hypotheses Ruled Out

These were checked and did not make BLIT correct:

| Hypothesis | Result |
|---|---|
| fp16 lowering / `PAN_MESA_DEBUG=nofp16` | No effect. NIR and asm showed f32 coordinate handling; the loss is in the fixed-function varying interpolation. |
| Explicit `fmul coord, frag_w` | Red herring. The default path has no explicit multiply; the perspective divide is internal to `LD_VAR_IMM`. |
| Pixel-center mismatch | Refuted. The error grows with coordinate magnitude; a center mismatch would be a constant half-pixel shift. |
| AFBC or modifier layout, `PAN_MESA_DEBUG=linear` | Still failed. |
| Missing fence, `PAN_MESA_DEBUG=sync` | Still failed. |
| Readpixels cache, `ST_DEBUG=noreadpixcache` | Still failed. |
| Diagonal split / single triangle | Still failed. |
| TXF path toggles | Still failed. |
| `gl_FragCoord.w` correction | No useful correction was present. |
| `dFdx` reconstruction | Worse: `16187 / 16307` mismatches. |

The `dFdx`/reconstruction probe lives in
[`reproducers/probe_wcorr.c`](reproducers/probe_wcorr.c). The name is historical:
the final variant records the interpolated coordinate and derivative to test
whether the fragment shader can recover an exact coordinate locally.

## Why Asahi/AGX Was Not Evidence That BLIT Is Safe

Asahi also advertises a BLIT transfer path, and it uses the same high-level
`u_blitter` idea, but AGX does not have the same precision problem.

The important difference is interpolation implementation:

- AGX evaluates varying plane equations in f32 ALU with explicit coefficient
  access.
- It can do the perspective divide with f32 precision, not around `2^-10`.
- It also interpolates tile-locally, so the variable part is a small tile offset
  rather than a full 16000-wide coordinate.

Mali has no equivalent shader-visible coefficient load and no exact screen-linear
varying mode. The full-magnitude coordinate goes through the fixed-function
interpolator, so the relative error becomes visible.

## Options Considered

There are only three exact coordinate sources for this problem:

- Compute invocation IDs.
- `gl_FragCoord` plus correctly plumbed source/destination affine.
- CPU fallback.

That led to the following options:

| Option | Description | Trade-off |
|---|---|---|
| COMPUTE-only | Advertise `PIPE_TEXTURE_TRANSFER_COMPUTE`, do not advertise BLIT. | Panfrost-local, exact, covers readback and texture transfer paths. Gives up sampled BLIT. |
| BLIT + COMPUTE route | Advertise both, but route risky integer format-changing transfers to compute. | Keeps more BLIT paths, but needs state-tracker special casing and must be added everywhere relevant. |
| CPU fallback for risky readbacks | Keep BLIT but force the known risky readback to CPU. | Small but slow, only covers one path. |
| Rewrite `u_blitter` TXF to use `gl_FragCoord` | Exact for BLIT if all offset/scale/y-flip plumbing is correct. | Shared-code change, subtle, more work, and mostly helps Mali-class hardware. |
| Panfrost NIR pass | Try to reconstruct exact coordinates in Panfrost. | Cannot recover the source/destination affine from the shader alone. Fragile. |
| AGX-style rebase | Emit exact primitive base plus small interpolated delta. | More plumbing than `gl_FragCoord`, requires splitting/reworking blits, no clear upside. |

The practical fix was COMPUTE-only. It is contained in Panfrost, avoids the
varying interpolator, and the local transfer microbenchmarks did not show a BLIT
performance advantage on G610.

## Mesa Fix Shape

The texture-transfer cap changed to:

```c
caps->texture_transfer_modes = PIPE_TEXTURE_TRANSFER_COMPUTE;
```

Panfrost also wires a compute-copy heuristic:

```c
static bool
panfrost_is_compute_copy_faster(struct pipe_screen *pscreen,
                                enum pipe_format src_format,
                                enum pipe_format dst_format,
                                unsigned width, unsigned height,
                                unsigned depth, bool cpu)
{
   if (cpu)
      return (uint64_t)width * height * depth > 64 * 64;
   return false;
}
```

The first patch in MR !42563 fixes shader-image unbind bookkeeping, which the
compute transfer path relies on. Without that fix, a trailing unbind could leave
a stale `image_mask` bit pointing at a NULL image resource.

The verified Fixes trailer for that first patch is:

```text
Fixes: 72ff66c3d73 ("gallium: add unbind_num_trailing_slots to set_shader_images")
```

## Bottom Line

For Mali-G610, sampled BLIT texture transfers are unsafe for integer
format-changing paths that derive texel addresses from interpolated varyings.
There is no local Panfrost compiler toggle that makes `LD_VAR_IMM` exact.

The reliable choices are to avoid the varying unit with COMPUTE, or to rewrite
the shared blitter coordinate path around `gl_FragCoord`. COMPUTE is the smaller
and measured-safe fix.
