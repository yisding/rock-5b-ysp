# Forward-port RKVENC emits intermittently corrupt H.264/HEVC frames with clean kernel logs

> Scope: `kernel-drivers/tests` conformance (`ffmpeg` stage), forward-port BSP
> MPP drivers on the maintained kernel; `rockchip,rkv-encoder-v2-core`
> (`rkvenc-core@fdbd0000`)
> Source: booted `linux-image-ysp-rockchip64`
> `6.18.43+rk3588av1fwport20260808-0ubuntu1~rk1`; MPP
> `1.5.0+git20260805.a8b19653`; librga `2.2.0+git20260725.26a50ef`; suite FFmpeg
> `ffmpeg-rockchip-81` (`git-2026-07-11-844d95e047`, libavcodec 63); DT anchor
> `arch/arm64/boot/dts/rockchip/rk3588-base.dtsi` `rkvenc0:` (~:1538) in
> `../rock-5b/kernel/linux-6.18-rkvenc` @ `d9cbcf21cda1c`
> Date: 2026-08-16
> Trust: MEASURED, BOARD-REPRODUCED, SOURCE-INSPECTED, BOOT-VERIFIED, PARTIAL.
> The cache-maintenance mechanism is MEASURED on 6.18.64 (2026-11-27); no fix
> is applied

## Result

The `forward-port` conformance run rooted at
`../rock-5b/build/rockchip-conformance/logs/forward-port/20260816-151007-*`
failed the required `ffmpeg` stage on exactly two cases,
`system_ffmpeg_encode_h264_options` (PSNR average 26.58) and
`system_ffmpeg_encode_hevc_options` (27.02), against
`FFMPEG_PSNR_THRESHOLD=35`. Every other stage passed, both encodes produced all
60 frames at correct geometry, the bounded kernel log was clean (`status clean`,
`new_lines 0`, `fatal_lines 0`), and every forbidden MPP/RGA debugfs counter
delta was zero.

**The hardware encoder intermittently emits badly wrong frames.** Within a
single 60-frame stream the per-frame PSNR is bimodal: a handful of frames land
at ~44 dB while the rest sit at ~25 dB. The defect is nondeterministic run to
run with byte-identical input and configuration.

The visual signature is distinctive: flat colour fields are reproduced exactly,
while every high-contrast feature (the `testsrc2` diagonal ramp, the grey bar,
the timestamp overlay) **smears horizontally to the right**, as if a run of
macroblocks lost its residual and fell back on left-neighbour prediction. Bad
frames are also *larger* than good ones — the encoder spends more bits and
produces a worse picture.

### What is ruled out

Each of these was tested, not assumed:

| Candidate | Verdict | Evidence |
|---|---|---|
| Checker frame-pairing defect | **ruled out** | `encoded_psnr_against_testsrc` still uses the timestamp-synced path and logs `not matching timebases`, but decoding both legs to raw YUV and comparing frame N to frame N reproduces the suite number to the digit (`24.457497`), with equal frame and byte counts |
| Rate control | **ruled out** | `-rc_mode CQP -qp_init 26` (RC removed) still produces five different bitstreams from identical input: 377–560 KB, 24.4–38.9 dB |
| Reference/recon path | **ruled out** | all-intra (`-g 1`) is still nondeterministic and still bad (27.3 / 34.4 / 28.8 / 41.8 dB) |
| Stale or duplicated input frames | **ruled out** | for every bad frame the best-matching reference is offset 0 — it is the correct frame, encoded wrong |
| The case's encoder option set | **ruled out** | plain `-c:v h264_rkmpp` defaults swing identically (34.7 / 35.5 / 39.8 dB) |
| MPP userspace | **ruled out** | MPP `1375813c` (2026-05-29), extracted from the apt cache and loaded via `LD_LIBRARY_PATH`, shows the same spread (24.8–39.7 dB) as installed `a8b19653` |
| Encoder core overclock | **not supported** | see § Clock below |
| Concurrency | **not a factor** | reproduces solo, nothing else on the board |

### Clock observation

`clk_rkvenc0_core` reads **786431998 Hz**. That is AUPLL (786.432 MHz), and it
is the nearest achievable rate at or below the 800 MHz that
`rockchip,normal-rates` / `assigned-clock-rates` request in the DT node above —
`COMPOSITE(CLK_RKVENC0_CORE, "clk_rkvenc0_core", gpll_cpll_aupll_npll_p, ...)`
in `drivers/clk/rockchip/clk-rk3588.c` (~:1730) offers gpll/cpll/aupll/npll, and
none of the others divide to 800 MHz. So the encoder core is running as the BSP
configures it and **this is not an overclock** — the marginal-clock hypothesis
is disconfirmed as stated.

It does leave one untested coupling worth recording: the video encoder core
clock is parented on the *audio* PLL, so any AUPLL reconfiguration would shift
the encoder clock underneath in-flight jobs. Nothing in this run touches audio,
so this is not offered as the mechanism.

At idle sampling, `aclk_rkvenc0`/`hclk_rkvenc0` were enabled and every
`rkvenc1` clock was gated, which is consistent with only core 0 being in use —
i.e. the encoder-side analogue of the rewrite driver's dual-core dispatch race
is not what is happening here. This is a single idle-time sample, not a
measurement taken during encode.

## Boundary

- **Not attributed to a specific commit.** Two variables moved between the last
  clean forward-port baseline (`20260804-202700`, 46.98 dB, kernel
  `6.18.42+rk3588av1fwport20260804`) and this run: the kernel
  (`.42`→`.43+…20260808`) and MPP (`ad325345`→`a8b19653`). MPP is exonerated
  above, which leaves the kernel — but no kernel A/B has been run, so
  "kernel-side" is an elimination result, not a bisect. Board or silicon state
  is not excluded.
- The kernel release string alone does not discriminate: `6.18.43` appears in
  both clean and dirty historical runs, so those binaries differ.
- Only the H.264 and HEVC RKVENC encode paths were exercised. Decode,
  transcode, RGA and GStreamer cases all passed in the same run.
- The mechanism behind the rightward smear is **not** pinned. Macroblock
  residual loss is the shape of the artifact, not a diagnosed cause; no register
  dump or per-task inspection was taken.
- The AUPLL coupling is source-inspected only and was never provoked.
- `clk_summary` was read once, at idle, after the runs.

## Evidence and reproduction

- **Identity:** ROCK 5B, booted `6.18.43-ysp-rockchip64` from
  `linux-image-ysp-rockchip64 6.18.43+rk3588av1fwport20260808-0ubuntu1~rk1`,
  production configuration (matrix-identity stage confirms `CONFIG_KASAN`,
  `CONFIG_KCSAN`, and both rewrite symbols absent).
- **Detection:** `h264_rkmpp` / `hevc_rkmpp` on `rkvenc-core@fdbd0000`, MPP
  service ABI probe clean in the same run.
- **Exercise:** fixed-QP loop, which removes rate control as a variable:
  ```
  ffmpeg -f lavfi -i "testsrc2=size=640x360:rate=30:duration=2" -pix_fmt nv12 \
    -c:v h264_rkmpp -rc_mode CQP -qp_init 26 -f h264 out.h264
  ```
  compared index-aligned against a raw `testsrc2` reference.
- **Pass/fail signal:** identical input and configuration must yield identical
  output. Observed: five distinct md5s, 377–560 KB, 24.4–38.9 dB. Ten of twelve
  runs of the actual conformance case fell below the 35 dB gate.
- **Negative control:** a constant-colour source
  (`color=c=blue:size=640x360:rate=30:duration=2`) is bit-exact and
  deterministic across runs — 7832 bytes every time, PSNR `inf`. The defect
  requires changing content, which is why a static smoke test will never catch
  it.
- **Artifacts:** `~/Code/tmp/ffmpeg-encode-psnr/` (bitstreams, raw YUV legs,
  extracted good/bad frame PNGs); suite logs and per-frame stats under
  `../rock-5b/build/rockchip-conformance/logs/forward-port/20260816-151007-ffmpeg-suite/`.

## History

This is not new today, but today is the worst instance recorded. The same
per-frame signature is already present in `forward-port/20260722-073958`
(51 of 60 frames below 35 dB) and `20260723-060817` (36 of 60); those runs
passed only because the PSNR gate predates commit 4c37a64. The 2026-08-04
forward-port runs were effectively clean (2 of 60), and every `rewrite` and
`rewrite-kasan` run has landed at ~47 dB. Today: 55 of 60.

So the gate did not become wrong — it became honest, and it is now catching a
defect that earlier forward-port runs were already exhibiting at lower severity.
The severity has also genuinely shifted: no run in the twelve-run loop exceeded
38.2 dB, against the 41–47 dB the 08-04 baseline reached.

## Candidate mechanism: unsynced cached input frames (2026-11-22)

Trust for this section: SOURCE-INSPECTED, HYPOTHESIS. Found by the
2026-11-22 full driver review
([update finding](2026-11-22-forward-port-6-18-64-rebase-and-driver-review.md)).
No runtime test has been run.

The forward-port's dma-buf import cache maps an input buffer, and so cleans the
CPU cache for it, only on first import. A later task that reuses a pooled
buffer (`mpp_dma_import_fd()` finds it and takes only a `kref`) gets no
`DMA_TO_DEVICE` sync from `rkvenc_alloc_task()` or `rkvenc_run()`. The only
sync calls in `mpp_rkvenc2.c` are for the JPEG bitstream, which RK3588 never
reaches. That is verbatim BSP behaviour: the BSP assumes uncached heaps, and
this kernel has only cached `system`, CMA and `reserved` heaps, so MPP falls
back to cached memory.

On the userspace side, suite FFmpeg's `hwcontext_rkmpp.c` defaults to
`MPP_BUFFER_FLAGS_DMA32` without `MPP_BUFFER_FLAGS_CACHABLE`, and it issues
`DMA_BUF_IOCTL_SYNC` only when it requested a cacheable buffer. So neither side
flushes CPU writes to a reused frame buffer, and the encoder can read stale RAM
for lines still dirty in cache.

This fits several recorded symptoms: flat colour is bit-exact, a few good
frames per stream (first use of each pool buffer), larger bad frames with
row-wise artefacts, survival across CQP, all-intra, MPP versions and solo
runs, a clean kernel log, and unaffected decode.

**Weighing against it:** the rewrite MPP driver also reuses session imports
without a per-job sync (`rk_mpp_import_fd()` in `mpp_rewrite.c`), yet rewrite
runs land at ~47 dB. The near-clean 2026-08-04 forward-port run is not
explained either. Treat this as a lead, not a cause.

Cheap discriminating tests, any one of which would settle it:

1. Run the twelve-iteration loop with FFmpeg's `cacheable=1` device option,
   which makes FFmpeg bracket its uploads with `DMA_BUF_IOCTL_SYNC`.
2. Do a resolution sweep. If this is the mechanism, corruption should fall
   sharply once a frame far exceeds the CPU caches (4K).
3. Feed the same raw YUV through MPP's `mpi_enc_test`, which syncs its own
   buffers.

The corresponding fix belongs in userspace (sync whenever the buffer is
actually cached). A kernel-side per-task `DMA_TO_DEVICE` sync would also mask
it, at a per-frame flush cost. Neither is applied.

## Mechanism measured: unsynced cached input frames (2026-11-27)

Trust for this section: MEASURED, BOARD-REPRODUCED on
`6.18.64-ysp-rockchip64` (`0001`–`0107`), FFmpeg `ffmpeg-rockchip-81`
`463f542c32`, MPP `a8b19653`. Not reproduced on any other kernel.

`kernel-drivers/tests/rkvenc-encode-loop.sh` ran the fixed-QP encode above
twelve times in each of three input modes. All three allocate from the same
cached `/dev/dma_heap/system`: MPP tries every `*-uncached` heap first, and
none exists on this kernel (`strace` of `openat`). The `device1` mode differs
from `device0` only in asking FFmpeg for cacheable buffers, which adds exactly
one `DMA_BUF_IOCTL_SYNC` start and end per uploaded frame (240 sync ioctls
against 120 for 60 frames).

| Codec | Mode | Distinct bitstreams | Runs below 35 dB | PSNR average range |
|-------|------|--------------------:|-----------------:|--------------------|
| H.264 | `plain` (as the conformance case) | 12 / 12 | 10 | 24.2–39.7 dB |
| H.264 | `device0` (`cacheable=0`) | 12 / 12 | 11 | 24.3–37.9 dB |
| H.264 | `device1` (`cacheable=1`) | **1 / 12** | **0** | **48.53 dB every run** |
| HEVC | `plain` | 12 / 12 | 10 | 25.0–36.7 dB |
| HEVC | `device0` | 12 / 12 | 8 | 24.6–40.4 dB |
| HEVC | `device1` | **1 / 12** | **0** | **46.22 dB every run** |

Flushing the CPU's writes to each input frame before the encoder reads it
turns a nondeterministic, mostly failing encode into a byte-identical one
well above the gate, on both codecs. So the corruption is the encoder reading
input frames whose newest contents are still in the CPU cache. The
`device0`/`device1` pair rules out the change of code path as the cause.

Still open:

- **Why the rewrite measured ~47 dB.** Its `rk_mpp_import_fd()` also returns a
  reused import without a sync, and the rewrite runs used the same cached
  heaps and userspace. Something in that path keeps frames coherent, or those
  runs did not reuse buffers the same way. Not investigated.
- **Where the bug originated.** On the vendor BSP kernel MPP would get an
  uncached heap and need no flush; that kernel has not been measured.
- **The fix.** The narrowest one is in FFmpeg: sync around every CPU upload
  regardless of the cacheable flag it requested, since the allocator can
  hand back cached memory anyway. A kernel-side per-task `DMA_TO_DEVICE` sync
  on the import-cache hit would cover every client at a per-frame cost.
  Neither is applied; `cacheable=1` is a working stopgap for FFmpeg users.
- Artifacts: `~/Code/tmp/rkvenc-heap/loop12-h264` and `loop12-hevc` (local,
  disposable).

## Verification gate

Run the same twelve-iteration fixed-QP loop on a second forward-port kernel and
compare the spread. Two boots answer different questions, and the *forward* one
does not substitute for the backward one:

- **Forward — `6.18.44` (the operator's pending upgrade).** Tells you whether
  the defect still reproduces on the current tip. A clean result closes the
  operational question but does **not** identify what fixed it, because the
  `.43`→`.44` delta is not scoped to anything implicated here.
- **Backward — `6.18.42+rk3588av1fwport20260804`, the last measured-clean
  baseline.** This is the discriminating boot. If the spread collapses there and
  every run lands above 40 dB, the defect is a kernel regression between
  `.42+20260804` and `.43+20260808` and is bisectable from there; if the spread
  persists, the kernel is exonerated too and the remaining suspects are board or
  silicon state.

Record the twelve PSNR values either way — a single passing run does not close
this, because 2 of 12 runs cleared the gate even on the worst-observed boot.

Until that A/B runs, `system_ffmpeg_encode_h264_options` and
`system_ffmpeg_encode_hevc_options` should stay required — they are reporting a
real defect, and lowering `FFMPEG_PSNR_THRESHOLD` would only hide it.

## Why it matters

Hardware encode is silently lossy on the forward-port target under ordinary
settings, with no kernel diagnostic of any kind. Anything that encodes on this
kernel — the desktop-app HW video work, transcode pipelines, screen capture —
is exposed, and because flat content encodes perfectly, the failure will not
show up in a smoke test or a static screenshot. It only appears on moving,
detailed content, which is exactly the workload that matters.
