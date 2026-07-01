# Mesa/Panfrost Texture-Transfer Investigation

This note captures the Mesa-side work that grew out of the GRD readback
baseline: why `MESA_COMPUTE_PBO=1` helped, what went wrong when we tried to
enable the sampled BLIT path for Panfrost, and why the upstream Mesa direction is
now COMPUTE texture transfers instead.

Hardware used for the investigation:

- Radxa ROCK 5B / RK3588
- Mali-G610 MC4
- Panfrost/Panthor
- Mesa 26.2-devel local build
- dEQP GLES3, surfaceless pbuffer

## Why We Looked At Mesa

GRD's software RFX path spends most of a frame in a `glReadPixels` GPU-to-CPU
readback. The local benchmark in [`bench/readback_bench.c`](bench/readback_bench.c)
showed that `MESA_COMPUTE_PBO=1` moves the heavy detile/swizzle work onto the
GPU:

```text
default Mesa:
  sync glReadPixels BGRA : 19.92 ms
  async PBO t_issue      : 22.86 ms
  async PBO t_fence      :  0.00 ms

MESA_COMPUTE_PBO=1:
  sync glReadPixels BGRA : 11.01 ms
  async PBO t_issue      :  0.15 ms
  async PBO t_fence      :  5.13 ms
```

That environment variable is a Mesa debug override. The proper fix is for
Panfrost to advertise a texture-transfer mode in `pan_screen.c`:

```c
caps->texture_transfer_modes = PIPE_TEXTURE_TRANSFER_COMPUTE;
```

## What We Changed Upstream

The active Mesa MR is
[!42563](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42563).
It started as "enable BLIT", but the investigation changed the direction to
COMPUTE.

The series now has two patches:

1. Fix Panfrost shader-image unbind bookkeeping.
2. Enable compute-based texture transfers.

The first patch fixes a real crash exposed while testing GPU texture transfers:
`panfrost_set_shader_images(..., images = NULL)` released resources for
`count + unbind_num_trailing_slots` slots, but only cleared `count` bits from
`image_mask`. If Gallium requested only trailing unbinds, Panfrost could leave a
mask bit set while the resource pointer was already NULL, and descriptor
emission could later dereference that NULL image resource.

That patch carries:

```text
Fixes: 72ff66c3d73 ("gallium: add unbind_num_trailing_slots to set_shader_images")
```

The second patch is based on Joshua Watt's original transfer-mode enablement
from Mesa !38433, but uses COMPUTE instead of BLIT.

## Why BLIT Is Not Safe

The sampled BLIT path was not obviously miscompiled. The blit fragment shader
used the expected Mali varying load, then converted the interpolated coordinate
to integer texel coordinates:

```asm
LD_VAR_IMM.slot0.v4.f32.center.store.wait0 @r0:r1:r2:r3, r61^, table:0x1, index:0x0
F32_TO_S32.rtz.discard r2, r3^
F32_TO_S32.rtz r1, r1^
F32_TO_S32.rtz r0, r0^
TEX_FETCH.slot1.reserved.32.2d.texel_offset.wait0126 @r0:r1:r2:r3, @r0:r1:r2, [r4^:r5^]
```

So the instruction selection was sensible: load an interpolated `vec4` coordinate
as f32, truncate to integer, then do a texel fetch.

The bug is the precision of the interpolation result. On Mali-G610, the
perspective interpolation inside `LD_VAR_IMM` drifts by about `2^-10` relative
error. That is acceptable for normal normalized texture coordinates, but not for
an integer `TXF`/texel-address path that truncates coordinates.

Standalone readback reproducer:

```text
W=16307  BLIT mismatches=15672 / 16307
i=1024   sampled=1023
i=8192   sampled=8185
i=16306  sampled=16293
```

The shift is not constant; it grows with x. At the right edge of a 16307-wide
one-row transfer, the drift is about 13 texels.

A probe that isolated interpolation from texture fetch found the same pattern:

```text
smooth varying:
  floor(interp) != i : 15672 / 16307
  i=16306 interp=16293.28, ideal=16306.5

gl_FragCoord.x:
  floor(interp) != i : 0 / 16307
  i=16306 interp=16306.5, ideal=16306.5
```

That points at the varying interpolator, not `TEX_FETCH`.

## Why We Did Not Work Around BLIT

The obvious alternatives were checked:

- `noperspective` is not an exact-linear varying path on Mali. Panfrost lowers it
  through the same perspective-correct varying machinery.
- A derivative-based reconstruction was worse in the repro:
  `16187 / 16307` mismatches.
- `gl_FragCoord` is exact, but converting `u_blitter`'s general texture-coordinate
  path to a `gl_FragCoord` path would be a shared blitter rewrite with offset,
  y-flip, scale, and rectangle plumbing.
- CPU fallback is correct but gives up the GPU-side transfer win.

COMPUTE is the clean local fix: it uses integer invocation coordinates and avoids
varying interpolation entirely.

## Performance: BLIT vs COMPUTE

On the same ROCK 5B / Mali-G610 MC4, median timings with
`ST_DEBUG=noreadpixcache`:

```text
16307x1    BLIT 0.559-0.565 ms   COMPUTE 0.433-0.450 ms
16000x1    BLIT 0.707 ms         COMPUTE 0.633 ms
16384x1    BLIT 0.559 ms         COMPUTE 0.419 ms
1024x1024  BLIT 15.53 ms         COMPUTE 14.81 ms
4096x256   BLIT 15.68 ms         COMPUTE 14.81 ms
```

COMPUTE was not a measured regression in these local transfer tests. It was
slightly faster, and it fixes correctness.

## dEQP Validation

After switching the Panfrost cap to `PIPE_TEXTURE_TRANSFER_COMPUTE` and
rebuilding the local DRI target:

```text
Exact dEQP cases from the MR comment: 0 Fail/Crash, 24/25 Pass, 1/25 QualityWarning
precision.abs.*:                         24/24 Pass
pbo.*:                                   54/54 Pass
texture.specification.basic_teximage2d.*: 98/98 Pass
```

The one `QualityWarning` was:

```text
dEQP-GLES3.functional.shaders.builtin_functions.precision.acos.mediump_fragment.vec2
```

It reproduced in the earlier clean run too, so it does not appear to be caused by
the transfer-mode change.

## What This Means For GRD

For the GRD software path, `MESA_COMPUTE_PBO=1` was a useful proof that the
Panfrost compute transfer path can cut the readback cost substantially. If Mesa
!42563 lands, Panfrost should opt into that path directly for texture transfers,
making the debug environment variable unnecessary for this class of readback.

This still does not beat the hardware-encode path. Compute transfer makes the
software path less bad; the rkmpp/VEPU580 backend removes the GPU-to-CPU readback
from the hot path entirely.
