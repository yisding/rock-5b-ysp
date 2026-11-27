# Forward-port 6.18.64 production conformance passes except the known H.264 encode corruption

> Scope: kernel forward port, `0001`–`0107` on Linux 6.18.64, through the
> standard `run-conformance.sh` set; `kernel-drivers/tests/mpp-suite.sh`,
> `ffmpeg-suite.sh`, `rkmppenc-suite.sh`, `suite-common.sh`
> Source: PPA package `linux-image-ysp-rockchip64`
> `6.18.64+rk3588av1fwport20261122-0ubuntu1~rk1` (series tip `9fb65e963624`,
> `linux-rock5b:rk3588-video-6.18`); harness at ysp `260bb8c`, `d23d3cc`,
> `46d7eee`
> Date: 2026-11-27
> Trust: MEASURED on the board, production configuration only,
> FIX-RUNTIME-VERIFIED for the harness fixes, PARTIAL. One run per suite.

## Result

On the installed and booted 6.18.64 forward-port, the standard conformance set
passes every stage except FFmpeg, whose single failure is the known
intermittent RKVENC H.264 corruption:

| Stage | Result | Detail |
|-------|--------|--------|
| `system-info`, `matrix-identity`, `abi` | pass | Target and configuration autodetected as `forward-port` / `production`. |
| `mpp` | pass | 12 of 12 required: info, H.264/H.265/VP9 decode, multi-thread and multi-instance decode, H.264/H.265 encode with and without slices, multi-thread HEVC encode, H.264 rate control. |
| `librga` | pass | 31 of 31 required. Diagnostic: 1 `log-fail` (`rga_allocator_drm_phy_demo`), 5 samples not built for this platform. |
| `gstreamer` | pass on re-run | 103 of 103 required; 31 diagnostic pass, 10 diagnostic fail (VP8 and JPEG encoders, which RK3588 does not offer). |
| `ffmpeg` | **fail** | 13 of 14 required; all 11 diagnostic cases pass, including the AV1 decode, AFBC and transcode cases. |

Every suite's kernel-log scan was clean. The FFmpeg stage added no kernel-log
lines at all. The counter checks are empty here because the forward-port
exposes none of the rewrite's debugfs counters.

### The FFmpeg failure is the RKVENC encode corruption

`system_ffmpeg_encode_h264_options` measured PSNR y 35.15, u 30.57, v 27.74,
**average 32.00 dB, minimum 25.26 dB**, against the suite's 35 dB gate. Its
HEVC twin, `system_ffmpeg_encode_hevc_options`, passed in the same run at
average 41.81 dB (minimum 31.53). A clean kernel log, one codec failing while
the other passes, and chroma well below luma all match the
[RKVENC encode-corruption finding](2026-08-16-forward-port-rkvenc-intermittent-encode-corruption.md).
So the defect survives the 6.18.64 rebase and `0098`–`0107`. A twelve-run
loop later the same day measured its rate and cause: 10 of 12 H.264 and
10 of 12 HEVC encodes failed, and all 12 became byte-identical and clean once
FFmpeg synced each input frame. That result lives in the RKVENC finding's
"Mechanism measured" section.

### Getting a valid run took three harness fixes

The first attempt, from an interactive terminal on a conformance workspace
that had been wiped, could not have produced a verdict:

1. **The FFmpeg input generators hung forever** (`260bb8c`). `run_generator`
   in `ffmpeg-suite.sh` and `rkmppenc-suite.sh` called the software `ffmpeg`
   under `timeout` without `-nostdin`. `timeout` puts its child in a background
   process group, so ffmpeg's terminal read stopped the group with SIGTTIN,
   `timeout` included, and its limit never fired. Earlier runs had no terminal
   attached.
2. **The MPP stage passed with 2 of its 12 cases** (`d23d3cc`). The suite only
   required the H.264, H.265, encode, slice, multi-instance and rate-control
   cases when their input files already existed. It now generates those
   inputs when they are missing (640x480 `testsrc2`, 150 frames, GOP 15;
   120 frames of 1280x720 NV12), keeps the cases required either way, and
   returns the files to the invoking user after a `sudo` run.
3. **The GStreamer stage failed on a desktop log line** (`46d7eee`). The
   shared kernel-log scan is case-insensitive, so its `WARNING:` pattern
   matched net/wireless's lowercase
   `` warning: `ThreadPoolForeg' uses wireless extensions ... ``, printed when
   a browser thread read Wi-Fi statistics during the run. `SUITE_DMESG_BENIGN_RE`
   now drops that exact line from the fatal matches; the selftest checks that
   a real `WARNING: CPU:` beside it still fails. The line did not recur in the
   GStreamer re-run, so the filter is verified by the selftest, not on the
   board.

## Evidence and reproduction

- **Identity:** ROCK 5B, SPI → NVMe, `6.18.64-ysp-rockchip64` (Launchpad
  build), booted 2026-11-22 10:24 PST. Userspace: `librockchip-mpp1` and
  `rockchip-mpp-demos` `1.5.0+git20260805.a8b19653+ds-0ubuntu1~rk1`, `librga2`
  `2.2.0+git20260725.26a50ef-0ubuntu1~rk1`, FFmpeg `ffmpeg-rockchip-81` at
  `463f542c32`. Conformance sources at the `MANIFEST.tsv` pins.
- **Setup:** `bootstrap-sources.sh bootstrap` run from a copy of
  `kernel-drivers/tests/conformance/{scripts,MANIFEST.tsv,patches}` placed in
  `../rock-5b/build/rockchip-conformance`. The script fetches next to itself,
  while the build scripts look in the workspace; that mismatch is not fixed.
  Then `build-librga-samples-full.sh`, `build-mpp-tests.sh` and
  `build-gstreamer-rockchip.sh`, with `PATH=/usr/sbin:/usr/bin:/sbin:/bin` and
  `PKG_CONFIG=/usr/bin/pkg-config`.
- **Exercise:**
  `sudo PATH=/usr/sbin:/usr/bin:/sbin:/bin PKG_CONFIG=/usr/bin/pkg-config KERNEL_UAPI=… KERNEL_ARCH_UAPI=… bash kernel-drivers/tests/run-conformance.sh --target forward-port --configuration production --continue < /dev/null`,
  then the same with `--only gstreamer` after `46d7eee`. `KERNEL_UAPI` and
  `KERNEL_ARCH_UAPI` point at `/usr/src/linux-headers-6.18.64-ysp-rockchip64`
  because the ioctl fuzzer's default headers are the rewrite tree's, which
  lacks `linux/rk-mpp.h`. Device-free `--validate` passed every stage with the
  same environment.
- **Pass/fail signal:** per-stage `RESULT` lines and each suite's
  `summary.tsv` and `dmesg-scan.tsv`.
- **Artifacts:** run `20261127-133636` and GStreamer re-run `20261127-144521`
  under `../rock-5b/build/rockchip-conformance/logs/forward-port/`. Local and
  disposable; not committed.

## Boundary

- Production configuration only. No KASAN/lockdep build of this tail was run,
  and none of the hostile, fault-admission, alias-staging or soft-CCU gates.
- gray256 and the two historically intermittent RGA2 USERPTR samples were not
  run as their own repeated gate.
- One iteration per case. A pass here does not exclude an intermittent defect;
  the H.264 failure rate on this kernel is unmeasured.
- No paired comparison against an earlier forward-port or the rewrite.
