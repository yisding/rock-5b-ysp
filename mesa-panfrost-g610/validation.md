# Validation And Performance

This records what was tested while moving Mesa MR !42563 from sampled BLIT
texture transfers to COMPUTE texture transfers on Panfrost/Mali-G610.

## Patch Series Shape

The Mesa MR has two patches:

1. `panfrost: clear shader image mask on trailing unbinds`
2. `panfrost: enable compute-based texture transfers`

The first patch fixes a crash exposed by compute texture-transfer testing.
Gallium can call:

```c
set_shader_images(..., images = NULL, count = 0,
                  unbind_num_trailing_slots = N)
```

Panfrost released resources for `count + unbind_num_trailing_slots`, but only
cleared `count` bits in `image_mask`. That could leave a mask bit set while the
corresponding image resource pointer was already NULL. Later image descriptor
emission could dereference that NULL resource.

The verified Fixes trailer is:

```text
Fixes: 72ff66c3d73 ("gallium: add unbind_num_trailing_slots to set_shader_images")
```

The second patch advertises:

```c
caps->texture_transfer_modes = PIPE_TEXTURE_TRANSFER_COMPUTE;
```

It also wires:

```c
screen->base.is_compute_copy_faster = panfrost_is_compute_copy_faster;
```

That hook matters. `st_pbo_compute.c` consults
`screen->is_compute_copy_faster(...)` on the normal non-`MESA_COMPUTE_PBO=1`
path before using the compute readback. The Panfrost implementation mirrors the
simple zink/radeonsi heuristic:

```c
if (cpu)
   return (uint64_t)width * height * depth > 64 * 64;
return false;
```

So large CPU-readback transfers use compute; small ones can stay on the CPU.

## Correctness Repro

The BLIT failure is reproduced by
[`reproducers/repro_blit.c`](reproducers/repro_blit.c):

```text
W=16307  mismatches=15672 / 16307
i=1024   sampled=1023
i=8192   sampled=8185
i=16306  sampled=16293
```

With COMPUTE transfer enabled, the same reproducer becomes exact:

```text
mismatches = 0 / 16307
```

The interpolation probe in
[`reproducers/probe_interp.c`](reproducers/probe_interp.c) explains why:

```text
smooth varying:
  floor(interp) != i : 15672 / 16307
  i=16306 interp=16293.28, ideal=16306.5

gl_FragCoord.x:
  floor(interp) != i : 0 / 16307
  i=16306 interp=16306.5, ideal=16306.5
```

That isolates the failure to Mali's varying interpolation path.

## BLIT vs COMPUTE Timing

Measured on ROCK 5B / Mali-G610 MC4 with `ST_DEBUG=noreadpixcache`:

```text
16307x1    BLIT 0.559-0.565 ms   COMPUTE 0.433-0.450 ms
16000x1    BLIT 0.707 ms         COMPUTE 0.633 ms
16384x1    BLIT 0.559 ms         COMPUTE 0.419 ms
1024x1024  BLIT 15.53 ms         COMPUTE 14.81 ms
4096x256   BLIT 15.68 ms         COMPUTE 14.81 ms
```

In these local transfer tests, COMPUTE was not a performance regression. It was
slightly faster and fixed the correctness issue.

## GRD Readback Timing

The original GRD motivation was the software RFX path spending most of a frame
inside a GPU-to-CPU readback:

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

That debug environment variable forced the compute path and proved the GPU-side
detile/swizzle path was useful. The MR makes Panfrost advertise the compute path
directly for texture transfers instead of depending on the debug override.

## dEQP Reruns

After switching to `PIPE_TEXTURE_TRANSFER_COMPUTE` and rebuilding the local DRI
target on ROCK 5B / Mali-G610:

```text
Exact cases from the MR comment:          0 Fail/Crash, 24/25 Pass, 1/25 QualityWarning
precision.abs.*:                          24/24 Pass
pbo.*:                                    54/54 Pass
texture.specification.basic_teximage2d.*: 98/98 Pass
```

The one `QualityWarning` was:

```text
dEQP-GLES3.functional.shaders.builtin_functions.precision.acos.mediump_fragment.vec2
```

It reproduced in an earlier clean run too, so it was not introduced by the
transfer-mode change.

The exact MR-comment case list is kept in:

```text
reproducers/mr42563-comment-failures.txt
```

## Build Checks

After restoring `panfrost_is_compute_copy_faster` and rebasing the MR branch,
the following local build checks passed in `build-codex-main`:

```bash
CCACHE_DIR=/home/yi/Code/mesa/.codex-ccache \
  ninja -C build-codex-main src/gallium/drivers/panfrost/libpanfrost.a

CCACHE_DIR=/home/yi/Code/mesa/.codex-ccache \
  ninja -C build-codex-main src/gallium/targets/dril/libdril_dri.so
```

The Panfrost static-library build still emits an unrelated existing warning in
`pan_resource.c` about ignoring `asprintf`'s return value.

## Current MR State

MR !42563 is titled:

```text
panfrost: enable compute-based texture transfers
```

The branch direction is intentionally COMPUTE, not BLIT:

- BLIT is unsafe for Mali-G610 integer format-changing transfers because the
  coordinate arrives through lossy `LD_VAR_IMM` interpolation.
- COMPUTE uses exact integer invocation coordinates.
- The local BLIT-vs-COMPUTE timings did not show a transfer-performance loss.
- The `is_compute_copy_faster` hook is required for the normal state-tracker
  compute path and is part of the patch.
