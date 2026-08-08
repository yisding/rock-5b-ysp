# Cross-process RGA3 contention corrupts vpp_rkrga output frames — lead, not root-caused

> Scope: rewrite RGA driver (`rk_rga_rewrite`) RGA3 job isolation under concurrent clients; ffmpeg-rockchip `vpp_rkrga` crop+transpose
> Source: runtime on `6.18.43-video-rewrite-kasan-rockchip64` `#8 gf37186832202`; suite logs `logs/rewrite/20260807-224358-ffmpeg-suite` (vpp `average:12.718429`) and a 22:47 single-case run (`average:13.063727`)
> Date: 2026-08-07
> Trust: MEASURED, PARTIAL

## Result

While validating the overhauled ffmpeg PSNR checkers, the
`ffmpeg_filter_vpp_rkrga_crop_transpose` case (decode → `vpp_rkrga`
crop+transpose on `rga3_core0`, `async_depth=2` → `hevc_rkmpp` encode)
intermittently produced corrupt frames — run averages 12.7 and 13.1 dB with
per-frame min ~6.7 (garbage) and max ~38.5 (clean) against a 38.93 dB clean
baseline. Both corrupt observations occurred **only when a second ffmpeg
suite was running concurrently** on the same hardware, including a second
pipeline forcing the same `rga3_core0` plus decode/encode sessions and CPU
load. The case is deterministic-clean in every serialized context tried:

- 6/6 suite-case runs solo: 38.93 dB.
- 12/12 standalone decode→vpp→encode runs (async_depth 2 and 0): clean.
- 20/20 decode→vpp→hwdownload runs (no encoder; rga3 forced/unforced, rga2,
  async/sync): clean.
- 6/6 with one concurrent scale+encode pipeline on `rga3_core1`: clean.

So neither the encoder, async fences, core selection, nor a single
concurrent RGA client reproduces it; the observed trigger was full
suite-vs-suite contention (multiple MPP decode/encode sessions, two RGA
clients with one forcing the same core, debugfs counter snapshots, and CPU
load spinners at once). No RGA error/timeout/fault counters moved and dmesg
stayed clean in the corrupt windows — jobs "succeeded" while producing wrong
pixels, which suggests per-job context or output isolation on RGA3 breaks
under multi-client scheduling rather than a detected fault.

## Boundary

Not root-caused and no minimal repro yet: the exact contending ingredient
(same-core cross-process interleaving, snapshot reads during active jobs, or
scheduler-level context switching) is unisolated — a targeted repro should
add one ingredient at a time to the clean two-pipeline baseline, starting
with two processes forcing the same RGA3 core. Conformance runs execute one
suite at a time, so the required vpp case is stable in normal use; this is a
stress/robustness defect in the same family the recovery-stress and
reset-contention tooling targets. KASAN was active and silent throughout, so
whatever breaks is contained to job output, not kernel memory safety.
