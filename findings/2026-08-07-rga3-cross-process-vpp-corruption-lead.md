# RGA3 vpp_rkrga output corruption — first seen cross-process, now reproduced solo; not root-caused

> Scope: rewrite RGA driver (`rk_rga_rewrite`) RGA3 job isolation; ffmpeg-rockchip `vpp_rkrga` crop+transpose
> Source: runtime on `6.18.43-video-rewrite-kasan-rockchip64` `#8 gf37186832202`; suite logs `logs/rewrite/20260807-224358-ffmpeg-suite` (vpp `average:12.718429`) and a 22:47 single-case run (`average:13.063727`); solo full-conformance repros `20260807-204828-ffmpeg-suite` (`average:8.558860`) and `20260808-081340-ffmpeg-suite` (`average:12.479600`)
> Date: 2026-08-07 (updated 2026-08-08)
> Trust: MEASURED, PARTIAL; concurrency-necessity **FALSIFIED** 2026-08-08

> **Corrected 2026-08-08 — the concurrency-necessary premise is falsified.** The
> vpp case reproduced this corruption in two consecutive **solo** full
> `run-conformance.sh` runs, with no second suite and no concurrent ffmpeg case:
> the runner executes suites sequentially and `ffmpeg-suite.sh` executes cases
> sequentially (`:1707-1713`), and the only case that backgrounds anything is the
> h264 repeat-exact case spinning CPU, not an RGA client. `20260807-204828`
> scored `average:8.56` (min 8.50 / max 8.64 — every frame trashed);
> `20260808-081340` scored `average:12.48` (min 6.33 / max 38.48 — mixed
> clean/garbage). dmesg was clean both times. Cross-process contention is
> therefore **not necessary**; it is at most a rate amplifier, and the "6/6 clean
> solo" / "only under suite-vs-suite contention" claims below did not survive.
> The defect is an intermittent single-client RGA3 job-output isolation failure.
> With the transform-aware reference now in place (checker fix `4c37a64`), a
> working run scores ~38.9 dB, so these 6–12 dB results are genuine driver output
> corruption, not the old checker-geometry artifact. Leading refined hypothesis:
> the victim's own `async_depth=2` pipelining (two of its jobs in flight on
> `rga3_core0`) is the minimal contended condition — the revised
> [contention-harness plan](2026-08-08-rga3-cross-process-contention-harness-plan.md)
> makes a solo victim loop with an `async_depth` bisection its first experiment.

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

Not root-caused and no minimal repro yet, but the search space narrowed as of
2026-08-08: the corruption fires **single-client**, so the trigger is not
cross-process interleaving. The bisection now starts from a solo victim loop and
asks whether the case's own `async_depth=2` pipelining is sufficient (toggle it
to 0), before adding any second client; contention is tested as a rate
amplifier, not a prerequisite. The earlier "clean serialized" runs — 6/6 solo,
12/12 standalone `async_depth 2`/`0`, 20/20 hwdownload — are now read as an
intermittent bug that happened to miss, not as evidence of a concurrency gate;
the required vpp case is **no longer stable in normal conformance** (it failed
the last two full runs). KASAN was active and silent throughout, so whatever
breaks is contained to job output, not kernel memory safety. This is a
stress/robustness defect in the same family the recovery-stress and
reset-contention tooling targets.
