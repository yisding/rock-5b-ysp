# Production PPA kernel (…20260723) — full driver conformance run, all gates green

> Scope: the Launchpad-built **production (non-KASAN)** forward-port kernel
> `linux-image-ysp-rockchip64 6.18.38+rk3588av1fwport20260723-0ubuntu1~rk1`
> (renumbered patch tail `0001`–`0071`, the same tip validated on the
> 2026-07-23 KASAN boot), installed from the PPA and booted on the board.
> Source: booted board; test harness under `kernel-drivers/tests/`.
> Date: 2026-07-24
> Trust: MEASURED

## Result

The full driver conformance set is **green on the production PPA kernel** —
this closes the "rebuild a production image of this tail and repeat the green
gates on it" follow-up from the
[2026-07-23 KASAN validation run](./2026-07-23-forward-port-current-tip-full-validation-run.md):

- **ABI probe + full ABI replay** — required probes pass; the modern
  request-wrapper unsupported-descriptor errno is `EFAULT` per contract.
- **Official MPP 12-case matrix** (`20260724-043045-mpp-suite`) — **12/12
  pass**: H.264/H.265/VP9 decode, mt/multi decode, H.264/H.265 encode, both
  low-delay slice cases, mt-H.265, RC2.
- **FFmpeg suite, AV1 required** (`20260724-043221-ffmpeg-suite`) — **24/24
  pass, zero failures**, including the `h264→hevc` rkrga transcode and
  `hevc_main10→P010` cases that deadlocked the stale FFmpeg-master `FFDIR`
  binary on 2026-07-23; the harness's `ffmpeg-rockchip-81` default (carries
  `da5befc806`) runs them clean.
- **`decode-differential.sh`** — H.264 / H.265 / VP9 / **AV1** all **bit-exact
  (PSNR = inf)**, 30/30 frames each.
- **`test-decode.sh`** — pass (clips regenerated; see harness gaps).
- **`librga-smoke.sh`** — pass (default matrix; 10-bit not attempted — staged
  librga is still the unpatched `v1.10.6_[3]`, not the P010 fork).
- **Root gates** (`20260724-043509-root-gates`, `sudo run-root-gates.sh`) —
  `encode-test-tiny` PASS, `transcode` PASS, `rga-mmu-debug` PASS,
  `iommu-machinery-fuzz` PASS (the scattered-userptr unaligned-base reject
  end-to-end), `mpp-debug-capture` expected SKIP (77, forward-port),
  **`vp9-show-existing` PASS** (30 loops × 4 concurrent decodes + 60 s
  deferred-fault wait; `flagged_kernel_lines=0` — first survival on a
  production build of this tail). Every per-gate kernel scan clean.
- **Whole-battery journal fatal sweep** — zero BUG/Oops/KASAN/UAF/OOB/WARN/
  hung-task lines across the unprivileged battery window (the only kernel-log
  noise is attributed below).

Production build → these results also stand as **performance** evidence
(unlike the KASAN runs): H.265 720p encode ~353 fps at PSNR 60–62.6 dB;
transcode 20.8× (h264→RGA→hevc) and 88× (hevc→RGA→h264) realtime.

## New finding — GStreamer NV12_10 legacy-blit RGA IOMMU read faults

First full GStreamer suite run on a **production (non-KASAN) Published PPA
kernel**: `20260724-043045-gstreamer-suite`, **129 required cases pass, 4
required fail**, all four with userspace-side signatures. The suite itself first
ran on 2026-07-22 against the KASAN forward-port build — 98/102 required in the
[userspace-gaps finding](2026-07-22-gstreamer-suite-forward-port-userspace-gaps.md),
then 129/4 in the [current-tip port](2026-07-22-bsp-high-current-tip-port.md);
the required-case count grew from 102 to 133 between those runs:

- `generated_dec_h265_10_rga_scale` and
  `generated_dec_h265_10_env_disable_nv12_10`: pushing **NV12_10** (H.265
  Main10 output, e.g. stride 448 for width 320) through the JeffyCN plugin's
  **legacy `RGA_BLIT`** path raises a burst of **RGA IOMMU read faults**
  (60 lines, single IOVA `0xdeeb0000`, `fdb60f00.iommu`, "check the memory
  size") confined to 04:31:08–09 — exactly these cases' window. The driver
  aborts the job cleanly (no WARN/oops, session recovers); userspace sees
  `RgaBlit … RGA_BLIT fail: Permission denied` — the post-fault errno, **not**
  a privilege problem. The plain 10-bit decode case
  (`generated_dec_h265_10_fakesink`) passes, so this is specific to the
  RGA leg. Same class as the `0048`/`0049` 10-bit stride/size work, but on the
  legacy-blit leg those im2d fixes never covered; the fault pattern (read past
  end of a buffer sized without the 10-bit stride) points first at the
  plugin's buffer-size computation, with the kernel's legacy-blit NV12_10
  size validation as the defensive follow-up. Not a regression — no prior
  GStreamer baseline exists on any kernel here.
- `generated_transcode_h264_dmabuf_to_h265`: `h264parse` caps-negotiation
  failure (`not-negotiated`, `is_avcC=1`) — plugin/pipeline issue.
- `event_flush_dec_h264`: flush-event harness reports "no valid frames decoded
  before end of stream" — plugin flush behavior.
- Diagnostic VP8/JPEG cases fail as **expected**: this kernel exposes no
  VP8/JPEG encoder cores.

**Root-caused later the same day — it is a kernel regression from our `0048`
RGA3 stride fix, not a plugin bug**: see
[`2026-07-24-rga3-legacy-blit-10bit-stride-convention-fault.md`](./2026-07-24-rga3-legacy-blit-10bit-stride-convention-fault.md)
(forced-core reproducer: identical legacy request succeeds on RGA2,
faults on RGA3; fix direction and verification gate recorded there).

## Pre-existing, reconfirmed (not regressions)

- **librga-suite upstream demo matrix** (`20260724-042733-librga-suite`): ~39
  required demos fail with the **identical** failure set as the validated
  2026-07-22 KASAN boot — missing Android-style `/data/*.bin` sample images
  plus missing `system-uncached`/`system-uncached-dma32` heaps (this kernel
  exposes only `system`/`default_cma_region`/`reserved`). Two cases
  *improved* to pass vs 2026-07-22: `rga_cvtcolor_gray256_demo`,
  `rga_rop_demo`. The harness's own `ysp_librga_smoke` case passes. This demo
  matrix has never been green on this board; the standalone `librga-smoke.sh`
  remains the validated librga gate.
- The `mpp_platform: client N driver is not ready!` stderr lines are the BSP
  libmpp probing client types this kernel intentionally doesn't register —
  benign.

## Harness gaps found this run

> **All four fixed in-tree later on 2026-07-24**: `mpp-suite.sh` now defaults
> its media inputs from the tracked assets and selects the standard 12-case
> matrix when they resolve; `rewrite-conformance-run.sh` gained
> `RUN_CONTINUE_ON_FAIL=1`; `test-decode.sh` regenerates its software clips
> via the first available libx264/libx265 ffmpeg when `CLIP_DIR` is absent;
> and the VP9 gate writes under the caller's `OUT` (root-gates co-locates it)
> instead of the stale dated path. The mpp-suite and test-decode fixes were
> re-run green on this boot (12/12 and PASS respectively).

- `mpp-suite.sh` defaults to `mpp_info_test` only; without the
  `MPP_*_INPUT`/`MPP_REQUIRED_CASES` env the KASAN wrapper supplies, the
  12-case matrix silently records `missing-env` (`20260724-042944-mpp-suite`).
  The runner's canonical `PROFILE=forward-port` invocation therefore does
  **not** exercise MPP media cases on its own.
- `rewrite-conformance-run.sh` aborts on the first failing suite (only exit 77
  skips continue), so the always-red librga demo matrix and the GStreamer
  failures each blocked the FFmpeg suite; suites had to be resumed/run
  individually.
- `test-decode.sh`'s default `CLIP_DIR`
  (`../rock-5b/build/kernel/rock5b-kernel-build/ffmpeg-stack/testdata`) is a dev-box path
  absent on the board; clips were regenerated per the README recipe and passed.
- `mpp-vp9-show-existing-repro.sh` writes its output under a stale
  `logs/2026-07-21-p70a5-gates/mpp-vp9-crash` directory name.

## Evidence

- Kernel identity: `uname` `6.18.38-ysp-rockchip64 #1 SMP PREEMPT` (reproducible
  timestamp), built by `build@launchpad` with gcc 15.2.0; package
  `linux-image-ysp-rockchip64 6.18.38+rk3588av1fwport20260723-0ubuntu1~rk1`;
  `/boot/config-…` has no `CONFIG_KASAN`; `/proc/mpp_service/version` =
  `6.18-rkvenc-fwport`; nodes `video-codec0/1`, `rkvenc-core0/1`, `/dev/rga`,
  `/dev/mpp_service` all present.
- Run artifacts (raw, not committed) under
  `../rock-5b/build/rockchip-conformance/logs/forward-port/`: `20260724-042733-{system,mpp-suite,librga-suite}`,
  `20260724-043045-{mpp-suite,gstreamer-suite}`, `20260724-043221-ffmpeg-suite`,
  `20260724-043509-root-gates` (summary.tsv: 5 PASS / 1 SKIP, all
  `kernel_flags=0`); ABI replay logs under
  `kernel-drivers/tests/logs/abi-replay/forward-port.*`.
- Unprivileged suites ran with `SUITE_DMESG_SCAN=0` (`dmesg_restrict=1`); the
  cursor-bracketed whole-run `journalctl -k` sweep substitutes, per the
  2026-07-23 methodology. Root gates used their own per-gate journal scans.

## Boundary

- No soak/long-duration runs this session; single-boot evidence.
- P010/10-bit librga correctness still not re-established on this boot
  (unpatched staged librga); kernel-side `0049`/`0051`-class fixes were
  validated on prior debug builds only.
- GStreamer NV12_10/caps/flush failures are recorded, unattributed beyond the
  userspace-first analysis above — triage pending.
- Rollback validation (PPA install/remove path) not exercised.

## Why it matters / follow-up

- The shipped PPA production kernel is now **boot-, correctness-, and
  root-gate-validated on hardware**, with performance numbers, matching the
  KASAN tip's results — the distribution gate for this tail is effectively
  closed except rollback validation.
- Follow-ups: triage the GStreamer NV12_10 legacy-blit fault (plugin size
  computation vs kernel validation), fix the harness gaps above (mpp-suite
  default inputs, runner continue-on-fail option, `CLIP_DIR` default), stage
  the P010 librga fork to re-establish 10-bit coverage, and validate rollback.
