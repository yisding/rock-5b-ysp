# Mesa/Panfrost Texture Transfers — GRD-Facing Summary

> **Canonical home:** [`../mesa-panfrost-g610/`](../../mesa-panfrost-g610/).
> This page keeps only what a GRD reader needs; every shared figure, asm
> listing, reproducer, and validation result is owned by that folder and is
> deliberately **not** duplicated here.

## Why GRD Cares

GRD's software RFX path spends most of a frame in a `glReadPixels` GPU-to-CPU
readback. The local benchmark
([`bench/readback_bench.c`](../bench/readback_bench.c)) showed that
`MESA_COMPUTE_PBO=1` — a Mesa debug override that moves the detile/swizzle
work onto the GPU — cuts the 1080p `GL_BGRA` sync readback from ~19.9 ms to
~11.0 ms (full numbers:
[`../mesa-panfrost-g610/docs/validation.md` § GRD Readback Timing](../../mesa-panfrost-g610/docs/validation.md)).

The proper fix is for Panfrost to advertise a GPU texture-transfer mode in
`pan_screen.c` so the debug variable becomes unnecessary. That is Mesa MR
[!42563](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42563).

## What The Investigation Found (One Paragraph)

Enabling the sampled **BLIT** transfer path (the original direction, based on
Joshua Watt's MR !38433) is not bit-exact on Mali-G610: the blit shader's
texel coordinate arrives through the fixed-function varying interpolator
(`LD_VAR_IMM`), which drifts by ~`2^-10` relative error, and integer
format-changing readbacks truncate that drift into wrong texels (96% wrong at
width 16307). **COMPUTE** transfers avoid the varying unit, fixed every
measured failure, and were slightly faster than BLIT — but on 2026-07-01
maintainer review rejected COMPUTE-only because compute shaders cannot write
AFBC-compressed resources; the fix shape is being reworked (gl_FragCoord-based
blit fix, or BLIT plus a targeted integer-case route). Root cause, evidence,
options grid, and dated MR lifecycle:
[`../mesa-panfrost-g610/docs/blit-precision.md`](../../mesa-panfrost-g610/docs/blit-precision.md)
and [`../mesa-panfrost-g610/README.md` § Status](../../mesa-panfrost-g610/README.md).

A real crash fixed along the way (Panfrost shader-image unbind bookkeeping,
`Fixes: 72ff66c3d73`) is documented in
[`../mesa-panfrost-g610/docs/validation.md`](../../mesa-panfrost-g610/docs/validation.md);
its first patch already carries an upstream `Reviewed-by`.

## What This Means For GRD

- Until a transfer mode ships in Mesa, `MESA_COMPUTE_PBO=1` remains a valid
  board-local mitigation for the software-path readback cost (it is exact —
  the precision bug is specific to the sampled BLIT path, which the compute
  override does not use).
- Whatever shape lands upstream, GRD needs no code change: the win arrives
  through `glReadPixels` picking a GPU transfer path inside Mesa.
- This does not change this repo's larger conclusion: **hardware encode is
  the real fix**, because it removes the GPU-to-CPU readback from the hot
  path entirely, rather than making it cheaper
  ([`README.md`](../README.md), [`profiling.md`](profiling.md)).
