# Forward-port RGA3 passes the repeated small-geometry AFBC-to-P010 dropped-write discriminator

> Scope: C15 hardware codecs/RGA; forward-port/vendor RGA3 versus the
> rewrite-driver failure recorded on 2026-07-31
> Source: booted ROCK 5B kernel
> `6.18.41-ysp-rockchip64 #1`, package
> `6.18.41+rk3588av1fwport20260802-0ubuntu1~rk1`; installed ysp8 VA-API,
> MPP, RGA, and FFmpeg stack identified below
> Date: 2026-08-02
> Trust: **MEASURED** + **BOOT-VERIFIED** + **CONFIRMED** (byte-exact output,
> audited conversion counts, explicit per-core exercise, and clean kernel-log
> interval) + **SOURCE-INSPECTED** (the separate throughput-accounting result)

## Result

The RGA3 AFBC-NV15 to linear-P010 success-without-destination-write failure
was **not reproduced on the forward-port/vendor RGA3 driver**. The dedicated
run substantially exceeds the rewrite-driver experiment at both affected
geometries, covers serial and concurrent processes, and explicitly exercises
both RGA3 cores:

| Geometry | Process runs | Byte-compared frames | Audited conversions | Result |
|---|---:|---:|---:|---|
| 416x240 | 90 | 4,320 | 4,320 | PASS |
| 320x240 | 90 | 4,320 | 4,320 | PASS |
| 1280x720 control | 8 | 384 | 384 | PASS |

The first 80 runs at each small geometry comprise 60 serial runs and two of
four mixed concurrent workers, ten runs per worker. A diagnostic then called
librga's documented thread-local
`imconfig(IM_CONFIG_SCHEDULER_CORE, IM_SCHEDULER_RGA3_CORE1)` immediately
before `improcess()` and added ten runs per geometry on RGA3 core 1. Core-1
runtime-active time increased from 32 ms to 382 ms while core 0 remained
unchanged, and both devices returned to runtime-suspended state.

Additional exactness coverage passed:

- the repository Main10 gate's generated 320x240/48-frame and pinned
  416x240/256-frame cases;
- ten complete VP9 Profile 2 gates: 480 generated visible frames, 100 pinned
  displayed frames, and 590 decoded-frame conversions; and
- six complete 1080p VP9 Profile 2 decodes: 1,440 displayed P010 frame hashes
  byte-identical to software, with 265 conversions and 265 assignments on
  every run.

Across those exactness gates, 11,348 displayed frames were compared and 11,508
RGA conversions were audited. No stale or zero destination, comparison
failure, RGA refusal, external-buffer mismatch, decode failure, or linear
fallback occurred. The kernel journal contained no warning-priority entry and
no RGA, IOMMU, bus-error, timeout, hang, oops, or kernel-bug signature during
the final test intervals.

This is a strong counterexample to the defect being an unavoidable property of
RK3588 RGA3 hardware. The narrow current verdict is:

- the silent dropped write remains proven on rewrite build `#23`;
- it is not reproduced on the production forward-port/vendor driver; and
- Main10/VP9 Profile 2 on this forward-port kernel are no longer blocked by
  that rewrite-driver observation.

## Exact stack

| Component | Measured identity |
|---|---|
| Kernel | `Linux 6.18.41-ysp-rockchip64 #1` |
| Kernel package | `6.18.41+rk3588av1fwport20260802-0ubuntu1~rk1` |
| RGA driver | forward-port/vendor `rga3`; both `fdb60000.rga` and `fdb70000.rga` bound |
| `rockchip-vaapi` / config | `1.0.11+ysp8-0ubuntu1~rk1` |
| `librockchip-mpp1` | `1.5.0+git20260730.ad325345+ds-0ubuntu1~rk1` |
| `librga2` | `2.2.0+git20260725.26a50ef-0ubuntu1~rk1` |
| FFmpeg | `/usr/bin/ffmpeg` `8.0.3-0ubuntu1~rk1` |
| CMA | 256 MiB from `cma=256M` |

The fixed inputs were 48-frame HEVC Main10 `testsrc2` streams with
`bframes=0`, matching the original rewrite-driver discriminator. Each
hardware run forced the hidden `hevc-main10` VA profile, required AFBC V2
input to RGA, downloaded P010, compared against the software decode, and
required exactly 48 `convert: NV15->P010 ... afbc=1` markers.

## Separate throughput-validator result

HEVC Main10 throughput passed at 250.65 and 147.81 fps. VP9 Profile 2 produced
240 visible frames at 225.74 and 186.26 fps, but the throughput script rejected
both runs because it counted one more completed RGA conversion than converted
surface assignment (`255/254` and `256/255`). This was not the dropped-write
symptom.

The retained log shows that `assign_mpp_frame()` completed a conversion, then
found that the target surface fence had advanced before it acquired the
surface lock and safely discarded the stale route. The mismatch appears when
FFmpeg stops at the explicit 240-output-frame limit. The six complete,
non-truncated VP9 decodes instead logged `265/265` and were byte-exact.
`tests/check-10bit-throughput.sh` should distinguish a completed-but-cancelled
conversion from one assigned to a surface rather than require the two raw log
counts to match under an output limit.

## CMA observation

`CmaFree` moved from 68,808 KiB before stress to a 3,916 KiB low-water
snapshot. No allocation failed. A final 1080p VP9 exact decode was deliberately
started after the counter fell below 5 MiB and still completed 240/240 exact
frames with `265/265` conversions/assignments. This demonstrates reclaimable
capacity for that run; it does not replace the intended 512 MiB production CMA
configuration or prove that 256 MiB is sufficient for simultaneous 4K video
and GPU composition.

## Boundary

- This is a cross-track discriminator, not a strict single-variable kernel
  bisection. The forward-port and rewrite kernels differ beyond the RGA driver,
  and their installed MPP revisions differ.
- The corrected rewrite power/map ordering has passed build gates but remains
  untested on a booted rewrite kernel, so the rewrite mechanism is still not
  root-caused.
- The repeated test covers RGA3 AFBC NV15-to-P010. It does not qualify the
  RGB-to-NV12 encode conversion or the 8-bit export-repack shapes.
- The test is broad repeated evidence, not a multi-hour RGA soak. Main10 and
  VP9 Profile 2 remain experimental for their separate physical-HDR, browser
  sandbox, packaging, and release gates.
- Raw P010 outputs were deleted after comparison to recover about 350 MiB. The
  remaining ignored run directory was also discarded in the 2026-08-04 workspace
  cleanup; the command, checksums, diagnostic, and result summary recorded here
  remain the reproducible evidence boundary.

## Next discriminator

Boot a rewrite kernel containing the corrected power-before-map and
unmap-before-power-off ordering, then run the same serial, concurrent, and
forced-core small-geometry matrix. A clean result would runtime-verify the
rewrite fix; a recurrence would prove the ordering bug was real but not the
cause of the silent dropped write.
