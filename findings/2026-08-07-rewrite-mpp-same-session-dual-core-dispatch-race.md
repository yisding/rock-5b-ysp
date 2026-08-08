# Rewrite MPP scheduler races same-session frames across both rkvdec cores; ordering + CCU-conformance fix committed

> Scope: `mpp-rewrite` kernel driver rkvdec2 dual-core dispatch; FFmpeg RKMPP conformance track 5
> Source: `../rock-5b/kernel/linux-6.18-rkvenc` @ `67f323aebdf3` — `mpp_rewrite.c`
> `rk_mpp_scheduler_take_job()`, `rk_mpp_hw_get_for_client()`,
> `rk_mpp_rkvdec2_start_ccu_job()`; vendor comparison `rockchip-kernel`
> `mpp_rkvdec2_link.c` `rkvdec2_hard_ccu_enqueue()`; fixes `93e94526a695`,
> `3caf851241c2`, `f37186832202` (branch `rk3588-rewrite-6.18`)
> Date: 2026-08-07
> Trust: MEASURED, SOURCE-INSPECTED, CONFIRMED (root cause); COMPILE-VERIFIED
> (fixes; boot + repro gate below still pending)

> **Update 2026-08-07 evening (kernel #8 `gf37186832202` booted):** the fix
> reduces but does not eliminate the failure class. The promoted
> `ffmpeg_decode_h264_repeat_exact_load` gate passed 20/20 in the 20:48
> conformance run and 30x in focused checks, but solo gate runs at 22:55 and
> 23:03 failed — one `MISMATCH from frame 2` at iteration 1/20 (the original
> corruption signature) and one `h264_rkmpp` AVERROR_BUG ("decoder returned
> an unexpected error code") mid-iteration under load, kernel log silent both
> times. Either the dispatch-order barrier leaves a residual window or a
> second mechanism exists. Keep the gate required; do not treat clean runs
> as closure.

## Result

The intermittent H.264/HEVC hw-decode corruption from the
[2026-08-06 rewrite-kasan run](./2026-08-06-rewrite-kasan-media-suite-userspace-fixes-and-intermittent-h264.md)
is a task-scheduling defect in the rewrite driver's dual-core rkvdec dispatch,
not the MPP `a8b19653` VP9 show-existing fix and not FFmpeg frame lifetime.

**Mechanism.** The rewrite binds each job to a core at submission time
(least-loaded, `rk_mpp_hw_get_for_client()`) and its scheduler
(`rk_mpp_scheduler_take_job()`) skipped a queued head job whose bound core was
busy, starting a later job on the other core instead. With MPP's default
3-deep fast-parse pipeline, frame N+1 of a session could start on core 1 while
frame N was still queued for core 0. The vdpu381 inter-core reference
handshake (per-session film_idx tag, reg28[25:16]) only stalls a consumer
against a producer that has already started, so the overtaking frame's
motion-compensation reference fetches free-ran into memory the producer had
not reconstructed: reference top rows valid, bottom rows zero or
pre-loop-filter, then GOP-wide propagation. The vendor driver cannot express
this state — it binds cores at dispatch, strictly head-of-queue-or-nothing.

**Discriminating experiments** (board, kernel `g67f323aebdf3`, exact suite
command and input, `/usr/bin/ffmpeg` from `c9428bedaa`; scripts were staged at
`~/Code/tmp/ffmpeg-corruption/{repro.sh,repro-fp0.sh}`, `ITER=20`, `LOAD=1`
background CPU load):

| Configuration | Corrupt runs |
|---------------|--------------|
| Installed MPP `a8b19653` (with VP9 fix), default pipelining | 9/20 |
| Source-built MPP `ad325345` (5 commits before the VP9 fix) | 9/20 |
| Same stack, `-fast_parse 0` (serialized session submission) | 0/20 |

Identical failure rates with and without the VP9 fix exonerate it; corruption
vanishing when same-session submission is serialized pins the defect to
concurrent in-flight frames. Matching suite evidence: the failing window's
debugfs deltas split single 60-frame sessions ~50/50 across rkvdec
core0/core1, and the one FFmpeg decode case that always passed
(`decode_h264_extbuf_to_null`) is exactly the one that runs `-fast_parse 0`.
Frame-hash analysis showed no hw frame ever equals any sw frame, ruling out
duplication/reordering; the 2026-08-06 finding's "clean focused repeats" were
luck — under background CPU load the race fires in roughly half of runs.

## Fix

Three commits on `rk3588-rewrite-6.18` (`67f323aebdf3..f37186832202`), each
compile-verified against the rewrite-debug config:

1. `93e94526a695` — **keep same-session jobs in dispatch order.** The
   scheduler stamps a session when a scan passes over one of its queued jobs
   and refuses to start any later job of that session in the same scan. Jobs
   of one session start strictly in submission order; in-order dual-core
   overlap (which the film_idx handshake supports) and cross-session
   parallelism are preserved. New KUnit case
   `rk_mpp_scheduler_session_start_order_kunit`.
2. `3caf851241c2` — **flush IOTLB before every hard-CCU CFG_DONE**, in add
   mode too, matching vendor `rkvdec2_hard_ccu_enqueue()`; the hard-CCU path
   previously never flushed per enqueue (the soft-CCU path already did).
3. `f37186832202` — **prove bus idle before completing rkvdec jobs.** Both
   completion paths (soft-CCU ready IRQ, hard-CCU descriptor-status drain)
   now poll `DEBUG_INT` BUS_IDLE before job completion and power-off — the
   proof the recovery path already demanded. Timeouts are counted
   (`rkvdec_bus_not_idle_count` in debugfs and the procfs error line) and
   warned, not failed. New KUnit case `rk_mpp_rkvdec2_wait_bus_idle_kunit`.

The KUnit manifest moved to 94 MPP + 152 RGA cases (246 total) in the paired
ysp commit.

The 2026-08-07 `rewrite-debug` integration build completed on Armbian's
6.18.43 stable base and produced package identity
`6.18.43-S7b92-D6d03-P3b3c-Cad24-H1c44-HK01ba-Vc222-B3ab8-R448a` from source
stamp `gf37186832202`. The wrapper verified the packaged rewrite options and
reported `P3b3c-Cad24`; its final config is byte-identical to the prior
`P7215-Cad24` KASAN config. These packages are built and package-verified, not
installed, booted, or runtime-qualified.

## Verification gate

1. Install the rebuilt `rewrite-debug` debs with `PHASH=P3b3c-Cad24` and boot;
   `rewrite-kunit-log-check.sh` must show the exact 246-case manifest green
   under KASAN.
2. Repro loop, promoted from the scratch scripts into the FFmpeg conformance
   suite on 2026-08-07: required case `ffmpeg_decode_h264_repeat_exact_load`
   (20 per-frame-hash-exact hardware decodes under 4 CPU spinners) with
   diagnostic control `ffmpeg_decode_h264_repeat_exact_fp0` (identical load,
   MPP `-fast_parse 0` serialized submission);
   `FFMPEG_REPEAT_EXACT_ITER`/`FFMPEG_REPEAT_EXACT_LOAD_JOBS` tune them. On
   unfixed `g67f323aebdf3` the required case measured 2/20 mismatching
   iterations, both diverging from frame 2 — the exact race fingerprint —
   while the control passed 20/20, so the pair discriminates a
   dispatch-order regression from general decode breakage. The fixed kernel
   must pass the required case twice plus the control. Watch
   `rkvdec_bus_not_idle_count` and confirm per-core debugfs deltas still show
   both cores used (the fix must not silently serialize onto one core).
3. Full FFmpeg suite replay on rewrite-kasan with the bit-exact H.264/HEVC
   gates required, per the 2026-08-06 finding's boundary.

## Boundary

Not yet booted or repro-verified — the trust line stays COMPILE-VERIFIED for
the fixes until the gate above runs. The three fixes land together, so a clean
result will not attribute which was necessary; if corruption persists with
ordering enforced, in-order dual-core overlap itself is unsafe in the rewrite
(CCU work-mode coupling is the next suspect) — that discrimination was the
point of enforcing start order in the driver. Whether the skip-head dispatch
was a regression or always latent is open (no decoder-driver commit landed
between the validated 6.18.42 and failing 6.18.43 builds; all ten were
RGA-side), and the hard-CCU IOTLB and bus-idle gaps were closed as
vendor-conformance hardening, not as proven contributors to this corruption.
