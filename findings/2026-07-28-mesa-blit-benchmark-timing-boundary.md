# Mesa blit benchmark missed work before its timer end marker

> Scope: `video-libraries/mesa`; MR !43161 workaround microbenchmark on Panfrost / Mali-G610
> Source: Mesa `0c1cf4a71b4`, `panfrost_begin_query()`, `panfrost_end_query()`, and `panfrost_get_fresh_batch_for_fbo()`; YSP `e771981` `blit_workaround_bench.c`
> Date: 2026-07-28
> Trust: SOURCE-INSPECTED, MEASURED, BOARD-REPRODUCED, FIX-RUNTIME-VERIFIED, PARTIAL

## Result

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

At query end, `panfrost_get_fresh_batch_for_fbo()` submits the current
framebuffer's batch if it contains draws, then puts the end timestamp in a new
batch. Batches for the other destination FBOs remain pending until the later
`glFlush()`. The resulting `1.5..2 us` query values therefore did not bracket
the same work as the completion-wall measurement. Moving only the flush after
the query would not fix the start boundary: the start marker also needs to be
submitted before measured framebuffer batches are created.

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
`R²=0.987`. These replace the prior operation-count-invariant timer behavior
and prove the corrected boundary scales; the unlocked governor makes their
absolute slopes unsuitable as workaround-cost evidence.

The runner now preserves each adjacent pair in ABBA/BAAB order, rejects
non-positive or low-`R²` slope pairs, and reports the median paired percentage
with a deterministic bootstrap 95% interval. A percentage is resolved only
when enough high-quality pairs survive and the interval excludes zero.

## Verification gate

Pin GPU min/max/current to `500 MHz`, pin the selected CPU at a stable
frequency on the non-KASAN kernel, and run at least six ABBA/BAAB blocks (12
adjacent pairs) for one affected and one ordinary size. Start with:

```bash
./run_blit_workaround_bench.py --blocks 6 --cpu 6 \
  --expect-gpu-hz 500000000 -- \
  --width 12288 --height 1 --counts 1,2,4,8,16,64,256 \
  --samples 11 --warmups 2 --ring 256 --schedule batched
```

Use the same instrumented binary and require its
`PAN_BLIT_DEPTH_BIAS=off|on` acknowledgement. Quote the absolute
`on - off` GPU slope, paired percentage, and 95% interval from
`PAIRED-SUMMARY,batched,gpu`. If `EFFECT-GATE` remains `UNRESOLVED`, increase
blocks or measured operations; do not promote the central estimate alone.

## Boundary

The repaired smoke proves timer scaling and removes destination-FBO reuse, but
it does not yet measure the workaround at a fixed clock. The benchmark still
needs the planned internal-draw/workaround-decision counters and descriptor
trace. Its percentage is specific to `R32UI`, the selected geometry, format,
clock, and scheduling mode; it is not a universal property of the descriptor
bit.
