# tests/conformance.md — driver conformance harness and rewrite qualification

The expert half of [`kernel-drivers/tests/README.md`](./README.md). The user-facing on-ramp (decode,
encode, transcode smoke tests) leads in [`README.md`](./README.md); this page
owns the cross-kernel conformance harness, the rewrite clean-build gate, the tracked
[`conformance/`](conformance/README.md) seed for the external
`../rock-5b/build/rockchip-conformance` runtime bundle, and the full per-suite reference (MPP /
librga / GStreamer / ffmpeg-rockchip) with its env-var matrices, privileges, and
comparators. The strategic "what it
would take to ship the rewrite" plan is
[`../docs/rewrite-validation-plan.md`](../docs/rewrite-validation-plan.md); this
page is the operational how-to-run counterpart it leans on.

The standard catalog runs on BSP, forward-port, and rewrite targets, under
production, KASAN, or KCSAN configurations. All hardware suites assume the
combined kernel booted and `/dev/mpp_service` + `/dev/rga` present. Differential
work additionally needs the two compared profiles booted in turn with identical
userspace and assets.

Keep the two matrix axes distinct:

| Axis | Answers | Defined by |
|------|---------|------------|
| Target | Which driver implementation owns the devices? | [`conformance/targets/`](conformance/targets/) — `bsp`, `forward-port`, `rewrite` |
| Configuration | Which instrumentation/build shape is booted? | [`conformance/configurations/`](conformance/configurations/) — `production`, `kasan`, `kcsan` |
| Test selector | Which standard or focused behavior is exercised? | [`conformance/TESTS.tsv`](conformance/TESTS.tsv) |

Use `run-conformance.sh --plan` before a board run. It shows standard tests,
compatible opt-ins, and rejected matrix-specific cases without touching
hardware.

## Fast re-entry: the evidence ladder

This page owns **how to produce and interpret rewrite evidence**. It does not
own the live qualification verdict: recover that from
[`status.md` track 4](../../status.md), then use its action path to select the
next rung below. Passing a lower rung never licenses a claim from a higher one.

| Rung | Entry point | What a clean result proves | What it still does not prove |
|------|-------------|----------------------------|------------------------------|
| 1. Clean-source build | [Rewrite clean build gate](#rewrite-clean-build-gate) | Both rewrite objects, the IOMMU provider, and the ROCK 5B DTB compile from committed source under the selected warning/sanitizer profile. | That the kernel boots, probes the devices, or survives real DMA/IRQ traffic. |
| 2. Boot lifecycle and KUnit | [Post-reboot preflight](#post-reboot-identity-and-ownership-preflight) | The exact expected 94 MPP + 152 RGA cases ran; their complete boot interval is fatal-free, lockdep is still live, and production services/cores were restored after test isolation. | Media correctness, userspace compatibility, or hardware scheduling beyond the paths the fixtures model. |
| 3. ABI boundary | [Raw ABI replay](#raw-abi-replay-comparisons) | Safe query/import/release/parser behavior and explicit negative contracts match the selected profile after normalization. | Correct registers, pixels, bitstreams, interrupts, or recovery under active work. |
| 4. Real consumer workloads | [What each suite proves](#what-each-suite-proves) | Official MPP, librga, GStreamer, and FFmpeg paths reach the devices with clean dmesg windows, expected counter deltas, and persisted output artifacts where required. | Parity with the forward port, untested feature combinations, or production-duration stability. |
| 5. Paired differential | [Suites and comparators](#running-the-suites-and-comparators) | Identical assets and commands under forward-port and rewrite profiles meet required-case, artifact, and configured performance-ratio checks. | Correctness outside the compared cases or meaningful performance conclusions from sanitizer builds. |
| 6. Hostile lifetime/recovery | [Recovery stress](#what-each-suite-proves) and [ioctl fuzz](#what-each-suite-proves) | Selected close/reset/unbind and allocation/unwind paths remain live, fatal-free, and counter-clean under the named instrumented kernel. | Exhaustive race freedom or recovery from fault classes that were not injected. |
| 7. Evidence audit | [Rewrite acceptance](#rewrite-acceptance-one-command) | The required paired logs, KUnit reports, artifacts, counters, dmesg windows, and comparator results exist and satisfy the maintained acceptance policy. | More than the collected experiments establish; the audit checks evidence completeness, not unmeasured behavior. |

### One result, from experiment to conclusion

Keep this chain intact for every booted qualification run:

```text
exact boot/package/source identity
  -> correlated 246-case KUnit report + full fatal/lockdep interval
  -> post-KUnit service and core inventory
  -> per-suite command + environment + summary
  -> output artifact sizes/checksums
  -> before/after counters + bounded dmesg report
  -> same-input forward-port comparison
  -> rewrite-evidence-audit verdict
  -> status update scoped to the gates that actually passed
```

The run-correlated directory is the evidence unit. A terminal transcript,
isolated `exit 0`, or later uncorrelated `dmesg` excerpt cannot replace it.

### Similar green results that support different claims

| Do not conflate | Distinction |
|-----------------|-------------|
| `VALIDATE_ONLY=1` vs a runtime pass | Validate-only proves harness builders, parsers, comparators, and rejection logic without touching the devices. |
| Exact green KUnit vs hardware conformance | KUnit proves the modeled logic and boot isolation interval; consumer suites prove real userspace/MMIO/DMA/IRQ paths. |
| Process exit 0 vs correct media | Required artifacts, byte counts/checksums, PSNR or semantic comparators, counters, and dmesg must agree with the claimed path. |
| Required vs diagnostic case | A diagnostic result records information and may be promotable later; it cannot silently satisfy a required gate. |
| Positive hardware counter vs correct output | The counter proves traversal of an instrumented path. The artifact/comparator proves the observed output for that case. |
| Candidate pass vs paired parity | A rewrite pass alone does not show that identical forward-port inputs and outputs agree or that the configured slowdown ceiling holds. |
| Sanitizer timing vs production timing | KASAN/KCSAN runs support safety claims; only the unsanitized production profile supports performance and soak conclusions. |

## Contents

- **Gate & bundle:** [Rewrite clean build gate](#rewrite-clean-build-gate) · [Expanded conformance bundle](#expanded-conformance-bundle)
- **Per-suite reference:** [librga](#librga-suite-reference) · [mpp](#mpp-suite-reference) · [gstreamer](#gstreamer-suite-reference)
- **Running them:** [privileges](#suite-privileges) · [what each proves](#what-each-suite-proves) · [running & comparators](#running-the-suites-and-comparators) · [acceptance (one command)](#rewrite-acceptance-one-command)
- **Targeted checks:** [raw ABI replay](#raw-abi-replay-comparisons) · [VP9 decode](#vp9-decode-via-the-suites) · [AV1 diagnostics](#av1-diagnostics-via-the-gstreamer-suite) · [legacy advertised decode](#legacy-advertised-decode-diagnostics-via-the-gstreamer-suite)

## Rewrite clean build gate

Before hardware testing a rewrite slice, run the focused cross-kernel build gate
from this support repo:

```bash
kernel-drivers/tests/rewrite-build-gate.sh all
```

The script builds from `git archive` copies of `../rock-5b/kernel/linux-6.18-rkvenc` and
`../rock-5b/kernel/linux`, forces the mutually exclusive rewrite drivers plus their KUnit
coverage, and builds the provider/topology integration with them:

```text
drivers/iommu/rockchip-iommu.o
drivers/video/rockchip/mpp-rewrite/mpp_rewrite.o
drivers/video/rockchip/rga-rewrite/rga_rewrite.o
rockchip/rk3588-rock-5b.dtb
```

It fails on dirty kernel worktrees by default, proves an ordinary
`KUNIT_ALL_TESTS=y` config leaves both lifecycle suites off, requires both
suites in qualification profiles, and treats compiler warnings as failures.
The 6.18 run reuses that tree's `.config` when present, so it also covers the
BTF helper path used by the current dev config; mainline falls back to
`defconfig` unless a `.config` exists. The default `normal` profile is the
strict provider/rewrite/DTB build gate. `REWRITE_BUILD_PROFILES` can add a
production-shape test-disabled profile and compile-only sanitizer profiles:

- `test-disabled`: builds the same targets with both rewrite KUnit suites off.
- `memory`: enables KASAN plus fault-injection options used by the fail-nth
  ioctl unwind tests.
- `race`: enables KCSAN plus lockdep for race-oriented compile coverage.

The sanitizer profiles intentionally set a higher `FRAME_WARN` threshold because
KASAN/KCSAN instrumentation inflates KUnit stack frames; the normal profile keeps
the existing stricter warning behavior. These profiles prove the provider/rewrite
objects and Rock 5B DTB compile with the relevant instrumentation on both kernel
lines, but they are not
a substitute for booted KASAN/KCSAN runtime evidence.

Useful overrides:

```bash
KERNEL_6_18=/path/to/linux-6.18-rkvenc \
KERNEL_MAINLINE=/path/to/linux \
JOBS=16 KEEP_TMP=1 \
kernel-drivers/tests/rewrite-build-gate.sh all

REWRITE_BUILD_TMP_ROOT=/path/with-space-for-clean-archives \
kernel-drivers/tests/rewrite-build-gate.sh all

REWRITE_BUILD_PROFILES="normal memory race" \
kernel-drivers/tests/rewrite-build-gate.sh all

REWRITE_BUILD_PROFILES=test-disabled VERIFY_ABI_STATIC_ASSERT=1 \
kernel-drivers/tests/rewrite-build-gate.sh all
```

`ALLOW_DIRTY=1` still builds the committed `HEAD` archive, not uncommitted
source edits. Use it only when checking the last pushed state while another
worktree has unrelated local changes.

Last recorded compile gates: on 2026-08-05 `normal` passed warning-free for
maintained 6.18 `df22eeef8757` and mainline `518f59c9f1f8`. Each built
Rockchip and VSI IOMMU support, both KUnit-enabled rewrite objects, and the
Rock 5B DTB from a clean archive. The source audit reported 306 known signals,
zero new, and zero absent. The `test-disabled`, `memory`, `race`, and deliberate
ABI-size-mutation results remain older-tip evidence and must not be attributed
to these tips. Every profile runs the checked KUnit source-debt audit first and
removes its scratch tree after success. Set `REWRITE_BUILD_TMP_ROOT` to a
task-specific directory under `../rock-5b/build/`; use the sole shared ccache
at `~/Code/.ccache` and do not create another cache in the build workspace. The
same maintenance path also runs
`kernel-drivers/tests/run-conformance.sh --target rewrite --validate`, plus the
same device-free counter-default validation with
`LIBRGA_FORCE_RGA_USERPTR_IOMMU=1`; all
passed, including the forced RGA userptr-IOMMU fallback counter-default wiring
and the cache-line boundary-fuzzer build check.

The dedicated PPAs now publish replacement sources `18623665` and `18623666`,
exporting the Armbian-based composites `8daf5e9513b8` (6.18.38
current/forward-port base) and `24f7424fb958` (`v7.2-rc3` plus bleedingedge)
with the July 15 rewrite hardening applied last. Their arm64 builds `33406491`
and `33406492` succeeded, and exact replacement binaries are Published. Install
and boot one before treating a packaged board run as validation of those
composites; the newer July 17 source tips described above still require a fresh
package before package testing can stand in for current-source validation.

## Expanded conformance bundle

The narrow in-repo tests are still the fast gate. For rewrite parity work, also
use the external runtime bundle at `../rock-5b/build/rockchip-conformance`
(`/home/yi/Code/rock-5b/build/rockchip-conformance` on the dev box). It is intentionally
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

The standard catalog is intentionally identical across driver implementations:

```bash
# On a booted board, autodetect target and instrumentation, then run.
sudo ../rock-5b-ysp/kernel-drivers/tests/run-conformance.sh

# Inspect the matrix cell first.
../rock-5b-ysp/kernel-drivers/tests/run-conformance.sh \
  --target forward-port --configuration production --plan

# Boot and test vendor BSP, forward-port, and rewrite kernels in turn.
sudo ../rock-5b-ysp/kernel-drivers/tests/run-conformance.sh --target bsp
sudo ../rock-5b-ysp/kernel-drivers/tests/run-conformance.sh --target forward-port
sudo ../rock-5b-ysp/kernel-drivers/tests/run-conformance.sh --target rewrite \
  --compare-to forward-port

# Instrumentation is orthogonal; focused tests opt in by catalog ID.
sudo ../rock-5b-ysp/kernel-drivers/tests/run-conformance.sh \
  --target forward-port --configuration kasan \
  --include reset-session-kasan,ioctl-fuzz-kasan
sudo ../rock-5b-ysp/kernel-drivers/tests/run-conformance.sh \
  --target rewrite --configuration kcsan \
  --include iommu-stress,recovery-stress,reset-contention
```

`run-conformance.sh` resolves [`conformance/TESTS.tsv`](conformance/TESTS.tsv),
then sequences system-info collection, normalized ABI replay, MPP, librga,
GStreamer, and ffmpeg-rockchip for every target/configuration cell. Rewrite
rows add KUnit and counter requirements; sanitizer-specific safety tests remain
explicit opt-ins. With no matrix selectors, rewrite/vendor Kconfig identifies
the driver family, vendor kernels on 5.10/6.1/6.6 are classified as BSP and
other vendor-kernel series as forward-port, and KASAN/KCSAN Kconfig selects the
configuration independently. Use `--only` for a focused run, `--skip` for a
documented temporary omission, `--include rkmppenc` for the optional application
suite, `--compare-to PROFILE` for comparators, and `--validate` for the
device-free runner, ioctl-fuzzer build, direct
`librga` smoke build, optional GStreamer event-harness build, RGA IOMMU
scatter-fuzzer build, recovery stress harness config validation,
system-info redaction, MPP/librga/GStreamer case-builder validation, librga
sample-result classification, FFmpeg/rkmppenc case-list validation, catalog and
descriptor coverage, per-stage result reporting, comparator maintenance, ABI
replay filter, and paired-evidence audit selftests, including the
diagnostic-failure and named optional-case audit paths. The two syzlang checks
this runner used to perform — the ABI-marker consistency check and the optional
syzkaller `make descriptions` compile check — moved to the private
`rock-5b-security` repository together with the description they validate; run
them from there when the fuzzer ABI grammar changes.

For per-suite debugging, the equivalent manual sequence is:

```bash
cd ../rock-5b/build/rockchip-conformance
PROFILE=rewrite ./scripts/collect-system-info.sh
# build on the RK3588 target userspace, then run smoke/real media cases
../rock-5b-ysp/kernel-drivers/tests/build-librga-samples-full.sh
../rock-5b-ysp/kernel-drivers/tests/build-mpp-tests.sh
../rock-5b-ysp/kernel-drivers/tests/build-gstreamer-rockchip.sh
PROFILE=rewrite ../rock-5b-ysp/kernel-drivers/tests/mpp-suite.sh
PROFILE=rewrite ../rock-5b-ysp/kernel-drivers/tests/librga-suite.sh
PROFILE=rewrite ../rock-5b-ysp/kernel-drivers/tests/gstreamer-suite.sh
PROFILE=rewrite FFDIR=../rock-5b/ffmpeg/ffmpeg-rockchip-81 ../rock-5b-ysp/kernel-drivers/tests/ffmpeg-suite.sh

# reboot into the BSP forward-port kernel and repeat:
PROFILE=forward-port ./scripts/collect-system-info.sh
PROFILE=forward-port ../rock-5b-ysp/kernel-drivers/tests/mpp-suite.sh
PROFILE=forward-port ../rock-5b-ysp/kernel-drivers/tests/librga-suite.sh
PROFILE=forward-port ../rock-5b-ysp/kernel-drivers/tests/gstreamer-suite.sh
PROFILE=forward-port FFDIR=../rock-5b/ffmpeg/ffmpeg-rockchip-81 ../rock-5b-ysp/kernel-drivers/tests/ffmpeg-suite.sh

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
[`../rga/userspace-consumers.md`](../rga/docs/userspace-consumers.md). It found no
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

- MPP: H.264/H.265 decode at 1080p/4K, VP9 and AVS2 decode, H.264/H.265 encode
  from NV12 at 1080p/4K, low-delay CTU-split encode, multi-instance decode,
  multi-thread encode/decode, rate-control, and `vpu_api_test`. The direct VP9
  MPP case can generate its own IVF input. AVS2 is a real RK3588 VDPU381 claim
  in pinned MPP and has a rewrite translation table, so it requires an explicit
  `MPP_AVS2_INPUT` asset rather than being omitted from the final evidence set.
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
  of the full `ffmpeg-rockchip` path. It runs the selected `FFDIR/ffmpeg`
  against installed MPP/librga by default. Set `FFMPEG_RUNTIME_MODES="system
  staged"` with `STAGE` or `FFMPEG_STAGED_LD_LIBRARY_PATH` for an explicit
  packaging/library-skew comparison. The suite records `uname`, `ffmpeg
  -version`, `ldd`, device-node and
  `/proc/mpp_service/supports-device` preflight data, probes H.264/H.265/VP9
  RKMPP decoders, H.264/H.265 RKMPP encoders, RKRGA filters, and treats an
  absent AV1 RKMPP encoder as expected. It generates shared software H.264,
  H.265, VP9, AV1, H.265 Main10, resolution-change, and optional 4K/8K inputs
  under `../rock-5b/build/rockchip-conformance/assets/ffmpeg-generated`. Required cases cover
  H.264/H.265/VP9 decode to null, bit-exact HW-vs-SW decode PSNR, H.264/H.265
  encode sanity with a PSNR floor, H.264<->RGA<->H.265 transcodes, and
  `scale_rkrga` and `vpp_rkrga`. Encoded-artifact checks decode both sides to
  raw frames and compare index-aligned at a fixed rate with a byte-count
  gate, because the generated elementary streams carry decode-order
  timestamps whose non-monotonic PTS would otherwise measure CFR vsync
  duplicate/drop churn instead of codec output; transcode legs run
  `-fps_mode passthrough` for the same reason. `overlay_rkrga` is opt-in via
  `FFMPEG_RUN_OVERLAY_BLEND=1` until the rewrite RGA driver handles its
  valid RGBA blend chain (RGA2 SWIOTLB segment limit; deterministic RGA3
  IOMMU fault). AV1 decode, AV1 PSNR,
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
`../rock-5b/build/rockchip-conformance/logs/$PROFILE/`. It also scans each official
sample log for fatal diagnostics: some upstream sample `main()` functions
return a failed `IM_STATUS` value whose numeric value is zero, which otherwise
looks like a successful shell exit. Successful samples commonly return
`IM_STATUS_SUCCESS`, numeric value one, which otherwise looks like a shell
failure. A matched fatal line always becomes `log-fail`; status one becomes a
pass only when the same log contains the official sample's explicit terminal
`running success!` message. Its default **required** set includes the in-repo
`ysp_librga_smoke` direct-userspace artifact case plus official copy/FBC/tile/
splice, crop/resize, CSC/gray, alpha/colorkey/global-alpha, rotate/flip,
async/fence, core config, malloc/system-dma/DRM allocator, and ROP samples.
Thirteen official samples that hard-code the absent vendor
heap nodes `/dev/dma_heap/system-uncached` or `system-uncached-dma32` are not
run by default; set `LIBRGA_ENABLE_VENDOR_HEAP_CASES=1` on a kernel that exposes
those heap types to add the UV-downsample, full-CSC, fill/rectangle, OSD,
vendor-heap allocator, padding, and Gaussian samples back as required cases.
Use `build-librga-samples-full.sh`, not only the external bundle's top-level
sample build, because the pinned `airockchip/librga` CMake omits `gauss_demo`
from `samples/CMakeLists.txt`; the helper keeps the opt-in Gaussian binaries
available. `ysp_librga_smoke`
writes deterministic raw
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
Three official samples are absent from both default classes because they do not
measure the kernel: librga rejects the RGBA5551-alpha and mosaic cases before
an ioctl, while `rga_palette_demo` emits a malformed CSC field on 1.10.6_[3]
and an unbound LUT-update/apply sequence on both 1.10.5 and 1.10.6. The palette
sample also declares success without comparing output pixels to its LUT. The
[palette finding](../../findings/2026-08-06-librga-palette-demo-is-not-kernel-conformance.md)
records the request differential and the deferred userspace/same-core fix;
strict rewrite rejection remains the default contract.
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
installed `test/` binaries under `/usr/bin`. It writes
`summary.tsv`, per-case logs/status/command files, dmesg tail, and before/after
MPP procfs/debugfs snapshots under `../rock-5b/build/rockchip-conformance/logs/$PROFILE/`,
plus structured `debugfs-counters-{before,after,delta}.tsv` counter tables.
Those tables include the rewrite's aggregate and per-core `hw_total_ns*` /
`hw_max_ns*` timing counters when the rewrite driver owns `/dev/mpp_service`.
Set `MPP_BIN_DIR` and `MPP_LIBDIR` only for an explicit staged or legacy
comparison. `build-mpp-tests.sh` remains the mechanism for constructing that
optional source-built comparison prefix.
The default required set is intentionally asset-free: `mpp_info_test` only.
Select real codec/performance cases with `MPP_REQUIRED_CASES` so both kernel
profiles run the same matrix against the same media:

```bash
PROFILE=rewrite \
MPP_H264_INPUT=assets/sample-1080p.h264 \
MPP_H265_INPUT=assets/sample-1080p.h265 \
MPP_AVS2_INPUT=assets/sample.avs2 \
MPP_ENC_INPUT=assets/nv12-1920x1080.yuv \
MPP_ENC_WIDTH=1920 MPP_ENC_HEIGHT=1080 MPP_ENC_FORMAT=0 \
MPP_REQUIRED_CASES="mpp_info_test mpi_dec_h264 mpi_dec_h265 mpi_dec_vp9 mpi_dec_avs2 mpi_dec_mt_h264 mpi_dec_multi_h265 mpi_enc_h264 mpi_enc_h265 mpi_enc_h264_slice mpi_enc_h265_slice mpi_enc_mt_h265 mpi_rc2_h264" \
../rock-5b-ysp/kernel-drivers/tests/mpp-suite.sh
```

Useful case names are `mpi_dec_h264`, `mpi_dec_h265`, `mpi_dec_vp9`,
`mpi_dec_avs2`, `mpi_dec_mt_*`, `mpi_dec_multi_*`, `mpi_enc_h264`,
`mpi_enc_h265`, `mpi_enc_h264_slice`, `mpi_enc_h265_slice`, `mpi_enc_mt_*`,
`mpi_rc2_h264`, and `mpi_rc2_h265`. The slice cases use the official
multi-thread test so its output thread can drain low-delay callbacks while
encoding is in progress. Their `split_mode=2`, `split_out=1`, and
`split_arg=120` defaults make 1280x720 H.264 and H.265 produce multiple slices
without overflowing the kernel's 256-entry per-task slice FIFO; tune them with
`MPP_ENC_SPLIT_*` and `MPP_ENC_SLICE_INSTANCES`.
The legacy Android/libvpu path is available as an explicit diagnostic case
(`vpu_api_dec_h264`, `vpu_api_dec_h265`, `vpu_api_dec_avs2`) but is not part of
the default Linux/RK3588 pass gate.
When `mpi_dec_vp9`, `mpi_dec_mt_vp9`, or `mpi_dec_multi_vp9` is selected and
`MPP_VP9_INPUT` is unset, the wrapper generates a shared VP9 IVF input under
`MPP_GENERATED_INPUT_CACHE` (default
`../rock-5b/build/rockchip-conformance/assets/mpp-generated`) with `ffmpeg`/`libvpx-vp9`.
Set `MPP_GENERATE_VP9_INPUT=0` to require an explicit `MPP_VP9_INPUT`, or tune
`MPP_VP9_GENERATED_WIDTH`, `MPP_VP9_GENERATED_HEIGHT`, and
`MPP_VP9_GENERATED_FPS`.
AVS2 cannot be generated by the ordinary suite toolchain; `mpi_dec_avs2`,
`mpi_dec_mt_avs2`, and `mpi_dec_multi_avs2` require `MPP_AVS2_INPUT` and accept
optional `MPP_AVS2_WIDTH`/`MPP_AVS2_HEIGHT`.
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
`gstreamer-rockchip` plugin from `../rock-5b/build/rockchip-conformance/out/gstreamer-rockchip`.
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
  `generated_transcode_h264_dmabuf_to_h265`,
  `generated_transcode_h265_dmabuf_to_h264`;
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
`../rock-5b/build/rockchip-conformance/assets/gstreamer-generated`). They then feed those
shared files through `filesrc ! *parse ! mppvideodec` decode and decode->encode
transcode pipelines. Keeping the cache outside each profile's log directory
makes forward-port and rewrite runs consume the same input streams. That keeps
the default run self-contained while covering the media-file path that
same-pipeline roundtrips do not hit. VP9 cases are enabled and required by
default; set `GST_ENABLE_VP9_CASES=0` to remove them or
`GST_REQUIRE_VP9_CASES=0` to keep them diagnostic-only on images missing
`vp9enc`, `ivfmux`, or `ivfparse`. The maintained rewrite source has a separate
VPU981 AV1 backend, but it has no hardware baseline; set
`GST_ENABLE_AV1_CASES=1` to add generated AV1 fakesink/DMABuf decode plus
RGA-scale and AV1-to-H.264 transcode diagnostics, or
`GST_REQUIRE_AV1_CASES=1` for full current-tip qualification. Set
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
more output afterward. The encoder flush cases send
`FLUSH_START`/`FLUSH_STOP` to the element's sink pad and directly drive
JeffyCN's `GstVideoEncoder.flush` hook, which calls `mpi->reset()`. Decoder
flush cases exercise the same target-pad reset, restore the active segment
cleared by `FLUSH_STOP(TRUE)`, and then seek to a keyframe before requiring
post-flush output; resuming mid-GOP without that segment and reference point is
not a valid compressed-stream restart. The force-key-unit
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
`generated_transcode_h264_dmabuf_to_h265`,
`generated_transcode_h265_dmabuf_to_h264`, `generated_transcode_vp9_to_h264`,
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

**10-bit chroma content check.** The four 10-bit cases that emit a CPU-readable
output — `generated_dec_h265_10_rga_scale`,
`generated_dec_h265_10_env_disable_nv12_10`, and their `422_10` siblings — are
not scored on "did the pipeline run" alone. Each decodes the same generated
input in software, scales it to the same geometry, and requires the captured
output's **U and V planes** to match within `GST_CHROMA_MIN_PSNR` (default
`20` dB); `GST_CHROMA_CHECK=0` disables it. Luma is reported but deliberately
not gated: a UV plane read from the wrong offset leaves luma clean, which is
exactly how that defect class hides. Measured on the `0072` kernel this check
reports `y=40.9 u=7.5 v=7.0` and `y=52.4 u=7.5 v=7.0` — a ~7 dB chroma floor
against clean luma — for the two cases that previously reported **pass**
([UV-offset finding](../../findings/2026-07-24-rga-10bit-uv-plane-offset-still-pixel-scaled.md)).
The plain `fakesink` 10-bit cases stay liveness-only: they emit the decoder's
native compact NV12_10/NV16_10, which is not a raw format `ffmpeg` reads back.
The check needs `GST_CAPTURE_ARTIFACTS=1` (the default) and fails closed if the
output or `ffmpeg` is missing rather than silently passing.

By default `GST_CAPTURE_ARTIFACTS=1` makes generated,
optional external-media decode/transcode, encoded RC-mode, and AFBC transcode
cases write decoded raw buffers or encoded elementary streams under each run's
`artifacts/` directory and records byte counts plus SHA-256s in
`artifacts.tsv`; set it to `0` for pure pass/fail timing runs. Every registered
artifact must be a nonempty regular file: an otherwise successful case is
reclassified as failed before its summary row is written when artifact
validation fails. Required
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
| `build-mpp-tests.sh` | optional legacy-comparison builder; no device access and writes staged MPP library/tests under `../rock-5b/build/rockchip-conformance/out/mpp` |
| `build-gstreamer-rockchip.sh` | no device access; needs a Git source checkout plus installed MPP, librga, and GStreamer development `.pc` files by default. It archives the pinned source into a content-keyed disposable directory beside `BUILD_DIR`, applies [`patches/gstreamer-rockchip/`](./patches/gstreamer-rockchip/README.md), and leaves the checkout untouched; `GST_ROCKCHIP_PATCH_DIR=` selects an intentional unpatched comparison. Explicit `MPP_PREFIX`/`PKG_SHIM` values select staged dependencies. It also builds `gstreamer-event-harness` into the GStreamer prefix. `GST_EVENT_HARNESS_VALIDATE_BUILD=1` compiles only the event harness and returns `77` when the GStreamer development `.pc` files are absent. |
| `run-conformance.sh` | same device and dependency access as the selected catalog rows. `--target` selects BSP, forward-port, or rewrite drivers; `--configuration` independently selects production, KASAN, or KCSAN. The standard set is system-info, ABI, MPP, librga, GStreamer, and FFmpeg on every target. Rewrite adds KUnit and counter gates automatically. `--include` adds compatible focused tests, `--only` narrows by ID, `--plan` is board-free, and `--validate` checks catalog, parser, builder, comparator, and audit wiring. |
| `rewrite-kunit-log-check.sh` | runtime mode reads `/sys/kernel/debug/kunit/{rk_mpp_rewrite,rockchip-rga-rewrite}/results`, requires exactly the manifest's 94 + 152 cases with no fail/skip, extracts and scans the complete boot KUnit interval with the shared fatal regex, requires live lockdep, and optionally writes the correlated `KUNIT_REPORT` artifact set; `--selftest` is device-free. |
| `rewrite-kunit-source-audit.py` | device-free lexical audit of both embedded KUnit regions; the checked TSV baselines existing singleton, FD/raw-allocation, stack-async, manual-list, and fatal-before-cleanup signals, while any new signal or cross-tree mismatch fails. `rewrite-build-gate.sh` runs it before every profile. |
| `rewrite-ownership-source-audit.py` | device-free, source-pinned inventory of the production ownership seams targeted by the refactor: MPP reset, active-slot access/write, dispatch-lease access/write, CCU-power, IOMMU, terminal, IRQ-ack, and start writers plus RGA active-slot access/write, task-advance, command-writer, raw-task-emitter, and start writers. Its checked TSV permits reviewed signal removal but rejects new signals, an unpinned source HEAD, a whole-category parser disappearance, or cross-tree drift. `rewrite-build-gate.sh` runs it before every profile. |
| `suite-common-selftest.sh` | device-free good/fatal/ring-wrap/unavailable fixtures for the common before/after dmesg gate, plus strict multi-step case execution and nonempty artifact metadata checks used by the suite wrappers. |
| `rewrite-evidence-audit.sh` | no device access; reads the latest paired suite logs and, for rewrite candidates, each suite run's matching persisted KUnit report. Normal mode requires required-case passes, representative official-MPP H.264/H.265/VP9/AVS2, multi-thread/multi-instance/encode/slice/RC cases plus a nonempty checksum artifact for every media case (`MPP_DUMP_OUTPUTS=1` for decode), counter deltas, clean per-suite dmesg reports on both profiles, exact green booted KUnit evidence, and comparator-clean results with `PERF_MAX_RATIO=1.25`. Every relaxation is explicit (`REQUIRE_MPP_CORE_CASES=0`, `REQUIRE_DMESG_EVIDENCE=0`, `REQUIRE_KUNIT_EVIDENCE=0`, or the older artifact/counter/comparator overrides). |
| `ioctl-fuzz-smoke.sh` | device access for `/dev/mpp_service` and/or `/dev/rga`; no hardware-submit workload by design. Raw physical RGA imports are disabled unless `IOCTL_FUZZ_ENABLE_RGA_PHYSICAL=1`. `IOCTL_FUZZ_VALIDATE_BUILD=1` is device-free. `IOCTL_FUZZ_FAIL_NTH_MAX=N` additionally needs `/proc/self/fail-nth`; logging and dmesg bracketing use `IOCTL_FUZZ_OUT`, `IOCTL_FUZZ_DMESG_SCAN`, and `IOCTL_FUZZ_REQUIRE_DMESG`. |
| `mpp-suite.sh` | device access for `/dev/mpp_service`, `/dev/dma_heap/*`, readable MPP procfs/debugfs, and readable dmesg for full logs; root is the simplest mode. Pre/post state capture reads an explicit compatibility/state/event allowlist once, never recursively walks all generated MPP files, and fails closed on a read error such as rewrite `state` returning `EBUSY`. `MPP_VALIDATE_CASES=1` is the device-free maintenance mode and only validates selected case-builder wiring. |
| `mpp-debug-capture.sh` | root strongly preferred for runtime mode; needs readable rewrite `state`/`events`, and normally writable `events`/`trace_mask` plus readable dmesg for the focused bundle. It preserves the wrapped workload's exit code and uses exit `77` when the rewrite journal is absent. `MPP_DEBUG_VALIDATE_ONLY=1` is a device-free failure-path/trace-restore selftest. |
| `mpp-suite-compare.sh` | no device access; reads two `summary.tsv` files under `../rock-5b/build/rockchip-conformance/logs/` |
| `suite-compare.sh` | shared no-device result/artifact comparison engine used by all five thin `*-suite-compare.sh` launchers; required missing, zero-byte, or mismatched artifact rows fail comparison. It is not invoked directly because each launcher supplies its suite name and artifact policy. |
| `librga-suite.sh` | device access for `/dev/rga`, `/dev/dma_heap/*`, optional DRM render nodes, readable debugfs/dmesg for full logs, and the installed `librga-dev` package for the in-repo `ysp_librga_smoke` artifact case; root is the simplest mode. `LIBRGA_LIBDIR` selects an explicit staged or legacy runtime. `LIBRGA_SUITE_VALIDATE_LOG_PARSER=1` and `LIBRGA_SUITE_VALIDATE_CASES=1` are device-free selftests for fatal-log precedence, explicit-success/status-one normalization, and default/opt-in case lists. |
| `librga-suite-compare.sh` | no device access; reads two `summary.tsv` files and, by default, paired `artifacts.tsv` manifests under `../rock-5b/build/rockchip-conformance/logs/` |
| `gstreamer-suite.sh` | device access for `/dev/mpp_service` and `/dev/rga`, staged JeffyCN plugin under `../rock-5b/build/rockchip-conformance/out/gstreamer-rockchip`, software `ffmpeg`/`libx265` via `GST_GENERATOR` for generated H.265 Main10 inputs, optional `libaom-av1` support in `GST_GENERATOR` for opt-in AV1 diagnostics, ffmpeg H.263/MPEG encoder support for opt-in legacy decode diagnostics, and readable debugfs/dmesg for full logs; root is the simplest mode. Opt-in `GST_ENABLE_VIDEOFLIP_RGA_CASES=1` cases additionally need a GStreamer `videoflip` element carrying the Rockchip `GST_VIDEO_FLIP_USE_RGA=1` path if the run is meant to prove hardware use rather than generic CPU `videoflip` compatibility. Opt-in `GST_ENABLE_RGACONVERT_CASES=1` cases need the standalone `gstreamer-rga` converter element named by `GST_RGACONVERT_ELEMENT` (`rgavideoconvert` by default). Opt-in display/KMS cases also need staged `rkximage`/`kmssrc` plugins, an active DRM/KMS framebuffer, and access to the DRM device. `GST_VALIDATE_CASES=1` is the device-free maintenance mode and only validates case-builder/runner wiring. |
| `gstreamer-suite-compare.sh` | no device access; reads two `summary.tsv` files under `../rock-5b/build/rockchip-conformance/logs/` |
| `ffmpeg-suite.sh` | device access for `/dev/mpp_service`, `/dev/rga`, `/dev/dma_heap/*`, and a DRM render node; a staged `ffmpeg-rockchip` build via `FFDIR`; system and/or staged MPP runtime libraries via `FFMPEG_RUNTIME_MODES`, `STAGE`, or `FFMPEG_STAGED_LD_LIBRARY_PATH`; software ffmpeg encoders `libx264`, `libx265`, `libvpx-vp9`, and optionally `libsvtav1`/`libaom-av1` for generated inputs; and readable debugfs/dmesg for full logs. Root is the simplest mode. `FFMPEG_VALIDATE_CASES=1` is the device-free maintenance mode and validates case-list/runtime dispatch wiring. |
| `ffmpeg-suite-compare.sh` | no device access; reads two `summary.tsv` files and, by default, paired `artifacts.tsv` manifests under `../rock-5b/build/rockchip-conformance/logs/` |
| `rkmppenc-suite.sh` | opt-in app-level `rkmppenc` coverage for `/dev/mpp_service` plus `/dev/rga`; needs `rkmppenc`, software `ffmpeg` via `RKMPPENC_GENERATOR` for generated Y4M/raw/H.264 inputs, optional staged runtime libraries via `RKMPPENC_LD_LIBRARY_PATH`, and readable debugfs/dmesg for full logs. Runtime cases check `--check-mppinfo`, `--check-rgainfo`, generated Y4M H.264/H.265 encode with RGA resize, generated raw NV12 H.264 encode with RGA resize, and a diagnostic hardware-decode/RGA-resize/encode transcode. `RKMPPENC_VALIDATE_CASES=1` is device-free and validates the optional case list without needing `rkmppenc` installed. |
| `rkmppenc-suite-compare.sh` | no device access; reads two opt-in `rkmppenc` `summary.tsv` files and, by default, paired `artifacts.tsv` manifests under `../rock-5b/build/rockchip-conformance/logs/` |
| `debugfs-counter-check.sh` | no device access after a suite has run; requires selected positive hardware/fence-path counters and zero-after gauges. Rewrite defaults cover MPP imports/queued jobs, RGA imports/boundary-shadow views, and direct-librga userptr-IOMMU activity across new or legacy debugfs naming. It rejects positive timeout, recovery-failure, IOMMU-fault, spurious-IRQ, RGA IRQ/config-error, and boundary-shadow setup-failure deltas. `release_fence_count` is cumulative positive path evidence, not a zero-after leak gauge. |
| `rewrite-recovery-stress.sh` | root strongly preferred for runtime mode; needs `/dev/mpp_service` and/or `/dev/rga`, the selected `RECOVERY_WORKLOAD_CMD` inputs/artifacts, readable dmesg, and readable rewrite debugfs counters. The `unbind` case also needs writable platform driver bind/unbind files and explicit `RECOVERY_UNBIND_TARGETS`. `RECOVERY_VALIDATE_ONLY=1` is device-free and only validates case/config wiring. |

## What each suite proves

| Test | Exercises | Pass criterion |
|------|-----------|----------------|
| `run-conformance.sh` | **target × configuration conformance orchestration** | Resolves the checked `TESTS.tsv` catalog, runs the same broad standard consumer set across BSP/forward-port/rewrite and production/KASAN/KCSAN cells, then adds only compatible target/configuration-specific gates. It records the resolved plan with the run. Rewrite rows require KUnit and debugfs counters; sanitizer rows require readable fatal scans and never get production timing defaults. `--validate` is device-free and includes bad-fixture selftests plus case-builder/build checks. |
| `rewrite-evidence-audit.sh` | **paired forward-port/rewrite evidence gate** | Requires paired required-case passes, artifacts, counter deltas, clean dmesg evidence, the rewrite candidate's exact green KUnit report, a representative official-MPP core set including AVS2 and low-delay slice polling, and comparator-clean timing/artifact results. Named diagnostic promotion remains available. Normal mode is the final “enough evidence to claim parity?” check and is expected to fail before board logs exist; `--selftest` only proves rejection logic. |
| `ioctl-fuzz-smoke.sh` | **non-submit ioctl parser/import fault smoke** | Mutates safe MPP/RGA parser, query, import/release, and request-lifetime ioctls without submitting register jobs or RGA blits. Raw physical generation is opt-in. Fail-nth mode targets syscall-local allocation/usercopy unwind paths; persisted runs can bracket dmesg and fail on fatal signatures. |
| `abi-replay.sh` | **non-submit kernel ABI replay** | Saves raw/normalized/comparable/contract logs for safe MPP/RGA ABI behavior. Raw physical import is disabled on ordinary/forward profiles; `PROFILE=*rewrite*` explicitly enables it and requires `EOPNOTSUPP`. Comparable and contract logs prune both the result and disabled marker. See [the 2026-07-16 crash note](../rga/docs/raw-physical-import-crash.md). |
| `mpp-suite.sh` | **official MPP test conformance** using installed `/usr/bin` tools and system libraries | Runs selected info, H.264/H.265/VP9/AVS2 decode, multi-thread/multi-instance, H.264/H.265 encode, low-delay slice-poll, RC, and legacy API cases. `MPP_BIN_DIR`/`MPP_LIBDIR` opt into a staged or legacy comparison. VP9 can be generated; AVS2 needs an explicit asset. Slice cases record the `split_*` environment in their command and exercise `MPP_CMD_POLL_HW_IRQ`. The asset-free direct default remains `mpp_info_test`, but the normal evidence audit refuses that alone. Every runtime records artifacts, counters, and a clean before/after dmesg report. |
| `mpp-debug-capture.sh` | **one-reproduction MPP debug bundle** | Captures before/after live state, the bounded event journal, counters and deltas, procfs discovery, full/new dmesg, workload output/status, and a failure-focused event summary. It clears unrelated old events by default, can temporarily set `trace_mask`, restores that mask even when the workload fails, and exits with the wrapped command's status after preserving the after-state. |
| `mpp-suite-compare.sh` | **rewrite-vs-forward-port MPP comparator** | Compares the latest or explicitly provided `summary.tsv` files and, when `artifacts.tsv` manifests are present, compares official-test output byte counts and SHA-256s. A required baseline pass that is not a candidate pass, a required case failing on **both** sides (`required-fail-both` — not a regression, but not evidence either), a comparison sharing **no** required case at all, a required artifact mismatch, or a required pass/pass slowdown above `PERF_MAX_RATIO` exits nonzero; diagnostic differences and slowdowns remain informational. Set `PERF_MAX_RATIO` to fail required pass/pass slowdowns above that ratio, and set `REQUIRE_ARTIFACTS=1` for full media gates that must reject missing/empty artifact manifests. |
| `librga-suite.sh` | **official librga sample conformance plus direct artifact smoke** using sample binaries under `../rock-5b/build/rockchip-conformance/out/librga-samples/bin` with the installed librga, plus `librga-smoke.cpp` | Runs the broad sample set plus deterministic maintained-path artifacts and debugfs counter deltas. Fatal official-sample diagnostics override any process status, preventing failed `IM_STATUS` value zero from false-passing; status one is accepted only with the sample's explicit terminal success message, preventing `IM_STATUS_SUCCESS` value one from false-failing. `LIBRGA_LIBDIR` opts into a staged or legacy runtime. The raw physical probe is disabled on forward profiles and explicitly enabled as a hard rejection assertion on rewrite profiles; the FBC-tail negative assertion remains rewrite-profile automatic. |
| `librga-suite-compare.sh` | **rewrite-vs-forward-port suite comparator** | Compares the latest or explicitly provided `summary.tsv` files and, by default, paired `artifacts.tsv` manifests. A required baseline pass that is not a candidate pass, a required case failing on **both** sides (`required-fail-both` — not a regression, but not evidence either), a comparison sharing **no** required case at all, a required artifact mismatch, or a required pass/pass slowdown above `PERF_MAX_RATIO` exits nonzero; diagnostic differences and slowdowns remain informational. Set `PERF_MAX_RATIO` to fail required pass/pass slowdowns above that ratio, and set `REQUIRE_ARTIFACTS=0` only for legacy pass/fail-only logs. |
| `gstreamer-suite.sh` | **JeffyCN GStreamer MPP/RGA plugin conformance** using `../rock-5b/build/rockchip-conformance/out/gstreamer-rockchip` with installed MPP/librga | Runs plugin inspection plus real encode, generated 8-bit/10-bit decode/transcode, RGA-conversion, caps-renegotiation, explicit flush-event, restart-loop, AFBC decode-to-encode transcodes, optional external-media pipelines, opt-in `GST_VIDEO_FLIP_USE_RGA=1` `videoflip` NV12/BGRx rotate/flip pipelines, opt-in standalone `GST_RGACONVERT_ELEMENT` BGRx/NV12 convert/scale pipelines for the external GStreamer RGA path, and opt-in display/KMS capture pipelines under the selected `PROFILE`. `MPP_LIBDIR`/`LIBRGA_LIBDIR` opt into staged or legacy runtimes. It records per-case logs/status/commands, generated and optional external-media decode/transcode artifact checksums, encoded RC-mode/AFBC artifacts, plus MPP/RGA debugfs snapshots and counter deltas. Exit `77` means `/dev/mpp_service` or `/dev/rga` is absent. |
| `gstreamer-suite-compare.sh` | **rewrite-vs-forward-port GStreamer comparator** | Compares the latest or explicitly provided `summary.tsv` files and, by default, requires `artifacts.tsv` on both sides for generated and optional external-media decode/transcode byte-count and SHA-256 comparison. A required baseline pass that is not a candidate pass, a required case failing on **both** sides (`required-fail-both`), a comparison sharing **no** required case at all, a missing required artifact manifest, a required artifact mismatch, or a required pass/pass slowdown above `PERF_MAX_RATIO` exits nonzero; diagnostic differences and slowdowns remain informational. Set `REQUIRE_ARTIFACTS=0` for legacy pass/fail-only logs. |
| `ffmpeg-suite.sh` | **ffmpeg-rockchip CLI conformance** using `FFDIR/ffmpeg` and `FFDIR/ffprobe` | Runs against installed MPP/librga by default; `FFMPEG_RUNTIME_MODES="system staged"` explicitly adds a staged-runtime comparison. It performs component/option inspection, device/support preflight, required H.264/H.265/VP9 RKMPP decode and bit-exact PSNR, a required repeated bit-exact H.264 decode under background CPU load with a diagnostic `-fast_parse 0` serialized-submission control (the rewrite dual-core dispatch-race gate; `FFMPEG_REPEAT_EXACT_ITER`/`FFMPEG_REPEAT_EXACT_LOAD_JOBS` tune it), generated H.264/H.265 encoder-option encodes with PSNR sanity, generated-input H.264<->`scale_rkrga`<->H.265 hardware transcodes with index-aligned raw-frame PSNR and frame-count gates (`-fps_mode passthrough` legs; the generated elementary streams carry decode-order timestamps), required `scale_rkrga` and `vpp_rkrga` coverage with transform-aware references, opt-in `FFMPEG_RUN_OVERLAY_BLEND=1` `overlay_rkrga` coverage pending rewrite RGA blend-chain driver work, plus diagnostic/promotable AV1 decode/RGA/transcode/AFBC coverage. Diagnostics also cover H.265 Main10/P010 RGA and H.264 resolution changes; opt-in stress adds repeated short loops and an AV1->RGA->H.264 soak. It records per-case logs/status, encoded bitstream byte counts and SHA-256s, plus MPP/RGA debugfs snapshots and counter deltas. Exit `77` means `/dev/mpp_service` or `/dev/rga` is absent. |
| `ffmpeg-suite-compare.sh` | **rewrite-vs-forward-port ffmpeg-rockchip comparator** | Compares the latest or explicitly provided `summary.tsv` files and, by default, requires `artifacts.tsv` on both sides for encoded bitstream byte-count and SHA-256 comparison. A required baseline pass that is not a candidate pass, a required case failing on **both** sides (`required-fail-both`), a comparison sharing **no** required case at all, a missing required artifact manifest, a required artifact mismatch, or a required pass/pass slowdown above `PERF_MAX_RATIO` exits nonzero. Set `REQUIRE_ARTIFACTS=0` for legacy pass/fail-only logs. |
| `rkmppenc-suite.sh` | **optional rkmppenc app-level conformance** using `rkmppenc` | Runs `--check-mppinfo`, `--check-rgainfo`, generated Y4M H.264/H.265 encode with `--output-res` plus `--vpp-resize rga_bilinear`, generated raw NV12 H.264 encode through the same RGA resize path, and a diagnostic generated H.264 hardware-decode to HEVC encode transcode through `--avhw`. It records per-case logs/status, encoded output byte counts and SHA-256s, plus MPP/RGA debugfs counter deltas. This suite proves an independent MPP-frame producer/filter graph from the public `rkmppenc` app, but remains opt-in because the direct `librga-smoke` already covers the kernel-visible fd-backed crop/CSC/resize/fence chain. |
| `rkmppenc-suite-compare.sh` | **rewrite-vs-forward-port rkmppenc comparator** | Compares the latest or explicitly provided opt-in `rkmppenc` `summary.tsv` files and, by default, requires `artifacts.tsv` on both sides for encoded bitstream byte-count and SHA-256 comparison. A required baseline pass that is not a candidate pass, a required case failing on **both** sides (`required-fail-both`), a comparison sharing **no** required case at all, a missing required artifact manifest, a required artifact mismatch, or a required pass/pass slowdown above `PERF_MAX_RATIO` exits nonzero. Set `REQUIRE_ARTIFACTS=0` only for legacy pass/fail-only logs. |
| `debugfs-counter-check.sh` | **rewrite counter-delta gate** | Checks a captured `debugfs-counters-delta.tsv` from any suite. Use `REQUIRED_POSITIVE_COUNTERS` to prove selected hardware paths actually submitted and reached the IRQ/completion timing path; use `REQUIRED_POSITIVE_COUNTER_PREFIXES` with `component:counter_prefix:min_positive` to prove multicore spread across per-core counters; use `REQUIRED_ZERO_AFTER_COUNTERS` for gauges that must settle back to zero at rest; use `FORBID_POSITIVE_COUNTERS` to override the default timeout/fault/error guard. `REQUIRE_FORBIDDEN_COUNTERS=1` also rejects missing safety instrumentation and is automatic in rewrite runner/audit counter gates. Any required mode also rejects a delta file with **no data rows** — `debugfs-counters.sh` writes a header-only file when the debugfs directory is absent, and every forbidden counter then resolves to `component-not-captured`, which used to pass. This complements elapsed-time comparison because it catches “userspace passed but the rewrite did no hardware work” and “all work stuck to one core” cases. |
| `rewrite-recovery-stress.sh` | **reset/recovery stress harness** | Runs kill/close, reset-opener, and opt-in platform unbind/rebind loops around an explicit busy workload, then runs a post-case liveness command, scans new dmesg lines for fatal signatures, and records before/after/delta debugfs counters. `RECOVERY_VALIDATE_ONLY=1` validates the script config without touching devices and is included in the top-level `VALIDATE_ONLY=1` runner; it is not proof that close/reset/unbind recovery works on hardware. Runtime exit `77` means both device nodes are absent. |

## Running the suites and comparators

```bash
bash run-conformance.sh --target rewrite --validate  # device-free catalog/runner/build/parser/comparator/audit wiring check
MPP_DEBUG_VALIDATE_ONLY=1 bash mpp-debug-capture.sh  # device-free focused capture failure/restore selftest
sudo bash mpp-debug-capture.sh -o ../rock-5b/build/rockchip-conformance/logs/mpp-decode -- mpi_dec_test -i input.h264 -t 7  # one reproduction with state/events/counters/dmesg
LIBRGA_FORCE_RGA_USERPTR_IOMMU=1 bash run-conformance.sh --target rewrite --validate  # also validate forced userptr-IOMMU counter wiring
IOCTL_FUZZ_VALIDATE_BUILD=1 bash ioctl-fuzz-smoke.sh  # device-free mutator build check
sudo IOCTL_FUZZ_OUT=../rock-5b/build/rockchip-conformance/logs/rewrite/ioctl-failnth IOCTL_FUZZ_DMESG_SCAN=1 IOCTL_FUZZ_FAIL_NTH_MAX=4 IOCTL_FUZZ_ITERS=32 bash ioctl-fuzz-smoke.sh  # debug-kernel fail-nth allocation/usercopy sweep
bash run-conformance.sh --target rewrite --plan  # print standard and compatible opt-in rows
sudo bash run-conformance.sh --target rewrite  # standard rewrite set with KUnit and counters
sudo bash run-conformance.sh --target rewrite --compare-to forward-port  # run and compare latest production summaries
sudo LIBRGA_FORCE_RGA_USERPTR_IOMMU=1 bash run-conformance.sh --target rewrite --only librga  # focused RGA userptr-IOMMU attribution gate
RKMPPENC_VALIDATE_CASES=1 bash rkmppenc-suite.sh  # device-free optional rkmppenc case-list validation
sudo bash run-conformance.sh --target rewrite --include rkmppenc  # opt-in app-level MPP/RGA gate
sudo bash run-conformance.sh --target rewrite --include rkmppenc --compare-to forward-port  # compare it too
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
sudo RECOVERY_WORKLOAD_CMD='bash "$TEST_DIR/run-conformance.sh" --target rewrite --only mpp,librga' RECOVERY_CASES="kill reset" bash rewrite-recovery-stress.sh
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

For `CANDIDATE=*rewrite*`, `rewrite-evidence-audit.sh` checks counter contents,
not merely file presence. It requires the same hardware-start/busy-time deltas
as the runner and positive `rga:release_fence_count` in the direct librga suite
to prove async/fence traversal. MPP imports and queued jobs, RGA imports and
boundary-shadow views, and the direct-librga userptr-IOMMU active count must be
zero after the run. `*:active` deliberately spans the newer `userptr_iommu` and
legacy `route_b` component names. The default forbidden list now covers
timeouts, recovery failures, IOMMU faults, spurious IRQs, RGA IRQ/config errors,
and boundary-shadow setup failures; rewrite audits require every listed counter
for each component captured by that suite to exist, so missing instrumentation
cannot masquerade as zero.
`release_fence_count` is cumulative and is
therefore never used as a zero-after leak assertion. Use
`AUDIT_COUNTER_CHECKS=0` only for intentionally old/exploratory logs.

The same audit requires each paired suite directory to contain a clean
`dmesg-scan.tsv`, requires each selected rewrite suite's run-matched
`*-kunit.tsv` to report exactly 94 MPP plus 152 RGA cases with no fail/skip,
and requires the matching `*-kunit-dmesg-scan.tsv` to record a complete,
fatal-free interval with live lockdep. It also requires the named official-MPP
core matrix. `REQUIRE_DMESG_EVIDENCE=0`,
`REQUIRE_KUNIT_EVIDENCE=0`, and `REQUIRE_MPP_CORE_CASES=0` are explicit
relaxations, not production settings.

The focused `iommu-machinery-fuzz.sh` gate goes further when the boundary-shadow
counters added by the 2026-07-17 reconciliation are present: it requires
positive `shadow_copy_to_bytes` and `shadow_copy_from_bytes`, zero active
head/tail shadow views after the run, and zero `shadow_setup_failure_count`
delta. Its C++ workload sweeps all 64 cache-line offsets and checks guard bytes
outside every active source and destination range.

For rewrite runs with selected hardware cases, also gate the captured debugfs
counter deltas so a userspace pass cannot hide a missing hardware submission or
timer path. `run-conformance.sh` can run those checks automatically with
`RUN_COUNTER_CHECKS=1`; it always points the selected suite wrappers at known
`$CONFORMANCE_ROOT/logs/$PROFILE/$RUN_ID-*-suite/` directories so the matching
counter files are unambiguous. For `PROFILE=*rewrite*`, the profile runner also
defaults to requiring the counter files plus positive librga/GStreamer/FFmpeg
hardware-start and busy-time counters; it adds positive MPP counters only when
`MPP_REQUIRED_CASES` explicitly selects media cases because the direct default
`mpp_info_test` does not submit hardware. It also requires the MPP queue/import
and RGA import/boundary-shadow/userptr-IOMMU gauges to settle to zero. Set
`CONFORMANCE_COUNTER_DEFAULTS=0` to disable those automatic requirements for a
narrow diagnostic pass. The checker defaults to failing positive
timeout/fault/recovery/spurious/config/shadow-setup counters when the delta file
exists. To prove multicore spread, set
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
SUMMARY=../rock-5b/build/rockchip-conformance/logs/rewrite/<run>-mpp-suite/summary.tsv \
REQUIRED_POSITIVE_COUNTERS="mpp:started_job_count mpp:hw_total_ns" \
REQUIRED_POSITIVE_COUNTER_PREFIXES="mpp:started_rkvdec_core:2" \
bash debugfs-counter-check.sh

SUMMARY=../rock-5b/build/rockchip-conformance/logs/rewrite/<run>-librga-suite/summary.tsv \
REQUIRED_POSITIVE_COUNTERS="rga:started_job_count rga:hw_total_ns" \
REQUIRED_POSITIVE_COUNTER_PREFIXES="rga:started_rga3_core:2" \
bash debugfs-counter-check.sh

SUMMARY=../rock-5b/build/rockchip-conformance/logs/rewrite/<run>-librga-suite/summary.tsv \
REQUIRED_POSITIVE_COUNTERS="rga:started_job_count rga:hw_total_ns *:attempt *:ok" \
REQUIRED_ZERO_AFTER_COUNTERS="*:active" \
bash debugfs-counter-check.sh

SUMMARY=../rock-5b/build/rockchip-conformance/logs/rewrite/<run>-gstreamer-suite/summary.tsv \
REQUIRED_POSITIVE_COUNTERS="mpp:started_job_count rga:started_job_count mpp:hw_total_ns rga:hw_total_ns" \
bash debugfs-counter-check.sh
```

Maintenance gate: `shellcheck *.sh` in this directory and
`bash run-conformance.sh --validate` is expected to pass; it
now include the
`IOCTL_FUZZ_VALIDATE_BUILD=1` ioctl-mutator compile check,
`LIBRGA_SMOKE_VALIDATE_BUILD=1` direct `librga` smoke compile check, and
`IOMMU_FUZZ_VALIDATE_BUILD=1` RGA IOMMU scatter-fuzzer compile check, and
`RECOVERY_VALIDATE_ONLY=1` recovery stress harness config check in addition
to the runner, MPP/GStreamer case-builder, FFmpeg case-list, comparator,
`abi-replay.sh --selftest`, and `rewrite-evidence-audit.sh --selftest` checks;
it also attempts a
`GST_EVENT_HARNESS_VALIDATE_BUILD=1` GStreamer event-harness build when
GStreamer development `.pc` files are installed. They were last verified on
2026-07-17 after the cache-line boundary sweep and shadow-counter checks were
added to the RGA IOMMU fuzzer. Earlier maintenance additions include the
ioctl-fuzz build, direct `librga`
smoke build, optional GStreamer event-harness build, IOMMU-fuzzer build,
recovery stress config check, and MPP case-builder validation
steps were wired into `run-conformance.sh` — the syzlang ABI-marker and
`SYZKALLER_DIR`/Go description-compile steps were wired in at the same time and
have since moved to the private `rock-5b-security` repository — after the
evidence-audit
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
diagnostics were added for the rewrite's source-implemented but
hardware-unverified RKMPP AV1 backend; and after
opt-in generated VP8/H.263/MPEG diagnostics were added for advertised legacy
decoder caps outside the RK3588 rewrite gate; and after `debugfs-counter-check.sh`
was added to gate selected rewrite hardware-start/busy-time counter deltas and
default timeout/fault/error counters; after `run-conformance.sh`
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

### Post-reboot identity and ownership preflight

Installing a co-installable rewrite package does not prove that the machine is
running it. After reboot, run this preflight from the YSP repository root:

```bash
uname -r

grep -E '^(CONFIG_ROCKCHIP_(MPP|RGA)_REWRITE=y|# CONFIG_ROCKCHIP_MPP_SERVICE is not set|# CONFIG_VIDEO_ROCKCHIP_RGA is not set)$' \
  /boot/config-"$(uname -r)"

ls -l /dev/mpp_service /dev/rga
sudo test -d /sys/kernel/debug/rk_mpp_rewrite
sudo test -d /sys/kernel/debug/rk_rga_rewrite

sudo journalctl -k -b --no-pager | \
  grep -Ei 'mpp|rga|iommu|fault|timeout|oops|warning|panic'
```

The expected release is `6.18.38-ysp-alpha-6.18-rockchip64` for the 6.18.38
package or `7.2.0-rc3-ysp-alpha-7.2-rc3-rockchip64` for the 7.2-rc3 package.
Both character devices and both rewrite debugfs directories must exist. The
debugfs check distinguishes rewrite ownership from a different driver that
happens to expose the same device-node names. Review the complete filtered
kernel log; the grep command intentionally shows normal driver messages along
with fault signatures and is not by itself a pass/fail classifier.

### Quick consumer smoke

For rewrite acceptance, boot a kernel where `ROCKCHIP_MPP_REWRITE` and
`ROCKCHIP_RGA_REWRITE` own the device nodes, then run the maintained
sibling-worktree layout directly:

```bash
sudo \
  FFDIR=../rock-5b/ffmpeg/ffmpeg-rockchip \
  STAGE=../rock-5b/build/kernel/rock5b-kernel-build/ffmpeg-stack \
  bash kernel-drivers/tests/rewrite-smoke.sh
```

For a different workspace layout, supply the equivalent paths explicitly:

```bash
sudo MPP_BUILD=<mpp-build> FFDIR=<ffmpeg-rockchip> STAGE=<stage> \
  bash kernel-drivers/tests/rewrite-smoke.sh
```

The same command is valid on the BSP-derived forward-port kernel, which makes it
the quick parity check between the two implementations. (`rewrite-smoke.sh`
itself is documented in [`README.md`](./README.md).) It checks both device
nodes, captures rewrite counters before and after the workloads, and exercises
the non-submit ABI probe, hardware decode, hardware encode, and an
RKMPP-to-RGA-scale-to-RKMPP FFmpeg transcode. Exit `0` and the final
`ALL SELECTED REWRITE/FORWARD-PORT CONSUMER SMOKE TESTS PASSED` line are the
quick acceptance result; exit `77` means the driver nodes are absent, and any
other nonzero exit is a workload or environment failure.

### Full standalone and paired parity gates

After the smoke passes, run the expanded rewrite profile with hardware counter
assertions:

```bash
sudo bash kernel-drivers/tests/run-conformance.sh --target rewrite
```

The counter checks prove that the required workloads reached MPP/RGA hardware,
reject positive timeout/fault/error counters, and require tracked import gauges
to return to zero. Keep a known-good Armbian or forward-port kernel installed as
a recovery boot until the smoke and full profile pass.

For the full userspace-visible parity gate, collect the full forward-port
profile first, then reboot into the rewrite and compare against it:

```bash
sudo PROFILE=forward-port \
  bash kernel-drivers/tests/run-conformance.sh
sudo PROFILE=rewrite RUN_COUNTER_CHECKS=1 RUN_COMPARE=1 \
  bash kernel-drivers/tests/run-conformance.sh
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
the intentionally pruned raw physical-address import path and its disabled
marker. Raw evidence exists in `.raw.log` and `.norm.log` only when explicitly
enabled; rewrite profiles enable it automatically. It also writes a smaller `.contract.log`
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
`../rock-5b/build/rockchip-conformance/assets/mpp-generated`. The manual `mpi_dec_test` VP9
recipe (no suite) lives in [`README.md`](./README.md) § VP9 decode.
At the kernel level, the current rewrite pins also include KUnit coverage for
VP9 RKVDEC fd-to-IOVA register translation/validation, including rejection of
unknown RKVDEC format-table indices. They also pin the HARD-CCU DMA-visibility
gate: online decoder peers must share one DMA/IOMMU domain before the
coordinator may advertise or build an all-core descriptor mask. The Rock 5B DT
now establishes that domain through the provider-level
`rockchip,shared-domain-owner` link from `vdec1_mmu` to `vdec0_mmu`; targeted
binding validation and `dtbs_check` must stay clean, and booted evidence must
show both `fdc38000` and `fdc40000` decoder masters resolving to the same
`iommu_group` symlink. Shared-domain fault coverage also pins exact
controller/master matching and per-provider callback ownership: removing one
decoder must clear that decoder IOMMU's hook without clearing or redirecting
the surviving peer's hook. MPP deliberately has no legacy domain-handler
fallback because that set-once API cannot provide module-safe unregister
lifetime on the IOMMU-core-owned default DMA domain. An attached-domain core
must fail probe if the provider hook is unavailable; a core with no IOMMU
domain remains valid.
HARD-CCU fault coverage additionally separates physical attribution from
software job ownership. After matching the exact decoder controller, the
handler reads that source link's `CFG_ADDR` descriptor IOVA and routes recovery
to the active same-coordinator job that owns it. An unavailable or unmatched
descriptor falls back to any active HARD-CCU job on the coordinator, ensuring
the force-stop and dependent-job abort path runs instead of scheduling only an
empty `active_job` slot. The software owner must be published before the
`CFG_DONE` doorbell so the same routing remains valid for a fault raised by the
first descriptor fetch. Once the coordinator is stopped, a peer with a
contended run lock must queue an immediate exact-job abort rather than falling
back to the ordinary 500 ms timeout. KUnit pins target replacement and
reference lifetime. It also requires the target snapshot to precede the failed
lock attempt and requires timeout cancellation to follow the worker's exact-job
claim; a stale target must neither reset a replacement nor remove its watchdog.
Booted recovery stress must additionally show that a replacement job completes
or times out normally when the delayed worker finally acquires the lock.
The import-side KUnit gate also requires every codec dma-buf mapping to cover
the full allocation as a byte-contiguous 32-bit DMA span. Register provenance
coverage rejects cumulative embedded plus `SET_REG_ADDR_OFFSET` values that
leave the dma-buf or overflow the 32-bit IOVA register; literal non-fd register
offsets remain additive. Runtime media cases should keep
the rewrite `translate-fail` event count at zero for normal dma-heap buffers.
Import-cache coverage additionally resolves the dma-buf before lookup and keys
the mapping by object identity as well as fd and DMA device. A reused integer fd
must select the new dma-buf, while stale cache ownership is dropped without
invalidating mappings still referenced by an in-flight job.
Session-control coverage additionally treats every staged register job as an
immutable snapshot of its client type, translation table, codec information,
inherited RCB descriptors, and reset epoch. A later control message starts a
new staged job instead of retroactively changing earlier work. `RESET_SESSION`
removes earlier staged jobs for that session from the current ioctl, advances
the epoch before aborting queued/active work, and prevents a racing import or
admission from repopulating the cleared cache or entering the scheduler.
Active-list and scheduler-queue publication is one reset-atomic operation;
repeating the bound client type remains valid, while changing an initialized
session between encoder and decoder must return `-EBUSY`.
Poll-lifecycle coverage additionally requires a slice-FIFO overflow to report
`-EOVERFLOW` without permanently poisoning the head job: a later poll must be
able to drain retained slice words and reach normal completion. A non-split
`POLL_HW_IRQ` must take the full-frame path, and an empty session must return
`-EIO`, before either path validates or touches a slice-only flexible buffer.
Teardown-lifetime coverage additionally requires completion's `job->hw`
detach and abort's hardware pin to share the session lock. An abort racing
completion/removal must either acquire its own hardware reference or observe a
detached `NULL`; it must never use an unpinned devm hardware pointer while
platform removal waits for the final reference.
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
RGA IOMMU-fault coverage now requires a reported master/controller to match the
exact physical core even when another RGA shares its DMA domain; an unknown
source must fall through to the provider's normal fault reporting rather than
resetting the first peer. Attached-domain probe requires the unregisterable
provider hook, per-core removal clears that physical callback regardless of
same-domain peers, and the provider clear operation waits for callbacks already
executing in the IRQ path. Unbind/rebind recovery stress should therefore show
no fault callback, timeout work, or release-fence completion attributed to a
removed or wrong RGA core.
Acquire-fence recovery coverage also pins two callback contracts. Fence status
is read with the lock-held helper because dma-fence invokes callbacks under its
spinlock; using the locking wrapper recursively deadlocks the signaling path.
Last-core abort interleaved with callback registration must also wait for the
arming sentinel and every callback's pending-count share rather than releasing
the shared work reference while the submit path can still register another
callback. Booted close/unbind stress should produce exactly one release-fence
completion with no hang or KASAN report for jobs blocked on acquire fences.

**UNVERIFIED:** neither the generated GStreamer VP9 cases nor the direct MPP
VP9 suite case has a forward-port/rewrite hardware log yet. If you run either,
record the result in status.md.

<a id="av1-diagnostics-via-the-gstreamer-suite"></a>

## AV1 qualification via the GStreamer suite

The maintained rewrite source exposes a separate VPU981 RKMPP AV1 backend and
VSI-IOMMU path. Neither has hardware evidence. The GStreamer plugin advertises
`video/x-av1`, so the suite has opt-in bring-up cases that generate a small AV1
IVF stream with
`GST_GENERATOR`/`libaom-av1` and feed it through the same
`ivfparse ! mppvideodec` path as current userspace:

```bash
PROFILE=rewrite \
GST_ENABLE_AV1_CASES=1 \
../rock-5b-ysp/kernel-drivers/tests/gstreamer-suite.sh
```

Set `GST_REQUIRE_AV1_CASES=1` for a full current-tip rewrite qualification; the
default remains diagnostic so source-only bring-up can proceed in stages. The
enabled set covers fakesink decode, DMABuf decode, RGA-scale decode, and
AV1-to-H.264 transcode. Failure is an open VPU981/VSI hardware-qualification
gap, not evidence about the separate RKVDEC2 H.264/H.265/VP9/AVS2 path.

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
