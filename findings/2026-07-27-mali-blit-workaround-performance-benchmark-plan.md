# Plan for measuring per-blit cost of the Mali workaround

> Scope: Mesa MR !43161 on Panfrost / Mali-G610; follow-up to the fixed-clock
> [`offset_perf_probe.c`](../video-libraries/mesa/reproducers/interp_probe/offset_perf_probe.c)
> measurements.
> Source: YSP commit `aa3f020`; Mesa `4c23f1db1f9c` source inspection of
> `panfrost_bind_rasterizer_state()` and `panfrost_emit_depth_stencil()`;
> fixed-500-MHz ROCK 5B measurements recorded in
> [`2026-07-24-mali-blit-workaround-size-results.md`](2026-07-24-mali-blit-workaround-size-results.md).
> Date: 2026-07-27
> Trust: DESIGN, SOURCE-INSPECTED

## Result

The existing `~0.5%` result is a steady-state GPU-path measurement, not an
end-to-end per-blit result. `offset_perf_probe.c` selects baseline or
zero-valued polygon offset once, starts a GPU timer, and issues hundreds or
thousands of identical draws with that state. The workaround bit affects every
draw, but GL/Mesa state binding happens once per timed batch, CPU state work is
outside the GPU timer, and the source, destination, framebuffer, shader, and
caches stay unchanged.

A draw-count check at `1024x1024` found `+0.49%` with 256 draws per state setup
and `+0.59%` with 2,048. The lack of eightfold dilution supports a recurring
GPU-path cost. Runs with one through 64 draws could not resolve a per-blit
increment because roughly `0.7 ms` of job/query/finish overhead dominated each
sample. The next benchmark must therefore estimate fixed and per-operation
costs separately instead of timing one draw with one timer query.

Do not make repeated `glEnable(GL_POLYGON_OFFSET_FILL)` calls in the current
direct-draw probe the primary answer. Application polygon-offset state is saved
and replaced by Mesa's internal blitter, so that would measure state-tracker
behavior around a proxy draw rather than MR !43161's actual Panfrost blit path.
The decisive A/B must run the real Mesa entry point with the driver workaround
forced off and on.

## Question to answer

For each real internal fullscreen blit, what incremental cost comes from
setting Valhall's depth-bias-enable descriptor bit with factor, units, and clamp
all zero?

Report four quantities rather than one headline percentage:

1. fixed cost per submitted batch/job;
2. recurring GPU cost per blit;
3. CPU submission/state cost per blit; and
4. end-to-end completion cost per blit.

Keep the direct `gl_FragCoord` shader as a separate experiment. It changes the
shader, varying traffic, and shape-dependent scheduling and does not answer the
cost of MR !43161's descriptor workaround.

## Experimental Mesa A/B

Use one instrumented Mesa commit containing the proposed MR !43161 behavior and
a test-only three-way override at the narrowest point that selects the
Panfrost internal fullscreen-blit rasterizer/depth-stencil state:

- `auto`: proposed production predicate;
- `off`: never apply the erratum workaround; and
- `on`: apply it to every affected hardware/path blit.

Prefer a process-start debug option so `off` and `on` use byte-identical
binaries. If adding a runtime option would distort the reviewed patch, use two
build directories from the same source commit and record the one-line
difference. Do not compare unrelated Mesa commits or compiler builds.

The override must change only:

```text
depth_bias_enable = false  -> true
depth_units       = 0
depth_factor      = 0
depth_bias_clamp  = 0
```

It must not change shader selection, rectangle geometry, formats, scissor,
batching, or transfer-path selection. Capture shader hashes or compiler dumps
once to prove the baseline and workaround draws use the same shaders.

Add validation-only counters, disabled for timing runs, for:

- API operations requested;
- internal blitter draws reached;
- workaround decisions applied;
- depth/stencil descriptors emitted;
- GPU batches/jobs submitted; and
- fallback or alternate transfer paths selected.

The counter gate is one intended workaround decision per measured internal
blit. A trace capture of representative `off` and `on` cases must also show the
expected descriptor-bit difference and zero numeric bias values.

## Workload

Build a small standalone surfaceless EGL/GLES program, separate from the
direct-draw `offset_perf_probe`, that exercises actual Mesa blits:

1. **Primary GPU blit:** `glBlitFramebuffer` between texture-backed FBOs. This
   avoids CPU readback in the primary timing loop and reaches the internal
   rectangle/fullscreen draw.
2. **Original transfer shape:** format-changing `glReadPixels` through a pixel
   pack buffer, based on
   [`repro_blit.c`](../video-libraries/mesa/reproducers/repro_blit.c) and
   [`bench_transfer.c`](../video-libraries/mesa/reproducers/bench_transfer.c).
   Use a PBO ring so CPU memory copying and immediate mapping do not dominate
   submission timing.

Allocate resources and compile shaders before warm-up. Use a ring of
source/destination textures or PBOs large enough to prevent the driver from
turning the workload into one repeated dependency on a single resource.
Initialize sources with unique 32-bit pixel IDs and verify final destinations
outside the timed region. Baseline may be wrong on affected sizes; workaround
output must be exact.

Run two scheduling modes:

- **Batched throughput:** submit `N` real blits, then synchronize once. This
  estimates the recurring slope without per-query noise.
- **Isolated latency:** submit one real blit and synchronize before the next.
  This is an upper bound that includes job submission and synchronization; do
  not substitute it for the throughput result.

Do not issue thousands of `glDrawArrays` calls under one preselected
rasterizer state and label them independent blits. Each counted operation must
enter the real Mesa blit API and internal state-save/bind/draw/restore path.

## Timing model

For batched throughput, measure several operation counts:

```text
N = 1, 2, 4, 8, 16, 64, 256, 1024
```

Scale the largest `N` down for 4K or other cases whose batch would exceed about
100 ms. Use counts whose central samples span both the fixed-overhead region
and a region where blit work dominates.

Fit each mode to:

```text
T(N) = A + N * B
```

where `A` is fixed batch/query/job overhead and `B` is cost per real blit.
Report:

```text
fixed delta      = A_on - A_off
per-blit delta   = B_on - B_off
per-blit percent = (B_on / B_off - 1) * 100
```

Fit CPU submission, GPU timer, and completion-wall measurements separately:

- **CPU submission:** monotonic raw clock around the `N` API calls and flush,
  without waiting for completion.
- **GPU:** `GL_EXT_disjoint_timer_query` around the complete group; reject any
  sample where `GL_GPU_DISJOINT_EXT` is set. Finish the group in a way that
  keeps deferred Mali tile work owned by the intended query.
- **Completion wall:** monotonic raw clock from before the first API call
  through the final fence/`glFinish`.

Report absolute time per blit in addition to percentages. A percentage from a
sub-millisecond one-operation query is not usable when its `p10..p90` range
crosses zero widely.

Use paired `off`/`on` ABBA and BAAB process blocks with equal warm-up. Alternate
which mode starts each block. Keep initialization, allocation, verification,
and trace logging outside timed regions. Record medians and `p10..p90`; for the
fitted slopes, also report fit residuals so a nonlinear batching transition is
visible rather than hidden in one coefficient.

## Size and format matrix

Start with `R32UI` because it matches the independent correctness checker, then
add common formats so a decision is not based only on integer TXF:

- `RGBA8`;
- `R32UI`;
- `RGBA16F`; and
- the original format-changing integer readback.

Minimum size matrix:

| Class | Sizes |
|---|---|
| tiny/setup dominated | `1x1`, `16x16`, `64x64` |
| square | `256x256`, `512x512`, `1024x1024` |
| display | `1280x720`, `1920x1080`, `2560x1440`, `3840x2160` |
| known line failures/controls | `2079x1`, `2080x1`, `1x1480`, `8192x1`, `12288x1`, `16307x1` |
| oblong multi-row | `9350x11`, `11x9350`, `16383x127`, `127x16383` |

Phase one may use `R32UI` at `256x256`, `1024x1024`, `1920x1080`,
`3840x2160`, `12288x1`, and `9350x11`. Expand only after the A/B counters,
correctness gate, and timing model pass.

Test 1:1 nearest blits first. Scaled, flipped, scissored, layered, and MSAA
cases are follow-ups because they can select different shaders or internal
paths; add them only with counter proof that the intended MR path was reached.

## Machine controls

For primary GPU numbers on this ROCK 5B:

```bash
GPU_DEVFREQ=/sys/devices/platform/fb000000.gpu/devfreq/fb000000.gpu
echo 500000000 | sudo tee "$GPU_DEVFREQ/min_freq"
echo 500000000 | sudo tee "$GPU_DEVFREQ/max_freq"
cat "$GPU_DEVFREQ"/{min_freq,max_freq,cur_freq}
```

Record `min_freq`, `max_freq`, and `cur_freq` before and after every matrix
run, plus renderer, Mesa package/build commit, kernel, and GPU temperature.
Reject runs where the clock is not 500 MHz or the timer disjoint flag is set.

CPU submission timing also needs a controlled CPU: pin the process to one core,
record that core and its frequency policy, and either lock its frequency or
keep CPU results explicitly secondary. GPU-only ratios do not require a fixed
CPU clock as strongly, but wall and submission numbers do.

Restore the board afterward:

```bash
echo 1000000000 | sudo tee "$GPU_DEVFREQ/max_freq"
echo 300000000 | sudo tee "$GPU_DEVFREQ/min_freq"
```

## Acceptance gates

The benchmark is ready to support an "apply to all blits" decision only when:

1. `off` and `on` use the same Mesa binary, shader hashes, geometry, formats,
   and internal blit path.
2. Validation counters equal the requested operation count and prove the
   workaround decision occurs once per real blit.
3. Descriptor traces differ only in the intended enable bit and explicit zero
   bias values.
4. The correctness companion reproduces baseline failures at affected sizes
   and reports zero workaround mismatches.
5. Fixed-clock ABBA/BAAB runs complete without disjoint events.
6. `T(N)` separates fixed and per-blit terms with residuals small enough that
   the slope is meaningful; otherwise report the nonlinear curve directly.
7. CPU submission, GPU, and completion-wall results are reported separately.
8. The result includes at least the phase-one ordinary, display, one-row, and
   multi-row-oblong size classes.

The decision summary should lead with absolute recurring cost and its
percentage, then fixed cost. For example:

```text
At 500 MHz, forcing the workaround added X us/blit (Y%) to GPU slope,
Z us/blit to CPU submission, and W us per batch. The worst verified
size/format class was ...
```

Do not continue quoting `~0.5%` as the end-to-end per-blit answer unless this
plan reproduces it. Until then, retain it only as the cache-warm steady-state
GPU-path estimate.

## Boundary

This plan does not itself measure MR !43161. The system Mesa
`26.0.3-1ubuntu1` benchmark can validate the hardware bit through application
polygon-offset state, but application state does not control the internal
blitter's saved rasterizer state. The decisive result requires an instrumented
Mesa build that reaches the actual proposed workaround.

Even a passing microbenchmark does not cover application frame pacing, cold
memory, all transfer formats, scaled filtering, MSAA resolves, or concurrent
graphics/compute workloads. Those remain end-to-end follow-ups after the
per-blit fixed/slope question is answered.
