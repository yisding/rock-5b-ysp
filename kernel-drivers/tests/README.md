# tests/

On-hardware smoke tests. All need the combined kernel booted (see
[`../scripts/`](../scripts/README.md)) — i.e. the four cores under
`/proc/mpp_service` plus `/dev/rga` present. On the combined kernel the two
decoder cores appear as `video-codec0/1` (the DT keeps mainline's node name —
see [device-tree guide](../docs/device-tree.md)); the scripts accept the older
`rkvdec-core0/1` naming too.

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Prove on real hardware that decode, encode, and full transcode paths work after installing the kernel and userspace stack. |
| Developer focus | Keep each test's isolation clear: decoder-only software inputs, encoder PSNR/fault checks, and FFmpeg transcode paths with no software fallback. |
| Owns | `abi-probe.sh`, `abi-probe.c`, `librga-smoke.sh`, `librga-smoke.cpp`, `test-decode.sh`, `encode-test-tiny.sh`, `transcode-test.sh`, `rewrite-smoke.sh`, input-regeneration recipes, pass criteria, and observed reference results. |
| Depends on | A validated kernel from [`../scripts/`](../scripts/README.md), staged MPP/FFmpeg artifacts from [`../ffmpeg/`](../../ffmpeg/README.md), and device access from the codec udev rule. |
| Current state | H.264/H.265 decode, encode, and full HW transcode have been validated on the forward-port; VP9 decode remains an unverified recipe. A broader conformance bundle now exists beside the kernel trees for rewrite-vs-forward-port comparison; see "Expanded conformance bundle" below. |

## Expanded conformance bundle

The narrow in-repo tests are still the fast gate. For rewrite parity work, also
use the external bundle at the dev-box path `../rockchip-conformance`
(`/home/yi/Code/rockchip-conformance`). It is intentionally outside this repo
because it contains shallow third-party source checkouts and generated build/log
directories. Its own `README.md` is the operational guide; this section records
why each piece matters and what we learned to test.

Run it the same way under both kernels:

```bash
cd ../rockchip-conformance
PROFILE=rewrite ./scripts/collect-system-info.sh
# build on the RK3588 target userspace, then run smoke/real media cases
PROFILE=rewrite ./scripts/run-mpp-smoke.sh
PROFILE=rewrite ./scripts/run-librga-smoke.sh
PROFILE=rewrite ./scripts/run-gstreamer-smoke.sh

# reboot into the BSP forward-port kernel and repeat:
PROFILE=forward-port ./scripts/collect-system-info.sh
PROFILE=forward-port ./scripts/run-mpp-smoke.sh
PROFILE=forward-port ./scripts/run-librga-smoke.sh
PROFILE=forward-port ./scripts/run-gstreamer-smoke.sh
```

The important rule is that `assets/` and command lines stay identical between
the rewrite and forward-port runs, with only `PROFILE` and the booted kernel
changing. Compare `logs/rewrite/` against `logs/forward-port/`.

| Bundle component | What it is | Why it belongs in conformance |
|------------------|------------|-------------------------------|
| `sources/jeffycn-gstreamer-rockchip` | JeffyCN's `gstreamer-rockchip` branch from `JeffyCN/mirrors` | Highest-value new target beyond FFmpeg/rkmpp/librga. GStreamer stresses MPP/RGA through caps negotiation, buffer pools, pipeline state changes, EOS/flush/seek/restart, dmabuf allocator negotiation, KMS/Wayland sinks, and multi-stream scheduling. |
| `sources/rockchip-mpp` | Rockchip MPP library and official `test/` programs | Gives the canonical `mpp_info_test`, `mpi_dec_test`, `mpi_dec_mt_test`, `mpi_dec_multi_test`, `mpi_enc_test`, `mpi_enc_mt_test`, `mpi_rc2_test`, and `vpu_api_test` binaries. These hit sync/async decode, multi-instance and multi-thread paths, rate-control config, event/control paths, and the legacy VPU API more directly than FFmpeg. |
| `sources/airockchip-librga` | Official librga repo and IM2D sample suite | Must be run as a *suite*, not just a copy/resize smoke. It covers allocator modes, async jobs, FBC/tile copies, alpha/colorkey/OSD, CSC, fill arrays, mosaic, ROP, transform, crop, resize, and padding. These map almost exactly to the rewrite's remaining RGA feature boundaries. |
| `sources/mpp-linux-cpp-demo` | Linux MPP/RGA/DRM demo | Useful integration smoke because it chains MPP decode, RGA conversion, DRM display, and threading in one app. |
| `sources/rkmediacodec-demo` | Android RKMediaCodecDemo | Lower priority for Linux, but it is the Android-style MediaCodec/allocator path to run if Android compatibility matters. The earlier request called this RKMediaCoreDemo; the public Rockchip demo we found and staged is RKMediaCodecDemo. |

Suggested expanded matrix:

- MPP: H.264/H.265 decode at 1080p/4K, H.264/H.265 encode from NV12 at
  1080p/4K, multi-instance decode, multi-thread encode/decode, rate-control,
  and `vpu_api_test`. VP9 remains a useful add-on because the forward-port docs
  still mark it unverified.
- RGA: `copy`, `resize`, `cvtcolor`, `fill`, `alpha`, `transform`, `async`, and
  allocator samples first; then deliberately run `rop`, `mosaic`, `padding`,
  FBC/tile, colorkey/OSD, and 10-bit/compressed cases to distinguish clean
  `-EOPNOTSUPP` from real regressions.
- GStreamer: decode to `fakesink`, decode to KMS/Wayland display, raw NV12
  encode, transcode `decode -> convert/scale -> encode`, multi-stream jobs,
  stop/seek/EOS/restart loops, and dmabuf zero-copy paths where the sink/source
  supports them.

The expected rewrite result is not universal pass today. For implemented paths,
it should match the forward-port. For documented unsupported RGA profiles, it
should fail cleanly, preferably with `-EOPNOTSUPP`, without kernel warnings,
hangs, leaked fences, IOMMU fault storms, or stale async completions.

For RGA scheduler/core-routing validation, also capture the rewrite debugfs
counters under `/sys/kernel/debug/rk_rga_rewrite/` before and after forced-core
and mixed RGA2/RGA3 runs. The current rewrite exposes total scheduled,
dispatched, and hardware-started job counts plus per-core counters for
`rga3_core0`, `rga3_core1`, `rga2_core0`, and `rga2_core1`; those counters are
the lightweight replacement for carrying the BSP debugger ABI just to confirm
load balancing and `rga_req.core` routing.

**Privileges** (this differs per test):

| Test | Needs |
|------|-------|
| `test-decode.sh` | device access only: root, **or** membership in `video` with [`../scripts/99-rockchip-codec.rules`](../scripts/99-rockchip-codec.rules) installed (covers `/dev/mpp_service` **and** `/dev/dma_heap/*` — both required) |
| `encode-test-tiny.sh` | **root** — writes dmesg markers to `/dev/kmsg` and scans `dmesg` for faults (`kernel.dmesg_restrict=1` on Armbian) |
| `transcode-test.sh` | **root** — runs a `dmesg` fault sweep at the end |

> **Paths.** Every dev-box path is now an env-overridable variable with the
> original dev-box default. Naming matches [`../ffmpeg/README.md`](../../ffmpeg/README.md):
>
> | Var | Used by | Meaning |
> |-----|---------|---------|
> | `MPP_BUILD` | decode, encode | cmake build dir of `rockchip-linux/mpp` (the `<mpp-build>` of the ffmpeg README; build recipe there) — must contain `mpp/librockchip_mpp.so*` and `test/mpi_dec_test` / `test/mpi_enc_test` |
> | `CLIP_DIR` | decode | directory holding `tiny-320x240.h264/.h265` (regeneration below) |
> | `FFDIR` | transcode | ffmpeg-rockchip build dir (`./ffmpeg`, `./ffprobe`) |
> | `STAGE` | transcode | the MPP/RGA staging prefix from the ffmpeg README (e.g. `~/ffmpeg-stack`) |
> | `IN` | transcode | 1080p H.264 Annex-B input (default `$STAGE/testdata/input-1080p.h264`; regeneration below) |
> | `RUN_LIBRGA` | rewrite smoke | optional direct librga/im2d functional smoke (`0` by default; set `1` to run) |

## What each test proves

| Test | Exercises | Pass criterion |
|------|-----------|----------------|
| `abi-probe.sh` | **non-submit ABI** on current `/dev/mpp_service` + `/dev/rga` owner | Builds and runs a small C probe that records MPP/RGA ioctl numbers, struct sizes, `/proc/mpp_service` command-advertisement markers when visible, safe query results, MPP client-type HW-ID replay, initialized MPP session controls (`INIT_DRIVER_DATA`, `SEND_CODEC_INFO`, `RESET_SESSION`, and advertised `SET_ERR_REF_HACK`), a safe two-message MPP init batch, `SET_SESSION_FD` bad-fd `mpp_bat_msg.ret = -EBADF` and `MPP_BAT_MSG_DONE` marker handling, RGA version tuples/strings with exact version-query returns including intentional `RGA2_GET_VERSION ret=1`, no-op ioctl return codes, RGA virtual-address import/release, and modern RGA request create/config/cancel with a handle-backed bitblit task. Use the same binary/log format on the forward port and rewrite, then diff the logs. Exit `77` means both device nodes are absent. |
| `librga-smoke.sh` | **direct librga/im2d functional test** on current `/dev/rga` owner | Builds and runs a tiny C++ im2d client against staged `librga`: virtual-address imports plus `imcopy`, `imresize`, and `imfill`. This exercises the maintained librga request/import/submit path independently of FFmpeg. Exit `77` means `/dev/rga` is absent. |
| `rewrite-smoke.sh` | **current `/dev/mpp_service` + `/dev/rga` owner**: forward-port or rewrite | Runs the ABI probe plus decode, encode, and transcode gates below in one pass, and snapshots rewrite debugfs counters when present. Exit `77` means the device nodes are absent on this boot, not that the workload failed. |
| `test-decode.sh` | **decoder** (`rkvdec2`) | `mpi_dec_test` decodes *software-encoded* H.264 + H.265 320×240 clips to NV12 → exit 0 + non-empty output. Software-encoded input means a failure implicates the **decoder**, not our encoder. |
| `encode-test-tiny.sh` | **encoder** (VEPU580) | `mpi_enc_test` H.264 + H.265 at 256² and 1280×720 → valid NAL-start bitstreams, exit 0, no IOMMU fault (dmesg-marker scheme with a real-fault regex that excludes benign warnings). Reports PSNR + fps. |
| `transcode-test.sh` | **full pipeline** (both decoders, both encoders, RGA ×2) | ffmpeg-rockchip: `h264_rkmpp` → `scale_rkrga` 1080p→720p → `hevc_rkmpp`, then the reverse. `rkmpp`/`rkrga` have no SW fallback, so a pass *is* proof the hardware ran. Verifies each output with `ffprobe`. |

## Run

```bash
bash rewrite-smoke.sh                 # one-command gate; use sudo when devices are present
bash abi-probe.sh                     # fast non-submit ABI probe
bash abi-replay.sh                    # record normalized ABI log for this boot
bash librga-smoke.sh                  # direct librga/im2d smoke
bash test-decode.sh                  # decoder (device access is enough)
sudo bash encode-test-tiny.sh        # encoder
sudo bash transcode-test.sh          # end-to-end (needs ffmpeg-rockchip built — see ../ffmpeg)
```

For rewrite acceptance, boot a kernel where `ROCKCHIP_MPP_REWRITE` and
`ROCKCHIP_RGA_REWRITE` own the device nodes, then run:

```bash
sudo MPP_BUILD=<mpp-build> FFDIR=<ffmpeg-rockchip> STAGE=<stage> bash rewrite-smoke.sh
```

The same command is valid on the BSP-derived forward-port kernel, which makes it
the quick parity check between the two implementations.

For raw ABI replay comparisons, record one normalized log under each booted
kernel profile:

```bash
PROFILE=forward-port bash abi-replay.sh
PROFILE=rewrite BASELINE=forward-port bash abi-replay.sh
```

`abi-replay.sh` stores raw and normalized logs under
`kernel-drivers/tests/logs/abi-replay/`. Normalization removes volatile file
descriptor, import-handle, and request-id values before running `diff -u`.

## Regenerating the test inputs

The clips are not committed (nothing binary is — see
[`../packaging/README.md`](../../packaging/README.md)). Regenerate them anywhere
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
[userspace library guide](../../userspace-libraries/docs/how-the-userspace-libs-work.md) documents):

| Value | Enum | Codec |
|-------|------|-------|
| `7` | `MPP_VIDEO_CodingAVC` | H.264 |
| `10` | `MPP_VIDEO_CodingVP9` | VP9 |
| `16777220` (`0x01000004`) | `MPP_VIDEO_CodingHEVC` | H.265 |

(The jump to `0x01000004` is real: the enum restarts at the Rockchip extension
base `MPP_VIDEO_CodingVC1 = 0x01000000`.)

## VP9 decode (recipe — UNVERIFIED)

The port builds VP9 decode but only H.264/H.265 were validated
([kernel status](../docs/status.md)). `mpi_dec_test` selects its IVF reader by
the `.ivf` filename extension (`utils/mpi_dec_utils.c`), so:

```bash
ffmpeg -f lavfi -i testsrc2=size=320x240:rate=30:duration=1 -c:v libvpx-vp9 -pix_fmt yuv420p -f ivf "$CLIP_DIR/tiny-320x240-vp9.ivf"
LD_LIBRARY_PATH=$MPP_BUILD/mpp $MPP_BUILD/test/mpi_dec_test \
  -i "$CLIP_DIR/tiny-320x240-vp9.ivf" -t 10 -w 320 -h 240 -n 30 -o /tmp/dec_vp9.yuv -v f
```

**UNVERIFIED:** this recipe has not been run on the hardware (clip generation
works; the decode itself is deliberately left untested — same data path as
H.264/H.265 per status.md, but nobody has exercised the VP9 parser here). If you
run it, record the result in status.md.

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
standalone `librga-smoke.sh` covers the maintained im2d API directly; the full
hardware-frame RGA path is still validated through `transcode-test.sh`.
