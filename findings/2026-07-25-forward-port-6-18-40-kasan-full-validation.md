# Forward-port 6.18.40 KASAN validation closes the 0074 and 0075 hardware gates

> Scope: RK3588 codec/RGA forward-port on booted kernel
> `6.18.40-video-port-kasan-rockchip-rk3588 #2`, build marker
> `6.18-rkvenc-fwport`.
>
> Source: on-board validation runs from `/home/yi/Code/rock-5b-ysp`, with
> artifacts under `../rockchip-conformance/logs/forward-port/`.
>
> Date: 2026-07-25 PDT.
>
> Trust: **MEASURED** / **BOOT-VERIFIED** / **KASAN-CLEAN** / **PARTIAL**.

## Result

The booted KASAN forward-port closes the two gates that were still owed after
the 2026-07-24 production run:

- `0074` RGA 10-bit byte-stride and UV-offset behavior is hardware-verified by
  raw ioctl gates on RGA3 and RGA2, plus fresh-librga P010/NV15 im2d probes.
- `0075` RKVENC2 slice-FIFO overflow handling is hardware-verified with the
  aggressive `split_arg=4` H.264/H.265 slice cases and the paired MPP poll-loop
  userspace.

The validation does **not** make a new production-performance claim. This boot
is a KASAN debug build, and broad non-root suite runs could not use `dmesg`
because `kernel.dmesg_restrict` blocks the user; targeted wrappers and root
gates used journal or root windows and had zero fatal kernel flags.

## Boot Identity

- `uname -a`: `Linux rock-5b 6.18.40-video-port-kasan-rockchip-rk3588 #2 SMP PREEMPT Sat, 25 Jul 2026 22:35:13 +0000 aarch64 GNU/Linux`
- `/boot/vmlinuz-6.18.40-video-port-kasan-rockchip-rk3588` md5:
  `3eab94456f2e7bbd033d50c47ac77525`
- `/sys/kernel/notes` sha256:
  `66e0815b10770bdc8ec4352076eacc693d7fc0a39c39b3b50d5a7eb7eda5eac4`
- `/proc/sys/kernel/tainted`: `0`
- `/proc/mpp_service/version`: `6.18-rkvenc-fwport`
- `/proc/mpp_service/supports-device`: AV1DEC, RKVDEC, and RKVENC present.

## Broad Conformance

Full forward-port conformance ran as `RUN_ID=20260725-194940`:

```bash
PROFILE=forward-port FFMPEG_REQUIRE_AV1=1 RUN_CONTINUE_ON_FAIL=1 \
  kernel-drivers/tests/rewrite-conformance-run.sh
```

The broad suite results were:

- ABI replay: pass.
- MPP: 12/12 required cases pass.
- FFmpeg: 24/24 pass, including AV1-required decode/transcode/AFBC/RGA cases
  and diagnostic H.265 Main10 P010 RGA.
- GStreamer: 131/143 total pass. Required failures were
  `generated_transcode_h264_dmabuf_to_h265` and `event_flush_dec_h264`; both
  repeat across the 2026-07-22, 2026-07-24, and 2026-07-25 forward-port runs.
  `generated_transcode_h264_dmabuf_to_h265` fails before preroll with
  `h264parse` reporting `streaming stopped, reason not-negotiated (-4)` for
  the `mppvideodec dma-feature=true ! mpph265enc zero-copy-pkt=true` pipeline.
  `event_flush_dec_h264` sends `FLUSH_START`/`FLUSH_STOP` to `mppvideodec`
  after one buffer and then fails in the userspace event harness with
  `No valid frames decoded before end of stream`, while the sibling H.265 flush
  case passes. The H.265 Main10 chroma gates passed with per-plane PSNR above
  the 20 dB floor.
- librga sample suite: 8/53 pass, 40 fail, 5 missing in the broad
  `20260725-194940` run. Those failures are mixed userspace/environment cases,
  including sample fixture assumptions, missing Android-style uncached DMA
  heaps, and the then-stale installed librga's `imfill` failure.

The non-root broad-suite `dmesg-scan.tsv` files are `unavailable`, not clean
kernel proof, because `dmesg` access was denied. That is why the gates below
carry their own journal or root windows.

## 0075 Slice-FIFO Gate

The bounded overflow gate ran as `20260725-195350-mpp-suite`:

```bash
PROFILE=forward-port MPP_ENC_SPLIT_MODE=2 MPP_ENC_SPLIT_ARG=4 \
MPP_ENC_SPLIT_OUT=1 MPP_ENC_FRAMES=6 MPP_ENC_SLICE_INSTANCES=1 \
MPP_TIMEOUT=120 MPP_REQUIRED_CASES="mpi_enc_h264_slice mpi_enc_h265_slice" \
  kernel-drivers/tests/mpp-suite.sh
```

Both required cases passed:

| case | result |
|------|--------|
| `mpi_enc_h264_slice` | PASS |
| `mpi_enc_h265_slice` | PASS |

The H.264 artifact was 162674 bytes
(`62752d2f27c069de97ce1c3d9bb59aa0e2d50347320bff447652f178d31ba243`).
The H.265 artifact was 110759 bytes
(`403d76c96dee036fee0f25ab55f8a507b3c52f31f21e4e2c259fab86e8165a47`).

The kernel journal contained the expected merge warnings, including
`slice fifo full (256), merged N record(s)` producer lines and matching
`session ... merged N slice record(s)` consumer lines. That proves the run
exercised the overflow path rather than merely avoiding it.

The ordinary KASAN MPP regression suite then ran as
`20260725-195451-kasan-mpp-suite`: all 12 required cases passed with
`flagged_kernel_lines=0`.

## KASAN and Decoder Gates

The narrowed KASAN reproducer passed:

```text
RESULT abi_status=0 flagged_kernel_lines=0 clean=1
out=../rockchip-conformance/logs/forward-port/20260725-195438-kasan-narrowed
```

The full KASAN MPP suite passed all 12 required cases:

```text
RESULT suite_status=0 flagged_kernel_lines=0 clean=1
out=../rockchip-conformance/logs/forward-port/20260725-195451-kasan-mpp-suite
```

Decoder smoke also passed:

- `kernel-drivers/tests/test-decode.sh`: H.264 and H.265 30-frame liveness PASS.
- `kernel-drivers/tests/decode-differential.sh`: H.264, H.265, VP9, and AV1
  hardware-vs-software decode are bit-exact with average PSNR `inf`.

## 0074 RGA 10-Bit Gates

The raw RGA 10-bit gate ran as
`20260725-195821-rga-10bit-gates`. Every case exited 0 and every journal window
had `kernel_flags=0`:

| case | result |
|------|--------|
| `stride-core1` | PASS |
| `stride-core2` | PASS |
| `stride-core4` | PASS |
| `stride-core0` | PASS |
| `uv-core1` | PASS |
| `uv-core2` | PASS |
| `uv-core0` | PASS |

For the UV-offset discriminator, raster compact, raster incompact, tile8x8
compact, and both tightly-sized allocations passed on cores 1, 2, and 0. The
output showed chroma tracking the true byte offset and rejecting the old
pixel-scaled offset:

```text
uv-offset-test: PASS (0 failing checks)
```

The installed librga was stale for the new P010/NV15 probes, so a fresh local
build was made from `../rockchip-userspace/librga-fork` at the current fork tip
and linked into the test binaries. The stale-library failures from
`20260725-195914-rga-im2d-10bit-gates` are discarded as a userspace-version
artifact, not a kernel verdict.

With the fresh library (`rga_api version 1.10.6_[3]`), the current im2d gate ran
as `20260725-200145-rga-im2d-10bit-current-gates`:

| case | result |
|------|--------|
| `p010-default` | PASS |
| `nv15-256` | PASS |
| `nv15-320` | PASS |
| `nv15-1920` | PASS |

P010 -> NV12 reported neutral chroma, P010 -> P010 was bit-exact, and every
NV15 width passed semantic NV15 -> NV12, P010 -> NV15, and NV15 -> NV15
bit-exact checks.

`librga-smoke` with the same fresh library and `LIBRGA_SMOKE_10BIT=1` ran as
`20260725-200254-librga-smoke-10bit-current`. Its 10-bit subcases passed:

- `im2d P010->NV12 ok`
- `im2d P210->NV16 ok`

The whole smoke still exits 1 because its unrelated `imfill` case fails in
`imcheck`; the journal window had `kernel_flags=0`.

After the installed packages were updated to
`librga2`/`librga-dev 2.2.0+git20260725.26a50ef-0ubuntu1~rk1`, the
installed-library smoke was rerun as
`20260725-223424-librga-smoke-10bit-installed` with `LIBRGA_SMOKE_10BIT=1`.
It exited 0: P010 -> NV12, P210 -> NV16, `imresize`, and `imfill` all passed
against `/usr/lib/aarch64-linux-gnu/librga.so`.

A second installed-library smoke, `20260725-224125-librga-smoke-10bit-installed-sudo-dmesg`,
captured `sudo dmesg` before and after the run. The smoke again exited 0, the
suite fatal scan was clean (`fatal_lines=0`), and the focused dmesg window for
the fresh smoke contained only the expected RGA reject lines from unsupported
FBC-tail probes (`no core match` / `request commit failed`), also with
`fatal_lines=0`.

The broad official-sample suite was also rerun against the installed library as
`20260725-223239-librga-suite`; `ysp_librga_smoke` now passed, but the upstream
sample matrix remained red for userspace reasons. A group of demos prints
`running success!` and then exits with status 1 because the samples return the
raw librga `IM_STATUS_SUCCESS` enum (`1`) as the process exit status. Other
demos still fail before submitting work because this boot exposes only
`default_cma_region`, `reserved`, and `system` under `/dev/dma_heap`, while the
sample code opens `system-uncached` or `system-uncached-dma32`.

## Fuzz and Root Gates

The non-submit ioctl fuzz smoke ran as `20260725-200344-ioctl-fuzz-smoke` and
passed with `kernel_flags=0`:

```text
mpp fuzz: calls=256 ok=105 errors=151
rga fuzz: calls=294 ok=223 errors=71 physical=disabled
```

The root gate bundle ran as `20260725-200607-root-gates`:

| gate | result |
|------|--------|
| `encode-test-tiny` | PASS |
| `transcode` | PASS |
| `rga-mmu-debug` | PASS |
| `iommu-machinery-fuzz` | PASS |
| `mpp-debug-capture` | SKIP |
| `vp9-show-existing` | PASS |

Every root-gate window had `kernel_flags=0`. `mpp-debug-capture` skipped with
exit 77 because the rewrite debugfs interface is absent on this forward-port
kernel.

## Boundary

- This is a KASAN correctness and memory-safety validation run, not a production
  performance or soak run.
- Production packaging/rollback still need a separate gate once the 0074/0075
  tail ships in a production build.
- Broad GStreamer still has two required userspace/harness failures, and broad
  librga official-sample coverage is still not green because of sample exit
  status, fixture, and heap assumptions. The installed-librga custom smoke,
  including `imfill` and the 10-bit P010/P210 subcases, is green after the
  `26a50ef` package install and has a clean sudo-dmesg fatal scan.
- The broad non-root suite's `dmesg-scan.tsv` files are unavailable due
  `kernel.dmesg_restrict`; only the KASAN scripts, targeted journal-window
  wrappers, and root-gate windows support kernel-clean claims here.
