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
| Owns | The smoke tests `test-decode.sh`, `decode-differential.sh`, `encode-test-tiny.sh`, `transcode-test.sh`, `rewrite-smoke.sh`, `abi-probe.sh`/`abi-probe.c`, `abi-replay.sh`, `librga-smoke.sh`/`librga-smoke.cpp`, and the targeted RGA MMU diagnostic `rga-mmu-debug.sh`; the RGA/IOMMU stress tools `iommu-machinery-fuzz.sh`, `rga-iommu-fuzz.cpp`, and [`IOMMU-FUZZING.md`](./IOMMU-FUZZING.md); the sourced helpers `suite-common.sh` and `debugfs-counters.sh`; the conformance runner/wrappers `rewrite-conformance-run.sh`, `mpp-suite.sh`, `mpp-suite-compare.sh`, `librga-suite.sh`, `librga-suite-compare.sh`, `gstreamer-suite.sh`, `gstreamer-suite-compare.sh`, `ffmpeg-suite.sh`, `ffmpeg-suite-compare.sh`, `debugfs-counter-check.sh`, `rewrite-build-gate.sh`, `suite-compare-selftest.sh` and their build helpers `build-mpp-tests.sh`, `build-librga-samples-full.sh`, `build-gstreamer-rockchip.sh`, `gstreamer-event-harness.c` (all documented in [`rewrite-conformance.md`](./rewrite-conformance.md)); input-regeneration recipes; pass criteria; and observed reference results. |
| Depends on | A validated kernel from [`../scripts/`](../scripts/README.md), staged MPP/FFmpeg artifacts from [`video-libraries/ffmpeg/README.md`](../../video-libraries/ffmpeg/README.md), and device access from the codec udev rule. |
| Current state | H.264/H.265 decode, encode, and full HW transcode have been validated on the forward-port; **VP9 and AV1 decode are now hardware-validated bit-exact on the av1-fwport build** (2026-07-04, `decode-differential.sh` — AV1 needs that variant's `mpp_av1dec.c` backend). The MPP suite has `MPP_VALIDATE_CASES=1` device-free case-builder validation for the selected official-test matrix. The GStreamer suite additionally has generated VP9 IVF decode cases, opt-in generated AV1 IVF diagnostics, opt-in generated VP8/H.263/MPEG diagnostics for advertised legacy decoder caps, required generated H.265 Main10 decode/RGA/fallback cases, optional generated H.265 4:2:2 10-bit cases, required GStreamer RGA rotation coverage for 90/180/270-degree public rotation values, diagnostic coverage for advertised H.264 encoder input and decoder output formats, the diagnostic VP8 encoder alias, diagnostic VP8/JPEG encoder property setters, diagnostic JPEG decoder explicit/default output-format cases, diagnostic RFBC caps negotiation via `GST_MPP_DEC_FBC_IS_RFBC=1`, opt-in display sink env cases for `KMSSINK_DISABLE_VSYNC=1`/`GST_RKXIMAGE_USE_COLORKEY=1`, opt-in KMS capture cases for DRM dma-buf import into MPP encode including `GST_KMSSRC_DMA_FEATURE=1`, and `GST_VALIDATE_CASES=1` device-free case-builder validation. The ABI replay now optionally allocates a dma-heap buffer and records non-submit MPP `TRANS_FD_TO_IOVA`/`RELEASE_FD` plus RGA dma-buf import/release and raw physical-address import behavior for allocator handoff parity and unsupported-path evidence. The FFmpeg suite now runs the selected `ffmpeg-rockchip` build twice when possible - first with the system runtime, then with staged/from-source MPP via `STAGE`/`FFMPEG_STAGED_LD_LIBRARY_PATH` - and has `FFMPEG_VALIDATE_CASES=1` device-free case validation, required H.264/H.265/VP9 RKMPP decode, bit-exact decode PSNR gates, H.264/H.265 encoder-option sanity gates, RKRGA H.264<->H.265 transcodes, `scale_rkrga`, `vpp_rkrga`, and `overlay_rkrga` coverage, plus AV1 decode/transcode/AFBC diagnostics that can be promoted with `FFMPEG_REQUIRE_AV1=1`; absence of an AV1 RKMPP encoder is recorded as expected. `rewrite-conformance-run.sh` now sequences system-info, ABI replay, MPP, librga, GStreamer, FFmpeg, optional debugfs counter checks, and optional forward-port-vs-rewrite comparison steps for a full profile run. Its `VALIDATE_ONLY=1` mode includes device-free runner, syzlang ABI-marker, ioctl mutator build, direct `librga` smoke build, optional GStreamer event-harness build when GStreamer development `.pc` files are present, RGA IOMMU scatter-fuzzer build, MPP/GStreamer case-builder validation, FFmpeg case-list validation, comparator, and counter-default validation. The MPP conformance comparator now has byte-count/SHA-256 artifact comparison for official-test media outputs when the suite dumps decode/encode files, the librga conformance comparator now compares deterministic destination-buffer artifacts from the required direct RGA smoke case, and `debugfs-counter-check.sh` can enforce rewrite counter deltas for selected hardware-start/busy-time gates either standalone or through `RUN_COUNTER_CHECKS=1` in the profile runner. For `PROFILE=*rewrite* RUN_COUNTER_CHECKS=1`, the runner defaults to requiring counter files plus positive librga/GStreamer/FFmpeg hardware-start and busy-time counters; explicit MPP hardware counters are required when `MPP_REQUIRED_CASES` is set. The rewrite clean-source object-build gate passed both public rewrite branch tips on 2026-07-06: `d1cfb432da7f` on 6.18 and `c8a41bb830a6` on mainline. See [`rewrite-conformance.md`](./rewrite-conformance.md) for the parity/conformance machinery. |

## What each smoke test proves

| Test | Exercises | Pass criterion |
|------|-----------|----------------|
| `test-decode.sh` | **decoder** (`rkvdec2`) | `mpi_dec_test` decodes *software-encoded* H.264 + H.265 320×240 clips to NV12 → exit 0 + non-empty output. Software-encoded input means a failure implicates the **decoder**, not our encoder. |
| `decode-differential.sh` | **decoder correctness** (`rkvdec2` + `av1dec`) | Adds the strong oracle on top of the liveness gate: HW-decode vs SW-decode **PSNR must be `inf` (bit-exact)** for H.264, H.265, **VP9, and AV1**. Covers the codecs `test-decode.sh` doesn't; AV1 needs the av1-fwport variant. Generates its own software-encoded inputs. |
| `encode-test-tiny.sh` | **encoder** (VEPU580) | `mpi_enc_test` H.264 + H.265 at 256² and 1280×720 → valid NAL-start bitstreams, exit 0, no IOMMU fault (dmesg-marker scheme with a real-fault regex that excludes benign warnings). Reports PSNR + fps. |
| `transcode-test.sh` | **full pipeline** (both decoders, both encoders, RGA ×2) | ffmpeg-rockchip: `h264_rkmpp` → `scale_rkrga` 1080p→720p → `hevc_rkmpp`, then the reverse. `rkmpp`/`rkrga` have no SW fallback, so a pass *is* proof the hardware ran. Verifies each output with `ffprobe`. |
| `rewrite-smoke.sh` | **current `/dev/mpp_service` + `/dev/rga` owner**: forward-port or rewrite | Runs the ABI probe plus decode, encode, and transcode gates above in one pass, and snapshots rewrite debugfs counters, including aggregate/per-core timing counters, when present. Exit `77` means the device nodes are absent on this boot, not that the workload failed. |
| `abi-probe.sh` | **non-submit ABI** on current `/dev/mpp_service` + `/dev/rga` owner | Builds and runs a small C probe that records MPP/RGA ioctl numbers, struct sizes, `/proc/mpp_service` command-advertisement markers when visible, safe query results, MPP client-type HW-ID replay, initialized MPP session controls (`INIT_DRIVER_DATA`, `SEND_CODEC_INFO`, `RESET_SESSION`, and advertised `SET_ERR_REF_HACK`), a safe two-message MPP init batch, `SET_SESSION_FD` bad-fd `mpp_bat_msg.ret = -EBADF` and `MPP_BAT_MSG_DONE` marker handling, optional dma-heap-backed MPP `TRANS_FD_TO_IOVA`/`RELEASE_FD`, RGA version tuples/strings with exact version-query returns including intentional `RGA2_GET_VERSION ret=1`, no-op ioctl return codes, RGA virtual-address and dma-buf import/release, raw physical-address import observation, and modern RGA request create/config/cancel with a handle-backed bitblit task. Set `ABI_PROBE_EXPECT_RGA_PHYSICAL_REJECT=1` on rewrite-only negative runs to fail unless the raw physical-address import ioctl returns `-EOPNOTSUPP`; the default only records the result so the probe remains usable on the BSP-derived forward-port oracle. Use the same binary/log format on the forward port and rewrite, then diff the logs. Exit `77` means both device nodes are absent. |
| `ioctl-fuzz-smoke.sh` | **bounded non-submit ioctl fuzzing** | Builds and runs a small deterministic mutator over safe `/dev/mpp_service` and `/dev/rga` parser/import/control paths. It mutates sizes, flags, bad user pointers, MPP query/control payloads, RGA version/no-op calls, import/release pools, and request create/cancel without deliberately submitting hardware jobs. Tune with `IOCTL_FUZZ_ITERS`, `IOCTL_FUZZ_SEED`, `IOCTL_FUZZ_TIMEOUT`, and `IOCTL_FUZZ_VERBOSE`; set `IOCTL_FUZZ_VALIDATE_BUILD=1` for the compile-only check that is part of `VALIDATE_ONLY=1 rewrite-conformance-run.sh`. Exit `77` means both device nodes are absent. |
| `syzkaller/check-rockchip-syzlang.sh` | **device-free fuzzer ABI constant check** | Verifies the draft syzlang description in `syzkaller/rockchip_mpp_rga.txt` still matches the ioctl numbers and struct sizes built by `abi-probe.sh`. The syzlang draft covers safe parser/import/version ioctls by default and marks submit-capable MPP/RGA calls disabled/no-generate until the sacrificial RK3588 fuzzing setup exists. This check is also part of `VALIDATE_ONLY=1 rewrite-conformance-run.sh`, so normal device-free validation catches stale fuzzer ABI constants. |
| `abi-replay.sh` | **normalized ABI replay** for a single booted kernel profile | Records raw + normalized ABI logs under `logs/abi-replay/`, a `.compare.log` used for forward-port-vs-rewrite diffs after removing intentional obsolete-path deltas, and a `.contract.log` of the stable query/version and session-control lines. Feeds the ABI diff comparison in [`rewrite-conformance.md`](./rewrite-conformance.md) § Raw ABI replay. Exit `77` means the device nodes are absent. |
| `librga-smoke.sh` | **direct librga/im2d functional test** on current `/dev/rga` owner | Builds and runs a tiny C++ client against staged `librga`: virtual-address imports, dma-heap dma-buf allocation plus `importbuffer_fd` copy, `imcvtcolor`, async `imresize` with release-fence wait, crop, and flip, RKNN/RKNPU-style preprocessing (`RGB888` virtual `imresize`, fd-backed `RGB888`/`NV12`/`NV21` `improcess` resize/convert, fd-backed RGBA source-crop into an RGB letterbox rectangle, and legacy RGB `c_RkRgaBlit()` resize), an `rkmppenc`-shaped fd-backed RGB crop/CSC to NV12 plus async NV12 resize chain using acquire/release fences, legacy `c_RkRgaBlit()` conversions shaped like JeffyCN GStreamer and public display/compositor users (`BGRx` malloc source to NV12 dma-buf encoder preprocessing, rotated NV12 dma-buf to BGRx dma-buf decode conversion, fd-backed BGRx display-style 90-degree rotation, virtual RGBA flip, and planar I420 dma-buf to NV12 dma-buf fallback), fd-backed legacy `c_RkRgaColorFill()`, a no-submit physical-address import probe, public-API raster-to-AFBC32x8/RFBC64x4 negative probes, official Gaussian matrix blur via `imsetOptGaussianBlurMatrix()` + `imsetOpacity()` + `improcess(..., IM_SYNC | IM_GAUSS)`, sync `imcopy`/`imresize`/`imfill`, thread-default `imconfig()` scheduler-core + priority copy, a sequential two-task `imbeginJob()`/`imcopyTask()`/`imendJob()` copy chain, forced RGA3 core-mask + priority copy through `improcess`, forced RGA2 `IM_PRE_INTR` read/write line-interrupt copy, and an async acquire/release-fence copy chain waited with `imsync`. Set `LIBRGA_SMOKE_10BIT=1` to add direct IM2D P010->NV12 and P210->NV16 dma-buf conversions through the patched P010/P210 request-generation path. Set `LIBRGA_SMOKE_EXPECT_PHYSICAL_REJECT=1` on rewrite-only negative runs to fail if physical-address import is accepted, and `LIBRGA_SMOKE_EXPECT_FBC_TAIL_REJECT=1` to fail if AFBC32x8/RFBC64x4 destination modes are accepted; the defaults only record the results so the smoke remains usable on the forward-port oracle. Set `LIBRGA_SMOKE_ARTIFACT_DIR=<dir>` to dump deterministic raw destination buffers for byte-count/SHA-256 comparison. Set `LIBRGA_SMOKE_VALIDATE_BUILD=1` for the device-free compile-only check that is part of `VALIDATE_ONLY=1 rewrite-conformance-run.sh`. This exercises the maintained librga import/submit/core/fence/pre-intr/gauss/10-bit paths independently of FFmpeg. Exit `77` means `/dev/rga` is absent. |
| `build-gstreamer-rockchip.sh` | **GStreamer plugin and event harness build helper** | Stages JeffyCN's GStreamer Rockchip plugins and the `gstreamer-event-harness` helper used for flush, force-key-unit, seek, and EOS-loop cases. Set `GST_EVENT_HARNESS_VALIDATE_BUILD=1` for a device-free event-harness compile/link check; it returns `77` when the GStreamer development pkg-config files are absent, and the top-level validate-only runner records that as a visible skip. |
| `rga-mmu-debug.sh` | **targeted RGA3/IOMMU fault capture** for direct upstream librga samples | Enables `/sys/kernel/debug/rkrga` `reg msg int mm time` flags without blindly toggling already-enabled state, runs selected sample binaries (`rga_copy_demo`, `rga_resize_rect_demo`, `rga_transform_rotate_demo` by default), writes kmsg markers, captures per-case stdout/stderr, before/after dmesg, filtered RGA/IOMMU/MMU lines, and debugfs snapshots, then restores debug flags. It was added to root-cause the 2026-07-04 RGA3 `INTR[0x2]` finding and should be rerun after rebuilding the forward kernel with `13afe70c8271` and `6b9dba7abcd0`; set `RGA_FAIL_ON_CASE_FAILURE=1` when using it as a validation gate. |
| `iommu-machinery-fuzz.sh` | **RGA3 Route B and RK3588 IOMMU stress** | Builds `rga-iommu-fuzz.cpp`, runs scattered-userptr RGA copy/resize/rotate/cvtcolor correctness checks, reuses `decode-differential.sh` for bit-exact H.264/H.265/VP9/AV1 decode, and can run RGA scatter plus AV1 decode concurrently while bracketing dmesg and debugfs counters for IOMMU faults and Route B leaks. Run on booted hardware, ideally the debug kernel in [`IOMMU-FUZZING.md`](./IOMMU-FUZZING.md). Set `IOMMU_FUZZ_VALIDATE_BUILD=1` for the device-free C++ compile check that is part of `VALIDATE_ONLY=1 rewrite-conformance-run.sh`; that mode does not touch devices, debugfs, or target librga shared libraries. |

## Privileges

The smoke tests differ in what device access they need:

| Test | Needs |
|------|-------|
| `abi-probe.sh` | device access only for `/dev/mpp_service` and/or `/dev/rga`; with `/dev/dma_heap/*` access it also records optional dma-buf MPP translate/release and RGA import/release parity |
| `ioctl-fuzz-smoke.sh` | device access only for `/dev/mpp_service` and/or `/dev/rga`; no root requirement unless the local udev policy restricts the nodes. It does not intentionally submit MPP register jobs or RGA blits. |
| `test-decode.sh` | device access only: root, **or** membership in `video` with [`../scripts/99-rockchip-codec.rules`](../scripts/99-rockchip-codec.rules) installed (covers `/dev/mpp_service` **and** `/dev/dma_heap/*` — both required) |
| `librga-smoke.sh` | device access only: root, **or** membership in `video` with the codec udev rule installed (covers `/dev/rga` **and** `/dev/dma_heap/*` — the smoke allocates dma-bufs, imports them with `importbuffer_fd`, runs RKNN-style fd/virtual preprocessing including RGBA crop/letterbox, an `rkmppenc`-shaped fd crop/CSC/resize/fence chain, fd-backed `imcvtcolor`, async fd-backed `imresize`, legacy `c_RkRgaBlit()` GStreamer-style virtual-source, fd-to-fd rotate/convert, display-style BGRx rotation, IM2D and legacy flip, fd-backed legacy color fill, a sequential IM2D task job, and planar fallback conversions, records no-submit physical-address import plus AFBC32x8/RFBC64x4 destination-mode probes, exercises the official `improcess(..., IM_GAUSS)` Gaussian matrix shape, and can opt into P010/P210 IM2D conversions with `LIBRGA_SMOKE_10BIT=1`). `LIBRGA_SMOKE_VALIDATE_BUILD=1` is device-free and only compiles the C++ smoke object. |
| `build-gstreamer-rockchip.sh` | no device access for build; needs GStreamer development `.pc` files plus staged MPP/librga pkg-config paths for the full plugin build. `GST_EVENT_HARNESS_VALIDATE_BUILD=1` only needs `gstreamer-1.0` and `glib-2.0` development `.pc` files, and skips with `77` if they are absent. |
| `rga-mmu-debug.sh` | **root** — reads/writes RGA debugfs flags, writes `/dev/kmsg` markers, and reads full `dmesg` on systems with `kernel.dmesg_restrict=1` |
| `iommu-machinery-fuzz.sh` | **root strongly preferred** — `/dev/rga`, `/dev/mpp_service`, staged librga/MPP artifacts, full dmesg, and debugfs counters are needed for the Route B/IOMMU fault and leak signal. `IOMMU_FUZZ_VALIDATE_BUILD=1` is device-free and only compiles the RGA scatter fuzzer object. |
| `encode-test-tiny.sh` | **root** — writes dmesg markers to `/dev/kmsg` and scans `dmesg` for faults (`kernel.dmesg_restrict=1` on Armbian) |
| `transcode-test.sh` | **root** — runs a `dmesg` fault sweep at the end |

(The conformance-suite scripts have their own privilege table in
[`rewrite-conformance.md`](./rewrite-conformance.md) § Suite privileges.)

> **Paths.** Every dev-box path is an env-overridable variable with the
> original dev-box default. Naming matches [`video-libraries/ffmpeg/README.md`](../../video-libraries/ffmpeg/README.md):
>
> | Var | Used by | Meaning |
> |-----|---------|---------|
> | `MPP_BUILD` | decode, encode | an MPP build/install tree with `librockchip_mpp` + `mpi_dec_test`/`mpi_enc_test`. Default `../rockchip-conformance/out/mpp` (install layout `lib/`+`bin/`); a raw cmake build dir (`mpp/`+`test/`) is auto-detected too. `decode-differential.sh` uses the same default. |
> | `CLIP_DIR` | decode | directory holding `tiny-320x240.h264/.h265` (regeneration below) |
> | `FFDIR` | transcode | ffmpeg-rockchip build dir (`./ffmpeg`, `./ffprobe`) |
> | `STAGE` | transcode | the MPP/RGA staging prefix from the ffmpeg README (e.g. `~/ffmpeg-stack`) |
> | `FFMPEG_RUNTIME_MODES` | `ffmpeg-suite.sh` | runtime passes to run: `auto` (default, system plus staged when `$STAGE/lib` exists), or an explicit space-separated list such as `system staged`. |
> | `FFMPEG_REQUIRE_AV1` | `ffmpeg-suite.sh` | promote AV1 RKMPP decode, AV1->RGA->H.264/H.265 transcodes, AV1 PSNR, and AV1 AFBC probes from diagnostics to required cases (`0` by default because AV1 is outside the rewrite base gate). |
> | `FFMPEG_AV1_INPUT`, `FFMPEG_VP9_INPUT`, `FFMPEG_HEVC_MAIN10_INPUT` | `ffmpeg-suite.sh` | optional explicit inputs; otherwise the suite generates software AV1/VP9/Main10 inputs under `../rockchip-conformance/assets/ffmpeg-generated` when the needed software encoders are installed. |
> | `FFMPEG_SOAK_SECONDS`, `FFMPEG_STRESS_LOOPS` | `ffmpeg-suite.sh` | tune the opt-in FFmpeg stress/soak cases enabled by `FFMPEG_RUN_STRESS=1`. |
> | `IN` | transcode | 1080p H.264 Annex-B input (default `$STAGE/testdata/input-1080p.h264`; regeneration below) |
> | `RUN_LIBRGA` | rewrite smoke | optional direct librga/im2d functional smoke (`0` by default; set `1` to run) |
> | `ABI_PROBE_EXPECT_RGA_PHYSICAL_REJECT` | `abi-probe.sh` / `abi-replay.sh` | optional rewrite-only negative check for the raw `RGA_IOC_IMPORT_BUFFER` physical-address path (`abi-replay.sh` defaults it to `1` for `PROFILE=*rewrite*`; direct probe runs default to observational so the same binary can run on the BSP-derived forward-port) |
> | `LIBRGA_SMOKE_10BIT` | `librga-smoke.sh` | optional direct P010/P210 IM2D dma-buf conversion cases (`0` by default; set `1` when validating a patched librga/kernel pair) |
> | `LIBRGA_SMOKE_EXPECT_PHYSICAL_REJECT` | `librga-smoke.sh` / `librga-suite.sh` | optional rewrite-only negative check for direct physical-address import (`librga-suite.sh` defaults it to `1` for `PROFILE=*rewrite*`; direct smoke runs default to observational so they can still run on the BSP-derived forward-port, which may accept the import path) |
> | `LIBRGA_SMOKE_EXPECT_FBC_TAIL_REJECT` | `librga-smoke.sh` / `librga-suite.sh` | optional rewrite-only negative check for AFBC32x8/RFBC64x4 destination modes through public `librga` calls (`librga-suite.sh` defaults it to `1` for `PROFILE=*rewrite*`; direct smoke runs record, rather than fail, forward-port behavior) |
> | `LIBRGA_SMOKE_ARTIFACT_DIR` | `librga-smoke.sh` | optional directory for raw destination-buffer dumps; `librga-suite.sh` sets this for its required `ysp_librga_smoke` artifact case |
> | `LIBRGA_FORCE_ROUTE_B` | `librga-suite.sh` / `rewrite-conformance-run.sh` | set `route_b/force_remap` during the librga suite and restore it at exit; with rewrite counter defaults, also require positive `rga_route_b:attempt` and `rga_route_b:ok` deltas |
> | `RUN_GSTREAMER` | rewrite smoke | optional JeffyCN GStreamer plugin suite (`0` by default; set `1` to run) |
> | `RUN_COUNTER_CHECKS` | `rewrite-conformance-run.sh` | optional suite debugfs counter gate (`0` by default); with `PROFILE=*rewrite*`, the runner defaults to requiring counter files plus positive librga/GStreamer/FFmpeg hardware-start and busy-time counters |
> | `*_REQUIRED_POSITIVE_COUNTER_PREFIXES` | `rewrite-conformance-run.sh` / `debugfs-counter-check.sh` | optional multicore spread gate using `component:counter_prefix:min_positive`, e.g. `MPP_REQUIRED_POSITIVE_COUNTER_PREFIXES="mpp:started_rkvdec_core:2"` or `LIBRGA_REQUIRED_POSITIVE_COUNTER_PREFIXES="rga:started_rga3_core:2"` |
> | `REWRITE_COUNTER_DEFAULTS` | `rewrite-conformance-run.sh` | set `0` to disable the automatic rewrite counter requirements when doing a narrow diagnostic run |
> | `REQUIRED_ZERO_AFTER_COUNTERS` | `debugfs-counter-check.sh` | optional counter specs whose after-run value must be exactly zero, used by the Route B gate for `rga_route_b:active` |

## Run

```bash
bash rewrite-smoke.sh                 # one-command gate; use sudo when devices are present
bash abi-probe.sh                     # fast non-submit ABI probe
ABI_PROBE_EXPECT_RGA_PHYSICAL_REJECT=1 bash abi-probe.sh  # rewrite-only raw physical-import negative check
bash abi-replay.sh                    # record normalized ABI log for this boot
bash librga-smoke.sh                  # direct librga/im2d smoke
LIBRGA_SMOKE_VALIDATE_BUILD=1 bash librga-smoke.sh  # device-free direct librga smoke compile check
LIBRGA_SMOKE_10BIT=1 bash librga-smoke.sh  # add P010/P210 IM2D cases
LIBRGA_SMOKE_EXPECT_PHYSICAL_REJECT=1 bash librga-smoke.sh  # rewrite-only physical-import negative check
LIBRGA_SMOKE_EXPECT_FBC_TAIL_REJECT=1 bash librga-smoke.sh  # rewrite-only AFBC32x8/RFBC64x4 negative check
GST_EVENT_HARNESS_VALIDATE_BUILD=1 bash build-gstreamer-rockchip.sh  # device-free GStreamer event harness build check; may skip if dev .pc files are absent
sudo env RGA_FAIL_ON_CASE_FAILURE=1 bash rga-mmu-debug.sh  # RGA3/IOMMU validation gate
IOMMU_FUZZ_VALIDATE_BUILD=1 bash iommu-machinery-fuzz.sh  # device-free RGA scatter-fuzzer compile check
sudo bash iommu-machinery-fuzz.sh  # booted Route B/IOMMU stress gate
MPP_VALIDATE_CASES=1 bash mpp-suite.sh  # device-free MPP official-test case-builder validation
VALIDATE_ONLY=1 bash rewrite-conformance-run.sh  # device-free runner/syzlang/ioctl-fuzz/librga-smoke/gstreamer-harness/iommu-fuzz/case/comparator wiring check
VALIDATE_ONLY=1 PROFILE=rewrite RUN_COUNTER_CHECKS=1 bash rewrite-conformance-run.sh  # also checks rewrite counter-default wiring
VALIDATE_ONLY=1 PROFILE=rewrite RUN_COUNTER_CHECKS=1 LIBRGA_FORCE_ROUTE_B=1 bash rewrite-conformance-run.sh  # also checks Route B counter-default wiring
sudo PROFILE=rewrite bash rewrite-conformance-run.sh  # full profile run on a rewrite boot
sudo PROFILE=rewrite RUN_COUNTER_CHECKS=1 bash rewrite-conformance-run.sh  # require rewrite hardware counter deltas
sudo PROFILE=rewrite RUN_COUNTER_CHECKS=1 LIBRGA_FORCE_ROUTE_B=1 RUN_SYSTEM_INFO=0 RUN_ABI_REPLAY=0 RUN_MPP_SUITE=0 RUN_GSTREAMER_SUITE=0 RUN_FFMPEG_SUITE=0 RUN_LIBRGA_SUITE=1 bash rewrite-conformance-run.sh  # focused Route B attribution gate
bash test-decode.sh                  # decoder liveness (device access is enough)
bash decode-differential.sh          # decoder correctness: bit-exact HW-vs-SW PSNR, incl. VP9 + AV1
sudo bash encode-test-tiny.sh        # encoder
sudo bash transcode-test.sh          # end-to-end (needs ffmpeg-rockchip built — see ../ffmpeg)
FFMPEG_VALIDATE_CASES=1 bash ffmpeg-suite.sh  # device-free FFmpeg case-list validation
FFMPEG_VALIDATE_CASES=1 FFMPEG_REQUIRE_AV1=1 FFMPEG_RUN_STRESS=1 FFMPEG_STRESS_LOOPS=1 bash ffmpeg-suite.sh  # validate promoted/optional FFmpeg wiring
bash ffmpeg-suite.sh                 # profile/log/comparator FFmpeg conformance
sudo FFMPEG_REQUIRE_AV1=1 FFMPEG_RUNTIME_MODES="system staged" bash ffmpeg-suite.sh  # AV1-capable board/runtime gate
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

Add `RUN_COUNTER_CHECKS=1` on rewrite profile runs when the selected suites
should have submitted hardware. The runner defaults to requiring counter files,
positive librga/GStreamer/FFmpeg hardware-start and busy-time counters, and MPP
hardware counters when explicit MPP media cases are selected. Use
`REWRITE_COUNTER_DEFAULTS=0` only for a deliberately narrow diagnostic pass. To
prove multicore scheduling on a suite that should use more than one core, add a
positive-prefix gate such as
`MPP_REQUIRED_POSITIVE_COUNTER_PREFIXES="mpp:started_rkvdec_core:2"` or
`LIBRGA_REQUIRED_POSITIVE_COUNTER_PREFIXES="rga:started_rga3_core:2"`; the final
field is the minimum number of matching per-core counters whose delta must be
positive.

The official-test conformance suites (`mpp-suite.sh`, `librga-suite.sh`,
`gstreamer-suite.sh`), their comparators, the rewrite build gate, and the
external `../rockchip-conformance` bundle are all documented in
[`rewrite-conformance.md`](./rewrite-conformance.md).

## Regenerating the test inputs

The clips are not committed (nothing binary is — see
[`packaging/README.md`](../../packaging/README.md)). Regenerate them anywhere
with a stock ffmpeg that has libx264/libx265 (must be **software** encoders —
that isolation is the point of the decode test). The FFmpeg conformance suite
also uses `libvpx-vp9` for generated VP9 and `libsvtav1` or `libaom-av1` for
AV1 diagnostics when explicit inputs are not supplied:

```bash
ffmpeg -f lavfi -i testsrc2=size=320x240:rate=30:duration=1 -c:v libx264 -pix_fmt yuv420p "$CLIP_DIR/tiny-320x240.h264"
ffmpeg -f lavfi -i testsrc2=size=320x240:rate=30:duration=1 -c:v libx265 -pix_fmt yuv420p "$CLIP_DIR/tiny-320x240.h265"
ffmpeg -f lavfi -i testsrc2=size=320x240:rate=30:duration=1 -c:v libvpx-vp9 -pix_fmt yuv420p -f ivf "$CLIP_DIR/tiny-320x240-vp9.ivf"
ffmpeg -f lavfi -i testsrc2=size=320x240:rate=30:duration=1 -c:v libsvtav1 -preset 10 -crf 35 -pix_fmt yuv420p -f ivf "$CLIP_DIR/tiny-320x240-av1.ivf"
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

VP9 support is built in the decoder and, as of **2026-07-04, hardware-validated
bit-exact** on the forward-port (av1-fwport board build) via
[`decode-differential.sh`](./decode-differential.sh) — the fastest way to re-run
it. For a fully manual run, `mpi_dec_test` selects its IVF reader by the `.ivf`
filename extension (`utils/mpi_dec_utils.c`), so:

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
The MPP side also covers `MPP_CMD_SET_ERR_REF_HACK` copy/discard behavior for
the current libmpp VDPU382 probe path.
On the RGA side, the rewrite pins also cover the default legacy
`RGA_BLIT_SYNC` `c_RkRgaBlit()` path used by JeffyCN GStreamer: sync submission
waits for queued completion and leaves async release-fence copy-out untouched,
plus the legacy flush/result no-op ioctl return contract used by librga's
post-blit compatibility path.

**Forward-port: VERIFIED 2026-07-04** — `decode-differential.sh` decoded VP9
bit-exact (PSNR=inf) on the av1-fwport board build (recorded in status.md row 1).
The generated GStreamer VP9 cases, the direct MPP VP9 suite case, and any
**rewrite** VP9 hardware log are still unrecorded; if you run them, record the
result in status.md.

## Observed results (reference)

- decode: 30 frames each H.264/H.265, ~1200–1600 fps @ 320×240 (original run;
  a re-run 2026-07-01 on 6.18.37 #7 passed at 1470/3765 fps — the number varies
  with clip content, the PASS gate is exit code + output size).
- **decode correctness (2026-07-04, av1-fwport build `P1c9d` #8, `decode-differential.sh`):**
  H.264 / H.265 / VP9 / **AV1** all decoded 30/30 frames **bit-exact
  (PSNR=inf)** vs a software reference @ 640×480 (mpi_dec_test fps at that size:
  ~551 / 591 / 741 / 629). `av1_rkmpp` through the board's prebuilt `/usr/lib`
  MPP fails (`parser not registered`) — this run used `../rockchip-conformance`'s
  from-source `out/mpp`.
- encode: H.264 720p PSNR 53–55 dB @ ~359 fps; H.265 720p PSNR 60–62 dB @ ~297 fps.
  (2026-07-04 re-check via `mpi_enc_test`, 1280×720: H.264 / H.265 encoded 30
  frames each; software re-decode PSNR-vs-source 42.7 / 45.0 dB.)
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
RKNN/RKNPU-style RGB/NV12/NV21 preprocessing plus RGBA crop/letterbox, async
resize release fences, the official Gaussian matrix `IM_GAUSS` sample shape,
and the thread-default `imconfig(IM_CONFIG_SCHEDULER_CORE, ...)` plus
`IM_CONFIG_PRIORITY` paths seen in the public `imconfig()` API and standalone
`gstreamer-rga` core-mask usage, plus the legacy `c_RkRgaBlit()` conversion
shapes JeffyCN GStreamer uses for encoder preprocessing, decode-side fd-backed
rotate/format conversion, and planar fallback. The default no-submit
physical-address import probe records whether
the booted driver accepts the path; set `LIBRGA_SMOKE_EXPECT_PHYSICAL_REJECT=1`
for rewrite-only negative validation. The AFBC32x8/RFBC64x4 destination-mode
probes likewise record by default and become rewrite-only negative assertions
with `LIBRGA_SMOKE_EXPECT_FBC_TAIL_REJECT=1`. `librga-suite.sh` enables both
negative assertions automatically for `PROFILE=*rewrite*`. With
`LIBRGA_SMOKE_10BIT=1`, it also
covers the direct IM2D P010/P210 request-generation path exported by the local
librga patch series; the full hardware-frame RGA path is still validated
through `transcode-test.sh`.
Through `librga-suite.sh`, the same smoke now records deterministic destination
artifacts so rewrite-vs-forward-port comparison can catch byte-level RGA
regressions on maintained direct userspace paths.
