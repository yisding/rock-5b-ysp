# tests/rewrite-conformance.md — rewrite build gate & conformance suites

The expert half of [`kernel-drivers/tests/README.md`](./README.md). The user-facing on-ramp (decode,
encode, transcode smoke tests) leads in [`README.md`](./README.md); this page
owns the rewrite clean-build gate, the tracked
[`conformance/`](conformance/README.md) seed for the external
`../rockchip-conformance` runtime bundle, and the full per-suite reference (MPP /
librga / GStreamer / ffmpeg-rockchip) with its env-var matrices, privileges, and
comparators. The strategic "what it
would take to ship the rewrite" plan is
[`../docs/rewrite-validation-plan.md`](../docs/rewrite-validation-plan.md); this
page is the operational how-to-run counterpart it leans on.

All suites assume the combined kernel booted, `/dev/mpp_service` + `/dev/rga`
present, and (for rewrite parity work) the ability to dual-boot the forward-port
and rewrite kernels.

## Rewrite clean build gate

Before hardware testing a rewrite slice, run the focused cross-kernel build gate
from this support repo:

```bash
kernel-drivers/tests/rewrite-build-gate.sh all
```

The script builds from `git archive` copies of `../kernel/linux-6.18-rkvenc` and
`../kernel/linux`, forces the mutually exclusive rewrite drivers plus their KUnit
coverage, and builds only:

```text
drivers/video/rockchip/mpp-rewrite/mpp_rewrite.o
drivers/video/rockchip/rga-rewrite/rga_rewrite.o
```

It fails on dirty kernel worktrees by default, fails if the resolved config does
not enable both rewrite KUnit suites, and treats compiler warnings as failures.
The 6.18 run reuses that tree's `.config` when present, so it also covers the
BTF helper path used by the current dev config; mainline falls back to
`defconfig` unless a `.config` exists. The default `normal` profile is the
strict KUnit object-build gate. `REWRITE_BUILD_PROFILES` can add compile-only
sanitizer profiles:

- `memory`: enables KASAN plus fault-injection options used by the fail-nth
  ioctl unwind tests.
- `race`: enables KCSAN plus lockdep for race-oriented compile coverage.

The sanitizer profiles intentionally set a higher `FRAME_WARN` threshold because
KASAN/KCSAN instrumentation inflates KUnit stack frames; the normal profile keeps
the existing stricter warning behavior. These profiles prove the rewrite objects
compile with the relevant instrumentation on both kernel lines, but they are not
a substitute for booted KASAN/KCSAN runtime evidence.

Useful overrides:

```bash
KERNEL_6_18=/path/to/linux-6.18-rkvenc \
KERNEL_MAINLINE=/path/to/linux \
JOBS=16 KEEP_TMP=1 \
kernel-drivers/tests/rewrite-build-gate.sh all

REWRITE_BUILD_PROFILES="normal memory race" \
kernel-drivers/tests/rewrite-build-gate.sh all
```

`ALLOW_DIRTY=1` still builds the committed `HEAD` archive, not uncommitted
source edits. Use it only when checking the last pushed state while another
worktree has unrelated local changes.

Last recorded compile gates: on 2026-07-06 the default `normal` profile passed
warning-free for the current committed rewrite tips
`../kernel/linux-6.18-rkvenc@d1d15a3d052a` and
`../kernel/linux@12f712d71144`. The broader `normal`, `memory`, and `race`
profiles all passed warning-free the same day for the immediately earlier tips
`../kernel/linux-6.18-rkvenc@0a35c26a0fd7` and
`../kernel/linux@938b1d2032c3`.
After the gate was changed to remove each per-profile archive checkout as soon
as that profile passes, the all-in-one
`REWRITE_BUILD_PROFILES="normal memory race" kernel-drivers/tests/rewrite-build-gate.sh all`
run completed 6.18 `normal`/`memory`/`race` and mainline
`normal`/`memory`/`race` in one invocation. `/tmp` returned to 7.4 GiB free
after the run, with no leftover `rkcompat-rewrite-build.*` scratch directories.
The same maintenance pass also ran
`VALIDATE_ONLY=1 kernel-drivers/tests/rewrite-conformance-run.sh` and
`VALIDATE_ONLY=1 PROFILE=rewrite RUN_COUNTER_CHECKS=1 kernel-drivers/tests/rewrite-conformance-run.sh`,
plus the same counter-default validation with `LIBRGA_FORCE_RGA_USERPTR_IOMMU=1`; all
passed, including the forced RGA userptr-IOMMU fallback counter-default wiring check.

After the Rockchip IOMMU provider hardening slice, the default `normal` profile
passed warning-free for the committed tips
`../kernel/linux-6.18-rkvenc@d1d15a3d052a` and
`../kernel/linux@12f712d71144`. The same slice also passed focused provider
object builds of `drivers/iommu/rockchip-iommu.o` from clean temporary archives
with the staged diff applied before commit.

## Expanded conformance bundle

The narrow in-repo tests are still the fast gate. For rewrite parity work, also
use the external runtime bundle at `../rockchip-conformance`
(`/home/yi/Code/rockchip-conformance` on the dev box). It is intentionally
outside this repo because it contains shallow third-party source checkouts and
generated build/log directories.

The reproducible seed for that bundle is tracked in
[`conformance/`](conformance/README.md). To reconstruct the source checkouts from
a fresh clone:

```bash
cd kernel-drivers/tests/conformance
bash scripts/bootstrap-sources.sh
```

Then copy or mount the populated bundle where the suite expects it, or set
`CONFORMANCE_ROOT=/path/to/kernel-drivers/tests/conformance` when you want to run
in place. This section records why each piece matters and what we learned to
test.

Run it the same way under both kernels. The normal path is the profile runner:

```bash
# Boot the BSP-derived forward-port kernel first.
PROFILE=forward-port ../rock-5b-ysp/kernel-drivers/tests/rewrite-conformance-run.sh

# Then boot the rewrite kernel and compare against the saved forward-port logs.
PROFILE=rewrite RUN_COMPARE=1 ../rock-5b-ysp/kernel-drivers/tests/rewrite-conformance-run.sh
```

`rewrite-conformance-run.sh` sequences system-info collection, normalized ABI
replay, MPP, librga, GStreamer, and ffmpeg-rockchip suites for one booted
profile. Set `RUN_*_SUITE=0` to narrow a run, `RUN_COMPARE=1` to compare latest
saved summaries against `COMPARE_BASELINE=forward-port`, and
`VALIDATE_ONLY=1` for the device-free runner, syzlang ABI-marker, optional
syzkaller `make descriptions` compile check, ioctl-fuzzer build, direct
`librga` smoke build, optional GStreamer event-harness build, RGA IOMMU
scatter-fuzzer build, recovery stress harness config validation,
MPP/GStreamer case-builder validation, FFmpeg case-list validation, comparator
maintenance check, ABI replay filter selftest, and paired-evidence audit
selftest, including the
diagnostic-failure and named optional-case audit paths.

For per-suite debugging, the equivalent manual sequence is:

```bash
cd ../rockchip-conformance
PROFILE=rewrite ./scripts/collect-system-info.sh
# build on the RK3588 target userspace, then run smoke/real media cases
../rock-5b-ysp/kernel-drivers/tests/build-librga-samples-full.sh
../rock-5b-ysp/kernel-drivers/tests/build-mpp-tests.sh
../rock-5b-ysp/kernel-drivers/tests/build-gstreamer-rockchip.sh
PROFILE=rewrite ../rock-5b-ysp/kernel-drivers/tests/mpp-suite.sh
PROFILE=rewrite ../rock-5b-ysp/kernel-drivers/tests/librga-suite.sh
PROFILE=rewrite ../rock-5b-ysp/kernel-drivers/tests/gstreamer-suite.sh
PROFILE=rewrite FFDIR=../ffmpeg/ffmpeg-rockchip-81 ../rock-5b-ysp/kernel-drivers/tests/ffmpeg-suite.sh

# reboot into the BSP forward-port kernel and repeat:
PROFILE=forward-port ./scripts/collect-system-info.sh
PROFILE=forward-port ../rock-5b-ysp/kernel-drivers/tests/mpp-suite.sh
PROFILE=forward-port ../rock-5b-ysp/kernel-drivers/tests/librga-suite.sh
PROFILE=forward-port ../rock-5b-ysp/kernel-drivers/tests/gstreamer-suite.sh
PROFILE=forward-port FFDIR=../ffmpeg/ffmpeg-rockchip-81 ../rock-5b-ysp/kernel-drivers/tests/ffmpeg-suite.sh

# compare the latest two MPP suite summaries:
../rock-5b-ysp/kernel-drivers/tests/mpp-suite-compare.sh

# compare the latest two librga suite summaries:
../rock-5b-ysp/kernel-drivers/tests/librga-suite-compare.sh

# compare the latest two GStreamer suite summaries:
../rock-5b-ysp/kernel-drivers/tests/gstreamer-suite-compare.sh

# compare the latest two ffmpeg-rockchip suite summaries:
../rock-5b-ysp/kernel-drivers/tests/ffmpeg-suite-compare.sh
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

The current conformance set is still the right required gate. A follow-up public
source scan of additional `librga` users is recorded in
[`../rga/userspace-consumers.md`](../rga/userspace-consumers.md). It found no
new maintained media-server ABI beyond the `librga` IM2D and legacy
`c_RkRgaBlit()` surfaces already under test. It does identify useful optional
targets: a full `rkmppenc` run for a second MPP-frame producer/filter graph, a
standalone `gstreamer-rga` or env-gated GStreamer `videoflip` path for
independent legacy-blit converter coverage, and one UI/display
BGRA/XRGB/RGB565 rotation plus partial-blend smoke if appliance/display usage becomes part of
the target profile.
The direct `librga-smoke` binary now covers the `rkmppenc`-style fd-backed
IM2D crop/CSC/resize/acquire-fence/release-fence primitive chain and the
standalone `gstreamer-rga` thread-default core-mask primitive through
`imconfig(IM_CONFIG_SCHEDULER_CORE, ...)` and the public thread-default
`IM_CONFIG_PRIORITY` path, but not the plugin lifecycle. It can also opt into
the display/UI tail with `LIBRGA_SMOKE_DISPLAY_TAIL=1`, which adds BGRA, XRGB,
and RGB565 fd-backed legacy `c_RkRgaBlit()` display-rotation artifacts plus a
BGRA partial-rectangle alpha-blend artifact without making those
appliance-style paths part of the default media-server gate. The same scan found
old RKNN/Yolo code
using direct physical-address RGA
destinations; keep that recognized-but-unsupported unless a current RK3588
workload proves fd or virtual buffers are insufficient.
The strongest optional application gap from that scan is `rkmppenc`: its public
docs are active, explicitly mention ROCK 5B transcoding, expose
`--check-mppinfo`/`--check-rgainfo`, and select RGA resize through
`--output-res` plus `--vpp-resize rga_nearest/rga_bilinear/rga_bicubic`.
`rkmppenc-suite.sh` now makes that app-level gap executable as an opt-in profile
with version/probe commands, generated Y4M/raw H.264 and H.265 encode with RGA
resize, and a diagnostic hardware-decode to RGA-resize to encode transcode.
Keep it optional unless it proves a new kernel-visible ABI issue.

Suggested expanded matrix:

- MPP: H.264/H.265 decode at 1080p/4K, VP9 decode, H.264/H.265 encode from NV12
  at 1080p/4K, multi-instance decode, multi-thread encode/decode,
  rate-control, and `vpu_api_test`. The direct VP9 MPP case can now generate its
  own IVF input, but still needs a recorded forward-port/rewrite hardware run.
  VP8/MPEG/H.263/JPEG/AV1 names may be advertised by userspace; keep them out
  of the required RK3588 rewrite gate unless a current workload proves they
  need the legacy VDPU/JPEG or separate AV1 path.
- RGA: `copy`, `resize`, `cvtcolor`, `fill`, `alpha`, `transform`, `async`, and
  allocator samples first; then deliberately run `rop`, `mosaic`, `padding`,
  FBC/tile, colorkey/OSD, and 10-bit/compressed cases to distinguish clean
  `-EOPNOTSUPP` from real regressions. The standalone `librga-smoke.sh` also
  covers RKNN/RKNPU-style RGB/NV12/NV21 preprocessing plus RGBA crop/letterbox
  through virtual `imresize`, fd-backed `improcess`, and legacy RGB
  `c_RkRgaBlit` resize
  paths, and records NV12 raster-to-AFBC16x16-to-raster plus
  raster-to-tile8x8-to-raster round-trip artifacts;
  it records a no-submit physical-address import probe by default and
  can turn that probe into a rewrite-only negative check with
  `LIBRGA_SMOKE_EXPECT_PHYSICAL_REJECT=1`. It also records public-API
  raster-to-AFBC32x8/RFBC64x4 destination-mode probes by default and can turn
  those into rewrite-only negative checks with
  `LIBRGA_SMOKE_EXPECT_FBC_TAIL_REJECT=1`. `librga-suite.sh` enables both
  negative assertions automatically for `PROFILE=*rewrite*` so the full rewrite
  profile fails if these obsolete paths become accepted again. It can opt into direct P010/P210 IM2D dma-buf conversions with
  `LIBRGA_SMOKE_10BIT=1`, which is the smallest hardware check for the local
  P010/P210 request-generation patch before running full FFmpeg/Jellyfin RKRGA
  paths. It can also opt into BGRA/XRGB/RGB565 display-tail rotation artifacts
  and a BGRA partial-rectangle alpha-blend artifact with
  `LIBRGA_SMOKE_DISPLAY_TAIL=1` when appliance/display usage is in scope.
- GStreamer: use `gstreamer-suite.sh`, not the external
  `run-gstreamer-smoke.sh`, for parity evidence. Its default required set is
  asset-free but kernel-visible: plugin/element inspection, raw NV12
  H.264/H.265 encode, BGRx/RGBA encode cases that force the plugin's legacy
  `c_RkRgaBlit()` conversion path, generated elementary-stream decode and
  transcode, generated VP9 IVF decode, generated H.265 Main10 decode/RGA/fallback,
  in-pipeline caps renegotiation, explicit flush events,
  codec-specific encoder QP/profile controls, and repeated EOS and
  start/stop loops, and generated H.264/H.265 AFBC/FBC decode-output
  negotiation. Add H.264/H.265 inputs
  to enable decode to `fakesink`, decode-side RGA scale/format/rotate, and
  decode -> encode transcodes. Same-codec and mixed-codec generated
  multi-stream decode/transcode pipelines are diagnostic coverage.
  Display and KMS-capture DMABuf pipelines are opt-in because they require a
  target display plane, but the suite has explicit cases for JeffyCN's
  `rkximagesink` display import and `kmssrc` DRM dma-buf capture into MPP
  encode. Generated VP8/H.263/MPEG diagnostics are opt-in so the advertised
  legacy decoder caps remain testable without making legacy VDPU blocks part of
  the required RK3588 rewrite gate.
- FFmpeg: use `ffmpeg-suite.sh` for a profile/log/comparator-integrated version
  of the full `ffmpeg-rockchip` path. It runs the selected `FFDIR/ffmpeg` once
  against the current system runtime and, when available, once with staged
  from-source MPP via `STAGE` or `FFMPEG_STAGED_LD_LIBRARY_PATH`; this catches
  packaging/library skew such as a system `librockchip_mpp` without AV1 parser
  support. The suite records `uname`, `ffmpeg -version`, `ldd`, device-node and
  `/proc/mpp_service/supports-device` preflight data, probes H.264/H.265/VP9
  RKMPP decoders, H.264/H.265 RKMPP encoders, RKRGA filters, and treats an
  absent AV1 RKMPP encoder as expected. It generates shared software H.264,
  H.265, VP9, AV1, H.265 Main10, resolution-change, and optional 4K/8K inputs
  under `../rockchip-conformance/assets/ffmpeg-generated`. Required cases cover
  H.264/H.265/VP9 decode to null, bit-exact HW-vs-SW decode PSNR, H.264/H.265
  encode sanity with a PSNR floor, H.264<->RGA<->H.265 transcodes, and
  `scale_rkrga`, `vpp_rkrga`, and `overlay_rkrga`. AV1 decode, AV1 PSNR,
  AV1->RGA->H.264/H.265, and AV1 AFBC off/on/rga modes are diagnostic by
  default and become required with `FFMPEG_REQUIRE_AV1=1` for the av1-fwport
  build. Additional diagnostics cover H.265 Main10/P010 through RGA and H.264
  resolution-change decode; `FFMPEG_RUN_STRESS=1` adds repeated short
  encode/decode/transcode loops plus an AV1->RGA->H.264 soak controlled by
  `FFMPEG_STRESS_LOOPS` and `FFMPEG_SOAK_SECONDS`. The comparator can enforce
  pass/fail, elapsed-time ratios, and encoded bitstream byte-count/SHA parity
  against the forward-port.

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

## librga-suite reference

`librga-suite.sh` is the versioned in-repo wrapper for the external official
sample binaries. It writes `summary.tsv`, per-sample logs/status files, dmesg
tail, before/after RGA debugfs snapshots, and structured
`debugfs-counters-{before,after,delta}.tsv` counter tables under
`../rockchip-conformance/logs/$PROFILE/`. Its default **required** set includes
the in-repo `ysp_librga_smoke` direct-userspace artifact case plus the official
sample source surface the rewrite is expected to cover or fail as a real
regression: copy/FBC/tile/splice, crop, resize/UV-downsample, CSC/gray, fill and
rectangle task arrays, alpha/colorkey/OSD/global-alpha, rotate/flip,
async/fence, core config, malloc/dma-heap/DRM allocator fd imports, mosaic, ROP,
padding, palette, and gaussian blur. Use `build-librga-samples-full.sh`, not
only the external bundle's top-level sample build, because the pinned
`airockchip/librga` CMake omits `gauss_demo` and `palette_demo` from
`samples/CMakeLists.txt` even though those sample directories exist and are part
of the required rewrite surface. `ysp_librga_smoke` writes deterministic raw
destination artifacts for direct `imcopy`, dma-buf import/copy, fd-backed
`imcvtcolor`, async `imresize`, crop, flip, legacy
`c_RkRgaBlit()` BGRx->NV12, NV12->BGRx rotate, BGRx display rot90,
RGBA flip, I420->NV12, fd-backed legacy `c_RkRgaColorFill()`, RKNN-style
RGB virtual resize, fd-backed RGB->NV12/NV12->RGB/NV21->RGB `improcess`
resize/convert, fd-backed `rkmppenc`-shaped crop/CSC/resize fence chains,
legacy RGB resize, AFBC16x16 and tile8x8 round-trips, Gaussian matrix,
sequential IM2D task-job copy chains,
forced-core, pre-intr, async fence-chain, resize, and fill paths.
Its default
**diagnostic** set records environment-specific, outside-slice, or
not-installed-by-top-level cases without failing the whole run:
physical-contiguous DRM, Android GraphicBuffer, RV1106 CMA, and CFA samples.
The direct smoke logs the physical-address import probe without submitting a
physical-address job; set `LIBRGA_SMOKE_EXPECT_PHYSICAL_REJECT=1` only on a
rewrite-negative run where accepting that import should be a failure. It also
submits raster-to-AFBC32x8/RFBC64x4 destination-mode probes through public
`librga`; set `LIBRGA_SMOKE_EXPECT_FBC_TAIL_REJECT=1` only on rewrite-negative
runs where accepting those deprecated FBC tail modes should fail the smoke.
`PROFILE=*rewrite*` `librga-suite.sh` runs set both rewrite-negative smoke
flags by default; forward-port suite runs leave them observational.
Override with `RGA_REQUIRED_CASES` or `RGA_DIAGNOSTIC_CASES` when intentionally
probing a narrower or broader profile.
After both kernels have a suite result, run `librga-suite-compare.sh`. It finds
the latest `*-librga-suite/summary.tsv` for `BASELINE=forward-port` and
`CANDIDATE=rewrite` by default, prints a per-case verdict table with
elapsed-time ratios, compares `artifacts.tsv` when present, and exits nonzero
when a required case passed on the baseline but did not pass on the candidate or
when a required artifact differs. Suite summaries record `elapsed_s` as decimal
seconds with millisecond precision. Set `PERF_MAX_RATIO` to also fail required
cases that pass on both profiles but are slower than the configured
candidate/baseline elapsed-time ratio. Set `REQUIRE_ARTIFACTS=0` only when
comparing legacy pass/fail-only logs.

## mpp-suite reference

`mpp-suite.sh` is the matching versioned wrapper for Rockchip MPP's official
`test/` binaries from `../rockchip-conformance/out/mpp/bin`. It writes
`summary.tsv`, per-case logs/status/command files, dmesg tail, and before/after
MPP procfs/debugfs snapshots under `../rockchip-conformance/logs/$PROFILE/`,
plus structured `debugfs-counters-{before,after,delta}.tsv` counter tables.
Those tables include the rewrite's aggregate and per-core `hw_total_ns*` /
`hw_max_ns*` timing counters when the rewrite driver owns `/dev/mpp_service`.
Use `build-mpp-tests.sh` to stage these binaries. It keeps the official MPP
suite targets enabled but disables the obsolete `mpp_runtime_test` OSAL target,
whose no-argument pthread start routine is rejected by current GCC even though
the binary is not part of the driver conformance matrix.
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
When `mpi_dec_vp9`, `mpi_dec_mt_vp9`, or `mpi_dec_multi_vp9` is selected and
`MPP_VP9_INPUT` is unset, the wrapper generates a shared VP9 IVF input under
`MPP_GENERATED_INPUT_CACHE` (default
`../rockchip-conformance/assets/mpp-generated`) with `ffmpeg`/`libvpx-vp9`.
Set `MPP_GENERATE_VP9_INPUT=0` to require an explicit `MPP_VP9_INPUT`, or tune
`MPP_VP9_GENERATED_WIDTH`, `MPP_VP9_GENERATED_HEIGHT`, and
`MPP_VP9_GENERATED_FPS`.
For one-off compatibility with the older external smoke script, setting
`MPP_DEC_INPUT`/`MPP_DEC_TYPE` or `MPP_ENC_INPUT`/`MPP_ENC_*` without
`MPP_REQUIRED_CASES` automatically adds `mpi_dec_custom` or `mpi_enc_custom`.
After both kernels have a suite result, run `mpp-suite-compare.sh`. Like the RGA
comparator, it prints elapsed-time ratios and fails when a required forward-port
pass is not a rewrite pass. Set `PERF_MAX_RATIO` when using the compare step as
a performance gate; diagnostic differences and slowdowns are printed but do not
make the comparator fail.

## gstreamer-suite reference

`gstreamer-suite.sh` is the versioned wrapper for JeffyCN's
`gstreamer-rockchip` plugin from `../rockchip-conformance/out/gstreamer-rockchip`.
It writes `summary.tsv`, per-case logs/status/commands, dmesg tail,
before/after driver-state snapshots, and combined MPP/RGA debugfs counter
deltas. Use `build-gstreamer-rockchip.sh` to stage the plugin. It builds only
the Rockchip MPP plugin by default, requires the RGA dependency instead of
silently dropping conversion support, and disables the display-only `rkximage`
and `kmssrc` plugins for the headless default matrix. To stage the Rockchip KMS
display sink used by the opt-in display cases, rebuild with
`RKXIMAGE_FEATURE=enabled`; that additionally requires the `x11` and `libdrm`
pkg-config dependencies. To stage the KMS source used by the opt-in capture
cases, rebuild with `KMSSRC_FEATURE=enabled`; that requires `libdrm`. The
default required set needs no media files but still exercises real kernel
paths:

- `gst_inspect_rockchipmpp`, `gst_inspect_mppvideodec`,
  `gst_inspect_mpph264enc`, `gst_inspect_mpph265enc`;
- `enc_h264_nv12`, `enc_h265_nv12`,
  `enc_h264_control_props`, `enc_h265_control_props`,
  `enc_h264_qp_profile_props`, `enc_h265_qp_props`,
  `enc_h264_env_no_rga`, `enc_h264_env_max_pending`,
  `enc_h264_env_unaligned_vstride`;
- `enc_h264_bgrx_rga_rotate`, `enc_h264_bgrx_rga_rotate_180`,
  `enc_h264_bgrx_rga_rotate_270`, `enc_h265_rgba_rga_scale`;
- `enc_h264_i420`, `enc_h264_yuy2`, `enc_h264_uyvy`,
  `enc_h264_rgb16`, `enc_h264_argb`, `enc_h264_abgr`,
  `enc_h264_xrgb`, `enc_h264_xbgr`;
- `enc_h265_i420`, `enc_h265_yuy2`, `enc_h265_uyvy`,
  `enc_h265_rgb16`, `enc_h265_argb`, `enc_h265_abgr`,
  `enc_h265_xrgb`, `enc_h265_xbgr`;
- `roundtrip_h264_nv12`, `roundtrip_h265_nv12`,
  `roundtrip_h264_rga_rotate`, `roundtrip_h264_rga_rotate_270`;
- `generated_dec_h264_fakesink`, `generated_dec_h265_fakesink`,
  `generated_dec_h264_dmabuf`, `generated_dec_h265_dmabuf`,
  `generated_dec_h264_env_dmabuf`, `generated_dec_h264_env_no_rga`,
  `generated_dec_h264_mp4_codec_data`,
  `generated_dec_h265_mp4_codec_data`,
  `generated_dec_h265_10_fakesink`,
  `generated_dec_h265_10_rga_scale`,
  `generated_dec_h265_10_env_disable_nv12_10`,
  `generated_dec_h264_strict_props`,
  `generated_dec_h265_strict_props`,
  `generated_dec_h264_env_strict_props`,
  `generated_dec_h264_env_format_nv21`,
  `generated_dec_vp9_fakesink`, `generated_dec_vp9_dmabuf`,
  `generated_dec_h264_renegotiate`, `generated_dec_h265_renegotiate`,
  `generated_dec_h264_rga_rotate`, `generated_dec_h264_rga_rotate_180`,
  `generated_dec_h264_rga_rotate_270`, `generated_dec_h264_crop_meta`,
  `generated_dec_h264_rga_rgba_scale`,
  `generated_dec_h264_rga_bgra_scale`,
  `generated_dec_h264_rga_rgbx_scale`,
  `generated_dec_h264_rga_bgrx_scale`,
  `generated_dec_h265_rga_scale`;
- `generated_transcode_h264_to_h265`, `generated_transcode_h265_to_h264`,
  `generated_transcode_h264_mp4_to_h265`,
  `generated_transcode_h265_mp4_to_h264`,
  `generated_transcode_h264_rga_to_h265`,
  `generated_transcode_h264_dmabuf_to_h265`;
- `caps_renegotiate_h264_nv12`, `caps_renegotiate_h265_nv12`;
- `event_flush_enc_h264`, `event_flush_enc_h265`,
  `event_force_key_enc_h264`, `event_force_key_enc_h265`,
  `event_flush_dec_h264`, `event_flush_dec_h265`;
- `eos_loop_enc_h264`, `eos_loop_enc_h265`,
  `eos_loop_dec_h264`, `eos_loop_dec_h265`;
- `state_loop_h264_nv12`, `state_loop_roundtrip_h264`;
- `parallel_enc_h264`, `parallel_roundtrip_h264`,
  `parallel_dec_h264`, `parallel_dec_h265`,
  `parallel_dec_mixed_h264_h265`, and
  `parallel_transcode_mixed_h264_h265`.

The generated-media cases first write short H.264/H.265 elementary streams
with the Rockchip encoders, a short VP9 IVF stream with `vp9enc ! ivfmux`,
optional AV1 IVF input with `GST_GENERATOR` (default `ffmpeg`) plus
`libaom-av1`, and software-generated H.265 Main10 elementary streams with
`GST_GENERATOR` plus `libx265` under `GST_GENERATED_INPUT_CACHE` (default
`../rockchip-conformance/assets/gstreamer-generated`). They then feed those
shared files through `filesrc ! *parse ! mppvideodec` decode and decode->encode
transcode pipelines. Keeping the cache outside each profile's log directory
makes forward-port and rewrite runs consume the same input streams. That keeps
the default run self-contained while covering the media-file path that
same-pipeline roundtrips do not hit. VP9 cases are enabled and required by
default; set `GST_ENABLE_VP9_CASES=0` to remove them or
`GST_REQUIRE_VP9_CASES=0` to keep them diagnostic-only on images missing
`vp9enc`, `ivfmux`, or `ivfparse`. AV1 remains outside the required RK3588
rewrite gate because it needs a separate AV1 backend; set
`GST_ENABLE_AV1_CASES=1` to add generated AV1 fakesink/DMABuf decode plus
RGA-scale and AV1-to-H.264 transcode diagnostics, or
`GST_REQUIRE_AV1_CASES=1` when comparing an AV1-capable kernel. Set
`GST_ENABLE_LEGACY_DECODE_CASES=1` to add generated VP8 IVF plus
ffmpeg-generated H.263, MPEG-2, and MPEG-4 diagnostics for JeffyCN's advertised
legacy `mppvideodec` caps; `GST_REQUIRE_LEGACY_DECODE_CASES=1` should only be
used when comparing kernels that intentionally support those legacy decode
blocks. The `*_dmabuf`
variants set `mppvideodec dma-feature=true`, forcing DMABuf caps and the MPP
allocator/external-buffer-group handoff that zero-copy consumers negotiate.
The dormant libmpp batch server is not a required workload.  Current libmpp no
longer wires callers to `MPP_DEV_BATCH_ON`, so the rewrite driver recognizes
the known batch-server wait-array shape and returns `-EOPNOTSUPP` instead of
adding multi-`LAST_MSG` behavior that the BSP collector does not expose for
normal submissions.  Parallel decode/transcode cases remain required for
multi-session scheduling evidence through currently reachable userspace paths.
The generated H.265 Main10 cases are also enabled and required by default:
`generated_dec_h265_10_fakesink`,
`generated_dec_h265_10_rga_scale`, and
`generated_dec_h265_10_env_disable_nv12_10` cover compact NV12_10LE40 decode,
decoder-side RGA conversion to NV12, and the
`GST_MPP_DEC_DISABLE_NV12_10=1` fallback path without requiring external media.
Set `GST_REQUIRE_H265_10_CASES=0` to demote them during bring-up, or
`GST_ENABLE_H265_10_CASES=0 GST_REQUIRE_H265_10_CASES=0` to omit them from a
narrow debug run. The optional generated 4:2:2 10-bit set is disabled by
default because host `libx265` profile support varies; enable it with
`GST_ENABLE_H265_422_10_CASES=1` or require it with
`GST_REQUIRE_H265_422_10_CASES=1`.
The generated MP4 cases write H.264/H.265 through `mp4mux`, then decode or
transcode with `qtdemux ! *parse ! mppvideodec`; that covers JeffyCN's startup
path that sends container `codec_data` as MPP extra data before normal decode
packets, including the common demuxed-file transcode shape. These container
cases are enabled and required by default. Set
`GST_REQUIRE_CONTAINER_CASES=0` to demote them to diagnostics on minimal
GStreamer images missing `mp4mux`/`qtdemux`, or
`GST_ENABLE_CONTAINER_CASES=0 GST_REQUIRE_CONTAINER_CASES=0` to omit them from a
narrow debug run.
`generated_dec_h264_env_dmabuf` runs the same path with
`GST_MPP_DEC_DMA_FEATURE=1`, covering JeffyCN's global default-value path
separately from explicit element properties.
`enc_h264_env_no_rga` and `generated_dec_h264_env_no_rga` run basic H.264
encode/decode with `GST_MPP_NO_RGA=1`, covering the current plugin's global
no-RGA branch while staying on MPP-only paths that should not depend on
`/dev/rga`.
`generated_dec_h264_afbc_fakesink`, `generated_dec_h265_afbc_fakesink`,
`generated_dec_h264_env_fbc`, `generated_dec_h264_env_arm_afbc`, and the
generated AFBC decode-to-encode transcodes are enabled and required by default.
They validate the plugin-visible
`mppvideodec fbc=true`, `GST_MPP_VIDEODEC_DEFAULT_FBC=1`, and
`GST_MPP_VIDEODEC_DEFAULT_ARM_AFBC=1` decoder paths, plus explicit
`mpp*h26*enc arm-afbc=true` and `GST_MPP_ENC_DEFAULT_ARM_AFBC=1` encoder input
paths. The fakesink decode-only cases remain pass/fail-only because AFBC/FBC
buffers are compressed layout contracts, not stable raw-pixel dumps for
SHA-256 comparison; the AFBC transcode cases record encoded bitstream
artifacts. Set `GST_REQUIRE_FBC_CASES=0` to keep them diagnostic-only during
bring-up, or `GST_ENABLE_FBC_CASES=0 GST_REQUIRE_FBC_CASES=0` to omit them from
a narrow debug run.
`generated_dec_h264_env_rfbc` is diagnostic-only coverage for
`GST_MPP_DEC_FBC_IS_RFBC=1`; it forces `mppvideodec fbc=true` so JeffyCN's
userspace caps path reports RFBC instead of ARM AFBC for an otherwise FBC
frame. It records pass/fail negotiation behavior, not a raw-pixel artifact.
The strict decoder-property cases set `fast-mode=false` and
`ignore-error=false`, covering the current plugin path that changes
`MPP_DEC_SET_PARSER_FAST_MODE` and skips the default `MPP_DEC_SET_DISABLE_ERROR`
control before decode starts. The env-default variant runs the same decode with
`GST_MPP_DEC_DEFAULT_FAST_MODE=0` and `GST_MPP_DEC_DEFAULT_IGNORE_ERROR=0`, so
the default-value path is covered separately from explicit element properties.
The env-default format variant runs H.264 decode with
`GST_MPP_VIDEODEC_DEFAULT_FORMAT=NV21`, covering the plugin's global preferred
output-format path and the decoder-side RGA conversion it triggers.
When `GST_H265_10_INPUT` is set, the suite also adds required external-media
4:2:0 10-bit H.265 decode coverage, a scaled `format=NV12` decoder-side RGA
conversion from the compact NV12_10LE40 frame, plus
`GST_MPP_DEC_DISABLE_NV12_10=1`, recording the userspace-visible fallback from
NV12_10LE40 to NV12 on a supplied clip. When `GST_H265_422_10_INPUT` is set,
it does the same for a supplied 4:2:2 10-bit H.265 stream and adds a scaled
`format=NV16` RGA conversion from compact NV16_10LE40 before the
`GST_MPP_DEC_DISABLE_NV16_10=1` fallback case.
The decoder renegotiation cases concatenate two generated elementary streams at
different dimensions and feed them through `filesrc ! *parse ! mppvideodec`,
covering parser caps changes and decoder info-change/reset behavior without
external media assets. The encoder caps-renegotiation cases feed two finite raw
NV12 segments with different dimensions through one `concat ! mpp*h26*enc`
pipeline, forcing JeffyCN's encoder `set_format()` path to drain and reset the
existing MPP session inside one GStreamer pipeline rather than only across
process restarts.
The encoder-control-property cases set non-default `header-mode`, `sei-mode`,
`rc-mode`, `gop`, `max-reenc`, `bps*`, and `max-pending` values and disable
`zero-copy-pkt`, covering the current plugin path that applies
`MPP_ENC_SET_HEADER_MODE`, `MPP_ENC_SET_SEI_CFG`, `MPP_ENC_SET_CFG`, and the
packet copy-out path. Separate required H.264/H.265 RC-mode cases now exercise
the `rc-mode=cbr` narrow-BPS branch and the `rc-mode=fixqp` QP-lock branch and
record encoded bitstream artifacts for forward-port-vs-rewrite comparison.
`enc_h264_env_max_pending` runs the generated H.264
encoder path with `GST_MPP_ENC_MAX_PENDING` set, covering the same
userspace-visible outstanding-frame limit through JeffyCN's global default path
instead of an explicit element property. The codec-specific QP/profile cases
separately cover the current H.264/H.265 plugin properties that update
`rc:qp_*` and, for H.264, `h264:profile`/`h264:level` before the same
`MPP_ENC_SET_CFG` submit.
`enc_h264_env_unaligned_vstride` runs H.264 encode with
`GST_MPP_ENC_UNALIGNED_VSTRIDE=1` and a non-16-aligned even height, covering
the current plugin path that leaves `prep:ver_stride` unaligned for RKVENC.
The event cases use the staged `gstreamer-event-harness` helper to wait until
`mpph264enc`, `mpph265enc`, or `mppvideodec` has produced data, then require
more output afterward. The flush cases send `FLUSH_START`/`FLUSH_STOP` to the
element's sink pad and directly drive JeffyCN's `GstVideoEncoder.flush` and
`GstVideoDecoder.flush` hooks, which call `mpi->reset()`. The force-key-unit
encoder cases send a `GstForceKeyUnit` upstream event from the downstream peer
toward the encoder src pad, covering the plugin path that marks the next frame
as forced-key and calls `MPP_ENC_SET_IDR_FRAME`.
The EOS-loop cases use the same helper in `eos-loop` mode to restart one
finite encoder or generated elementary-stream decoder pipeline repeatedly in one
process. That drives JeffyCN's drain/shutdown paths, which send EOS packets into
MPP and then reuse the same GStreamer element graph for another cycle.
Parallel cases are required by default because CCU/multicore and multi-session
scheduling are part of rewrite parity, not optional diagnostics. Set
`GST_REQUIRE_PARALLEL_CASES=0` to demote them to diagnostics during bring-up, or
`GST_ENABLE_PARALLEL_CASES=0 GST_REQUIRE_PARALLEL_CASES=0` to omit them from a
narrow debug run.

The pinned JeffyCN plugin also registers userspace-visible VP8 and JPEG encoder
or decoder elements (`mppvp8enc`, `mppjpegenc`, and `mppjpegdec`), and may
register `mppvpxalphadecodebin` when built against a new enough GStreamer for
`codecalphademux`/`alphacombine`. Those map to legacy VPU/JPEG hardware or
conditional VPx-alpha helper plumbing outside the RK3588 RKVDEC2/RKVENC2
rewrite profile, so the suite keeps them diagnostic-only: it inspects the
elements, verifies the optional `GST_MPP_VP8ENC_FAKE_VP8ENC=1` `vp8enc` alias
resolves to Rockchip's VP8 encoder rather than a software element, and runs
short `enc_vp8_nv12`, `enc_jpeg_nv12`, and
`roundtrip_jpeg_nv12` pipelines, diagnostic `enc_vp8_qp_props` and
`enc_jpeg_qf_props` property-setter probes, plus explicit
`mppjpegdec format=BGRx` and
`GST_MPP_JPEGDEC_DEFAULT_FORMAT=BGRx` roundtrips, to record what current
userspace would observe without turning legacy coverage into a required pass
condition.
The required encoder-format set now covers JeffyCN's advertised common direct
H.264/H.265 MPP input formats `I420`, `YUY2`, `UYVY`, `RGB16`, `ARGB`,
`ABGR`, `xRGB`, and `xBGR`. The diagnostic encoder-format matrix keeps
chip-dependent direct `NV24`/`Y444` cases plus RGA-forced `NV21`, `I420`, and
`YV12` scale paths outside the required RK3588 gate until hardware logs prove
they are needed for current workloads.

Set `GST_H264_INPUT` and/or `GST_H265_INPUT` to add decode/transcode cases
automatically. With artifact capture enabled, these cases write decoded raw
buffers or encoded elementary streams to the run's artifact manifest just like
the generated-media cases. Set `GST_H265_10_INPUT` for 4:2:0 10-bit H.265
decode/fallback coverage and `GST_H265_422_10_INPUT` for 4:2:2 10-bit H.265
decode/fallback coverage:

```bash
PROFILE=rewrite \
GST_H264_INPUT=assets/sample-1080p.h264 \
GST_H265_INPUT=assets/sample-1080p.h265 \
GST_H265_10_INPUT=assets/sample-main10.h265 \
../rock-5b-ysp/kernel-drivers/tests/gstreamer-suite.sh
```

Set `GST_ENABLE_DISPLAY_CASES=1` to add opt-in display diagnostics against
`GST_DISPLAY_SINK` (default `rkximagesink`). These cases inspect the sink and
run generated H.264/H.265 elementary streams through `mppvideodec
dma-feature=true` into the sink, including AFBC variants. The H.264 DMABuf
display path is also repeated with `KMSSINK_DISABLE_VSYNC=1` and
`GST_RKXIMAGE_USE_COLORKEY=1` to record current `rkximagesink` env behavior.
Set `GST_REQUIRE_DISPLAY_CASES=1` on a board with a known-good display plane to
promote the same cases to required, and pass simple sink properties with
`GST_DISPLAY_SINK_ARGS`, for example `connector-id=... plane-id=...`.
Set `GST_ENABLE_KMS_CASES=1` to add opt-in KMS capture diagnostics for
JeffyCN's `kmssrc`. These inspect `kmssrc`, capture a small number of DRM
framebuffer-backed DMABuf frames to `fakesink`, feed the same capture stream
into `mpph264enc`, repeat the encoder path with
`GST_KMSSRC_DMA_FEATURE=1`, and optionally loop it through `GST_DISPLAY_SINK`.
The encoder cases are the userspace-visible import paths that matter for the
rewrite: they force MPP to consume dma-bufs exported by the display stack
instead of only
buffers allocated by MPP or dma-heap. Set `GST_REQUIRE_KMS_CASES=1` only on a
board/session with a stable active KMS framebuffer. Tune capture with
`GST_KMS_CAPTURE_BUFFERS` and pass source properties such as
`connector-id=... plane-id=... fb-id=...` through `GST_KMS_SRC_ARGS`.

Set `GST_ENABLE_VIDEOFLIP_RGA_CASES=1` to add the external-consumer
`videoflip` diagnostics found in the public librga survey. These inspect
`videoflip` and run `GST_VIDEO_FLIP_USE_RGA=1` NV12/BGRx clockwise rotation
plus BGRx horizontal-flip pipelines. They are diagnostic by default because an
unpatched GStreamer `videoflip` element can ignore the Rockchip env var and use
the generic CPU path; use `GST_REQUIRE_VIDEOFLIP_RGA_CASES=1` only with a
patched plugin/runtime and rewrite counter gates when the run is meant to prove
that this external GStreamer path submitted `/dev/rga` work.

Set `GST_ENABLE_RGACONVERT_CASES=1` to add standalone `gstreamer-rga`/
`rgavideoconvert` diagnostics found in the public librga survey. The suite
inspects `GST_RGACONVERT_ELEMENT` (`rgavideoconvert` by default) and runs short
BGRx->NV12, NV12->BGRx, and BGRx scale pipelines through that element. They are
diagnostic by default because the plugin is not part of the required JeffyCN
bundle; use `GST_REQUIRE_RGACONVERT_CASES=1` only on a runtime where that plugin
is deliberately installed and rewrite counter gates are enabled.

Set `GST_VALIDATE_CASES=1` to run a device-free case-builder validation pass.
That mode skips `/dev/mpp_service`, `/dev/rga`, GStreamer executable, and
plugin-directory preflight, disables artifact capture, builds every selected
required/diagnostic case, and fails if a case name is unknown, a required env var
is missing, or an internal `__builtin_*` payload is not wired into the runner.
It is a maintenance check for the suite matrix, not hardware or plugin
conformance evidence.

Useful explicit case names are `generated_dec_h264_fakesink`,
`generated_dec_h265_fakesink`, `generated_dec_h264_dmabuf`,
`generated_dec_h264_env_dmabuf`, `generated_dec_h265_dmabuf`,
`generated_dec_h264_mp4_codec_data`,
`generated_dec_h265_mp4_codec_data`,
`generated_dec_vp9_fakesink`,
`generated_dec_vp9_dmabuf`, `generated_dec_h264_strict_props`,
`generated_dec_h265_strict_props`, `generated_dec_h264_env_strict_props`,
`generated_dec_h264_env_format_nv21`, `generated_dec_h264_env_no_rga`,
`generated_dec_h264_afbc_fakesink`, `generated_dec_h265_afbc_fakesink`,
`generated_dec_h264_env_fbc`, `generated_dec_h264_env_arm_afbc`,
`generated_dec_h264_env_rfbc`,
`generated_dec_h265_10_fakesink`,
`generated_dec_h265_10_rga_scale`,
`generated_dec_h265_10_env_disable_nv12_10`,
`generated_dec_h265_422_10_fakesink`,
`generated_dec_h265_422_10_rga_scale`,
`generated_dec_h265_422_10_env_disable_nv16_10`,
`generated_dec_h264_renegotiate`,
`generated_dec_h265_renegotiate`, `generated_dec_h264_rga_rotate`,
`generated_dec_h264_rga_rotate_180`, `generated_dec_h264_rga_rotate_270`,
`generated_dec_h264_crop_meta`,
`generated_dec_h264_rga_rgba_scale`, `generated_dec_h264_rga_bgra_scale`,
`generated_dec_h264_rga_rgbx_scale`, `generated_dec_h264_rga_bgrx_scale`,
`generated_dec_h265_rga_scale`, `generated_dec_vp9_rga_scale`,
`generated_transcode_h264_to_h265`,
`generated_transcode_h265_to_h264`,
`generated_transcode_h264_mp4_to_h265`,
`generated_transcode_h265_mp4_to_h264`,
`generated_transcode_h264_rga_to_h265`,
`generated_transcode_h264_dmabuf_to_h265`, `generated_transcode_vp9_to_h264`,
`caps_renegotiate_h264_nv12`, `caps_renegotiate_h265_nv12`,
`enc_h264_control_props`, `enc_h265_control_props`,
`enc_h264_qp_profile_props`, `enc_h265_qp_props`,
`enc_h264_env_no_rga`, `enc_h264_env_max_pending`,
`enc_h264_env_unaligned_vstride`,
`enc_h264_bgrx_rga_rotate_180`, `enc_h264_bgrx_rga_rotate_270`,
`enc_h264_i420`, `enc_h264_yuy2`, `enc_h264_uyvy`,
`enc_h264_rgb16`, `enc_h264_argb`, `enc_h264_abgr`,
`enc_h264_xrgb`, `enc_h264_xbgr`,
`enc_h265_i420`, `enc_h265_yuy2`, `enc_h265_uyvy`,
`enc_h265_rgb16`, `enc_h265_argb`, `enc_h265_abgr`,
`enc_h265_xrgb`, `enc_h265_xbgr`,
`event_flush_enc_h264`, `event_flush_enc_h265`,
`event_force_key_enc_h264`, `event_force_key_enc_h265`,
`event_flush_dec_h264`, `event_flush_dec_h265`,
`eos_loop_enc_h264`, `eos_loop_enc_h265`,
`eos_loop_dec_h264`, `eos_loop_dec_h265`,
`dec_h264_fakesink`, `dec_h265_fakesink`, `dec_h264_rga_rotate`,
`dec_h265_rga_scale`, `dec_h265_10_fakesink`,
`dec_h265_10_rga_scale`, `dec_h265_10_env_disable_nv12_10`,
`dec_h265_422_10_fakesink`, `dec_h265_422_10_rga_scale`,
`dec_h265_422_10_env_disable_nv16_10`, `transcode_h264_to_h265`,
`transcode_h265_to_h264`, `transcode_h264_rga_to_h265`,
`roundtrip_h264_nv12`, `roundtrip_h265_nv12`,
`roundtrip_h264_rga_rotate`, `roundtrip_h264_rga_rotate_270`,
`state_loop_h264_nv12`, and
`state_loop_roundtrip_h264`. The roundtrip cases are asset-free decoder gates:
they feed `videotestsrc` through the MPP encoder, parser, and `mppvideodec` in
one pipeline so GStreamer's decoder-side buffer-group, short-timeout polling,
info-change, and reset paths are exercised even before media assets are staged.
Diagnostic cases include `gst_inspect_mppvp8enc`, `gst_inspect_mppjpegenc`,
`gst_inspect_mppjpegdec`, `gst_inspect_mppvpxalphadecodebin`,
`gst_inspect_vp8enc_alias`, `enc_vp8_nv12`, `enc_vp8_qp_props`,
`enc_jpeg_nv12`, `enc_jpeg_qf_props`,
`roundtrip_jpeg_nv12`, `roundtrip_jpeg_format_bgrx`,
`roundtrip_jpeg_env_format_bgrx`, `event_seek_enc_h264`, `event_seek_enc_h265`,
`event_seek_dec_h264`, `event_seek_dec_h265`,
`enc_h264_nv24`, `enc_h264_y444`, `enc_h265_nv24`, `enc_h265_y444`,
`generated_dec_h264_env_rfbc`,
`generated_dec_vp9_rga_scale`, `generated_transcode_vp9_to_h264`,
`generated_dec_vp8_fakesink`, `generated_dec_vp8_dmabuf`,
`generated_dec_vp8_rga_scale`, `generated_transcode_vp8_to_h264`,
`generated_dec_h263_fakesink`, `generated_dec_h263_rga_scale`,
`generated_transcode_h263_to_h264`,
`generated_dec_mpeg2_fakesink`, `generated_dec_mpeg2_rga_scale`,
`generated_transcode_mpeg2_to_h264`,
`generated_dec_mpeg4_fakesink`, `generated_dec_mpeg4_rga_scale`,
`generated_transcode_mpeg4_to_h264`,
`dec_h264_afbc_fakesink`, and `dec_h265_afbc_fakesink`. They also include a
GStreamer encoder-format matrix for advertised direct H.264/H.265 MPP formats
I420/YUY2/UYVY/RGB16/ARGB/ABGR/xRGB/xBGR plus diagnostic NV24/Y444, plus currently advertised
legacy `c_RkRgaBlit()` conversions: encoder-side
NV21/I420/YV12/BGR16/RGB/BGR/BGRA/RGBx/NV16/NV61 scale paths and decoder-side
BGR16/RGB/BGR/NV21/NV16/NV61/I420/YV12 output-format paths; the
advertised H.264 decoder-side RGBA/BGRA/RGBx/BGRx output-format paths are in
the required set. With
`GST_ENABLE_DISPLAY_CASES=1`, diagnostics also include
`gst_inspect_display_sink`, `generated_dec_h264_display_dmabuf`,
`generated_dec_h265_display_dmabuf`, `generated_dec_h264_display_afbc`, and
`generated_dec_h265_display_afbc`,
`generated_dec_h264_display_env_no_vsync`, and
`generated_dec_h264_display_env_colorkey`. With `GST_ENABLE_KMS_CASES=1`,
diagnostics also include `gst_inspect_kmssrc`, `kms_capture_dmabuf_fakesink`,
`kms_capture_dmabuf_encode_h264`, `kms_capture_env_dmabuf_encode_h264`, and
`kms_capture_dmabuf_display`. Override with `GST_REQUIRED_CASES` or
`GST_DIAGNOSTIC_CASES` for narrower hardware debugging, and tune dimensions with
`GST_WIDTH`, `GST_HEIGHT`, `GST_UNALIGNED_HEIGHT`,
`GST_SCALE_WIDTH`, `GST_SCALE_HEIGHT`,
`GST_NUM_BUFFERS`, `GST_FORMAT_MATRIX_BUFFERS`,
`GST_GENERATED_INPUT_BUFFERS`, `GST_CAPS_RENEGOTIATE_BUFFERS`,
`GST_EVENT_TRIGGER_BUFFERS`, `GST_EVENT_POST_BUFFERS`,
`GST_EVENT_TIMEOUT_MS`, `GST_EVENT_SLEEP_US`, `GST_STATE_LOOPS`,
`GST_ENABLE_PARALLEL_CASES`, `GST_REQUIRE_PARALLEL_CASES`,
`GST_ENABLE_FBC_CASES`, `GST_REQUIRE_FBC_CASES`,
`GST_ENABLE_KMS_CASES`, `GST_REQUIRE_KMS_CASES`,
`GST_KMS_CAPTURE_BUFFERS`, `GST_KMS_SRC_ARGS`, and `GST_TIMEOUT`.
By default `GST_CAPTURE_ARTIFACTS=1` makes generated,
optional external-media decode/transcode, encoded RC-mode, and AFBC transcode
cases write decoded raw buffers or encoded elementary streams under each run's
`artifacts/` directory and records byte counts plus SHA-256s in
`artifacts.tsv`; set it to `0` for pure pass/fail timing runs. Required
generated AFBC/FBC fakesink decode-only cases are intentionally pass/fail-only
and do not add artifact rows. After both
kernels have a suite result, run
`gstreamer-suite-compare.sh`; it follows the same baseline pass vs candidate
pass rule as the MPP/RGA comparators and supports the same `PERF_MAX_RATIO`
elapsed-time slowdown gate. By default `REQUIRE_ARTIFACTS=1` also requires both
runs to have `artifacts.tsv`; required artifact byte-count or checksum
mismatches are regressions even if the pipeline itself exited 0. Set
`REQUIRE_ARTIFACTS=0` only when intentionally comparing older pass/fail-only
logs.

## Suite privileges

| Test | Needs |
|------|-------|
| `build-mpp-tests.sh` | no device access; writes staged MPP library/tests under `../rockchip-conformance/out/mpp` |
| `build-gstreamer-rockchip.sh` | no device access; needs GStreamer development `.pc` files plus staged MPP/librga pkg-config paths; also builds `gstreamer-event-harness` into the GStreamer prefix. `GST_EVENT_HARNESS_VALIDATE_BUILD=1` compiles only the event harness and returns `77` when the GStreamer development `.pc` files are absent. |
| `rewrite-conformance-run.sh` | same device and dependency access as the selected suites; sequences system-info, ABI replay, MPP, librga, GStreamer, FFmpeg, optional `rkmppenc`, optional debugfs counter checks, and optional comparator steps. `VALIDATE_ONLY=1` is device-free and checks runner wiring, syzkaller ABI markers, optional syzkaller description compilation when `SYZKALLER_DIR` and Go are available, ioctl mutator buildability, direct `librga` smoke buildability, optional GStreamer event-harness buildability, RGA IOMMU scatter-fuzzer buildability, recovery stress harness config, MPP/GStreamer case builders, FFmpeg case lists, optional `rkmppenc` case lists, comparator selftests, the ABI replay filter selftest, and the paired-evidence audit selftest. With `PROFILE=*rewrite* RUN_COUNTER_CHECKS=1`, the runner defaults to requiring counter files plus positive librga/GStreamer/FFmpeg hardware-start and busy-time counters, with `rkmppenc` positive MPP/RGA counters added only when `RUN_RKMPPENC_SUITE=1`, and MPP positive counters added when explicit MPP media cases are selected. Per-suite `*_REQUIRED_POSITIVE_COUNTER_PREFIXES` variables add multicore-spread requirements such as `mpp:started_rkvdec_core:2` or `rga:started_rga3_core:2`. If `LIBRGA_FORCE_RGA_USERPTR_IOMMU=1` is also set, the librga counter gate additionally requires positive `rga_userptr_iommu:attempt` and `rga_userptr_iommu:ok` deltas. ABI replay also uses `/dev/dma_heap/*` when available to record MPP dma-buf translate/release, RGA dma-buf import/release parity, and raw RGA physical-address import behavior. |
| `rewrite-evidence-audit.sh` | no device access; reads the latest paired suite logs under `../rockchip-conformance/logs/$BASELINE` and `../rockchip-conformance/logs/$CANDIDATE` for MPP, librga, GStreamer, and FFmpeg by default. Normal mode requires required-case passes on both profiles, non-empty `artifacts.tsv`, non-empty `debugfs-counters-delta.tsv`, and comparator-clean results with `PERF_MAX_RATIO=1.25` unless `REQUIRE_ARTIFACTS=0`, `REQUIRE_COUNTER_DELTAS=0`, `PERF_MAX_RATIO=0`, or `RUN_COMPARATORS=0` deliberately relax the gate. Set `REQUIRE_DIAGNOSTIC_PASS=1` when an opt-in diagnostic run is meant to be hard evidence, and set `AUDIT_REQUIRED_CASES="suite:case ..."` to prove selected optional cases were actually recorded and passed on both profiles. `--selftest` is device-free and part of `VALIDATE_ONLY=1`; normal mode is expected to fail until booted forward-port and rewrite evidence has been collected. |
| `ioctl-fuzz-smoke.sh` | device access for `/dev/mpp_service` and/or `/dev/rga`; no hardware-submit workload by design. `IOCTL_FUZZ_VALIDATE_BUILD=1` is device-free. `IOCTL_FUZZ_FAIL_NTH_MAX=N` additionally needs a fault-injection debug kernel exposing `/proc/self/fail-nth`, and exits `77` if fail-nth mode is requested on a kernel without that proc entry. Set `IOCTL_FUZZ_OUT=<dir>` for persisted logs and `IOCTL_FUZZ_DMESG_SCAN=1`/`IOCTL_FUZZ_REQUIRE_DMESG=1` for dmesg bracketing. |
| `mpp-suite.sh` | device access for `/dev/mpp_service`, `/dev/dma_heap/*`, readable MPP procfs/debugfs, and readable dmesg for full logs; root is the simplest mode. `MPP_VALIDATE_CASES=1` is the device-free maintenance mode and only validates selected case-builder wiring. |
| `mpp-suite-compare.sh` | no device access; reads two `summary.tsv` files under `../rockchip-conformance/logs/` |
| `librga-suite.sh` | device access for `/dev/rga`, `/dev/dma_heap/*`, optional DRM render nodes, readable debugfs/dmesg for full logs, and a staged librga source/lib or `librga.pc` for the in-repo `ysp_librga_smoke` artifact case; root is the simplest mode |
| `librga-suite-compare.sh` | no device access; reads two `summary.tsv` files and, by default, paired `artifacts.tsv` manifests under `../rockchip-conformance/logs/` |
| `gstreamer-suite.sh` | device access for `/dev/mpp_service` and `/dev/rga`, staged JeffyCN plugin under `../rockchip-conformance/out/gstreamer-rockchip`, software `ffmpeg`/`libx265` via `GST_GENERATOR` for generated H.265 Main10 inputs, optional `libaom-av1` support in `GST_GENERATOR` for opt-in AV1 diagnostics, ffmpeg H.263/MPEG encoder support for opt-in legacy decode diagnostics, and readable debugfs/dmesg for full logs; root is the simplest mode. Opt-in `GST_ENABLE_VIDEOFLIP_RGA_CASES=1` cases additionally need a GStreamer `videoflip` element carrying the Rockchip `GST_VIDEO_FLIP_USE_RGA=1` path if the run is meant to prove hardware use rather than generic CPU `videoflip` compatibility. Opt-in `GST_ENABLE_RGACONVERT_CASES=1` cases need the standalone `gstreamer-rga` converter element named by `GST_RGACONVERT_ELEMENT` (`rgavideoconvert` by default). Opt-in display/KMS cases also need staged `rkximage`/`kmssrc` plugins, an active DRM/KMS framebuffer, and access to the DRM device. `GST_VALIDATE_CASES=1` is the device-free maintenance mode and only validates case-builder/runner wiring. |
| `gstreamer-suite-compare.sh` | no device access; reads two `summary.tsv` files under `../rockchip-conformance/logs/` |
| `ffmpeg-suite.sh` | device access for `/dev/mpp_service`, `/dev/rga`, `/dev/dma_heap/*`, and a DRM render node; a staged `ffmpeg-rockchip` build via `FFDIR`; system and/or staged MPP runtime libraries via `FFMPEG_RUNTIME_MODES`, `STAGE`, or `FFMPEG_STAGED_LD_LIBRARY_PATH`; software ffmpeg encoders `libx264`, `libx265`, `libvpx-vp9`, and optionally `libsvtav1`/`libaom-av1` for generated inputs; and readable debugfs/dmesg for full logs. Root is the simplest mode. `FFMPEG_VALIDATE_CASES=1` is the device-free maintenance mode and validates case-list/runtime dispatch wiring. |
| `ffmpeg-suite-compare.sh` | no device access; reads two `summary.tsv` files and, by default, paired `artifacts.tsv` manifests under `../rockchip-conformance/logs/` |
| `rkmppenc-suite.sh` | opt-in app-level `rkmppenc` coverage for `/dev/mpp_service` plus `/dev/rga`; needs `rkmppenc`, software `ffmpeg` via `RKMPPENC_GENERATOR` for generated Y4M/raw/H.264 inputs, optional staged runtime libraries via `RKMPPENC_LD_LIBRARY_PATH`, and readable debugfs/dmesg for full logs. Runtime cases check `--check-mppinfo`, `--check-rgainfo`, generated Y4M H.264/H.265 encode with RGA resize, generated raw NV12 H.264 encode with RGA resize, and a diagnostic hardware-decode/RGA-resize/encode transcode. `RKMPPENC_VALIDATE_CASES=1` is device-free and validates the optional case list without needing `rkmppenc` installed. |
| `rkmppenc-suite-compare.sh` | no device access; reads two opt-in `rkmppenc` `summary.tsv` files and, by default, paired `artifacts.tsv` manifests under `../rockchip-conformance/logs/` |
| `debugfs-counter-check.sh` | no device access after a suite has run; reads a suite directory's `debugfs-counters-delta.tsv` and optionally requires positive hardware counters such as `mpp:started_job_count`, `mpp:hw_total_ns`, `rga:started_job_count`, or `rga:hw_total_ns`. `REQUIRED_ZERO_AFTER_COUNTERS` requires selected gauges to be exactly zero after the run; the forced RGA userptr-IOMMU fallback gate uses this for `rga_userptr_iommu:active`. By default it fails positive rewrite timeout/fault/error counters when the counter file exists. |
| `rewrite-recovery-stress.sh` | root strongly preferred for runtime mode; needs `/dev/mpp_service` and/or `/dev/rga`, the selected `RECOVERY_WORKLOAD_CMD` inputs/artifacts, readable dmesg, and readable rewrite debugfs counters. The `unbind` case also needs writable platform driver bind/unbind files and explicit `RECOVERY_UNBIND_TARGETS`. `RECOVERY_VALIDATE_ONLY=1` is device-free and only validates case/config wiring. |

## What each suite proves

| Test | Exercises | Pass criterion |
|------|-----------|----------------|
| `rewrite-conformance-run.sh` | **full profile conformance orchestration** | Runs the selected profile's system-info, ABI replay, MPP, librga, GStreamer, FFmpeg, and opt-in `rkmppenc` suite steps in a fixed order with deterministic per-suite output directories for that run id, then optionally runs debugfs counter checks and the latest forward-port-vs-rewrite comparators. For rewrite profiles, `RUN_COUNTER_CHECKS=1` defaults to hard hardware-start/busy-time checks for the suites that should submit RGA/MPP work, while avoiding a false MPP hardware requirement for the default `mpp_info_test`-only suite; `rkmppenc` counter checks are added only when `RUN_RKMPPENC_SUITE=1`. In `VALIDATE_ONLY=1` mode it also runs the syzkaller ABI-marker check, optional syzkaller description compilation, compile-only ioctl mutator, direct `librga` smoke, optional GStreamer event-harness, RGA IOMMU scatter-fuzzer, recovery stress harness config validation, MPP/GStreamer case-builder, FFmpeg and `rkmppenc` case-list validation, comparator selftest, ABI replay filter selftest, and evidence-audit selftest checks, so stale ioctl numbers, stale struct sizes, stale ABI replay filters, stale syzlang syntax, or broken fuzzer/smoke/helper sources fail the same device-free maintenance gate as the case builders, comparators, and evidence audit. A nonzero required suite, counter check, syzlang marker check, syzkaller compile check when required/configured, ioctl-fuzz build check, `librga` smoke build check, event-harness build check when dependencies are present, IOMMU-fuzzer build check, recovery harness config check, case-builder/case-list check, comparator result, ABI replay filter selftest, or evidence-audit selftest fails the runner; suite exit `77` still means the relevant device nodes are absent on this boot, while the optional event-harness and syzkaller compile steps use `77` to mean their local development dependencies are not installed/configured. |
| `rewrite-evidence-audit.sh` | **paired forward-port/rewrite evidence gate** | Finds the latest MPP, librga, GStreamer, and FFmpeg suite summaries for the baseline and candidate profiles, verifies both sides have required cases and that every required case passed, requires non-empty artifact and counter-delta manifests by default, then runs the suite comparators with explicit summary paths and a default `PERF_MAX_RATIO=1.25` required-case slowdown ceiling. `REQUIRE_DIAGNOSTIC_PASS=1` promotes all recorded diagnostics in the selected summaries to pass/fail evidence, and `AUDIT_REQUIRED_CASES="suite:case ..."` requires named optional cases such as `gstreamer:rgaconvert_bgrx_to_nv12`, `gstreamer:videoflip_rga_nv12_clockwise`, or `rkmppenc:rkmppenc_avhw_h264_to_hevc_rga_resize` to exist and pass on both profiles. Set `PERF_MAX_RATIO=0` only for exploratory audits where timing is intentionally ignored. Its normal mode is the "do we actually have enough evidence to claim parity?" check and should fail before booted rewrite logs exist; use `--selftest` for the device-free maintenance check. |
| `ioctl-fuzz-smoke.sh` | **non-submit ioctl parser/import fault smoke** | Mutates safe MPP/RGA parser, query, import/release, and request-lifetime ioctls without deliberately submitting register jobs or RGA blits. `IOCTL_FUZZ_FAIL_NTH_MAX=N` runs the same mutator repeatedly with `/proc/self/fail-nth` set immediately around each ioctl, which is the narrow debug-kernel gate for syscall-local allocation/usercopy unwind paths. `IOCTL_FUZZ_FAIL_NTH_REQUIRE_HIT=1` fails a run where the requested fail-nth value never reaches an injectable failure point. With `IOCTL_FUZZ_OUT` and `IOCTL_FUZZ_DMESG_SCAN=1`, each normal or fail-nth run leaves stdout/stderr logs, dmesg before/after snapshots, and fatal-signature files when KASAN/Oops/lockdep/DMA-debug lines appear. |
| `abi-replay.sh` | **non-submit kernel ABI replay** | Runs the C ABI probe on the booted `/dev/mpp_service` and `/dev/rga`, saves raw/normalized logs, and extracts a comparable log plus the stable contract subset for forward-port-vs-rewrite diffing. It records ioctl numbers, struct sizes, version/query returns, safe MPP session controls, multi-message setup, bad-fd batch return markers, optional dma-heap-backed MPP `TRANS_FD_TO_IOVA`/`RELEASE_FD`, RGA version/no-op behavior, virtual-address plus optional dma-buf import/release, and raw physical-address import behavior. `PROFILE=*rewrite*` defaults `ABI_PROBE_EXPECT_RGA_PHYSICAL_REJECT=1` so accepting raw physical-address import fails rewrite runs; `.compare.log` and `.contract.log` omit that intentionally pruned path so forward-port/default direct runs remain observational. `--selftest` verifies volatile-value normalization, physical-import pruning, and preservation of the modern `RGA_IOC_REQUEST_CONFIG` unsupported errno in `.contract.log`. Exit `77` means both device nodes are absent. |
| `mpp-suite.sh` | **official MPP test conformance** using `../rockchip-conformance/out/mpp/bin` | Runs the selected MPP official-test matrix under the selected `PROFILE`, records per-case logs/status/commands plus MPP procfs/debugfs snapshots and counter deltas, and fails required cases. Default required case is `mpp_info_test`; codec and performance cases are opt-in so missing assets do not masquerade as driver regressions. Media cases write `artifacts.tsv` rows for produced decode/encode outputs; set `MPP_DUMP_OUTPUTS=1` to make decode cases dump YUV outputs for byte-exact comparison. Explicit VP9 decode cases can generate a shared IVF input when `MPP_VP9_INPUT` is unset. Set `MPP_VALIDATE_CASES=1` to validate the selected case builders without touching `/dev/mpp_service`. Exit `77` means `/dev/mpp_service` is absent in runtime mode. |
| `mpp-suite-compare.sh` | **rewrite-vs-forward-port MPP comparator** | Compares the latest or explicitly provided `summary.tsv` files and, when `artifacts.tsv` manifests are present, compares official-test output byte counts and SHA-256s. A required baseline pass that is not a candidate pass, a required artifact mismatch, or a required pass/pass slowdown above `PERF_MAX_RATIO` is a regression and exits nonzero; diagnostic differences and slowdowns remain informational. Set `PERF_MAX_RATIO` to fail required pass/pass slowdowns above that ratio, and set `REQUIRE_ARTIFACTS=1` for full media gates that must reject missing/empty artifact manifests. |
| `librga-suite.sh` | **official librga sample conformance plus direct artifact smoke** using `../rockchip-conformance/out/librga-samples/bin` and `librga-smoke.cpp` | Runs the broad current Linux/RK3588 sample set plus `ysp_librga_smoke` under the selected `PROFILE`, records per-case logs/status plus RGA debugfs snapshots and counter deltas, and fails required cases. The direct smoke case records deterministic destination buffers in `artifacts.tsv` for maintained im2d including fd-backed `imcvtcolor`, async `imresize` with release-fence wait, crop, flip, `imrectangle()` border drawing, and `imrectangleTaskArray()` job-array border drawing, RKNN/RKNPU-style preprocessing including RGBA crop/letterbox, an `rkmppenc`-shaped fd-backed crop/CSC/resize fence chain, pre-intr, AFBC16x16 and tile8x8 round-trips, Gaussian, GStreamer/display-shaped legacy `c_RkRgaBlit()` paths including virtual RGBA flip, fd-backed legacy `c_RkRgaColorFill()`, and a sequential IM2D task-job copy chain, logs a no-submit physical-address import probe, and records public-API AFBC32x8/RFBC64x4 destination-mode negative probes. `LIBRGA_SMOKE_DISPLAY_TAIL=1` adds opt-in public UI/display-tail BGRA, XRGB, and RGB565 fd-backed legacy display-rotation artifacts plus a BGRA partial-rectangle alpha-blend artifact. `LIBRGA_FORCE_RGA_USERPTR_IOMMU=1` sets `userptr_iommu/force_remap` for the run and snapshots `rga_userptr_iommu` counters so virtual-address fallback attribution is deterministic instead of allocation-luck-dependent. `PROFILE=*rewrite*` defaults the physical/FBC-tail probes to hard negative assertions; forward-port runs keep them observational. Diagnostic outside-slice cases are recorded for parity investigation without turning the whole suite red. Exit `77` means `/dev/rga` is absent. |
| `librga-suite-compare.sh` | **rewrite-vs-forward-port suite comparator** | Compares the latest or explicitly provided `summary.tsv` files and, by default, paired `artifacts.tsv` manifests. A required baseline pass that is not a candidate pass, a required artifact mismatch, or a required pass/pass slowdown above `PERF_MAX_RATIO` is a regression and exits nonzero; diagnostic differences and slowdowns remain informational. Set `PERF_MAX_RATIO` to fail required pass/pass slowdowns above that ratio, and set `REQUIRE_ARTIFACTS=0` only for legacy pass/fail-only logs. |
| `gstreamer-suite.sh` | **JeffyCN GStreamer MPP/RGA plugin conformance** using `../rockchip-conformance/out/gstreamer-rockchip` | Runs plugin inspection plus real encode, generated 8-bit/10-bit decode/transcode, RGA-conversion, caps-renegotiation, explicit flush-event, restart-loop, AFBC decode-to-encode transcodes, optional external-media pipelines, opt-in `GST_VIDEO_FLIP_USE_RGA=1` `videoflip` NV12/BGRx rotate/flip pipelines, opt-in standalone `GST_RGACONVERT_ELEMENT` BGRx/NV12 convert/scale pipelines for the external GStreamer RGA path, and opt-in display/KMS capture pipelines under the selected `PROFILE`. It records per-case logs/status/commands, generated and optional external-media decode/transcode artifact checksums, encoded RC-mode/AFBC artifacts, plus MPP/RGA debugfs snapshots and counter deltas. Exit `77` means `/dev/mpp_service` or `/dev/rga` is absent. |
| `gstreamer-suite-compare.sh` | **rewrite-vs-forward-port GStreamer comparator** | Compares the latest or explicitly provided `summary.tsv` files and, by default, requires `artifacts.tsv` on both sides for generated and optional external-media decode/transcode byte-count and SHA-256 comparison. A required baseline pass that is not a candidate pass, a missing required artifact manifest, a required artifact mismatch, or a required pass/pass slowdown above `PERF_MAX_RATIO` is a regression and exits nonzero; diagnostic differences and slowdowns remain informational. Set `REQUIRE_ARTIFACTS=0` for legacy pass/fail-only logs. |
| `ffmpeg-suite.sh` | **ffmpeg-rockchip CLI conformance** using `FFDIR/ffmpeg` and `FFDIR/ffprobe` | Runs system-runtime and staged-MPP-runtime passes when available, component/option inspection, device/support preflight, required H.264/H.265/VP9 RKMPP decode and bit-exact PSNR, generated H.264/H.265 encoder-option encodes with PSNR sanity, generated-input H.264<->`scale_rkrga`<->H.265 hardware transcodes, required `scale_rkrga`, `vpp_rkrga`, and `overlay_rkrga` coverage, plus diagnostic/promotable AV1 decode/RGA/transcode/AFBC coverage. Diagnostics also cover H.265 Main10/P010 RGA and H.264 resolution changes; opt-in stress adds repeated short loops and an AV1->RGA->H.264 soak. It records per-case logs/status, encoded bitstream byte counts and SHA-256s, plus MPP/RGA debugfs snapshots and counter deltas. Exit `77` means `/dev/mpp_service` or `/dev/rga` is absent. |
| `ffmpeg-suite-compare.sh` | **rewrite-vs-forward-port ffmpeg-rockchip comparator** | Compares the latest or explicitly provided `summary.tsv` files and, by default, requires `artifacts.tsv` on both sides for encoded bitstream byte-count and SHA-256 comparison. A required baseline pass that is not a candidate pass, a missing required artifact manifest, a required artifact mismatch, or a required pass/pass slowdown above `PERF_MAX_RATIO` is a regression and exits nonzero. Set `REQUIRE_ARTIFACTS=0` for legacy pass/fail-only logs. |
| `rkmppenc-suite.sh` | **optional rkmppenc app-level conformance** using `rkmppenc` | Runs `--check-mppinfo`, `--check-rgainfo`, generated Y4M H.264/H.265 encode with `--output-res` plus `--vpp-resize rga_bilinear`, generated raw NV12 H.264 encode through the same RGA resize path, and a diagnostic generated H.264 hardware-decode to HEVC encode transcode through `--avhw`. It records per-case logs/status, encoded output byte counts and SHA-256s, plus MPP/RGA debugfs counter deltas. This suite proves an independent MPP-frame producer/filter graph from the public `rkmppenc` app, but remains opt-in because the direct `librga-smoke` already covers the kernel-visible fd-backed crop/CSC/resize/fence chain. |
| `rkmppenc-suite-compare.sh` | **rewrite-vs-forward-port rkmppenc comparator** | Compares the latest or explicitly provided opt-in `rkmppenc` `summary.tsv` files and, by default, requires `artifacts.tsv` on both sides for encoded bitstream byte-count and SHA-256 comparison. A required baseline pass that is not a candidate pass, a missing required artifact manifest, a required artifact mismatch, or a required pass/pass slowdown above `PERF_MAX_RATIO` is a regression and exits nonzero. Set `REQUIRE_ARTIFACTS=0` only for legacy pass/fail-only logs. |
| `debugfs-counter-check.sh` | **rewrite counter-delta gate** | Checks a captured `debugfs-counters-delta.tsv` from any suite. Use `REQUIRED_POSITIVE_COUNTERS` to prove selected hardware paths actually submitted and reached the IRQ/completion timing path; use `REQUIRED_POSITIVE_COUNTER_PREFIXES` with `component:counter_prefix:min_positive` to prove multicore spread across per-core counters; use `REQUIRED_ZERO_AFTER_COUNTERS` for gauges that must settle back to zero at rest; use `FORBID_POSITIVE_COUNTERS` to override the default timeout/fault/error guard. This complements elapsed-time comparison because it catches “userspace passed but the rewrite did no hardware work” and “all work stuck to one core” cases. |
| `rewrite-recovery-stress.sh` | **reset/recovery stress harness** | Runs kill/close, reset-opener, and opt-in platform unbind/rebind loops around an explicit busy workload, then runs a post-case liveness command, scans new dmesg lines for fatal signatures, and records before/after/delta debugfs counters. `RECOVERY_VALIDATE_ONLY=1` validates the script config without touching devices and is included in the top-level `VALIDATE_ONLY=1` runner; it is not proof that close/reset/unbind recovery works on hardware. Runtime exit `77` means both device nodes are absent. |

## Running the suites & comparators

```bash
VALIDATE_ONLY=1 bash rewrite-conformance-run.sh  # device-free runner/syzlang/syzkaller/ioctl-fuzz/librga-smoke/gstreamer-harness/iommu-fuzz/recovery/case/comparator/abi-replay/evidence wiring check
VALIDATE_ONLY=1 PROFILE=rewrite RUN_COUNTER_CHECKS=1 bash rewrite-conformance-run.sh  # also validate rewrite counter-default wiring
VALIDATE_ONLY=1 PROFILE=rewrite RUN_COUNTER_CHECKS=1 LIBRGA_FORCE_RGA_USERPTR_IOMMU=1 bash rewrite-conformance-run.sh  # also validate RGA userptr-IOMMU fallback counter-default wiring
IOCTL_FUZZ_VALIDATE_BUILD=1 bash ioctl-fuzz-smoke.sh  # device-free mutator build check
sudo IOCTL_FUZZ_OUT=../rockchip-conformance/logs/rewrite/ioctl-failnth IOCTL_FUZZ_DMESG_SCAN=1 IOCTL_FUZZ_FAIL_NTH_MAX=4 IOCTL_FUZZ_ITERS=32 bash ioctl-fuzz-smoke.sh  # debug-kernel fail-nth allocation/usercopy sweep
PROFILE=rewrite bash rewrite-conformance-run.sh  # run all suites for the booted rewrite profile
PROFILE=rewrite RUN_COMPARE=1 bash rewrite-conformance-run.sh  # run and compare latest summaries
PROFILE=rewrite RUN_COUNTER_CHECKS=1 bash rewrite-conformance-run.sh  # add default rewrite hardware counter gates
PROFILE=rewrite RUN_COUNTER_CHECKS=1 LIBRGA_FORCE_RGA_USERPTR_IOMMU=1 RUN_SYSTEM_INFO=0 RUN_ABI_REPLAY=0 RUN_MPP_SUITE=0 RUN_GSTREAMER_SUITE=0 RUN_FFMPEG_SUITE=0 RUN_LIBRGA_SUITE=1 bash rewrite-conformance-run.sh  # focused RGA userptr-IOMMU fallback attribution gate
RKMPPENC_VALIDATE_CASES=1 bash rkmppenc-suite.sh  # device-free optional rkmppenc case-list validation
PROFILE=rewrite RUN_RKMPPENC_SUITE=1 RUN_COUNTER_CHECKS=1 bash rewrite-conformance-run.sh  # opt-in rkmppenc app-level MPP/RGA gate
PROFILE=rewrite RUN_RKMPPENC_SUITE=1 RUN_COMPARE=1 bash rewrite-conformance-run.sh  # run and compare latest opt-in rkmppenc summaries too
bash mpp-suite.sh                     # official MPP test conformance
MPP_VALIDATE_CASES=1 bash mpp-suite.sh  # device-free MPP official-test case-builder validation
bash mpp-suite-compare.sh             # compare latest forward-port/rewrite MPP summaries
bash librga-suite.sh                  # official librga sample conformance
LIBRGA_SMOKE_DISPLAY_TAIL=1 bash librga-smoke.sh  # direct display/UI tail rotation and partial-blend artifacts
bash librga-suite-compare.sh          # compare latest forward-port/rewrite suite summaries
GST_VALIDATE_CASES=1 bash gstreamer-suite.sh  # device-free GStreamer case-builder validation
GST_VALIDATE_CASES=1 GST_ENABLE_VIDEOFLIP_RGA_CASES=1 bash gstreamer-suite.sh  # validate opt-in videoflip/RGA external-consumer wiring
GST_VALIDATE_CASES=1 GST_ENABLE_RGACONVERT_CASES=1 bash gstreamer-suite.sh  # validate opt-in standalone gstreamer-rga converter wiring
bash gstreamer-suite.sh               # JeffyCN GStreamer MPP/RGA conformance
bash gstreamer-suite-compare.sh       # compare latest forward-port/rewrite GStreamer summaries
FFMPEG_VALIDATE_CASES=1 bash ffmpeg-suite.sh   # device-free FFmpeg case-list validation
FFMPEG_VALIDATE_CASES=1 FFMPEG_REQUIRE_AV1=1 FFMPEG_RUN_STRESS=1 FFMPEG_STRESS_LOOPS=1 bash ffmpeg-suite.sh  # validate promoted/optional FFmpeg wiring
bash ffmpeg-suite.sh                  # ffmpeg-rockchip CLI conformance
sudo FFMPEG_REQUIRE_AV1=1 FFMPEG_RUNTIME_MODES="system staged" bash ffmpeg-suite.sh  # AV1-capable board/runtime gate
bash ffmpeg-suite-compare.sh          # compare latest forward-port/rewrite FFmpeg summaries
bash rkmppenc-suite-compare.sh        # compare latest opt-in forward-port/rewrite rkmppenc summaries
bash suite-compare-selftest.sh        # device-free comparator regression selftest
bash abi-replay.sh --selftest         # device-free ABI replay normalization/filter regression selftest
bash rewrite-evidence-audit.sh --selftest  # device-free paired-evidence audit regression selftest
bash rewrite-evidence-audit.sh        # audit latest paired forward-port/rewrite evidence; expected to fail until full booted logs exist
SUITES="mpp librga gstreamer ffmpeg rkmppenc" bash rewrite-evidence-audit.sh  # include optional rkmppenc once both profiles have logs
SUITES="gstreamer rkmppenc" REQUIRE_DIAGNOSTIC_PASS=1 AUDIT_REQUIRED_CASES="gstreamer:rgaconvert_bgrx_to_nv12 gstreamer:videoflip_rga_nv12_clockwise rkmppenc:rkmppenc_avhw_h264_to_hevc_rga_resize" bash rewrite-evidence-audit.sh  # hard-audit selected optional librga consumer tails
PERF_MAX_RATIO=0 bash rewrite-evidence-audit.sh  # exploratory paired audit without the default 1.25x slowdown ceiling
AUDIT_COUNTER_CHECKS=0 bash rewrite-evidence-audit.sh  # exploratory paired audit without candidate hardware-counter content checks
RECOVERY_VALIDATE_ONLY=1 bash rewrite-recovery-stress.sh  # device-free recovery stress harness config check
sudo RECOVERY_WORKLOAD_CMD='PROFILE=rewrite RUN_COUNTER_CHECKS=1 bash "$TEST_DIR/rewrite-conformance-run.sh"' RECOVERY_CASES="kill reset" bash rewrite-recovery-stress.sh
sudo RECOVERY_CASES=list-bindings bash rewrite-recovery-stress.sh  # discover opt-in unbind targets
```

For MPP media parity, run the same official-test cases on the forward port and
rewrite with identical inputs and `MPP_DUMP_OUTPUTS=1`. Encoder and RC2 cases
already emit bitstreams; `MPP_DUMP_OUTPUTS=1` adds decoded YUV dumps for decode
cases. `mpp-suite-compare.sh` compares `artifacts.tsv` rows whenever both
manifests exist, and `REQUIRE_ARTIFACTS=1` makes a missing or empty manifest a
hard failure for full media conformance runs.

The top-level `rewrite-evidence-audit.sh` now passes
`PERF_MAX_RATIO=1.25` to every selected suite comparator by default, because the
rewrite goal includes forward-port-level performance. For manual comparator
runs or a stricter/looser audit, set a candidate/baseline elapsed-time ceiling.
The suite wrappers record fractional `elapsed_s` values, so short RGA and
GStreamer cases still produce usable ratios. For example, this fails any
required case that passes on both profiles but takes more than 25% longer on
the rewrite:

```bash
PERF_MAX_RATIO=1.25 bash mpp-suite-compare.sh
PERF_MAX_RATIO=1.25 bash librga-suite-compare.sh
PERF_MAX_RATIO=1.25 bash gstreamer-suite-compare.sh
PERF_MAX_RATIO=1.25 bash ffmpeg-suite-compare.sh
PERF_MAX_RATIO=1.25 bash rkmppenc-suite-compare.sh
```

For `CANDIDATE=*rewrite*`, `rewrite-evidence-audit.sh` also checks the
candidate counter contents by default, not just that the candidate
`debugfs-counters-delta.tsv` exists. The audit uses the same default positive
hardware-start and busy-time counters as the profile runner for librga,
GStreamer, FFmpeg, and optional `rkmppenc`; it keeps MPP positive counters
opt-in because the default MPP suite is `mpp_info_test` only. The audit still
uses `debugfs-counter-check.sh`'s default timeout/fault/error guard for every
selected rewrite suite and adds the forced RGA userptr-IOMMU fallback `rga_userptr_iommu:attempt`,
`rga_userptr_iommu:ok`, and zero-after `rga_userptr_iommu:active` requirements when
`LIBRGA_FORCE_RGA_USERPTR_IOMMU=1`. Use `AUDIT_COUNTER_CHECKS=0` only when intentionally
inspecting old logs that predate the rewrite debugfs counter contract.

For rewrite runs with selected hardware cases, also gate the captured debugfs
counter deltas so a userspace pass cannot hide a missing hardware submission or
timer path. `rewrite-conformance-run.sh` can run those checks automatically with
`RUN_COUNTER_CHECKS=1`; it always points the selected suite wrappers at known
`$CONFORMANCE_ROOT/logs/$PROFILE/$RUN_ID-*-suite/` directories so the matching
counter files are unambiguous. For `PROFILE=*rewrite*`, the profile runner also
defaults to requiring the counter files plus positive librga/GStreamer/FFmpeg
hardware-start and busy-time counters; it adds positive MPP counters only when
`MPP_REQUIRED_CASES` explicitly selects media cases because the default
`mpp_info_test` case does not submit hardware. Set `REWRITE_COUNTER_DEFAULTS=0`
to disable those automatic requirements for a narrow diagnostic pass. The
checker defaults to failing positive timeout/fault/error counters when the delta
file exists. To prove multicore spread, set
`REQUIRED_POSITIVE_COUNTER_PREFIXES` directly, or the per-suite runner variables
`MPP_REQUIRED_POSITIVE_COUNTER_PREFIXES`,
`LIBRGA_REQUIRED_POSITIVE_COUNTER_PREFIXES`,
`GSTREAMER_REQUIRED_POSITIVE_COUNTER_PREFIXES`, and
`FFMPEG_REQUIRED_POSITIVE_COUNTER_PREFIXES`. Prefix specs use
`component:counter_prefix:min_positive`; for example,
`mpp:started_rkvdec_core:2` requires at least two MPP decoder-core counters with
positive deltas. Override or add explicit positive counters when a run
intentionally uses a different suite mix:

```bash
SUMMARY=../rockchip-conformance/logs/rewrite/<run>-mpp-suite/summary.tsv \
REQUIRED_POSITIVE_COUNTERS="mpp:started_job_count mpp:hw_total_ns" \
REQUIRED_POSITIVE_COUNTER_PREFIXES="mpp:started_rkvdec_core:2" \
bash debugfs-counter-check.sh

SUMMARY=../rockchip-conformance/logs/rewrite/<run>-librga-suite/summary.tsv \
REQUIRED_POSITIVE_COUNTERS="rga:started_job_count rga:hw_total_ns" \
REQUIRED_POSITIVE_COUNTER_PREFIXES="rga:started_rga3_core:2" \
bash debugfs-counter-check.sh

SUMMARY=../rockchip-conformance/logs/rewrite/<run>-librga-suite/summary.tsv \
REQUIRED_POSITIVE_COUNTERS="rga:started_job_count rga:hw_total_ns rga_userptr_iommu:attempt rga_userptr_iommu:ok" \
REQUIRED_ZERO_AFTER_COUNTERS="rga_userptr_iommu:active" \
bash debugfs-counter-check.sh

SUMMARY=../rockchip-conformance/logs/rewrite/<run>-gstreamer-suite/summary.tsv \
REQUIRED_POSITIVE_COUNTERS="mpp:started_job_count rga:started_job_count mpp:hw_total_ns rga:hw_total_ns" \
bash debugfs-counter-check.sh
```

Maintenance gate: `shellcheck *.sh` in this directory and
`VALIDATE_ONLY=1 bash rewrite-conformance-run.sh` are expected to pass; they
now include the syzkaller ABI-marker consistency check,
optional syzkaller description compilation when `SYZKALLER_DIR` and Go are
available,
`IOCTL_FUZZ_VALIDATE_BUILD=1` ioctl-mutator compile check,
`LIBRGA_SMOKE_VALIDATE_BUILD=1` direct `librga` smoke compile check, and
`IOMMU_FUZZ_VALIDATE_BUILD=1` RGA IOMMU scatter-fuzzer compile check, and
`RECOVERY_VALIDATE_ONLY=1` recovery stress harness config check in addition
to the runner, MPP/GStreamer case-builder, FFmpeg case-list, comparator,
`abi-replay.sh --selftest`, and `rewrite-evidence-audit.sh --selftest` checks;
it also attempts a
`GST_EVENT_HARNESS_VALIDATE_BUILD=1` GStreamer event-harness build when
GStreamer development `.pc` files are installed. They were last verified on
2026-07-06 after the syzkaller ABI-marker, ioctl-fuzz build, direct `librga`
smoke build, optional GStreamer event-harness build, IOMMU-fuzzer build,
recovery stress config check, and MPP case-builder validation
steps were wired into `rewrite-conformance-run.sh`, after the evidence-audit
selftest was added to the same maintenance gate, after that checker was made
safe for concurrent validation runs by giving `abi-probe.sh` a private build
directory, after direct `librga-smoke` coverage gained the `rkmppenc`-shaped fd-backed
crop/CSC/resize fence chain, after it added a public-API tile8x8
round-trip artifact, and after it added a public-API AFBC16x16 round-trip
artifact. Historical reruns include the checks after generated GStreamer H.264
RGBA/BGRA/RGBx/BGRx decoder output-format cases were promoted to required;
after GStreamer `crop-rectangle` crop-meta
decode coverage was promoted to required; after the required GStreamer public
encoder/decoder 270-degree and decoder 180-degree RGA rotation cases were
added; after the dormant GStreamer libmpp batch-server mixed H.264/H.265
parallel decode case was removed from the required set; after
diagnostic GStreamer
`GST_MPP_VP8ENC_FAKE_VP8ENC` alias validation was added; after diagnostic
GStreamer JPEG decoder
explicit-format and `GST_MPP_JPEGDEC_DEFAULT_FORMAT` cases were added; after
required generated GStreamer H.264
decode output-format cases were expanded for the advertised RGBA/BGRA/RGBx/BGRx
decoder-side RGA paths; after common direct GStreamer H.264/H.265 encoder-format
cases were promoted to required while the diagnostic matrix kept chip-dependent
NV24/Y444 plus remaining NV21/I420/YV12 RGA scale paths; after the `GST_VALIDATE_CASES=1`
GStreamer case-builder/runner dry validation mode was added; after
`FFMPEG_VALIDATE_CASES=1` dry validation, FFmpeg system/staged runtime passes,
VP9 required decode/PSNR gates, AV1 diagnostic/promotable decode/RGA/transcode
coverage, H.265 Main10/P010 and resolution-change diagnostics, stress/soak
hooks, decoder-option, H.264/H.265 encoder-option, forced-core/async/AFBC,
`vpp_rkrga`, and `overlay_rkrga` cases were added;
after opt-in external GStreamer `videoflip` RGA diagnostics were added for
`GST_VIDEO_FLIP_USE_RGA=1` NV12/BGRx rotate/flip paths;
after
`ffmpeg-suite.sh` and
`ffmpeg-suite-compare.sh` made ffmpeg-rockchip a first-class
forward-port-vs-rewrite conformance gate with encoded-bitstream artifacts; after the
`GST_MPP_VIDEODEC_DEFAULT_ARM_AFBC=1` alias was added to the required
GStreamer AFBC/FBC fakesink decode-output coverage; after generated GStreamer
AFBC/FBC fakesink decode-output cases were promoted to required pass/fail
coverage and generated AFBC decode-to-encode transcodes were added with
encoded-artifact comparison; after diagnostic
`GST_MPP_DEC_FBC_IS_RFBC=1` coverage was added for JeffyCN's RFBC caps path;
after diagnostic VP8 QP and JPEG quality-factor property coverage was added;
after opt-in KMS capture coverage was expanded for
`GST_KMSSRC_DMA_FEATURE=1`;
after opt-in display sink coverage was expanded for
`KMSSINK_DISABLE_VSYNC=1` and `GST_RKXIMAGE_USE_COLORKEY=1`;
after the GStreamer codec-specific encoder QP
cases and encoded
CBR/FIXQP RC-mode artifact cases were added to the required set; after the
GStreamer env-default strict decoder and env-default decoder
DMA-feature/output-format cases were added to the required set; after the
GStreamer encoder unaligned-vstride env-default case was added to the required
set; after the GStreamer encoder max-pending env-default case was added to the
required set; after GStreamer MP4 container codec-data decode/transcode cases
were added to the required set; after GStreamer no-RGA env-default
encode/decode cases were added to the required set; after generated H.265
Main10 decode/fallback/RGA-conversion cases were added to the required set and
generated H.265 4:2:2 10-bit cases were added as opt-in coverage; after opt-in
10-bit H.265 external-media decode/fallback/RGA-conversion cases were added; after the
conditional GStreamer VPx-alpha decodebin inspect was added as diagnostic
coverage; after the GStreamer strict decoder-property cases were wired into the
generated-decode builtin dispatch, the asset-free parallel cases became
required by default, and after the direct `librga` smoke gained forced-core,
fence, pre-intr, dma-buf fd-import, opt-in P010/P210 IM2D conversion, and
legacy `c_RkRgaBlit()`
coverage for the GStreamer virtual-source, fd-backed rotate/convert, and planar
fallback shapes; after the MPP official-test suite/comparator and build helper
were added; and after the GStreamer build wrapper, suite, comparator, opt-in
display/DMABuf sink diagnostics, asset-free decoder roundtrip,
generated-media decode/transcode, explicit flush-event, EOS-loop,
generated-AFBC cases, and generated multi-stream diagnostics
were added. It was re-run after the GStreamer KMS capture diagnostics were
added for `kmssrc` DMABuf capture into MPP encode and display loopback; after
the GStreamer generated-input cache,
artifact-checksum comparator, and generated VP9 IVF decode cases were added.
It was re-run after ABI replay gained optional dma-heap-backed MPP
`TRANS_FD_TO_IOVA`/`RELEASE_FD`, RGA dma-buf import/release coverage for
GStreamer allocator handoff parity, and raw RGA physical-address import
observation; and after opt-in generated GStreamer AV1
diagnostics were added for the separate RKMPP AV1 backend gap; and after
opt-in generated VP8/H.263/MPEG diagnostics were added for advertised legacy
decoder caps outside the RK3588 rewrite gate; and after `debugfs-counter-check.sh`
was added to gate selected rewrite hardware-start/busy-time counter deltas and
default timeout/fault/error counters; after `rewrite-conformance-run.sh`
started defaulting those positive hardware-start/busy-time requirements for
rewrite profile runs with `RUN_COUNTER_CHECKS=1`; and after required GStreamer
encoder/decoder RGA rotation cases were extended to cover the remaining
180/270-degree public rotation values. The device-free
`suite-compare-selftest.sh` covers the comparator pass, functional regression,
slowdown, MPP/GStreamer/FFmpeg artifact mismatch, debugfs counter-check pass
and failure paths, and librga latest-summary filtering paths. `build-mpp-tests.sh`
staged the official MPP binaries locally; `build-gstreamer-rockchip.sh`
currently stops at its dependency preflight on this host because the GStreamer
development `.pc` files are missing.

## Rewrite acceptance (one command)

For rewrite acceptance, boot a kernel where `ROCKCHIP_MPP_REWRITE` and
`ROCKCHIP_RGA_REWRITE` own the device nodes, then run:

```bash
sudo MPP_BUILD=<mpp-build> FFDIR=<ffmpeg-rockchip> STAGE=<stage> bash rewrite-smoke.sh
```

The same command is valid on the BSP-derived forward-port kernel, which makes it
the quick parity check between the two implementations. (`rewrite-smoke.sh`
itself is documented in [`README.md`](./README.md).)

For the full userspace-visible parity gate, collect the full forward-port
profile first, then reboot into the rewrite and compare against it:

```bash
sudo PROFILE=forward-port bash rewrite-conformance-run.sh
sudo PROFILE=rewrite RUN_COMPARE=1 bash rewrite-conformance-run.sh
```

## Raw ABI replay comparisons

For raw ABI replay comparisons, record one normalized log set under each booted
kernel profile:

```bash
PROFILE=forward-port bash abi-replay.sh
PROFILE=rewrite BASELINE=forward-port bash abi-replay.sh
```

`abi-replay.sh` stores raw, normalized, comparable, and contract logs under
`kernel-drivers/tests/logs/abi-replay/`. Normalization removes volatile file
descriptor, import-handle, request-id, dma-buf heap, and IOVA values. The
forward-port-vs-rewrite `diff -u` uses `.compare.log`, which additionally drops
the intentionally pruned raw physical-address import path while preserving that
evidence in `.raw.log` and `.norm.log`. It also writes a smaller `.contract.log`
that keeps the stable query/version and session-control lines, including
optional dma-heap-backed MPP `TRANS_FD_TO_IOVA`/`RELEASE_FD`, RGA dma-buf
import/release, and the intentional legacy `RGA2_GET_VERSION ret=1` result
copied from the BSP/librga contract. It also records a handle-backed modern
`RGA_IOC_REQUEST_CONFIG` unsupported-profile case whose observable errno is
`EFAULT`, matching the BSP request wrapper after the initial request-check
stage has passed. Use `abi-replay.sh --selftest` to verify those filters remain
stable without requiring device nodes.

## VP9 decode via the suites

The GStreamer suite generates a short VP9 IVF stream with `vp9enc ! ivfmux`
and requires `generated_dec_vp9_fakesink` plus `generated_dec_vp9_dmabuf` by
default, matching JeffyCN `mppvideodec`'s advertised `video/x-vp9` sink caps.
This is still not a recorded hardware pass; run it under both
`PROFILE=forward-port` and `PROFILE=rewrite`, then compare with
`gstreamer-suite-compare.sh`.

The direct MPP suite path is:

```bash
PROFILE=rewrite \
MPP_REQUIRED_CASES="mpp_info_test mpi_dec_vp9" \
../rock-5b-ysp/kernel-drivers/tests/mpp-suite.sh
```

If `MPP_VP9_INPUT` is unset, `mpp-suite.sh` generates the IVF file under
`../rockchip-conformance/assets/mpp-generated`. The manual `mpi_dec_test` VP9
recipe (no suite) lives in [`README.md`](./README.md) § VP9 decode.
At the kernel level, the current rewrite pins also include KUnit coverage for
VP9 RKVDEC fd-to-IOVA register translation/validation, including rejection of
unknown RKVDEC format-table indices.
They also cover `MPP_CMD_SET_ERR_REF_HACK` copy/discard behavior for the current
libmpp VDPU382 probe path, and `SET_SESSION_FD` batch-server wait-array
recognition plus collector-level rejection so the dormant multi-slot polling
shape fails with `-EOPNOTSUPP` without status-slot writeback instead of
extending the ABI beyond BSP-visible normal submissions.
The RGA side also includes KUnit coverage for the default legacy
`RGA_BLIT_SYNC` `c_RkRgaBlit()` path used by JeffyCN GStreamer: a sync ioctl
queues behind a busy core, waits for queued completion, and does not copy an
async release fence back to userspace. It also covers the legacy flush/result
no-op ioctl return contract used by librga's post-blit compatibility path and
the BGRx->BGRx 90-degree display-shaped legacy blit profile used by public
compositor/game-UI callers.
The direct smoke additionally covers fd-backed legacy `c_RkRgaColorFill()`,
which keeps the old public C fill wrapper used by language bindings in parity
without requiring raw physical-address fill submissions.
It also records a sequential IM2D task-job copy chain, exercising
`imbeginJob()`/`imcopyTask()`/`imendJob()` through the current public batching
API with deterministic artifact comparison.
It also records an `rkmppenc`-shaped fd-backed filter chain: RGB source crop and
CSC to NV12, then NV12 resize with the first operation's release fence supplied
as the second operation's acquire fence.
The direct `librga-smoke` path also covers scheduler-core and priority
`imconfig()` calls, followed by `imcopy`, matching the thread-default core-mask
configuration path exposed by standalone `gstreamer-rga` and the documented
thread-default priority API without making that full plugin a required
conformance target. The kernel KUnit suite now also pins invalid public
scheduler-core masks to `-EINVAL` for bitblit, fill, palette, and
update-palette request shapes.

**UNVERIFIED:** neither the generated GStreamer VP9 cases nor the direct MPP
VP9 suite case has a forward-port/rewrite hardware log yet. If you run either,
record the result in status.md.

## AV1 diagnostics via the GStreamer suite

AV1 remains outside the required RK3588 rewrite gate because the validated
forward-port/rewrite path does not expose the separate RKMPP AV1 backend. The
GStreamer plugin still advertises `video/x-av1`, so the suite has opt-in
diagnostics that generate a small AV1 IVF stream with
`GST_GENERATOR`/`libaom-av1` and feed it through the same
`ivfparse ! mppvideodec` path as current userspace:

```bash
PROFILE=rewrite \
GST_ENABLE_AV1_CASES=1 \
../rock-5b-ysp/kernel-drivers/tests/gstreamer-suite.sh
```

Set `GST_REQUIRE_AV1_CASES=1` only for an AV1-capable kernel comparison. The
enabled diagnostic set covers fakesink decode, DMABuf decode, RGA-scale decode,
and AV1-to-H.264 transcode. A pass on the rewrite would require an RKMPP AV1
backend; failures on the current rewrite are expected evidence of the separate
AV1 gap, not a regression in the RKVDEC2 H.264/H.265/VP9 slice.

## Legacy advertised decode diagnostics via the GStreamer suite

JeffyCN `mppvideodec` also advertises VP8, H.263, MPEG-2, and MPEG-4 caps.
Those routes map to legacy VDPU-era blocks rather than the RK3588 RKVDEC2 path
this rewrite is targeting, so they are not part of the required gate. To keep
that userspace-visible boundary executable, the suite can generate short VP8
IVF, H.263, MPEG-2, and MPEG-4 streams and run fakesink decode, selected DMABuf
decode, RGA-scale decode, and legacy-to-H.264 transcode diagnostics:

```bash
PROFILE=rewrite \
GST_ENABLE_LEGACY_DECODE_CASES=1 \
../rock-5b-ysp/kernel-drivers/tests/gstreamer-suite.sh
```

Set `GST_REQUIRE_LEGACY_DECODE_CASES=1` only when comparing a kernel that
intentionally supports those legacy decode blocks. On the current rewrite,
failures are expected unsupported-profile evidence unless a current RK3588
workload proves one of these advertised caps must be promoted.
