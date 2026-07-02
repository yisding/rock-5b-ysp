# Validation And Performance

This records what was tested while moving Mesa MR !42563 from sampled BLIT
texture transfers to COMPUTE texture transfers on Panfrost/Mali-G610.
For the MR's current direction (COMPUTE-only was rejected in review on
2026-07-01), see [`README.md` § Status](../README.md) and
[`blit-precision.md`](blit-precision.md).

## Patch Series Shape

As of the 2026-07-01 rebase (branch `panfrost-transfer-blit-update`,
commits `37ce0f3111d` + `9d7f561cd9d`), the Mesa MR has two patches:

1. `panfrost: clear shader image mask on trailing unbinds`
   (carries `Reviewed-by: Iago Toral Quiroga <itoral@igalia.com>`)
2. `panfrost: enable compute-based texture transfers`
   (benchmark table below is reproduced in its commit message)

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
[`reproducers/repro_blit.c`](../reproducers/repro_blit.c) on a build carrying the
archived BLIT-advertising patch
([`reproducers/0001-panfrost-advertise-transfer-blit-and-compute.patch`](../reproducers/0001-panfrost-advertise-transfer-blit-and-compute.patch)):

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
[`reproducers/probe_interp.c`](../reproducers/probe_interp.c) explains why:

```text
smooth varying:
  floor(interp) != i : 15672 / 16307
  i=16306 interp=16293.28, ideal=16306.5

gl_FragCoord.x:
  floor(interp) != i : 0 / 16307
  i=16306 interp=16306.5, ideal=16306.5
```

That isolates the failure to Mali's varying interpolation path. Both probe
counts were re-verified on the board on 2026-07-01
([`reproducers/README.md`](../reproducers/README.md)).

## BLIT vs COMPUTE Timing

Measured on ROCK 5B / Mali-G610 MC4 with `ST_DEBUG=noreadpixcache`, on a
build with the archived BLIT patch applied (default path = BLIT;
`MESA_COMPUTE_PBO=1` forces COMPUTE — there was never a BLIT|COMPUTE cap
build; see the patch's annotation block):

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
inside a GPU-to-CPU readback. Numbers from the GRD benchmark
[`../gnome-remote-desktop/bench/readback_bench.c`](../../gnome-remote-desktop/bench/)
(1080p `GL_BGRA`):

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
detile/swizzle path was useful. The MR makes Panfrost advertise a GPU transfer
path directly instead of depending on the debug override.

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

It reproduced in an earlier clean run too (baseline worktree
`/home/yi/Code/mesa-origin-main`, detached at `0983c72a7ed`), so it was not
introduced by the transfer-mode change.

The exact MR-comment case list is kept in:

```text
reproducers/mr42563-comment-failures.txt
```

## dEQP Invocation

Recorded from the `#sessionInfo commandLineParameters` lines of the surviving
`.qpa` logs (dev box, `/home/yi/Code/mesa/.codex-tmp/*.qpa`):

- Binary: `deqp-gles3` from a local VK-GL-CTS "Surfaceless" target build,
  dEQP Core release `1c51d6e4b98`; the build lived at
  `/tmp/deqp-gles-ci/modules/gles3/deqp-gles3` on the dev box (disposable
  location — rebuild from VK-GL-CTS with the surfaceless target to repeat).
- Flags:

  ```bash
  deqp-gles3 --deqp-surface-width=256 --deqp-surface-height=256 \
    --deqp-surface-type=pbuffer --deqp-visibility=hidden \
    --deqp-gl-config-name=rgba8888d24s8ms0 \
    --deqp-log-filename=<out.qpa> \
    --deqp-case=<single.case.name>          # or:
    --deqp-caselist-file=<cases.txt>        # batch runs
  ```

- Driver selection: the same `LD_LIBRARY_PATH`/`LIBGL_DRIVERS_PATH`/
  `GBM_BACKENDS_PATH`/`EGL_PLATFORM=surfaceless` environment as the
  reproducers ([`reproducers/README.md`](../reproducers/README.md)).

## Build Checks

After restoring `panfrost_is_compute_copy_faster` and rebasing the MR branch,
the following local build checks passed in `build-codex-main` (a meson build
dir of the working tree `/home/yi/Code/mesa`; the LLVM-22 native-file shim it
was configured with is documented in
[`texture-query-levels.md` § Build Notes](texture-query-levels.md)):

```bash
CCACHE_DIR=/home/yi/Code/mesa/.codex-ccache \
  ninja -C build-codex-main src/gallium/drivers/panfrost/libpanfrost.a

CCACHE_DIR=/home/yi/Code/mesa/.codex-ccache \
  ninja -C build-codex-main src/gallium/targets/dril/libdril_dri.so
```

The Panfrost static-library build still emits an unrelated existing warning in
`pan_resource.c` about ignoring `asprintf`'s return value.

## Current MR State

(Last verified 2026-07-01 against the local Mesa tree; the GitLab page itself
was unreachable from the board — see [`README.md` § Status](../README.md) for
the dated lifecycle table.)

MR !42563 is titled:

```text
panfrost: enable compute-based texture transfers
```

The tested branch direction was COMPUTE, not BLIT:

- BLIT is unsafe for Mali-G610 integer format-changing transfers because the
  coordinate arrives through lossy `LD_VAR_IMM` interpolation.
- COMPUTE uses exact integer invocation coordinates.
- The local BLIT-vs-COMPUTE timings did not show a transfer-performance loss.
- The `is_compute_copy_faster` hook is required for the normal state-tracker
  compute path and is part of the patch.

**However**, COMPUTE-only was rejected by maintainer review on 2026-07-01
("Compute isn't the right solution. We can't write AFBC that way") — compute
shaders cannot write AFBC-compressed destinations, so a blanket COMPUTE
preference would break or force-decompress AFBC resources. The correctness
and timing results above remain valid evidence; the fix shape is being
reworked. Candidate follow-ups (local branches, 2026-07-01):

- `panfrost-transfer-fragcoord-blit` (rebased to `2f6e8a6afcc`) — make the
  sampled blit exact by deriving the TXF coordinate from `gl_FragCoord` plus
  the blit affine
  (see [`blit-precision.md` § Options Considered](blit-precision.md)).
- `panfrost-transfer-targeted-fallback` (rebased to `6a292503585`) — keep
  `PIPE_TEXTURE_TRANSFER_BLIT` but route pure-integer format-changing
  transfers to the non-blit path in `st_cb_readpixels.c` and
  `st_cb_texture.c` (`src_format != dst_format` and both pure-integer).

## Outcome (2026-07-01): fragcoord branch selected

On-device verification decided between the two candidates — canonical
write-up in
[`blit-precision.md` § On-Device Verification](blit-precision.md), probes in
[`../reproducers/`](../reproducers/README.md). Summary:

```text
repro_blit_float (RG32F -> RGBA32F via GL_RGBA+GL_FLOAT, W=16307)
  targeted-fallback git-6a29250358:  15672/16307 corrupt (96.1%), first at 623
  fragcoord         git-2f6e8a6afc:      0/16307
repro_blit (RG32UI integer control)   both branches exact
repro_blit_off (offsets 1..16000)     fragcoord exact
probe_const (constant varying, K=1.0..16306.5)
                                      bit-exact at every K
repro_afbc (AFBC CPU-map staging path, unfixed Mesa 26.0.3)
                                      clean — no pre-existing corruption
```

The float case corrupts through the targeted fallback's pure-integer gate —
the drift is format-agnostic, so the fallback is under-inclusive and was
dropped. Branch smoke numbers (both branches, `git diff --check` clean,
driver identity verified via `GL_VERSION` git hash):

```text
panfrost-transfer-fragcoord-blit
  repro_blit 16307:                  0 / 16307 mismatches
  bench_transfer 16307x1 median:     0.1794 ms, 0 mismatches
  bench_transfer 4096x1024 median:  49.9171 ms, 0 mismatches

panfrost-transfer-targeted-fallback
  repro_blit 16307:                  0 / 16307 mismatches
  bench_transfer 16307x1 median:     0.1668 ms, 0 mismatches
  bench_transfer 4096x1024 median:  47.6324 ms, 0 mismatches
```

The reworked 6-patch series was assembled locally on 2026-07-01
(`panfrost-transfer-blit-update`, final tip `2e50c2622aa`, 7 commits after the array-view fix; earlier validated tips `993410a8f25`/`7fedfca1204`, not pushed — see
[`README.md` § Status](../README.md)). Its validation: full probe battery
green including flips at non-pow2 widths (`repro_blit_flip` 12000x8 and
16307x2, all four orientations exact), `GALLIUM_TESTS`
`test_unscaled_blit_precision` pass (and fail on a negative-control build
without the panfrost opt-in — 40884 wrong texels), perf A/B-equal vs the
previous fragcoord build (16307x1 ~0.179 ms, 4096x1024 ~71 ms medians).

dEQP rerun on the series build (2026-07-01, surviving local
`deqp-gles3` at `/tmp/deqp-gles-ci`, same invocation as above) — zero
failures across 858 tests:

```text
MR-comment case list:                     24/25 Pass, 1 QualityWarning
  (the warning is the known pre-existing acos.mediump_fragment.vec2,
   reproduced on clean builds before this work)
cases2.txt (MR 38433/42563 failures):     16/16 Pass
precision.abs.*:                          24/24 Pass
pbo.*:                                    54/54 Pass
texture.specification.basic_teximage2d.*: 98/98 Pass
fbo.blit.*:                               629/641 Pass, 12 NotSupported
```

Scissored wide blits verified exact (`repro_blit_scissor.c`: 0 mismatches
inside the scissor, 0 sentinel overwrites outside).

Array-layer readbacks initially regressed (`repro_blit_array.c`:
15672/16307 corrupt vs exact CPU path on unpatched drivers; no dEQP/piglit
coverage). Resolved first via a single-layer 1D/2D view, then superseded
the same day by **generalizing the fragcoord mechanism to all
single-sample TXF targets** (1D/2D/RECT, 1D/2D arrays single- and
multi-layer, 3D): the coordinate attribute now carries scale sign bits
(scale is exactly +-1 for TXF), the layer/slice, and the biased offsets —
all per-draw constants, which interpolate bit-exactly.

While generalizing, a **second bug in the earlier branch revision** was
found: the draw-side gate did not exclude MSAA sources, so every MSAA
resolve fed sign/offset data to resolve shaders that expect texcoords —
`dEQP-GLES3.functional.fbo.msaa.*` was **62/70 Fail**; fixed by gating on
`nr_samples <= 1` (now 0 Fail, 66 Pass + 4 NotSupported).

Final series tip: `628e599172c` (6 commits — the interim array-view commit
was dropped as superseded). Final dEQP matrix, **zero failures across 1097
tests**: MR-comment 24/25 + known `acos` QualityWarning; cases2 16/16;
precision.abs 24/24; pbo 54/54; basic_teximage2d 98/98; fbo.blit 629/641 +
12 NotSupported; fbo.msaa 66/70 + 4 NotSupported; fbo.color.tex2darray
36/36; fbo.color.tex3d 36/36; basic_teximage3d 98/98. The u_tests case
grew to seven checks (unflipped, flipped, single array layer, 2x
multi-layer, 2x 3D slice); the negative control (series minus the panfrost
opt-in) fails ALL seven with the drift signature (40884 wrong texels
each), proving per-pass sensitivity. Probe battery and perf unchanged
(16307x1 ~0.183 ms, 4096x1024 ~74 ms).

Still needed: piglit getteximage/PBO/readpixels subsets (no local piglit
build on the board).

## 2026-07-02 Revision: Self-Review Fixes And Revalidation

A structured multi-angle review of the !42613 diff produced ten verified
findings; all were fixed, folded into the original commits, and
force-pushed (!42613 `51cb29834d1` -> `486b6f7002f`, !42614
`628e599172c` -> `e9125bd526f`).

Correctness fixes:

1. **ZS<->color pack shaders / fs_override clobber.** The draw-side
   fragcoord repacking fired whenever (target, samples, txf) matched,
   but `blitter_get_fs_pack_color_zs` shaders and caller `fs_override`
   shaders read the attribute as raw texel coordinates. The encoding
   decision moved into `util_blitter_blit_generic`, next to fragment
   shader selection, and is threaded through `do_blits` to the draw;
   pack and override paths keep the plain layout. This also replaced
   the hardcoded `nr_samples=1` at the shader-getter call sites with
   the real sample count, so shader-side and draw-side predicates can
   no longer diverge.
2. **Midgard gating.** `texture_transfer_modes` was enabled for every
   arch while the fragcoord fix only engaged on Bifrost+
   (`fs_position_is_sysval`), leaving Midgard's transfers on the lossy
   interpolated path. Both sites now gate on `arch >= 6`; Midgard's
   position input goes through the same varying unit, so the fragcoord
   path is not known to be exact there and stays off.
3. **Zero-area blits.** `glCopyImageSubData` permits `width == 0`, and
   `util_blitter_blit_with_txf`'s bounds test passes such boxes, so the
   scale computation hit `0/0 = NaN` and the new
   `assert(fabsf(scale_x) == 1.0f)` aborted debug builds. Degenerate
   axes substitute scale 1 (no fragments are rasterized).

Cleanups: POSITION declared as sysval **or FS input** per
`pipe_caps.fs_position_is_sysval` inside `ureg_load_tex` (dropping the
implicit sysval-only contract and the fragcoord parameter threading;
`u_blitter.h` flag documented); attribute encoding simplified from
sign-bits + F2I/AND/AND/I2F/MAD/MAD to `x = scale_x`,
`y = scale_y * (layer + 0.25)` — decode is one SSG plus an abs source
modifier, and the 0.25 bias truncates away for both integer array
layers and half-integer 3D slice centers; `get_texcoords()` skipped
(not overwritten) in the fragcoord path; the six-target allow-list
collapsed to the same CUBE/CUBE_ARRAY exclusion
`util_blitter_blit_with_txf` uses.

Reviewed and rejected as non-issues: constant-varying exactness (the
error term scales with vertex deltas, zero for constants; verified
empirically on 2026-07-01), cube transfers (panfrost's
`sampler_view_target` makes u_blitter sample cubes as 2D-array views,
which take the exact path), and the zero-fill of unused coordinate
channels (required: TXF reads `.w` as LOD and `coord.zw` carry large
offsets).

Revalidation (build `git-e9125bd526`, Rock 5B / Mali-G610):

```text
repro_blit 16307:                        0/16307
repro_blit_off X0=8000:                  0 mismatches
repro_blit_float 16307:                  0/16307
repro_blit_array 16307:                  0/16307
repro_blit_scissor:                      0/32612 inside, 0 sentinel hits
repro_blit_flip 16307x8:                 0/130456 in all 4 orientations
probe_const K=16000.25:                  0/16307 bit errors
repro_afbc:                              0/65536
GALLIUM_TESTS:                           test_unscaled_blit_precision pass (7/7 checks)
bench_transfer 16307x1 (noreadpixcache): 0.578 ms median, 0 mismatches
dEQP fbo.msaa.*:                         66 Pass / 4 NotSupported / 0 Fail
dEQP precision.abs.*:                    24/24
dEQP MR-comment list:                    22 Pass + known acos QualityWarning
```

**dEQP harness caveat:** the local dEQP at `/tmp/deqp-gles-ci` was
rebuilt since 2026-07-01 and now fails 26 `pbo.*` and all 34 runnable
`fbo.blit.default_framebuffer.*` cases with a **zero-pixel image
difference judged against a negative threshold** (-9.3e-10). The same
cases fail bit-identically on the unpatched series build and on shipped
Mesa 26.0.3 (failure sets diffed: identical), so these are test-harness
artifacts, not driver regressions. The 2026-07-01 "zero failures across
1097 tests" matrix was produced by the previous dEQP build.
