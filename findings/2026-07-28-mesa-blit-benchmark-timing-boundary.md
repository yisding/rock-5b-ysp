# Mesa single-context benchmark resolves MR !43161 workaround cost

> Scope: `video-libraries/mesa`; MR !43161 workaround microbenchmark on Panfrost / Mali-G610
> Source: YSP benchmark harness in this finding's commit; Mesa benchmark branch `6000414f9ea`; fixed-clock logs `71b03cd2`, `2743f33b`, and `a518ae24`
> Date: 2026-07-28
> Trust: SOURCE-INSPECTED, MEASURED, BOARD-REPRODUCED, FIX-RUNTIME-VERIFIED

## Result

The balanced, single-context benchmark resolves the cost of forcing MR !43161's
zero-valued depth-bias workaround on every affected internal blit. For the
known-failing `R32UI` `12288x1` workload:

| Metric | Off slope | On slope | Absolute delta | Central change | Bootstrap 95% interval |
|---|---:|---:|---:|---:|---:|
| CPU API submission | `5.899 us/blit` | `5.996 us/blit` | `+0.078 us/blit` | `+1.32%` | `+0.64%..+2.11%` |
| Completion tail | `24.164 us/blit` | `24.288 us/blit` | `+0.121 us/blit` | **`+0.50%`** | **`+0.34%..+0.73%`** |
| End-to-end wall | `30.081 us/blit` | `30.263 us/blit` | `+0.185 us/blit` | **`+0.62%`** | **`+0.44%..+1.01%`** |

These are medians of 30 whole-block contrasts. Each contrast first averages
the two off and two on fitted slopes in one ABBA/BAAB block, then calculates
the log slope ratio. Component-wise medians mean the printed delta need not
equal the difference between the two printed median slopes.

```text
BLOCK-SUMMARY,coalesced,tail,...,24.164351,24.288280,0.120586,0.499098,...,0.339926,0.733073,30,30
BLOCK-QUALITY-GATE,coalesced,tail,PASS,30,30,0.980000
BLOCK-EFFECT-GATE,coalesced,tail,SLOWER,0.339926,0.733073
BLOCK-SUMMARY,coalesced,wall,...,30.081436,30.262587,0.184990,0.615110,...,0.435351,1.012183,30,30
BLOCK-EFFECT-GATE,coalesced,wall,SLOWER,0.435351,1.012183
```

The completion-tail result is the closest estimate of deferred driver plus GPU
cost. End-to-end wall is the application-visible answer for this synthetic
same-FBO throughput workload. Neither is a workload-independent percentage.

The independent direct-draw control remains consistent:

```text
size=12288x1 draws=4096 blocks=30 warmups=4
workaround baseline_ms=87.295323 test_ms=87.750031
           slowdown_pct=0.451 p10_pct=0.081 p90_pct=0.666
```

It measures the cache-warm descriptor/hardware path rather than real
`glBlitFramebuffer` entry, so its `+0.451%` is corroboration, not a replacement
for the `+0.50%` completion-side or `+0.62%` end-to-end results.

## Why this design can resolve the effect

The first repaired process-level run remained unresolved at `-1.90%..+2.11%`.
It used distinct EGL processes and unique destination FBOs. Both choices added
variation larger than the expected half-percent effect.

The final design makes four changes:

1. A test-only `PAN_BLIT_DEPTH_BIAS=dynamic` mode alternates
   `PAN_BLIT_DEPTH_BIAS_DYNAMIC=off|on` in one long-lived EGL context. Context,
   resources, shaders, query objects, and process state are identical.
2. All measured blits target one destination FBO. Panfrost holds that batch
   until `glFinish()`, avoiding the 32-live-FBO eviction pipeline.
3. `tail = wall - CPU API submission` isolates completion after the caller's
   blit loop. `T(N) = A + N*B` separates the fixed `glFinish()` boundary from
   per-blit cost.
4. Every ABBA/BAAB block gives each label one ascending-count and one
   descending-count fit. The first same-context A/A, which used ascending fits
   only, falsely reported `+0.37%`; balancing count order removed that bias.

Panfrost's `GL_TIME_ELAPSED_EXT` result stays at the roughly `1.5 us` marker
floor in the same-FBO schedule and is explicitly rejected as a decision
signal. The completion tail brackets the deferred batch through `glFinish()`;
the hardware-query row is retained only as a diagnostic.

## A/A control

The required off/off control used the same context, ABBA/BAAB schedule, and
balanced count order as A/B:

```text
BLOCK-SUMMARY,coalesced,tail,...,-0.147929,...,-0.273268,0.150778,12,12
BLOCK-EFFECT-GATE,coalesced,tail,UNRESOLVED,-0.273268,0.150778
BLOCK-SUMMARY,coalesced,wall,...,-0.079151,...,-0.357214,0.353716,12,12
BLOCK-EFFECT-GATE,coalesced,wall,UNRESOLVED,-0.357214,0.353716
```

The null interval contains zero for both primary metrics. All 2,016 samples
were non-disjoint, all 98 clock records were exactly 500 MHz, and both labels
reproduced the same `11744 / 12288` baseline mismatch count.

## Controlled A/B run

The decision invocation was:

```bash
meson devenv -C build-bench env EGL_PLATFORM=surfaceless \
  /path/to/run_blit_workaround_bench.py \
  --in-process --single-context \
  --blocks 30 --min-blocks 30 --min-pairs 60 \
  --bootstrap-samples 50000 --cpu 6 \
  --expect-gpu-hz 500000000 \
  --off-env PAN_BLIT_DEPTH_BIAS=off \
  --on-env PAN_BLIT_DEPTH_BIAS=on -- \
  --width 12288 --height 1 \
  --counts 16,64,128,256,512,1024 \
  --samples 9 --warmups 2 --ring 2 --schedule coalesced
```

Machine controls and identity were:

- kernel `6.18.40-video-port-rockchip64`, not the prior KASAN boot;
- GPU min/max/current fixed at `500000000 Hz`;
- CPU 6 policy min/max/current fixed at `1800000 kHz`, governor
  `performance`;
- `rock5b-passive-cooling.service` stopped so it could not restore CPU policy;
  and
- Mesa source equal to local benchmark commit `6000414f9ea`. The measured
  binary was built immediately before that local commit, so its embedded
  version string names parent `0c1cf4a71b`; the archived patch and committed
  source are byte-identical in the driver code.

All 242 clock records saw exactly 500 MHz. All 6,480 samples had
`disjoint=0`. All 30 completion-tail and wall blocks passed the
`R² >= 0.98` gate; 26/30 completion-tail contrasts were positive.
Workaround-off reproduced `11744 / 12288` mismatches, while workaround-on
reported zero.

The raw machine-local evidence is:

| Artifact | SHA-256 | Purpose |
|---|---|---|
| `/home/yi/Code/rock-5b/build/mesa/mesa-mr43161-benchmark-20260728/coalesced-single-balanced-ab-off-on-30.log` | `2743f33b0c94c81f3a00180bd522bb5b47fd723e0727899b368d0de9d44bb964` | Primary 30-block A/B |
| `/home/yi/Code/rock-5b/build/mesa/mesa-mr43161-benchmark-20260728/coalesced-single-balanced-aa-off-off.log` | `71b03cd2c80894c87ab35a540041d14d35a5bab1699a813bb8c9b3dd83b68bf6` | Balanced 12-block A/A |
| `/home/yi/Code/rock-5b/build/mesa/mesa-mr43161-benchmark-20260728/coalesced-single-aa-off-off.log` | `029f1cb01adbf4c7265946e35d1750406edc3a87b24ebe8559e3ed1b27683653` | Ascending-only A/A that exposed count-order bias |
| `/home/yi/Code/rock-5b/build/mesa/mesa-mr43161-benchmark-20260728/coalesced-aa-off-off.log` | `2aa6acdcd532b3e98dbf5e47120296029e02a21e1ba9e0edf67efe94b33d462d` | Two-context A/A that exposed context-position bias |
| `/home/yi/Code/rock-5b/build/mesa/mesa-mr43161-benchmark-20260728/12288x1.log` | `c008b4b197eaf19c9e72c8acacd7e86b6a02df7a1be9c06e19716cd5139ba111` | Prior process-level run |
| `/home/yi/Code/rock-5b/build/mesa/mesa-mr43161-benchmark-20260728/12288x1-offset-control.log` | `a518ae24bbe2163f798dea14b6911ac0ac870806bc99ce5a64661e7ef9ccd3a1` | Direct-draw control |

## Why increasing `N` did not tighten the interval

Panfrost has only 32 live framebuffer-batch slots
(`PAN_MAX_BATCHES` in `pan_resource.h`). The benchmark deliberately uses a
different destination FBO for every counted blit so the tile renderer cannot
fold repeated fullscreen overwrites into one framebuffer batch. Once the live
set exceeds 32, the least-recently-used batch is submitted while the CPU is
still issuing later API calls.

That scheduling makes the `GL_TIME_ELAPSED_EXT` interval an end-to-end GPU
timeline, not a pure sum of shader-busy durations. It contains CPU submission
gaps at small counts and CPU/GPU overlap once batch eviction pipelines the
work. CPU submission varied by several percent between driver processes even
with CPU and GPU clocks fixed, and that common variation dominated the much
smaller workaround effect.

A diagnostic rerun increased the maximum count from 256 to 1,024 unique FBOs.
All 12 GPU pairs still passed the fit gate, but the result remained unresolved:

```text
PAIRED-SUMMARY,batched,gpu,...,66.581284,67.195481,0.294345,0.433552,...,-2.021896,2.848002,12,12
EFFECT-GATE,batched,gpu,UNRESOLVED,-2.021896,2.848002
```

At that resource footprint the fitted `GPU elapsed - CPU submission` slope
collapsed toward zero and had near-zero `R²`, directly showing overlap rather
than a longer pure-GPU sample. More unique FBOs are therefore not the route to
a precise descriptor-only percentage.

## Original timer defects

The first all-blit A/B could not produce a percentage because its independent
variable did not describe the work inside the GPU timer.

Panfrost implements `PIPE_QUERY_TIME_ELAPSED` by writing timestamps into fresh
batches associated with the currently bound framebuffer. The old
`run_batched()` sequence was:

```text
begin query
issue N blits across the resource ring
end query
flush
finish
```

At query end, `panfrost_get_fresh_batch_for_fbo()` submitted the current
framebuffer's batch if it contained draws, then put the end timestamp in a new
batch. Batches for the other destination FBOs remained pending until the later
`glFlush()`. The resulting `1.5..2 us` query values therefore did not bracket
the same work as the completion-wall measurement. Moving only the flush after
the query would not fix the start boundary: the start marker also needed to be
submitted before measured framebuffer batches were created.

The resource schedule had a second independent defect. With `--ring 4`,
operation counts above four reused destination FBOs. Panfrost batches rendering
by FBO, so multiple fullscreen overwrites shared a tile batch and final store.
The fixed-clock `3840x2160` wall medians grew from about `3.2 ms` at one blit to
`10.6 ms` at four, then stayed near `10.6 ms` at eight. Treating the repeated
API calls as eight independent GPU blits made the fitted slope meaningless.

The repaired benchmark:

1. flushes the query-start marker before measured work;
2. flushes all measured FBO batches before ending the query;
3. flushes the end marker before waiting; and
4. refuses a batched run unless `ring >= max(operation_count)`, so every
   measured operation has a unique destination FBO.

An unlocked-clock `64x64` runtime smoke against instrumented Mesa
`0c1cf4a71b4` produced GPU medians of `108.5 us` at `N=1` and `583.9 us` at
`N=8`, with a `69.23 us/blit` slope and `R²=0.988`. A separate affected
`12288x1` smoke with `ring=256` produced a `64.92 us/blit` GPU slope and
`R²=0.987`. These proved the corrected interval scaled, but their unlocked
governor made the absolute slopes unsuitable as workaround-cost evidence.

## Boundary and next scope

The fixed-clock result closes the immediate question for the affected
`R32UI 12288x1` microbenchmark: the workaround is about `0.50%` slower on the
completion side and `0.62%` slower end to end, with both intervals excluding
zero and an A/A interval that includes zero.

Do not generalize that number to all applications or blit classes. The next
useful evidence is a size/format matrix using the same A/A-qualified,
single-context boundary, followed by application frame-time or hardware
busy-cycle counters if a workload-level percentage is needed. The planned
internal-draw/workaround-decision counters and descriptor trace also remain
useful semantic gates: they can prove one real internal blitter entry and one
workaround decision per API operation with no unequal instrumentation.
