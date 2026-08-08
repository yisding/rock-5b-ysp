# Rewrite rkvdec zero-copy decode duplicates frames after the #8 scheduler/completion fixes

> Scope: `kernel-drivers/tests` ffmpeg-rockchip conformance on `rewrite-kasan`; rewrite MPP driver decode delivery in DRM-prime/zero-copy mode
> Source: kernel `g67f323aebdf3` (#6, passing) vs `gf37186832202` (#8, failing); the delta is exactly `93e94526a6950` (same-session dispatch order), `3caf851241c24` (hard-CCU IOTLB flush), `f371868322027` (BUS_IDLE before completion) in `drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c`; repro in `~/Code/tmp/ffmpeg-rkrga-regression`
> Date: 2026-08-07
> Trust: MEASURED, PARTIAL

## Result

The 20260807-204828 ffmpeg-suite failures (all five required `*_rkrga` cases,
plus the AV1 RGA diagnostics) are one kernel regression, and it is not pixel
corruption and not an RGA problem. On kernel #8, an `h264_rkmpp` decode with
`-hwaccel_output_format drm_prime` delivers a **bit-exact duplicate of the
previous frame roughly every 4-5 frames and silently drops the real frame**.
Frame-md5 of the 60-frame conformance clip: every output frame is a bit-exact
copy of *some* reference frame (49 unique + 11 duplicates at positions
6,8,18,21,25,29,34,38,42,48,52; the 11 displaced reference frames never
appear). The same command family passed in the 20260806-203117 suite on
kernel #6.

The defect is deterministic, not the 2026-08-07 dispatch-race class:
`-fast_parse 0` (the old race's 0/20 control) reproduces PSNR identical to six
decimals (`average:26.503998`), and repeated runs match exactly. It also has
nothing to do with RGA async fences: `scale_rkrga` at `async_depth=0` scores
the same, and dropping RGA entirely (`hwdownload` of the drm-prime frames to
CPU) shows the identical duplicate pattern. RGA fed CPU-uploaded frames is
clean (avg 39.96 vs swscale reference, min 39.6).

Why the rest of the suite stayed green: the pure-decode PSNR/bit-exact gates
decode to software frames (no `drm_prime`), and that path is clean on #8 —
including 30x repeat-exact under load, so the dispatch-order fix did cure the
old corruption. The GStreamer dmabuf decode cases also passed on this boot, so
zero-copy alone does not trigger it; ffmpeg's frame-holding pattern (filter
pipeline keeps several drm-prime buffers referenced) is part of the trigger.

The driver believes everything succeeded: forbidden counters all zero for the
failing window, `rkvdec_bus_not_idle_count` delta 0, dmesg scan clean, and the
RGA counter profile (540 jobs, 270/270 across rga3 cores, 540 release fences)
is identical between the passing #6 run and the failing #8 run.

## Evidence and reproduction

- **Identity:** ROCK 5B, `6.18.43-video-rewrite-kasan-rockchip64` `#8` `gf37186832202`; ffmpeg-rockchip-81 `git-2026-07-11-844d95e047` (unchanged since Jul 11); MPP `a8b19653`, librga `26a50ef` (unchanged since Aug 5).
- **Exercise:** `ffmpeg -hwaccel rkmpp -hwaccel_output_format drm_prime -c:v h264_rkmpp -i ffmpeg-h264-1920x1080-30fps-2s.h264 -vf hwdownload,format=nv12 -f rawvideo out.yuv`, then `-f framemd5` on the output vs the software reference decode.
- **Pass/fail signal:** duplicate md5 pairs in the output where the reference has 60 distinct frames; stream PSNR vs reference `average:26.50 max:inf` (frame 1 exact, later frames sit at adjacent-frame similarity because they are the previous frame).
- **Differentials:** encoder exonerated (no-encoder path identical); RGA exonerated (`hwupload` source clean); async exonerated (`async_depth=0` identical); parser mode exonerated (`-fast_parse 0` byte-identical).
- **Artifacts:** `~/Code/tmp/ffmpeg-rkrga-regression/` (`cpu1080.yuv`, `corrupt.md5`, `ref.md5`, repro outputs); suite logs `../rock-5b/build/rockchip-conformance/logs/rewrite-kasan/20260807-204828-ffmpeg-suite/`.

## Suspects

The duplicate/drop signature reads as a completion-to-job or
ready-status-to-buffer pairing error, not a memory race. Prime suspect is the
interaction of the new BUS_IDLE completion poll (`f371868322027`) with
back-to-back dual-core completions in the soft-CCU thread — delayed completion
of job N can coalesce with job N+1's ready IRQ, and the thread "completes the
active job off the ready IRQ". The dispatch-order stamp (`93e94526a6950`)
interacting with a buffer-starved session (drm-prime consumers hold buffers,
so decode blocks on pool returns) is the second candidate. Not yet bisected:
all three commits shipped together in #8.

## Boundary

No single-commit attribution yet — that needs three kernel builds (or
revert-boots), which this session did not run. The mechanism above is
signature-based inference, not source-pinned. HEVC was shown failing only
in-suite (same class assumed, not frame-hashed). The
`overlay_rkrga` "Unsupported 'input' pad 1 format: nv12" reinit failure and
the `av1_afbc_rga` zero-frame failure occurred in the same run and are
presumed downstream manifestations, but were not independently root-caused.
GStreamer/librga/MPP suites passing on #8 bounds the blast radius to the
drm-prime frame-delivery path under consumer buffer holding, but the exact
trigger condition (pool size, hold depth, pacing) is uncharacterized.
