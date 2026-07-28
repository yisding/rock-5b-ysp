# Mesa blit benchmark bounds end-to-end workaround cost but cannot resolve it

> Scope: `video-libraries/mesa`; MR !43161 workaround microbenchmark on Panfrost / Mali-G610
> Source: YSP `e771a00`; Mesa `0c1cf4a71b4`; fixed-clock logs `c008b4b1`, `86b49728`, and `a518ae24`
> Date: 2026-07-28
> Trust: SOURCE-INSPECTED, MEASURED, BOARD-REPRODUCED, FIX-RUNTIME-VERIFIED, PARTIAL

## Result

The repaired, fixed-clock benchmark found **no detectable end-to-end slowdown**
from forcing MR !43161's zero-valued depth-bias workaround on every affected
internal blit. For the known-failing `R32UI` `12288x1` case, the primary
batched GPU elapsed slope changed by a central `-0.09%`; its paired bootstrap
95% interval was `-1.90%..+2.11%`. The interval crosses zero, so the honest
result is a bound, not a claimed speedup or slowdown:

```text
PAIRED-SUMMARY,batched,gpu,...,62.358476,62.586184,-0.056724,-0.091844,...,-1.898857,2.110672,12,12
PAIR-QUALITY-GATE,batched,gpu,PASS,12,8,0.980000
EFFECT-GATE,batched,gpu,UNRESOLVED,-1.898857,2.110672
```

All 12 adjacent A/B GPU pairs passed the `R² >= 0.98` fit gate. The CPU and
completion-wall intervals also crossed zero:

| Metric | Off slope | On slope | Paired central delta | Paired central change | Bootstrap 95% interval |
|---|---:|---:|---:|---:|---:|
| CPU submission | `60.471 us/blit` | `60.822 us/blit` | `-0.067 us/blit` | `-0.108%` | `-1.952%..+2.739%` |
| GPU elapsed interval | `62.358 us/blit` | `62.586 us/blit` | `-0.057 us/blit` | `-0.092%` | `-1.899%..+2.111%` |
| Completion wall | `62.344 us/blit` | `62.542 us/blit` | `-0.169 us/blit` | `-0.271%` | `-1.787%..+2.272%` |

Those columns are component-wise medians across accepted pairs, so the printed
median delta is not required to equal the difference between the two printed
median slopes.

The simultaneously controlled same-batch draw probe reproduced the narrower
steady-state GPU-path result:

```text
size=12288x1 draws=4096 blocks=30 warmups=4
workaround baseline_ms=87.295323 test_ms=87.750031
           slowdown_pct=0.451 p10_pct=0.081 p90_pct=0.666
```

This supports two distinct statements:

1. enabling the zero-valued polygon-offset/depth-bias hardware path costs about
   `0.45%` for thousands of cache-warm draws sharing one framebuffer batch; and
2. forcing that state through real, independent `glBlitFramebuffer` calls did
   not produce a measurable total-throughput slowdown in this workload; the
   observed 95% upper bound is `+2.11%`.

The first is the descriptor-path answer. The second is the end-to-end internal
blit answer. Neither is a workload-independent percentage.

## Controlled run

The primary invocation used the instrumented single Mesa binary at
`0c1cf4a71b4` and its required
`PAN_BLIT_DEPTH_BIAS=off|on` acknowledgement:

```bash
meson devenv -C build-bench env EGL_PLATFORM=surfaceless \
  /path/to/run_blit_workaround_bench.py \
  --binary /path/to/blit_workaround_bench \
  --blocks 6 --cpu 6 --expect-gpu-hz 500000000 -- \
  --width 12288 --height 1 \
  --counts 1,2,4,8,16,64,256 \
  --samples 11 --warmups 2 --ring 256 --schedule batched
```

Machine controls and identity were:

- kernel `6.18.40-video-port-rockchip64`, not the prior KASAN boot;
- GPU min/max/current fixed at `500000000 Hz`;
- CPU 6 policy min/max/current fixed at `1800000 kHz`, governor
  `performance`; and
- `rock5b-passive-cooling.service` stopped before the run so it could not
  restore the CPU policy every five seconds.

All 50 runner clock checks saw exactly `500 MHz`. All 1,848 timer samples had
`disjoint=0`. Every one of the 12 off processes reproduced
`3006464 / 3145728` mismatches, while all 12 on processes reported zero.

The raw machine-local evidence is:

| Artifact | SHA-256 | Purpose |
|---|---|---|
| `/home/yi/Code/mesa-mr43161-benchmark-20260728/12288x1.log` | `c008b4b197eaf19c9e72c8acacd7e86b6a02df7a1be9c06e19716cd5139ba111` | Primary decision run |
| `/home/yi/Code/mesa-mr43161-benchmark-20260728/12288x1-n1024.log` | `86b497287d67ebab8efecc830383d69c56c1617f3b2be145aae926a637ea5cbc` | Longer-count diagnostic |
| `/home/yi/Code/mesa-mr43161-benchmark-20260728/12288x1-offset-control.log` | `a518ae24bbe2163f798dea14b6911ac0ac870806bc99ce5a64661e7ef9ccd3a1` | Same-batch hardware-path control |

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

## Boundary and next discriminator

The fixed-clock result closes the immediate benchmark run: the broad workaround
has a repeatable roughly half-percent steady-state draw-path cost and no
resolved end-to-end penalty for the tested real-blit workload.

Tightening the real-blit interval below one percent requires a different A/B
boundary, not just larger `N`: alternate off/on inside one long-lived process
or context, or use driver/hardware counters that measure busy cycles after
submission. Such instrumentation must preserve one real internal blitter entry
and workaround decision per operation and avoid adding unequal work to either
side. The planned internal-draw/workaround-decision counters, descriptor trace,
other formats, and broader size matrix remain open.
