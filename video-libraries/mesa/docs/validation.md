# Validation And Performance

This is the accumulated evidence owner for the Panfrost transfer work. It
records immutable tested shapes, discriminating signals, and boundaries.
[W06](../../../status.md#watch-w06) owns live MR/CI state,
[`mr-review-findings.md`](mr-review-findings.md) owns code-review conclusions,
and [`blit-precision.md`](blit-precision.md) owns the causal model.

## Current MR And CI State (2026-07-06)

**Frozen CI snapshot, not current remote state.** The recorded four-part shape
was:

| MR | Recorded tip | Scope | Evidence at that tip |
|----|--------------|-------|----------------------|
| [!42563](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42563) | `833101f35ed` | Panfrost trailing-image-unbind fix | Selected x86/arm64 build and G610 GL/Piglit green |
| [!42679](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42679) | `6509025064f` | Shared default-off `u_blitter` fragcoord TXF path | Selected x86 build, clang, llvmpipe, and softpipe green |
| [!42613](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42613) | `8875a22856d` | Prerequisite, shared fix, Panfrost opt-in, allocation guard, BLIT enablement, expectation cleanup | Pipeline 1700162: four selected G610 shards green |
| [!42614](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42614) | `4c23f1db1f9` | Corrected stack plus Gallium setup and wide-blit test | Pipeline 1700163: four selected G610 shards green |

The hardware signal belongs to !42613/!42614 because !42679's shared flag
defaults off. This snapshot proves only those commits and selected jobs; a new
head needs a new run. Use [W06](../../../status.md#watch-w06) before any
upstream action.

### 2026-07-06 G610 Red-Job Classification

The first selected Panfrost runs were red for two stack-integration causes,
not for an unexplained fragcoord regression:

1. The pushed Panfrost branches had omitted the reviewed trailing-image-unbind
   fix. Stale `image_mask` bits could lead image emission to dereference a
   released resource during a blitter draw.
2. Allocation-only `st_TexImage(..., pixels = NULL)` still entered
   `st_TexSubImage` and attempted a maximum-size staging allocation after BLIT
   transfer enablement.

Restoring the prerequisite and skipping the no-data upload removed the crash
and allocation abort. The next rerun exposed only a stale expected-fail entry:
`glx-copy-sub-buffer` passed. After its G610 expectation was removed, the four
selected shards passed on both recorded tips.

The negative control matters: earlier board runs had used an experimental stack
that still contained the unbind fix, so their green result could not validate
the later accidentally incomplete branch.

## Patch Series Shape (COMPUTE Era, Superseded)

The frozen COMPUTE-era candidate paired the independent image-unbind fix with
`PIPE_TEXTURE_TRANSFER_COMPUTE` and a Panfrost
`is_compute_copy_faster` heuristic. It proved GPU readback could be exact and
fast, but was rejected as the general policy because shaders cannot write AFBC
destinations. The evidence remains valid; the patch shape does not.

## Correctness Repro

The archived BLIT-advertising configuration and
[`repro_blit.c`](../reproducers/repro_blit.c) produced:

```text
W=16307  BLIT mismatches=15672/16307
i=1024   sampled=1023
i=8192   sampled=8185
i=16306  sampled=16293
COMPUTE  mismatches=0/16307
```

The paired interpolation probe produced the same 15,672 wrong integer bins
through a smooth varying and zero through `gl_FragCoord.x`. GL and Vulkan raw
varying probes later reproduced the signature without `u_blitter`; ordinary
TEX-nearest also moved with the workaround. See the
[probe owner](../reproducers/interp_probe/README.md).

## BLIT vs COMPUTE Timing

On the recorded G610 build with `ST_DEBUG=noreadpixcache`, COMPUTE was exact
and slightly faster in the focused transfer measurements:

| Shape | BLIT | COMPUTE |
|-------|------|---------|
| 16307x1 | 0.559–0.565 ms | 0.433–0.450 ms |
| 16000x1 | 0.707 ms | 0.633 ms |
| 16384x1 | 0.559 ms | 0.419 ms |
| 1024x1024 | 15.53 ms | 14.81 ms |
| 4096x256 | 15.68 ms | 14.81 ms |

These results establish that COMPUTE was not the observed performance problem;
they do not overcome its AFBC write limitation or predict application-wide
speed.

## GRD Readback Timing

The GRD-owned 1080p `GL_BGRA` benchmark measured:

| Path | Synchronous | Async issue | Async fence |
|------|------------:|------------:|------------:|
| Default Mesa | 19.92 ms | 22.86 ms | 0.00 ms |
| `MESA_COMPUTE_PBO=1` | 11.01 ms | 0.15 ms | 5.13 ms |

The debug override proved GPU detile/swizzle helps the software fallback. It
does not remove GPU-to-CPU readback or supersede hardware encode.

## dEQP Reruns

The selected fragcoord series reached a zero-failure 1,097-case matrix:

| Set | Result |
|-----|--------|
| MR-comment list | 24/25 Pass, one known `acos` QualityWarning |
| Additional cases | 16/16 Pass |
| `precision.abs.*` | 24/24 Pass |
| `pbo.*` | 54/54 Pass |
| `basic_teximage2d.*` | 98/98 Pass |
| `fbo.blit.*` | 629 Pass, 12 NotSupported |
| `fbo.msaa.*` | 66 Pass, 4 NotSupported |
| 2D-array / 3D color cases | 36/36 Pass each |
| `basic_teximage3d.*` | 98/98 Pass |

The Gallium wide-blit test passed all seven shapes on the fixed path and failed
all seven on a negative-control build with exactly 40,884 wrong texels per
pass. That establishes test sensitivity, not just a green result.

A later rebuilt dEQP harness classified 26 PBO and 34 default-framebuffer blit
failures as harness artifacts: zero-pixel image differences were compared
against a negative threshold and the failure sets were bit-identical on the
patched build, unpatched build, and shipped Mesa. Keep harness identity with
every future matrix.

## dEQP Invocation

The recorded surfaceless invocation was:

```bash
deqp-gles3 \
  --deqp-surface-width=256 --deqp-surface-height=256 \
  --deqp-surface-type=pbuffer --deqp-visibility=hidden \
  --deqp-gl-config-name=rgba8888d24s8ms0 \
  --deqp-log-filename=<out.qpa> \
  --deqp-case=<case>
```

Use `--deqp-caselist-file=<cases.txt>` for batches and the environment from
[the reproducer README](../reproducers/README.md). Reconstruct disposable
VK-GL-CTS build state under the central external build workspace; do not rely
on an old `/tmp` binary.

## Build Checks

The focused static-library and DRI-target builds passed with central ccache:

```bash
CCACHE_DIR=/home/yi/Code/.ccache \
  ninja -C build-codex-main src/gallium/drivers/panfrost/libpanfrost.a
CCACHE_DIR=/home/yi/Code/.ccache \
  ninja -C build-codex-main src/gallium/targets/dril/libdril_dri.so
```

The unrelated `pan_resource.c` ignored-`asprintf` warning was not introduced by
this work. The [rebuild guide](rebuild-and-test.md) owns the complete board
environment and GLVND/Piglit traps.

## MR state — COMPUTE era, superseded

This compatibility heading preserves the rejected candidate's evidence
boundary. COMPUTE uses exact integer invocation coordinates and improved the
focused readback, but blanket COMPUTE transfer was rejected because it cannot
write AFBC. Do not use this section for live MR state; use
[W06](../../../status.md#watch-w06).

## Outcome (2026-07-01): fragcoord branch selected

On-device discriminators selected the fragcoord design:

- format-changing float readback disproved a pure-integer targeted fallback;
- offset, flip, scissor, array-layer, and 3D probes became exact;
- vertex-constant scale/offset remained bit-exact;
- the archived AFBC CPU-map staging control remained clean;
- generalizing the mechanism exposed and fixed an MSAA predicate bug; and
- the negative-control Gallium test failed every intended shape.

The canonical mechanics and hypotheses live in
[`blit-precision.md`](blit-precision.md). Exact probes and expected signals
live in [`reproducers/`](../reproducers/README.md).

## 2026-07-02 Revision: Self-Review Fixes And Revalidation

The self-review corrected three material issues:

1. coordinate repacking was moved beside shader selection so pack and override
   shaders could not consume the private attribute layout;
2. transfer advertisement and fragcoord opt-in were aligned to the same
   supported architecture class; and
3. zero-area copies were prevented from creating NaN scale state.

It also simplified the per-draw encoding, skipped dead texcoord work, and
aligned target predicates. Revalidation covered offsets, float/integer/array
readback, scissor, flips, AFBC control, Gallium negative control, MSAA, focused
dEQP, and the transfer benchmark. The
[maintained review](mr-review-findings.md) owns remaining code-level
should-fix items and their immutable source context.

## Depth-bias workaround validation

The later maintainer-provided workaround enables depth bias with all numeric
parameters zero. On the measured G610 it changes the relevant Valhall
descriptor state without moving depth and makes raw varyings exact in both
OpenGL and Vulkan; an ordinary nearest-texture probe follows the same result.
The exact internal reason is inferred, not public hardware knowledge.

Geometry sweeps disproved simple aspect thresholds of 1000 and 500: affected
and unaffected cases overlap. The durable policy candidate is therefore scoped
to the Panfrost internal fullscreen blitter on the affected Valhall generation,
with a size predicate only as a maintainer-requested compromise.

The forced all-blit A/B made both affected R32UI geometries exact and preserved
four ordinary controls. The final one-context, fixed-clock, balanced-order
benchmark measured:

| Signal | Result |
|--------|--------|
| Completion-side workaround cost | +0.50%; 95% interval +0.34%..+0.73% |
| End-to-end wall cost | +0.62%; 95% interval +0.44%..+1.01% |
| Off/off control | Interval includes zero |
| Samples / clock checks | 6,480 non-disjoint A/B samples; 242 checks at 500 MHz |
| Same-batch draw control | +0.451%; p10..p90 +0.081%..+0.666% |

These are workload-specific microbenchmark costs. The causal mechanism and
geometry boundary live in [`blit-precision.md`](blit-precision.md); the exact
benchmark procedure, controls, signals, and retained raw-output shape live in
[`../reproducers/README.md`](../reproducers/README.md#blit-workaround-bench).
The result does not establish every format, scaling, flipping, scissor, layer,
MSAA, or application frame-pacing path.
