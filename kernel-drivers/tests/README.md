# tests/ — on-hardware codec smoke tests

The fast user on-ramp: prove that decode, encode, and full transcode run on real
hardware after installing the kernel and userspace stack. All tests need the
combined kernel booted (see [`../scripts/`](../scripts/README.md)) — i.e. the
four cores under `/proc/mpp_service` plus `/dev/rga` present. On the combined
kernel the two decoder cores appear as `video-codec0/1` (the DT keeps mainline's
node name — see [device-tree guide](../docs/device-tree.md)); the scripts accept
the older `rkvdec-core0/1` naming too.

The heavier rewrite build gate, the external `../rockchip-conformance` bundle,
and the full MPP/librga/GStreamer/FFmpeg conformance-suite reference live in the
sibling [`rewrite-conformance.md`](./rewrite-conformance.md) so this page stays
a clean newcomer on-ramp.

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Prove on real hardware that decode, encode, and full transcode paths work after installing the kernel and userspace stack. |
| Developer focus | Keep each test's isolation clear: decoder-only software inputs, encoder PSNR/fault checks, and FFmpeg transcode paths with no software fallback. The rewrite build gate and conformance suites live in [`rewrite-conformance.md`](./rewrite-conformance.md). |
| Owns | The smoke tests `test-decode.sh`, `encode-test-tiny.sh`, `transcode-test.sh`, `rewrite-smoke.sh`, `abi-probe.sh`/`abi-probe.c`, `abi-replay.sh`, and `librga-smoke.sh`/`librga-smoke.cpp`; the sourced helpers `suite-common.sh` and `debugfs-counters.sh`; the conformance runner/wrappers `rewrite-conformance-run.sh`, `mpp-suite.sh`, `mpp-suite-compare.sh`, `librga-suite.sh`, `librga-suite-compare.sh`, `gstreamer-suite.sh`, `gstreamer-suite-compare.sh`, `ffmpeg-suite.sh`, `ffmpeg-suite-compare.sh`, `debugfs-counter-check.sh`, `rewrite-build-gate.sh`, `suite-compare-selftest.sh` and their build helpers `build-mpp-tests.sh`, `build-librga-samples-full.sh`, `build-gstreamer-rockchip.sh`, `gstreamer-event-harness.c` (all documented in [`rewrite-conformance.md`](./rewrite-conformance.md)); input-regeneration recipes; pass criteria; and observed reference results. |
| Depends on | A validated kernel from [`../scripts/`](../scripts/README.md), staged MPP/FFmpeg artifacts from [`video-libraries/ffmpeg/README.md`](../../video-libraries/ffmpeg/README.md), and device access from the codec udev rule. |
| Current state | H.264/H.265 decode, encode, and full HW transcode have been validated on the forward-port; VP9 decode remains unverified on hardware, but the GStreamer suite now has generated VP9 IVF decode cases, opt-in generated AV1 IVF diagnostics for the separate AV1 backend gap, opt-in generated VP8/H.263/MPEG diagnostics for advertised legacy decoder caps, required generated H.265 Main10 decode/RGA/fallback cases, optional generated H.265 4:2:2 10-bit cases, required GStreamer RGA rotation coverage for 90/180/270-degree public rotation values, diagnostic coverage for advertised H.264 encoder input and decoder output formats, the diagnostic VP8 encoder alias, diagnostic VP8/JPEG encoder property setters, diagnostic JPEG decoder explicit/default output-format cases, diagnostic RFBC caps negotiation via `GST_MPP_DEC_FBC_IS_RFBC=1`, opt-in display sink env cases for `KMSSINK_DISABLE_VSYNC=1`/`GST_RKXIMAGE_USE_COLORKEY=1`, opt-in KMS capture cases for DRM dma-buf import into MPP encode including `GST_KMSSRC_DMA_FEATURE=1`, and `GST_VALIDATE_CASES=1` device-free case-builder validation. The ABI replay now optionally allocates a dma-heap buffer and records non-submit MPP `TRANS_FD_TO_IOVA`/`RELEASE_FD` plus RGA dma-buf import/release behavior for allocator handoff parity. The FFmpeg suite now has `FFMPEG_VALIDATE_CASES=1` dry validation plus required decoder-option, `scale_rkrga` forced-core/async/AFBC-output, and `vpp_rkrga` crop/transpose cases, with diagnostic decoder `afbc=rga` and `overlay_rkrga` alpha composition. `rewrite-conformance-run.sh` now sequences system-info, ABI replay, MPP, librga, GStreamer, FFmpeg, and optional forward-port-vs-rewrite comparison steps for a full profile run. The MPP conformance comparator now has byte-count/SHA-256 artifact comparison for official-test media outputs when the suite dumps decode/encode files, the librga conformance comparator now compares deterministic destination-buffer artifacts from the required direct RGA smoke case, and `debugfs-counter-check.sh` can enforce rewrite counter deltas for selected hardware-start/busy-time gates. The rewrite clean-source object-build gate passed both public rewrite branch tips on 2026-07-04. See [`rewrite-conformance.md`](./rewrite-conformance.md) for the parity/conformance machinery. |

## What each smoke test proves

| Test | Exercises | Pass criterion |
|------|-----------|----------------|
| `test-decode.sh` | **decoder** (`rkvdec2`) | `mpi_dec_test` decodes *software-encoded* H.264 + H.265 320×240 clips to NV12 → exit 0 + non-empty output. Software-encoded input means a failure implicates the **decoder**, not our encoder. |
| `encode-test-tiny.sh` | **encoder** (VEPU580) | `mpi_enc_test` H.264 + H.265 at 256² and 1280×720 → valid NAL-start bitstreams, exit 0, no IOMMU fault (dmesg-marker scheme with a real-fault regex that excludes benign warnings). Reports PSNR + fps. |
| `transcode-test.sh` | **full pipeline** (both decoders, both encoders, RGA ×2) | ffmpeg-rockchip: `h264_rkmpp` → `scale_rkrga` 1080p→720p → `hevc_rkmpp`, then the reverse. `rkmpp`/`rkrga` have no SW fallback, so a pass *is* proof the hardware ran. Verifies each output with `ffprobe`. |
| `rewrite-smoke.sh` | **current `/dev/mpp_service` + `/dev/rga` owner**: forward-port or rewrite | Runs the ABI probe plus decode, encode, and transcode gates above in one pass, and snapshots rewrite debugfs counters, including aggregate/per-core timing counters, when present. Exit `77` means the device nodes are absent on this boot, not that the workload failed. |
| `abi-probe.sh` | **non-submit ABI** on current `/dev/mpp_service` + `/dev/rga` owner | Builds and runs a small C probe that records MPP/RGA ioctl numbers, struct sizes, `/proc/mpp_service` command-advertisement markers when visible, safe query results, MPP client-type HW-ID replay, initialized MPP session controls (`INIT_DRIVER_DATA`, `SEND_CODEC_INFO`, `RESET_SESSION`, and advertised `SET_ERR_REF_HACK`), a safe two-message MPP init batch, `SET_SESSION_FD` bad-fd `mpp_bat_msg.ret = -EBADF` and `MPP_BAT_MSG_DONE` marker handling, optional dma-heap-backed MPP `TRANS_FD_TO_IOVA`/`RELEASE_FD`, RGA version tuples/strings with exact version-query returns including intentional `RGA2_GET_VERSION ret=1`, no-op ioctl return codes, RGA virtual-address and dma-buf import/release, and modern RGA request create/config/cancel with a handle-backed bitblit task. Use the same binary/log format on the forward port and rewrite, then diff the logs. Exit `77` means both device nodes are absent. |
| `abi-replay.sh` | **normalized ABI replay** for a single booted kernel profile | Records raw + normalized ABI logs under `logs/abi-replay/` and a `.contract.log` of the stable query/version and session-control lines. Feeds the raw ABI diff comparison in [`rewrite-conformance.md`](./rewrite-conformance.md) § Raw ABI replay. Exit `77` means the device nodes are absent. |
| `librga-smoke.sh` | **direct librga/im2d functional test** on current `/dev/rga` owner | Builds and runs a tiny C++ client against staged `librga`: virtual-address imports, dma-heap dma-buf allocation plus `importbuffer_fd` copy, legacy `c_RkRgaBlit()` conversions shaped like JeffyCN GStreamer (`BGRx` malloc source to NV12 dma-buf encoder preprocessing, rotated NV12 dma-buf to BGRx dma-buf decode conversion, and planar I420 dma-buf to NV12 dma-buf fallback), official Gaussian matrix blur via `imsetOptGaussianBlurMatrix()` + `imsetOpacity()` + `improcess(..., IM_SYNC | IM_GAUSS)`, sync `imcopy`/`imresize`/`imfill`, forced RGA3 core-mask + priority copy through `improcess`, forced RGA2 `IM_PRE_INTR` read/write line-interrupt copy, and an async acquire/release-fence copy chain waited with `imsync`. Set `LIBRGA_SMOKE_10BIT=1` to add direct IM2D P010->NV12 and P210->NV16 dma-buf conversions through the patched P010/P210 request-generation path. Set `LIBRGA_SMOKE_ARTIFACT_DIR=<dir>` to dump deterministic raw destination buffers for byte-count/SHA-256 comparison. This exercises the maintained librga import/submit/core/fence/pre-intr/gauss/10-bit paths independently of FFmpeg. Exit `77` means `/dev/rga` is absent. |

## Privileges

The smoke tests differ in what device access they need:

| Test | Needs |
|------|-------|
| `abi-probe.sh` | device access only for `/dev/mpp_service` and/or `/dev/rga`; with `/dev/dma_heap/*` access it also records optional dma-buf MPP translate/release and RGA import/release parity |
| `test-decode.sh` | device access only: root, **or** membership in `video` with [`../scripts/99-rockchip-codec.rules`](../scripts/99-rockchip-codec.rules) installed (covers `/dev/mpp_service` **and** `/dev/dma_heap/*` — both required) |
| `librga-smoke.sh` | device access only: root, **or** membership in `video` with the codec udev rule installed (covers `/dev/rga` **and** `/dev/dma_heap/*` — the smoke allocates dma-bufs, imports them with `importbuffer_fd`, runs legacy `c_RkRgaBlit()` GStreamer-style virtual-source, fd-to-fd rotate/convert, and planar fallback conversions, exercises the official `improcess(..., IM_GAUSS)` Gaussian matrix shape, and can opt into P010/P210 IM2D conversions with `LIBRGA_SMOKE_10BIT=1`) |
| `encode-test-tiny.sh` | **root** — writes dmesg markers to `/dev/kmsg` and scans `dmesg` for faults (`kernel.dmesg_restrict=1` on Armbian) |
| `transcode-test.sh` | **root** — runs a `dmesg` fault sweep at the end |

(The conformance-suite scripts have their own privilege table in
[`rewrite-conformance.md`](./rewrite-conformance.md) § Suite privileges.)

> **Paths.** Every dev-box path is an env-overridable variable with the
> original dev-box default. Naming matches [`video-libraries/ffmpeg/README.md`](../../video-libraries/ffmpeg/README.md):
>
> | Var | Used by | Meaning |
> |-----|---------|---------|
> | `MPP_BUILD` | decode, encode | cmake build dir of `rockchip-linux/mpp` (the `<mpp-build>` of the ffmpeg README; build recipe there) — must contain `mpp/librockchip_mpp.so*` and `test/mpi_dec_test` / `test/mpi_enc_test` |
> | `CLIP_DIR` | decode | directory holding `tiny-320x240.h264/.h265` (regeneration below) |
> | `FFDIR` | transcode | ffmpeg-rockchip build dir (`./ffmpeg`, `./ffprobe`) |
> | `STAGE` | transcode | the MPP/RGA staging prefix from the ffmpeg README (e.g. `~/ffmpeg-stack`) |
> | `IN` | transcode | 1080p H.264 Annex-B input (default `$STAGE/testdata/input-1080p.h264`; regeneration below) |
> | `RUN_LIBRGA` | rewrite smoke | optional direct librga/im2d functional smoke (`0` by default; set `1` to run) |
> | `LIBRGA_SMOKE_10BIT` | `librga-smoke.sh` | optional direct P010/P210 IM2D dma-buf conversion cases (`0` by default; set `1` when validating a patched librga/kernel pair) |
> | `LIBRGA_SMOKE_ARTIFACT_DIR` | `librga-smoke.sh` | optional directory for raw destination-buffer dumps; `librga-suite.sh` sets this for its required `ysp_librga_smoke` artifact case |
> | `RUN_GSTREAMER` | rewrite smoke | optional JeffyCN GStreamer plugin suite (`0` by default; set `1` to run) |

## Run

```bash
bash rewrite-smoke.sh                 # one-command gate; use sudo when devices are present
bash abi-probe.sh                     # fast non-submit ABI probe
bash abi-replay.sh                    # record normalized ABI log for this boot
bash librga-smoke.sh                  # direct librga/im2d smoke
LIBRGA_SMOKE_10BIT=1 bash librga-smoke.sh  # add P010/P210 IM2D cases
VALIDATE_ONLY=1 bash rewrite-conformance-run.sh  # device-free conformance wiring check
sudo PROFILE=rewrite bash rewrite-conformance-run.sh  # full profile run on a rewrite boot
bash test-decode.sh                  # decoder (device access is enough)
sudo bash encode-test-tiny.sh        # encoder
sudo bash transcode-test.sh          # end-to-end (needs ffmpeg-rockchip built — see ../ffmpeg)
FFMPEG_VALIDATE_CASES=1 bash ffmpeg-suite.sh  # device-free FFmpeg case-list validation
bash ffmpeg-suite.sh                 # profile/log/comparator FFmpeg conformance
```

For rewrite acceptance in one command:

```bash
sudo MPP_BUILD=<mpp-build> FFDIR=<ffmpeg-rockchip> STAGE=<stage> bash rewrite-smoke.sh
```

The same command is valid on the BSP-derived forward-port kernel, which makes it
the quick parity check between the two implementations.

For the full artifact/timing conformance pass, boot the forward-port kernel and
run:

```bash
sudo PROFILE=forward-port bash rewrite-conformance-run.sh
```

Then boot the rewrite kernel and run:

```bash
sudo PROFILE=rewrite RUN_COMPARE=1 bash rewrite-conformance-run.sh
```

The official-test conformance suites (`mpp-suite.sh`, `librga-suite.sh`,
`gstreamer-suite.sh`), their comparators, the rewrite build gate, and the
external `../rockchip-conformance` bundle are all documented in
[`rewrite-conformance.md`](./rewrite-conformance.md).

## Regenerating the test inputs

The clips are not committed (nothing binary is — see
[`packaging/README.md`](../../packaging/README.md)). Regenerate them anywhere
with a stock ffmpeg that has libx264/libx265 (must be **software** encoders —
that isolation is the point of the decode test):

```bash
ffmpeg -f lavfi -i testsrc2=size=320x240:rate=30:duration=1 -c:v libx264 -pix_fmt yuv420p "$CLIP_DIR/tiny-320x240.h264"
ffmpeg -f lavfi -i testsrc2=size=320x240:rate=30:duration=1 -c:v libx265 -pix_fmt yuv420p "$CLIP_DIR/tiny-320x240.h265"
# transcode input (any 1080p Annex-B H.264 works; 10 s keeps the run short):
ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=30:duration=10 -c:v libx264 -pix_fmt yuv420p "$STAGE/testdata/input-1080p.h264"
```

(The `.h264`/`.h265` extensions select FFmpeg's raw Annex-B muxers; 30 frames
matches the scripts' `-n 30`. The tiny-clip recipes were verified end-to-end
against `test-decode.sh` on the board 2026-07-01; the 1080p recipe is the same
pattern but was not re-run — the original dev-box input was used for the
transcode verification.)

## Coding-type magic numbers

`mpi_dec_test -t` / `mpi_enc_test -t` take a raw `MppCodingType` value, defined
in `inc/rk_type.h` of `rockchip-linux/mpp` (the library
[userspace library guide](../../vendor-libraries/docs/how-the-userspace-libs-work.md) documents):

| Value | Enum | Codec |
|-------|------|-------|
| `7` | `MPP_VIDEO_CodingAVC` | H.264 |
| `10` | `MPP_VIDEO_CodingVP9` | VP9 |
| `16777220` (`0x01000004`) | `MPP_VIDEO_CodingHEVC` | H.265 |

(The jump to `0x01000004` is real: the enum restarts at the Rockchip extension
base `MPP_VIDEO_CodingVC1 = 0x01000000`.)

## VP9 decode

VP9 support is built in the decoder but not yet hardware-validated. For a fully
manual run, `mpi_dec_test` selects its IVF reader by the `.ivf` filename
extension (`utils/mpi_dec_utils.c`), so:

```bash
ffmpeg -f lavfi -i testsrc2=size=320x240:rate=30:duration=1 -c:v libvpx-vp9 -pix_fmt yuv420p -f ivf "$CLIP_DIR/tiny-320x240-vp9.ivf"
LD_LIBRARY_PATH=$MPP_BUILD/mpp $MPP_BUILD/test/mpi_dec_test \
  -i "$CLIP_DIR/tiny-320x240-vp9.ivf" -t 10 -w 320 -h 240 -n 30 -o /tmp/dec_vp9.yuv -v f
```

The suite-driven VP9 cases (generated GStreamer IVF decode and the direct MPP
`mpi_dec_vp9` suite case, which can generate its own IVF input) are documented in
[`rewrite-conformance.md`](./rewrite-conformance.md) § VP9 decode via the suites.
The rewrite branches also carry KUnit coverage for the VP9 RKVDEC fd-to-IOVA
register translation/validation path, so the remaining gap is booted hardware
evidence rather than parser/table coverage.
On the RGA side, the rewrite pins also cover the default legacy
`RGA_BLIT_SYNC` `c_RkRgaBlit()` path used by JeffyCN GStreamer: sync submission
waits for queued completion and leaves async release-fence copy-out untouched.

**UNVERIFIED:** neither the manual recipe, the generated GStreamer VP9 cases, nor
the direct MPP VP9 suite case has a forward-port/rewrite hardware log yet. If you
run any of them, record the result in status.md.

## Observed results (reference)

- decode: 30 frames each H.264/H.265, ~1200–1600 fps @ 320×240 (original run;
  a re-run 2026-07-01 on 6.18.37 #7 passed at 1470/3765 fps — the number varies
  with clip content, the PASS gate is exit code + output size).
- encode: H.264 720p PSNR 53–55 dB @ ~359 fps; H.265 720p PSNR 60–62 dB @ ~297 fps.
- transcode: both directions pass at 17–42× realtime, no faults.

## Skipped / superseded

The early bring-up used a **configfs DT overlay** + an out-of-tree `.ko`
(`load.sh`, `install-boot-overlay.sh`, `probe-only.sh`, `rollback.sh`,
`run-encode-test.sh` in the original tree). That approach is **superseded** by the
built-in combined kernel and is intentionally **not** included here — the overlay
path hit an alias-resolution bug and a configfs-rmdir deadlock (see
[gotchas](../../docs/gotchas.md)). The in-repo scripts have been scrubbed of
the overlay-era instructions they were imported with (2026-07-01). The
standalone `librga-smoke.sh` covers the maintained im2d API directly, including
the official Gaussian matrix `IM_GAUSS` sample shape, plus the legacy
`c_RkRgaBlit()` conversion shapes JeffyCN GStreamer uses for encoder
preprocessing, decode-side fd-backed rotate/format conversion, and planar
fallback. With `LIBRGA_SMOKE_10BIT=1`, it also covers the direct IM2D
P010/P210 request-generation path exported by the local librga patch series; the
full hardware-frame RGA path is still validated through `transcode-test.sh`.
Through `librga-suite.sh`, the same smoke now records deterministic destination
artifacts so rewrite-vs-forward-port comparison can catch byte-level RGA
regressions on maintained direct userspace paths.
