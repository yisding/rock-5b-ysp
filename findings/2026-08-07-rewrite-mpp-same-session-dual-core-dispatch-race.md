# Rewrite MPP scheduler races same-session frames across both rkvdec cores; ordering + CCU-conformance fix committed

> Scope: `mpp-rewrite` kernel driver rkvdec2 dual-core dispatch; FFmpeg RKMPP conformance track 5
> Source: `../rock-5b/kernel/linux-6.18-rkvenc` @ `c20fc8c1cbf76` — `mpp_rewrite.c`
> `rk_mpp_scheduler_take_job()`, `rk_mpp_hw_get_for_client()`,
> `rk_mpp_rkvdec2_start_ccu_job()`; vendor comparison `rockchip-kernel`
> `mpp_rkvdec2_link.c` `rkvdec2_hard_ccu_enqueue()`; fixes `93e94526a695`,
> `3caf851241c2`, `f37186832202`, `8fdb00c973403` (branch
> `rk3588-rewrite-6.18`); mainline mirror through `1698424efc46e`
> Date: 2026-08-07
> Trust: MEASURED, SOURCE-INSPECTED, CONFIRMED (unsafe same-session overlap);
> COMPILE-VERIFIED (successor serialization fix; boot + repro pending)

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

> **Update 2026-08-08 (`20260808-081340` full serial conformance):** a new,
> distinct manifestation of the residual window — `psnr_hevc_decode_inf` failed
> for the first time, `average:81.76` (min 63.98 / max inf) instead of the
> required `inf`, preceded by a run of non-monotonic DTS warnings to the muxer
> (`40>=38`, `41>=37`, `45>=43`, `46>=42`, …). It passed at `20260806` and at
> `20260807-204828`, so this is intermittent, not a hard regression. The 81 dB /
> min-64 profile is a few frames off by a hair (decode-order/precision), not
> whole-frame garbage — consistent with the residual dispatch-order window
> surfacing on HEVC decode this run rather than on the h264 repeat-exact gate.
> dmesg clean. Same run also failed the RGA3 vpp case solo (separate defect, see
> [rga3 vpp corruption](2026-08-07-rga3-cross-process-vpp-corruption-lead.md)).

> **Source follow-up 2026-08-08:** kernel #8 proves that preserving start order
> while allowing two frames from one decode session to overlap is not sufficient.
> Commit `8fdb00c973403` now gives RKVDEC sessions a dispatch token: the scheduler
> claims it while taking a job under `sched_lock` and releases it after full
> completion/hardware drop, or after RESET_SESSION proves an aborted dispatch
> can no longer start or own hardware. Reset failure keeps the token held
> fail-closed. A session therefore has at most one dispatched
> decode job, while jobs from independent sessions can still use both cores in
> parallel. Mainline commit `1698424efc46e` is byte-identical. Both maintained
> trees pass warning-fatal clean-archive `normal` and `test-disabled` builds, the
> exact 94 MPP + 152 RGA manifest, and the 308-signal source audit. This successor
> has not been packaged, booted, or runtime-qualified.

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

Four commits on `rk3588-rewrite-6.18` (`67f323aebdf3..8fdb00c973403`), each
compile-verified:

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
4. `8fdb00c973403` — **serialize dispatched decode work per session.** The
   kernel #8 residual falsified the assumption in step 1 that ordered
   same-session overlap was safe. RKVDEC alone now holds a per-session token
   from scheduler dispatch through complete hardware retirement; RESET_SESSION
   releases it only after abort proves the dispatch retired. Encoder jobs and
   independent decoder sessions retain the existing cross-core scheduling.
   The existing `rk_mpp_scheduler_session_start_order_kunit` case now proves
   that a second same-session job cannot dispatch until the first completes.

The KUnit manifest moved to 94 MPP + 152 RGA cases (246 total) in the paired
ysp commit.

The 2026-08-07 `rewrite-debug` integration build completed on Armbian's
6.18.43 stable base and produced package identity
`6.18.43-S7b92-D6d03-P3b3c-Cad24-H1c44-HK01ba-Vc222-B3ab8-R448a` from source
stamp `gf37186832202`. The wrapper verified the packaged rewrite options and
reported `P3b3c-Cad24`; its final config is byte-identical to the prior
`P7215-Cad24` KASAN config. Source stamp `gf37186832202` subsequently booted as
kernel #8 and produced the residual observations above. The successor
`8fdb00c973403` serialization fix is compile-verified only and has no package or
runtime evidence yet.

## Verification gate

1. Build, install, and boot a new `rewrite-debug` package from exact source
   `c20fc8c1cbf76` (which includes `8fdb00c973403`);
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
   both cores used across the workload. Sequential use by one session is now
   intentional; independent sessions must remain able to occupy both cores.
3. Full FFmpeg suite replay on rewrite-kasan with the bit-exact H.264/HEVC
   gates required, per the 2026-08-06 finding's boundary.

## Boundary

Kernel #8 booted and falsified the first three-commit fix as complete closure;
the fourth, per-session serialization step is not yet booted or repro-verified.
A clean exact-tip run would validate the revised unsafe-overlap explanation but
still would not isolate the hard-CCU IOTLB and bus-idle changes, which remain
vendor-conformance hardening rather than proven contributors. If corruption
persists with the token held until hardware retirement, the next suspect is
state outside the scheduler's session boundary rather than overtaking or
same-session overlap. Whether the original skip-head behavior was always latent
is open; no decoder-driver commit landed between the validated 6.18.42 and the
first failing 6.18.43 build.
