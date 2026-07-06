# Mesa/Panfrost Texture Transfers — GRD-Facing Summary

> **Canonical home:** [`video-libraries/mesa`](../../../video-libraries/mesa).
> This page keeps only what a GRD reader needs; every shared figure, asm
> listing, reproducer, and validation result is owned by that folder and is
> deliberately **not** duplicated here.

## Why GRD Cares

GRD's software RFX path spends most of a frame in a `glReadPixels` GPU-to-CPU
readback. The local benchmark
([`apps/gnome-remote-desktop/bench/readback_bench.c`](../bench/readback_bench.c)) showed that
`MESA_COMPUTE_PBO=1` — a Mesa debug override that moves the detile/swizzle
work onto the GPU — cuts the 1080p `GL_BGRA` sync readback from ~19.9 ms to
~11.0 ms (full numbers:
[`video-libraries/mesa/docs/validation.md` § GRD Readback Timing](../../../video-libraries/mesa/docs/validation.md)).

The proper fix is for Panfrost to advertise a GPU texture-transfer mode in
`pan_screen.c` so the debug variable becomes unnecessary. The current upstream
shape is a Mesa stack: [!42563](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42563)
is the independent shader-image unbind fix; [!42679](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42679)
fixes shared `u_blitter` TXF coordinates with `gl_FragCoord`; [!42613](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42613)
opts Panfrost in and enables BLIT transfers; [!42614](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42614)
adds the wide-blit Gallium test.

## What The Investigation Found (One Paragraph)

Enabling the sampled **BLIT** transfer path (the original direction, based on
Joshua Watt's MR !38433) is not bit-exact on Mali-G610: the blit shader's
texel coordinate arrives through the fixed-function varying interpolator
(`LD_VAR_IMM`), which drifts by ~`2^-10` relative error, and integer
format-changing readbacks truncate that drift into wrong texels (96% wrong at
width 16307). **COMPUTE** transfers avoid the varying unit, fixed every
measured failure, and were slightly faster than BLIT, but on 2026-07-01
maintainer review rejected COMPUTE-only because compute shaders cannot write
AFBC-compressed resources. The selected upstream direction keeps BLIT and makes
the TXF coordinate exact by deriving it from `gl_FragCoord` plus the blit
affine in `u_blitter`, with Panfrost opting in only on Bifrost+ (`arch >= 6`).
Root cause, evidence, options grid, and dated MR lifecycle:
[`video-libraries/mesa/docs/blit-precision.md`](../../../video-libraries/mesa/docs/blit-precision.md)
and [`video-libraries/mesa/README.md` § Status](../../../video-libraries/mesa/README.md).

A real crash fixed along the way (Panfrost shader-image unbind bookkeeping,
`Fixes: 72ff66c3d73`) is documented in
[`video-libraries/mesa/docs/validation.md`](../../../video-libraries/mesa/docs/validation.md);
its first patch already carries an upstream `Reviewed-by`.

## What This Means For GRD

- Until a transfer mode ships in Mesa, `MESA_COMPUTE_PBO=1` remains a valid
  board-local mitigation for the software-path readback cost (it is exact —
  the precision bug is specific to the sampled BLIT path, which the compute
  override does not use).
- GRD needs no code change for the Mesa stack: the win arrives through
  `glReadPixels` picking a GPU transfer path inside Mesa once Panfrost advertises
  it.
- This does not change this repo's larger conclusion: **hardware encode is
  the real fix**, because it removes the GPU-to-CPU readback from the hot
  path entirely, rather than making it cheaper
  ([`README.md`](../README.md), [`profiling.md`](profiling.md)).
