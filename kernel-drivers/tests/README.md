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
| Owns | `rewrite-build-gate.sh`, `abi-probe.sh`, `abi-probe.c`, `mpp-suite.sh`, `mpp-suite-compare.sh`, `build-librga-samples-full.sh`, `librga-smoke.sh`, `librga-smoke.cpp`, `librga-suite.sh`, `librga-suite-compare.sh`, `gstreamer-suite.sh`, `gstreamer-suite-compare.sh`, `test-decode.sh`, `encode-test-tiny.sh`, `transcode-test.sh`, `rewrite-smoke.sh`, input-regeneration recipes, pass criteria, and observed reference results. |
| Depends on | A validated kernel from [`../scripts/`](../scripts/README.md), staged MPP/FFmpeg artifacts from [`../ffmpeg/`](../../ffmpeg/README.md), and device access from the codec udev rule. |
| Current state | H.264/H.265 decode, encode, and full HW transcode have been validated on the forward-port; VP9 decode remains an unverified recipe. The rewrite clean-source object-build gate is versioned here and passed both public rewrite branch tips on 2026-07-03. A broader conformance bundle now exists beside the kernel trees for rewrite-vs-forward-port comparison; see "Expanded conformance bundle" below. |

## Rewrite clean build gate

Before hardware testing a rewrite slice, run the focused cross-kernel build gate
from this support repo:

```bash
kernel-drivers/tests/rewrite-build-gate.sh all
```

The script builds from `git archive` copies of `../linux-6.18-rkvenc` and
`../linux`, forces the mutually exclusive rewrite drivers plus their KUnit
coverage, and builds only:

```text
drivers/video/rockchip/mpp-rewrite/mpp_rewrite.o
drivers/video/rockchip/rga-rewrite/rga_rewrite.o
```

It fails on dirty kernel worktrees by default, fails if the resolved config does
not enable both rewrite KUnit suites, and treats compiler warnings as failures.
The 6.18 run reuses that tree's `.config` when present, so it also covers the
BTF helper path used by the current dev config; mainline falls back to
`defconfig` unless a `.config` exists. Useful overrides:

```bash
KERNEL_6_18=/path/to/linux-6.18-rkvenc \
KERNEL_MAINLINE=/path/to/linux \
JOBS=16 KEEP_TMP=1 \
kernel-drivers/tests/rewrite-build-gate.sh all
```

`ALLOW_DIRTY=1` still builds the committed `HEAD` archive, not uncommitted
source edits. Use it only when checking the last pushed state while another
worktree has unrelated local changes.

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
../rock-5b-ysp/kernel-drivers/tests/build-librga-samples-full.sh
PROFILE=rewrite ../rock-5b-ysp/kernel-drivers/tests/mpp-suite.sh
PROFILE=rewrite ../rock-5b-ysp/kernel-drivers/tests/librga-suite.sh
PROFILE=rewrite ../rock-5b-ysp/kernel-drivers/tests/gstreamer-suite.sh

# reboot into the BSP forward-port kernel and repeat:
PROFILE=forward-port ./scripts/collect-system-info.sh
PROFILE=forward-port ../rock-5b-ysp/kernel-drivers/tests/mpp-suite.sh
PROFILE=forward-port ../rock-5b-ysp/kernel-drivers/tests/librga-suite.sh
PROFILE=forward-port ../rock-5b-ysp/kernel-drivers/tests/gstreamer-suite.sh

# compare the latest two MPP suite summaries:
../rock-5b-ysp/kernel-drivers/tests/mpp-suite-compare.sh

# compare the latest two librga suite summaries:
../rock-5b-ysp/kernel-drivers/tests/librga-suite-compare.sh

# compare the latest two GStreamer suite summaries:
../rock-5b-ysp/kernel-drivers/tests/gstreamer-suite-compare.sh
```

The important rule is that `assets/` and command lines stay identical between
the rewrite and forward-port runs, with only `PROFILE` and the booted kernel
changing. Compare `logs/rewrite/` against `logs/forward-port/`.

| Bundle component | What it is | Why it belongs in conformance |
|------------------|------------|-------------------------------|
| `sources/jeffycn-gstreamer-rockchip` | JeffyCN's `gstreamer-rockchip` branch from `JeffyCN/mirrors` at `dcbcd6454ef8` | Highest-value new target beyond FFmpeg/rkmpp/librga. GStreamer stresses MPP/RGA through caps negotiation, buffer pools, pipeline state changes, EOS/flush/seek/restart, dmabuf allocator negotiation, KMS/Wayland sinks, and multi-stream scheduling. Source review shows its kernel-visible hot path is libmpp plus legacy `c_RkRgaBlit()` for fd-backed scale/convert/rotate between MPP decode/encode stages. |
| `sources/rockchip-mpp` | Rockchip MPP library and official `test/` programs | Gives the canonical `mpp_info_test`, `mpi_dec_test`, `mpi_dec_mt_test`, `mpi_dec_multi_test`, `mpi_enc_test`, `mpi_enc_mt_test`, `mpi_rc2_test`, and `vpu_api_test` binaries. These hit sync/async decode, multi-instance and multi-thread paths, rate-control config, event/control paths, and the legacy VPU API more directly than FFmpeg. |
| `sources/airockchip-librga` | Official librga repo and IM2D sample suite | Must be run as a *suite*, not just a copy/resize smoke. It covers allocator modes, async jobs, FBC/tile copies, alpha/colorkey/OSD, CSC, fill arrays, mosaic, ROP, palette, gauss, transform, crop, resize, and padding. These map almost exactly to the rewrite's remaining RGA feature boundaries. |
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
- GStreamer: use `gstreamer-suite.sh`, not the external
  `run-gstreamer-smoke.sh`, for parity evidence. Its default required set is
  asset-free but kernel-visible: plugin/element inspection, raw NV12
  H.264/H.265 encode, BGRx/RGBA encode cases that force the plugin's legacy
  `c_RkRgaBlit()` conversion path, and repeated start/stop encode loops. Add
  H.264/H.265 inputs to enable decode to `fakesink`, decode-side RGA
  scale/format/rotate, decode -> encode transcodes, and diagnostic AFBC decode
  output. Display/DMABuf sink pipelines remain manual add-ons until a target
  compositor/KMS setup is fixed.

The expected rewrite result is not universal pass today. For implemented paths,
it should match the forward-port. For documented unsupported RGA profiles, it
should fail cleanly, preferably with `-EOPNOTSUPP`, without kernel warnings,
hangs, leaked fences, IOMMU fault storms, or stale async completions.

For RGA scheduler/core-routing validation, also capture the rewrite debugfs
counters under `/sys/kernel/debug/rk_rga_rewrite/` before and after forced-core
and mixed RGA2/RGA3 runs. The current rewrite exposes total scheduled,
dispatched, and hardware-started job counts plus per-core counters for
`rga3_core0`, `rga3_core1`, `rga2_core0`, and `rga2_core1`, plus
aggregate and per-core `hw_total_ns*` / `hw_max_ns*` timing counters. Those
counters are the lightweight replacement for carrying the BSP debugger ABI
just to confirm load balancing, `rga_req.core` routing, and hardware busy-time
trends by core.

`librga-suite.sh` is the versioned in-repo wrapper for the external official
sample binaries. It writes `summary.tsv`, per-sample logs/status files, dmesg
tail, before/after RGA debugfs snapshots, and structured
`debugfs-counters-{before,after,delta}.tsv` counter tables under
`../rockchip-conformance/logs/$PROFILE/`. Its default **required** set matches
the official sample source surface the rewrite is expected to cover or fail as a
real regression: copy/FBC/tile/splice, crop, resize/UV-downsample, CSC/gray,
fill and rectangle task arrays, alpha/colorkey/OSD/global-alpha, rotate/flip,
async/fence, core config, malloc/dma-heap/DRM allocator fd imports, mosaic, ROP,
padding, palette, and gaussian blur. Use `build-librga-samples-full.sh`, not
only the external bundle's top-level sample build, because the pinned
`airockchip/librga` CMake omits `gauss_demo` and `palette_demo` from
`samples/CMakeLists.txt` even though those sample directories exist and are part
of the required rewrite surface. Its default
**diagnostic** set records environment-specific, outside-slice, or
not-installed-by-top-level cases without failing the whole run:
physical-contiguous DRM, Android GraphicBuffer, RV1106 CMA, and CFA samples.
Override with `RGA_REQUIRED_CASES` or `RGA_DIAGNOSTIC_CASES` when intentionally
probing a narrower or broader profile.
After both kernels have a suite result, run `librga-suite-compare.sh`. It finds
the latest `summary.tsv` for `BASELINE=forward-port` and `CANDIDATE=rewrite`
by default, prints a per-case verdict table, and exits nonzero only when a
required case passed on the baseline but did not pass on the candidate.

`mpp-suite.sh` is the matching versioned wrapper for Rockchip MPP's official
`test/` binaries from `../rockchip-conformance/out/mpp/bin`. It writes
`summary.tsv`, per-case logs/status/command files, dmesg tail, and before/after
MPP procfs/debugfs snapshots under `../rockchip-conformance/logs/$PROFILE/`,
plus structured `debugfs-counters-{before,after,delta}.tsv` counter tables.
Those tables include the rewrite's aggregate and per-core `hw_total_ns*` /
`hw_max_ns*` timing counters when the rewrite driver owns `/dev/mpp_service`.
The default required set is intentionally asset-free: `mpp_info_test` only.
Select real codec/performance cases with `MPP_REQUIRED_CASES` so both kernel
profiles run the same matrix against the same media:

```bash
PROFILE=rewrite \
MPP_H264_INPUT=assets/sample-1080p.h264 \
MPP_H265_INPUT=assets/sample-1080p.h265 \
MPP_ENC_INPUT=assets/nv12-1920x1080.yuv \
MPP_ENC_WIDTH=1920 MPP_ENC_HEIGHT=1080 MPP_ENC_FORMAT=0 \
MPP_REQUIRED_CASES="mpp_info_test mpi_dec_h264 mpi_dec_h265 mpi_dec_mt_h264 mpi_dec_multi_h265 mpi_enc_h264 mpi_enc_h265 mpi_enc_mt_h265 mpi_rc2_h264" \
../rock-5b-ysp/kernel-drivers/tests/mpp-suite.sh
```

Useful case names are `mpi_dec_h264`, `mpi_dec_h265`, `mpi_dec_vp9`,
`mpi_dec_mt_*`, `mpi_dec_multi_*`, `mpi_enc_h264`, `mpi_enc_h265`,
`mpi_enc_mt_*`, `mpi_rc2_h264`, and `mpi_rc2_h265`. The legacy Android/libvpu
path is available as an explicit diagnostic case (`vpu_api_dec_h264`,
`vpu_api_dec_h265`) but is not part of the default Linux/RK3588 pass gate.
For one-off compatibility with the older external smoke script, setting
`MPP_DEC_INPUT`/`MPP_DEC_TYPE` or `MPP_ENC_INPUT`/`MPP_ENC_*` without
`MPP_REQUIRED_CASES` automatically adds `mpi_dec_custom` or `mpi_enc_custom`.
After both kernels have a suite result, run `mpp-suite-compare.sh`. Like the RGA
comparator, it fails only when a required forward-port pass is not a rewrite
pass; diagnostic differences are printed but do not make the comparator fail.

`gstreamer-suite.sh` is the versioned wrapper for JeffyCN's
`gstreamer-rockchip` plugin from `../rockchip-conformance/out/gstreamer-rockchip`.
It writes `summary.tsv`, per-case logs/status/commands, dmesg tail,
before/after driver-state snapshots, and combined MPP/RGA debugfs counter
deltas. The default required set needs no media files but still exercises real
kernel paths:

- `gst_inspect_rockchipmpp`, `gst_inspect_mppvideodec`,
  `gst_inspect_mpph264enc`, `gst_inspect_mpph265enc`;
- `enc_h264_nv12`, `enc_h265_nv12`;
- `enc_h264_bgrx_rga_rotate`, `enc_h265_rgba_rga_scale`;
- `state_loop_h264_nv12`.

Set `GST_H264_INPUT` and/or `GST_H265_INPUT` to add decode/transcode cases
automatically:

```bash
PROFILE=rewrite \
GST_H264_INPUT=assets/sample-1080p.h264 \
GST_H265_INPUT=assets/sample-1080p.h265 \
../rock-5b-ysp/kernel-drivers/tests/gstreamer-suite.sh
```

Useful explicit case names are `dec_h264_fakesink`, `dec_h265_fakesink`,
`dec_h264_rga_rotate`, `dec_h265_rga_scale`, `transcode_h264_to_h265`,
`transcode_h265_to_h264`, and `transcode_h264_rga_to_h265`. Diagnostic cases
include `parallel_enc_h264`, `dec_h264_afbc_fakesink`, and
`dec_h265_afbc_fakesink`. Override with `GST_REQUIRED_CASES` or
`GST_DIAGNOSTIC_CASES` for narrower hardware debugging, and tune dimensions with
`GST_WIDTH`, `GST_HEIGHT`, `GST_SCALE_WIDTH`, `GST_SCALE_HEIGHT`,
`GST_NUM_BUFFERS`, `GST_STATE_LOOPS`, and `GST_TIMEOUT`. After both kernels have
a suite result, run `gstreamer-suite-compare.sh`; it follows the same baseline
pass vs candidate pass rule as the MPP/RGA comparators.

**Privileges** (this differs per test):

| Test | Needs |
|------|-------|
| `test-decode.sh` | device access only: root, **or** membership in `video` with [`../scripts/99-rockchip-codec.rules`](../scripts/99-rockchip-codec.rules) installed (covers `/dev/mpp_service` **and** `/dev/dma_heap/*` — both required) |
| `mpp-suite.sh` | device access for `/dev/mpp_service`, `/dev/dma_heap/*`, readable MPP procfs/debugfs, and readable dmesg for full logs; root is the simplest mode |
| `mpp-suite-compare.sh` | no device access; reads two `summary.tsv` files under `../rockchip-conformance/logs/` |
| `librga-smoke.sh` | device access only: root, **or** membership in `video` with the codec udev rule installed (covers `/dev/rga` **and** `/dev/dma_heap/*` — the smoke allocates dma-bufs, imports them with `importbuffer_fd`, and runs legacy `c_RkRgaBlit()` GStreamer-style virtual-source, fd-to-fd rotate/convert, and planar fallback conversions) |
| `librga-suite.sh` | device access for `/dev/rga`, `/dev/dma_heap/*`, optional DRM render nodes, and readable debugfs/dmesg for full logs; root is the simplest mode |
| `librga-suite-compare.sh` | no device access; reads two `summary.tsv` files under `../rockchip-conformance/logs/` |
| `gstreamer-suite.sh` | device access for `/dev/mpp_service` and `/dev/rga`, staged JeffyCN plugin under `../rockchip-conformance/out/gstreamer-rockchip`, readable debugfs/dmesg for full logs; root is the simplest mode |
| `gstreamer-suite-compare.sh` | no device access; reads two `summary.tsv` files under `../rockchip-conformance/logs/` |
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
> | `RUN_GSTREAMER` | rewrite smoke | optional JeffyCN GStreamer plugin suite (`0` by default; set `1` to run) |

## What each test proves

| Test | Exercises | Pass criterion |
|------|-----------|----------------|
| `abi-probe.sh` | **non-submit ABI** on current `/dev/mpp_service` + `/dev/rga` owner | Builds and runs a small C probe that records MPP/RGA ioctl numbers, struct sizes, `/proc/mpp_service` command-advertisement markers when visible, safe query results, MPP client-type HW-ID replay, initialized MPP session controls (`INIT_DRIVER_DATA`, `SEND_CODEC_INFO`, `RESET_SESSION`, and advertised `SET_ERR_REF_HACK`), a safe two-message MPP init batch, `SET_SESSION_FD` bad-fd `mpp_bat_msg.ret = -EBADF` and `MPP_BAT_MSG_DONE` marker handling, RGA version tuples/strings with exact version-query returns including intentional `RGA2_GET_VERSION ret=1`, no-op ioctl return codes, RGA virtual-address import/release, and modern RGA request create/config/cancel with a handle-backed bitblit task. Use the same binary/log format on the forward port and rewrite, then diff the logs. Exit `77` means both device nodes are absent. |
| `mpp-suite.sh` | **official MPP test conformance** using `../rockchip-conformance/out/mpp/bin` | Runs the selected MPP official-test matrix under the selected `PROFILE`, records per-case logs/status/commands plus MPP procfs/debugfs snapshots and counter deltas, and fails required cases. Default required case is `mpp_info_test`; codec and performance cases are opt-in so missing assets do not masquerade as driver regressions. Exit `77` means `/dev/mpp_service` is absent. |
| `mpp-suite-compare.sh` | **rewrite-vs-forward-port MPP comparator** | Compares the latest or explicitly provided `summary.tsv` files. A required baseline pass that is not a candidate pass is a regression and exits nonzero; diagnostic differences are printed but do not fail the comparator. |
| `librga-smoke.sh` | **direct librga/im2d functional test** on current `/dev/rga` owner | Builds and runs a tiny C++ client against staged `librga`: virtual-address imports, dma-heap dma-buf allocation plus `importbuffer_fd` copy, legacy `c_RkRgaBlit()` conversions shaped like JeffyCN GStreamer (`BGRx` malloc source to NV12 dma-buf encoder preprocessing, rotated NV12 dma-buf to BGRx dma-buf decode conversion, and planar I420 dma-buf to NV12 dma-buf fallback), sync `imcopy`/`imresize`/`imfill`, forced RGA3 core-mask + priority copy through `improcess`, forced RGA2 `IM_PRE_INTR` read/write line-interrupt copy, and an async acquire/release-fence copy chain waited with `imsync`. This exercises the maintained librga import/submit/core/fence/pre-intr paths independently of FFmpeg. Exit `77` means `/dev/rga` is absent. |
| `librga-suite.sh` | **official librga sample conformance** using `../rockchip-conformance/out/librga-samples/bin` | Runs the broad current Linux/RK3588 sample set under the selected `PROFILE`, records per-case logs/status plus RGA debugfs snapshots and counter deltas, and fails only required cases. Diagnostic outside-slice cases are recorded for parity investigation without turning the whole suite red. Exit `77` means `/dev/rga` is absent. |
| `librga-suite-compare.sh` | **rewrite-vs-forward-port suite comparator** | Compares the latest or explicitly provided `summary.tsv` files. A required baseline pass that is not a candidate pass is a regression and exits nonzero; diagnostic differences are printed but do not fail the comparator. |
| `gstreamer-suite.sh` | **JeffyCN GStreamer MPP/RGA plugin conformance** using `../rockchip-conformance/out/gstreamer-rockchip` | Runs plugin inspection plus real `gst-launch-1.0` encode, RGA-conversion, restart-loop, and optional decode/transcode pipelines under the selected `PROFILE`. It records per-case logs/status/commands plus MPP/RGA debugfs snapshots and counter deltas. Exit `77` means `/dev/mpp_service` or `/dev/rga` is absent. |
| `gstreamer-suite-compare.sh` | **rewrite-vs-forward-port GStreamer comparator** | Compares the latest or explicitly provided `summary.tsv` files. A required baseline pass that is not a candidate pass is a regression and exits nonzero; diagnostic differences are printed but do not fail the comparator. |
| `rewrite-smoke.sh` | **current `/dev/mpp_service` + `/dev/rga` owner**: forward-port or rewrite | Runs the ABI probe plus decode, encode, and transcode gates below in one pass, and snapshots rewrite debugfs counters, including aggregate/per-core timing counters, when present. Exit `77` means the device nodes are absent on this boot, not that the workload failed. |
| `test-decode.sh` | **decoder** (`rkvdec2`) | `mpi_dec_test` decodes *software-encoded* H.264 + H.265 320×240 clips to NV12 → exit 0 + non-empty output. Software-encoded input means a failure implicates the **decoder**, not our encoder. |
| `encode-test-tiny.sh` | **encoder** (VEPU580) | `mpi_enc_test` H.264 + H.265 at 256² and 1280×720 → valid NAL-start bitstreams, exit 0, no IOMMU fault (dmesg-marker scheme with a real-fault regex that excludes benign warnings). Reports PSNR + fps. |
| `transcode-test.sh` | **full pipeline** (both decoders, both encoders, RGA ×2) | ffmpeg-rockchip: `h264_rkmpp` → `scale_rkrga` 1080p→720p → `hevc_rkmpp`, then the reverse. `rkmpp`/`rkrga` have no SW fallback, so a pass *is* proof the hardware ran. Verifies each output with `ffprobe`. |

## Run

```bash
bash rewrite-smoke.sh                 # one-command gate; use sudo when devices are present
bash abi-probe.sh                     # fast non-submit ABI probe
bash abi-replay.sh                    # record normalized ABI log for this boot
bash mpp-suite.sh                     # official MPP test conformance
bash mpp-suite-compare.sh             # compare latest forward-port/rewrite MPP summaries
bash librga-smoke.sh                  # direct librga/im2d smoke
bash librga-suite.sh                  # official librga sample conformance
bash librga-suite-compare.sh          # compare latest forward-port/rewrite suite summaries
bash gstreamer-suite.sh               # JeffyCN GStreamer MPP/RGA conformance
bash gstreamer-suite-compare.sh       # compare latest forward-port/rewrite GStreamer summaries
bash test-decode.sh                  # decoder (device access is enough)
sudo bash encode-test-tiny.sh        # encoder
sudo bash transcode-test.sh          # end-to-end (needs ffmpeg-rockchip built — see ../ffmpeg)
```

Maintenance gate: `shellcheck *.sh` in this directory is expected to pass; it
was last verified on 2026-07-03 after the direct `librga` smoke gained
forced-core, fence, pre-intr, dma-buf fd-import, and legacy `c_RkRgaBlit()`
coverage for the GStreamer virtual-source, fd-backed rotate/convert, and planar
fallback shapes and after the MPP official-test suite/comparator were added. The
GStreamer suite/comparator were added later and have been syntax-checked
locally; run shellcheck on target when the package is installed.

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
It also writes a smaller `.contract.log` that keeps the stable query/version
and session-control lines, including the intentional legacy
`RGA2_GET_VERSION ret=1` result copied from the BSP/librga contract.

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
standalone `librga-smoke.sh` covers the maintained im2d API directly plus the
legacy `c_RkRgaBlit()` conversion shapes JeffyCN GStreamer uses for encoder
preprocessing, decode-side fd-backed rotate/format conversion, and planar
fallback; the full hardware-frame RGA path is still validated through
`transcode-test.sh`.
