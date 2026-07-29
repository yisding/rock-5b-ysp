# tests/ — on-hardware codec smoke tests

The fast user on-ramp: prove that decode, encode, and full transcode run on real
hardware after installing the kernel and userspace stack. All tests need the
combined kernel booted (see [`../scripts/`](../scripts/README.md)) — i.e. the
four cores under `/proc/mpp_service` plus `/dev/rga` present. On the combined
kernel the two decoder cores appear as `video-codec0/1` (the DT keeps mainline's
node name — see [device-tree guide](../docs/device-tree.md)); the scripts accept
the older `rkvdec-core0/1` naming too.

The heavier rewrite build gate, the tracked conformance seed under
[`conformance/`](conformance/README.md), the external runtime
`../rockchip-conformance` bundle it reconstructs, and the full
MPP/librga/GStreamer/FFmpeg conformance-suite reference live in the sibling
[`rewrite-conformance.md`](./rewrite-conformance.md) so this page stays a clean
newcomer on-ramp.

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Prove on real hardware that decode, encode, and full transcode paths work after installing the kernel and userspace stack. |
| Developer focus | Keep each test's isolation clear: decoder-only software inputs, encoder PSNR/fault checks, and FFmpeg transcode paths with no software fallback. The rewrite build gate and conformance suites live in [`rewrite-conformance.md`](./rewrite-conformance.md). |
| Owns | The smoke tests `test-decode.sh`, `decode-differential.sh`, `encode-test-tiny.sh`, `transcode-test.sh`, `rewrite-smoke.sh`, `mpp-debug-capture.sh`, `abi-probe.sh`/`abi-probe.c`, `abi-replay.sh`, `librga-smoke.sh`/`librga-smoke.cpp`, the single-purpose gate probes `rga-p010-test.cpp`, `rga-nv15-test.cpp`, `rga-core-match-test.cpp`, `legacy-blit-test.c`, `rga-10bit-legacy-stride-test.c`, and `rga-10bit-uv-offset-test.c`, and the targeted RGA MMU diagnostic `rga-mmu-debug.sh`; the root-gate orchestrator `run-root-gates.sh` (runs the root-only forward-port gates — `encode-test-tiny.sh`, `transcode-test.sh`, `rga-mmu-debug.sh`, `iommu-machinery-fuzz.sh`, `mpp-debug-capture.sh`, and the opt-in destructive `mpp-vp9-show-existing-repro.sh` — each with a per-gate journal fatal scan, forcing the hardware `/usr/bin/ffmpeg`); the recovery/RGA/IOMMU stress tools `rewrite-recovery-stress.sh`, `iommu-machinery-fuzz.sh`, `rga-iommu-fuzz.cpp`, and [`IOMMU-FUZZING.md`](./IOMMU-FUZZING.md); the RGA session-close force-free reproducer `rga-session-uaf.sh`/`rga-session-uaf.c` (documented in [`rga-session-uaf.md`](./rga-session-uaf.md)); the KASAN debug-kernel reproducers `kasan-narrowed-repro.sh` and `kasan-mpp-suite.sh`; the GRD system-heap scatterlist-corruption reproducer `grd-sg-oops-repro.sh`; the sourced helpers `suite-common.sh`, `debugfs-counters.sh`, and `kasan-scan.sh`; the conformance runner/wrappers `rewrite-conformance-run.sh`, `rewrite-evidence-audit.sh`, `rewrite-kunit-log-check.sh` plus its ordered `rewrite-kunit-manifest.tsv`, the fixture-debt guard `rewrite-kunit-source-audit.py` plus its checked `rewrite-kunit-source-audit-baseline.tsv`, `mpp-suite.sh`, `mpp-suite-compare.sh`, `librga-suite.sh`, `librga-suite-compare.sh`, `gstreamer-suite.sh`, `gstreamer-suite-compare.sh`, `ffmpeg-suite.sh`, `ffmpeg-suite-compare.sh`, `rkmppenc-suite.sh`, `rkmppenc-suite-compare.sh`, `debugfs-counter-check.sh`, `rewrite-build-gate.sh`, `suite-common-selftest.sh`, `suite-compare-selftest.sh`, the syzkaller checks under `syzkaller/`, and their build helpers `build-mpp-tests.sh`, `build-librga-samples-full.sh`, `build-gstreamer-rockchip.sh`, `gstreamer-event-harness.c` (all documented in [`rewrite-conformance.md`](./rewrite-conformance.md)); input-regeneration recipes; pass criteria; and observed reference results. |
| Depends on | A validated kernel from [`../scripts/`](../scripts/README.md), staged MPP/FFmpeg artifacts from [`video-libraries/ffmpeg/README.md`](../../video-libraries/ffmpeg/README.md), and device access from the codec udev rule. |
| Current state | H.264/H.265 decode, encode, and full HW transcode have been validated on the forward-port; VP9 and AV1 decode are hardware-validated bit-exact on the av1-fwport build as of 2026-07-04 (`decode-differential.sh`; AV1 needs that variant's `mpp_av1dec.c` backend). The rewrite conformance machinery now covers ABI replay, MPP/librga/GStreamer/FFmpeg suites, optional `rkmppenc`, artifact comparators, an exact ordered 84-MPP/148-RGA KUnit manifest with source/config/package identity plus a complete fatal-free outer-KTAP interval and live lockdep, before/after per-suite dmesg gates, safety/idle counter checks, official-MPP H.264/H.265/VP9/AVS2 plus slice-polling cases, fuzz-smoke build checks, syzlang ABI-marker checks, and the paired evidence audit; the detailed matrix lives in [`rewrite-conformance.md`](./rewrite-conformance.md) and the post-reconciliation findings in [`../docs/rewrite-conformance-gap-audit.md`](../docs/rewrite-conformance-gap-audit.md). MPP pre/post capture now reads an explicit endpoint allowlist and fails closed instead of recursively walking generated procfs/debugfs files. Device-free runner/counter/KUnit-parser/dmesg/default RGA userptr-IOMMU validations pass. Booted rewrite hardware evidence remains incomplete, so `rewrite-evidence-audit.sh` is expected to fail until paired forward-port/rewrite logs, artifacts, counters, clean dmesg reports, compound booted-KUnit evidence, and comparator-clean results exist. The MPP rewrite still has no AV1 backend; AV1 remains a separate implementation track rather than part of the current rewrite hardware gate. |

Evidence-audit note: for `CANDIDATE=*rewrite*`, `rewrite-evidence-audit.sh`
now checks the candidate counter contents by default, not just that a counter
delta file exists. That keeps placeholder or stale `debugfs-counters-delta.tsv`
files from passing the branch-level parity audit.

ABI-replay note: `abi-probe.sh` records the BSP-compatible modern RGA request
wrapper behavior for malformed and unsupported handle-backed
`RGA_IOC_REQUEST_CONFIG` descriptors. After the initial request-check stage
succeeds, the observable ioctl errno is `EFAULT`, while legacy/backend
unsupported paths can still use `EOPNOTSUPP`.

Forward-port crash gate (updated 2026-07-21): run `20260717-230531` Oopsed after
ABI replay and before its first media case. KASAN subsequently separated and
closed two lifetime faults: narrowed run `20260718-093751-kasan-narrowed`
verifies RESET_SESSION patch `0042`, and
`20260718-103917-kasan-mpp-suite` verifies the `0042`/`0043` memory paths with
empty kernel-fatal scans. The latter is **not** a full suite pass:
`mpi_dec_multi_h265` returned its average FPS as the process status rather than
a success code, and both slice encodes used the single-threaded test binary,
which cannot drain low-delay callbacks while `encode_put_frame` is blocked.
Isolated testing on 2026-07-20 identified and corrected both harness defects.
Run `20260720-213128-kasan-mpp-suite` then passed all three corrected 120-frame
cases with an empty journal/fatal scan, and the full 12-case official-MPP run
`20260720-213542-mpp-suite` passed. The same KASAN boot passed the FFmpeg codec
matrix and corrected H.264/H.265/VP9 bit-exact PSNR gate, but direct RGA2
dma-buf submission exposed an unmapped-address DMA-API sync warning. ABI replay
also retained two known RGA contract failures on that installed kernel. Patches
`0044`/`0045` fix them: rebuilt KASAN debug build `Pb999-C4ad2` passed run
`20260721-034716-kasan-narrowed` with `abi_status=0` and a clean memory scan,
then re-ran the 12-case MPP matrix (`20260721-042445-kasan-mpp-suite`) and the
full FFmpeg codec/bit-exact PSNR suite (`20260721-042631-ffmpeg-codec-suite`)
green with clean scans. The librga im2d smoke's chronic `no core match`
failures were root-caused (RGA3's 68-pixel minimum × RGA2's below-4G limit on
a dma32-heap-less kernel) and fixed in the harness. On debug build
`P63dd-C4ad2` (kernel fixes `0046`–`0048`) the smoke is fully green for the
first time — 28 cases pass with `LIBRGA_SMOKE_10BIT=1` against the
source-built librga fork, with gauss/pre_intr classified as
platform-unsupported skips and the `imconfig` reset using the all-cores mask
(librga rejects `IM_SCHEDULER_DEFAULT`). The same boot passed ABI replay
(`20260721-081456`), the 12-case MPP matrix (`20260721-081639`), and the
FFmpeg suite (`20260721-081448`, 14/14 required); the AV1
PSNR gate now passes bit-exact via a dav1d software reference. The Main10
P010 case stays diagnostic-red (chroma-only) until the `0049` UV
plane-offset fix boots. See the
[conformance root-cause finding](../../findings/2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md).
The GStreamer runtime matrix remains blocked on missing development packages. See the
[`0042` finding](../../findings/2026-07-18-mpp-reset-session-dma-double-free-kasan.md)
and [`0043` finding](../../findings/2026-07-18-rkvenc2-wait-result-task-uaf-kasan.md),
plus the
[`slice-FIFO`](../../findings/2026-07-20-rkvenc2-slice-fifo-terminal-drop.md)
and
[`RGA2 DMA-sync`](../../findings/2026-07-20-rga2-unmapped-page-table-dma-sync.md)
findings.

The slice-FIFO fix landed 2026-07-25 (kernel `0075` + MPP `0002`/`0003`) but its
[verification gate](../../findings/2026-07-20-rkvenc2-slice-fifo-terminal-drop.md#verification-gate)
is **unmet** — the bounded `split_arg=4` reproducer has never been run against
the fix. Scoring it requires the userspace half as well as the kernel: the
conformance MPP checkout is pinned to a different base than the packaging
baseline, so its copy is carried as a repo-owned bootstrap patch at
[`conformance/patches/rockchip-mpp/`](conformance/patches/rockchip-mpp/) and
applied by `bootstrap-sources.sh`. Run against unpatched userspace, the official
MPP binaries hang rather than terminate, which would misreport the kernel fix as
a failure.

## What each smoke test proves

| Test | Exercises | Pass criterion |
|------|-----------|----------------|
| `test-decode.sh` | **decoder** (`rkvdec2`) | `mpi_dec_test` decodes *software-encoded* H.264 + H.265 320×240 clips to NV12 → exit 0 + non-empty output. Software-encoded input means a failure implicates the **decoder**, not our encoder. |
| `decode-differential.sh` | **decoder correctness** (`rkvdec2` + `av1dec`) | Adds the strong oracle on top of the liveness gate: HW-decode vs SW-decode **PSNR must be `inf` (bit-exact)** for H.264, H.265, **VP9, and AV1**. Covers the codecs `test-decode.sh` doesn't; AV1 needs the av1-fwport variant. Generates its own software-encoded inputs. |
| `encode-test-tiny.sh` | **encoder** (VEPU580) | `mpi_enc_test` H.264 + H.265 at 256² and 1280×720 → valid NAL-start bitstreams, exit 0, no IOMMU fault (dmesg-marker scheme with a real-fault regex that excludes benign warnings). Reports PSNR + fps. |
| `transcode-test.sh` | **full pipeline** (both decoders, both encoders, RGA ×2) | ffmpeg-rockchip: `h264_rkmpp` → `scale_rkrga` 1080p→720p → `hevc_rkmpp`, then the reverse. `rkmpp`/`rkrga` have no SW fallback, so a pass *is* proof the hardware ran. Verifies each output with `ffprobe`. |
| `rewrite-smoke.sh` | **current `/dev/mpp_service` + `/dev/rga` owner**: forward-port or rewrite | Runs the ABI probe plus decode, encode, and transcode gates above in one pass, and snapshots rewrite debugfs counters, including aggregate/per-core timing counters, when present. It defaults `CONFORMANCE_ROOT` to `../rockchip-conformance`, accepts installed MPP `out/mpp/bin` + `lib` or raw `test` + `mpp` layouts, uses `../ffmpeg/ffmpeg-rockchip`, and selects the existing generated 320×240 H.264/H.265 decode clips plus 1080p H.264 transcode asset. Exit `77` means the device nodes are absent on this boot, not that the workload failed. |
| `mpp-debug-capture.sh` | **focused rewrite decode/encode failure capture** | Clears the bounded MPP event journal, optionally enables structured live tracing, runs one arbitrary reproduction, then records before/after `state`, `events`, numeric counters, `/proc/mpp_service`, dmesg, a counter delta, and an event summary. It always captures the after-state and preserves the wrapped workload's exit code. With no command it captures current state only; `MPP_DEBUG_VALIDATE_ONLY=1` runs a device-free workflow selftest. Exit `77` means the rewrite `state`/`events` files are absent on this boot. |
| `abi-probe.sh` | **non-submit ABI** on current `/dev/mpp_service` + `/dev/rga` owner | Records compile-time ABI values and safe query/control/import/release behavior. The request-config probe explicitly initializes both acquire-fence fields to the ABI's `-1` “no fence” sentinel; zero is a real fd and would make the probe test stdin as a sync file. Virtual and dma-buf imports run normally; raw physical import is disabled unless `ABI_PROBE_ENABLE_RGA_PHYSICAL=1` or the rewrite rejection expectation is set. `ABI_PROBE_ABI_ONLY=1` emits constants without device access. See [the crash note](../rga/docs/raw-physical-import-crash.md). |
| `ioctl-fuzz-smoke.sh` | **bounded non-submit ioctl fuzzing** | Deterministically mutates MPP/RGA parser, import/release, and request-lifetime paths without submitting hardware jobs. Raw physical RGA generation is disabled unless `IOCTL_FUZZ_ENABLE_RGA_PHYSICAL=1`; build-only, fail-nth, logging, and dmesg options are listed below. Needs **both** `/dev/mpp_service` and `/dev/rga`: with only one it exits `77` (skip) unless `IOCTL_FUZZ_ALLOW_PARTIAL=1`. |
| [`syzkaller/`](syzkaller/README.md) | **fuzzer setup and syzlang draft** | Directory README: how the Rockchip syzlang description is built, what is deliberately disabled until a sacrificial RK3588 target exists, and how to run the two checks below. |
| `syzkaller/check-rockchip-syzlang.sh` | **device-free fuzzer ABI constant check** | Compares the syzlang draft with `ABI_PROBE_ABI_ONLY=1` output. Submit-capable calls and the separate raw-physical import descriptor are disabled/no-generate until a sacrificial RK3588 target is used. |
| `syzkaller/check-rockchip-syzlang-compile.sh` | **optional syzkaller description compile check** | Copies an upstream syzkaller checkout from `SYZKALLER_DIR` to a temporary directory, installs the Rockchip draft as `sys/linux/dev_rockchip_mpp_rga.txt`, and runs syzkaller's `make descriptions` so syntax/type errors are caught by the real generator without dirtying the source checkout. It exits `77` when `SYZKALLER_DIR` or Go is missing unless `SYZKALLER_REQUIRE_COMPILE=1` is set. The validate-only runner records this as an optional skip on ordinary hosts. |
| `abi-replay.sh` | **normalized ABI replay** for a single booted kernel profile | Records raw + normalized ABI logs under `logs/abi-replay/`, a `.compare.log` used for forward-port-vs-rewrite diffs after removing intentional obsolete-path deltas, and a `.contract.log` of the stable query/version and session-control lines. `--selftest` verifies normalization, physical-import pruning, and preservation of the modern request-wrapper unsupported errno in `.contract.log`. Feeds the ABI diff comparison in [`rewrite-conformance.md`](./rewrite-conformance.md) § Raw ABI replay. Exit `77` means the device nodes are absent. |
| `librga-smoke.sh` | **direct librga/im2d functional test** on current `/dev/rga` owner | Exercises maintained virtual/dma-buf import, copy, resize, crop, flip, CSC, rectangle, batching/sequential, fences, pre-intr, AFBC/tile, Gaussian, RKNN, encoder, GStreamer, and display-shaped paths with deterministic artifacts. Raw physical import is disabled unless `LIBRGA_SMOKE_ENABLE_PHYSICAL_PROBE=1` or the rewrite rejection expectation is set. Optional 10-bit/display-tail/FBC-negative and build-only modes are listed below. |
| `rga-p010-test.cpp` | **10-bit P010 gate probe** (patches `0048`/`0049`) | Direct im2d P010→P010 copy and P010→NV12 convert against the patched librga fork (prebuilt librga rejects P010 in userspace; build with `-I<fork>/include -I<fork>/im2d_api` against the fork's `librga.so`). Pass = copy BIT-EXACT and NV12 chroma uniformly neutral `0x80`; it prints per-plane diagnostics that fingerprinted the `0048` stride shear and `0049` UV-offset defect. |
| `rga-nv15-test.cpp` | **compact-NV15 gate probe** (patch `0048` compact raster leg) | Direct im2d probes on CMA dmabufs (RGA3-eligible sizes, below-4G so the over-4G path never interferes): NV15→NV12 checked semantically against the LSB-first 4-pixels-in-5-bytes packing, P010→NV15 checked by CPU-unpacking the written 10-bit stream, and a bit-exact NV15→NV15 copy. Pass = all three exact (`rga-nv15-test [width]`, width must satisfy librga's 64-aligned NV15 stride rule; validated at 256/320/1920). Build like `rga-p010-test.cpp` against the patched librga fork. |
| `rga-core-match-test.cpp` | **RGA2 over-4G gate probe** (patches `0047`/`0051`) | Allocates a src/dst pair with independently chosen backing (`rga-core-match-test <src_spec> <dst_spec> <dim> [alloc_mb]`; a spec is a dma-heap path or `malloc` for the userptr import path; the old `<heap> <dim>` form still works), imports, and imcopies with `DMA_BUF_IOCTL_SYNC` brackets around CPU fill and readback. At `dim=64` the RGA3 68-px width floor forces RGA2: pre-`0051` the expected result is `EOPNOTSUPP` with the `0047` log; with `0051` the copy must run and verify content-exact through the swiotlb bounce. Mixed heaps (`system`→`default_cma_region` and inverse) isolate the src-only / dst-only bounce legs; `alloc_mb` over-allocates the buffers past the swiotlb per-mapping cap (256 KiB per exporter segment) or the 64 MiB pool to gate the `EOPNOTSUPP` mapping-failure fallback. Captures errno on failure. |
| `legacy-blit-test.c` | **legacy `RGA_BLIT` ABI gate probe** (patches `0044`–`0046`) | Raw legacy `rga_req` ioctl blit using the historical virtual-address convention (`uv_addr` populated, `yrgb_addr` zero); pass = successful blit with content match. Needs the shim headers noted in the source when built standalone. |
| `rga-10bit-legacy-stride-test.c` | **legacy 10-bit byte-stride convention gate probe** (per-core) | Raw legacy `RGA_BLIT_SYNC` compact NV12_10→NV12 blit with the legacy **byte**-stride `vir_w` (448 for 320-wide) on below-4G CMA dma-bufs, forced per core (`1`/`2`=RGA3, `4`=RGA2, `0`=scheduler). On the `0048`-regressed kernel RGA3 treats `vir_w` as pixels, over-reads 25% and IOMMU-faults (`EACCES`) while RGA2 passes; the fixed-kernel gate is exit 0 on all cores with a clean kernel-log window. See the [stride-convention finding](../../findings/2026-07-24-rga3-legacy-blit-10bit-stride-convention-fault.md). Build like `legacy-blit-test.c` (shim headers noted in the source). |
| `rga-10bit-uv-offset-test.c` | **10-bit UV plane-offset gate probe — chroma CORRECTNESS, RASTER + TILE8x8** (patch `0074`, per-core) | The content half of the pair above: that probe asks whether a tightly sized surface survives (a *size* question), this one asks whether the chroma came from the right offset (a *content* question), and they fail independently. The source is deliberately **over-allocated** so neither the byte-literal nor the pixel-scaled offset can fault, then the same blit runs **three times** varying (a) only the bytes the correct offset reads and (b) only the bytes the scaled offset reads; chroma that changes with (a) and not (b) is a pass. That is self-referential, so it needs no model of the 10-bit→NV12 colour conversion and cannot be satisfied by a blit that merely avoids faulting. Each mode is then re-run **tightly sized**, so a scaled offset has nowhere to read and must fail. Covers **RASTER** (compact + incompact) and **TILE8x8** (compact NV15) — 10-bit `vir_w` is a byte stride in every uncompressed mode, and TILE is where the pixel-convention misreading survived longest. **This is the gate class that a size-only test misses:** on the `0072` kernel the GStreamer NV12_10 cases passed purely because their buffers absorbed the over-read while the chroma stayed wrong. It drives the raw `RGA_BLIT_SYNC` ioctl, so it gates the **kernel** contract independently of which librga is installed. Pass = exit 0 on all five checks. See the [UV-offset finding](../../findings/2026-07-24-rga-10bit-uv-plane-offset-still-pixel-scaled.md) and the [TILE byte-stride finding](../../findings/2026-07-24-rga-10bit-tile-byte-stride-and-fbc-exception.md). Build like `legacy-blit-test.c` (shim headers noted in the source). |
| `build-gstreamer-rockchip.sh` | **GStreamer plugin and event harness build helper** | Stages JeffyCN's GStreamer Rockchip plugins and the `gstreamer-event-harness` helper used for flush, force-key-unit, seek, and EOS-loop cases. Set `GST_EVENT_HARNESS_VALIDATE_BUILD=1` for a device-free event-harness compile/link check; it returns `77` when the GStreamer development pkg-config files are absent, and the top-level validate-only runner records that as a visible skip. |
| `rga-mmu-debug.sh` | **targeted RGA3/IOMMU fault capture** for direct upstream librga samples | Enables `/sys/kernel/debug/rkrga` `reg msg int mm time` flags without blindly toggling already-enabled state, runs selected sample binaries (`rga_copy_demo`, `rga_resize_rect_demo`, `rga_transform_rotate_demo` by default), writes kmsg markers, captures per-case stdout/stderr, before/after dmesg, filtered RGA/IOMMU/MMU lines, and debugfs snapshots, then restores debug flags. It was added to root-cause the 2026-07-04 RGA3 `INTR[0x2]` finding and should be rerun after rebuilding the forward kernel with `13afe70c8271` and `6b9dba7abcd0`; set `RGA_FAIL_ON_CASE_FAILURE=1` when using it as a validation gate. |
| `iommu-machinery-fuzz.sh` | **RGA3 userptr-IOMMU and RK3588 IOMMU stress** | Builds `rga-iommu-fuzz.cpp`, runs scattered-userptr RGA copy/resize/rotate/cvtcolor correctness checks across all 64 cache-line offsets, and protects inactive source/destination bytes with guards. It reuses `decode-differential.sh` for bit-exact H.264/H.265/VP9/AV1 decode and can run RGA scatter plus AV1 decode concurrently while bracketing dmesg and debugfs counters for IOMMU faults, RGA userptr-IOMMU leaks, boundary-shadow copy coverage, active-shadow leaks, and setup failures. Run on booted hardware, ideally the debug kernel in [`IOMMU-FUZZING.md`](./IOMMU-FUZZING.md). Set `IOMMU_FUZZ_VALIDATE_BUILD=1` for the device-free C++ compile check that is part of `VALIDATE_ONLY=1 rewrite-conformance-run.sh`; that mode does not touch devices, debugfs, or target librga shared libraries. |
| `rewrite-recovery-stress.sh` | **reset/recovery stress harness** | Runs kill/close, reset-opener, and opt-in platform unbind/rebind loops around an explicit busy workload, then runs a post-case liveness command, scans new dmesg lines for fatal signatures, and snapshots MPP/RGA debugfs counter deltas. Set `RECOVERY_VALIDATE_ONLY=1` for device-free config validation; that mode is part of `VALIDATE_ONLY=1 rewrite-conformance-run.sh` and is not hardware recovery evidence. Runtime exit `77` means both device nodes are absent. |
| `rga-session-uaf.sh` | **RGA `/dev/rga` session-close force-free reproducer** (⚠️ destructive) | Two KASAN scenarios for the [session-close UAF finding](../../findings/2026-07-17-rga-session-close-uaf.md): `leak` deterministically reproduces the reported refcount-1 leak-and-close (expected quiet on any kernel), and `cross` drives the reachable cross-session in-flight-job UAF (expected KASAN use-after-free on the unpatched fwport kernel, quiet on `bc086cbe03d7`). Provokes a real kernel memory-safety bug — run only on a disposable KASAN board with `ramoops`/pstore configured. Details in [`rga-session-uaf.md`](./rga-session-uaf.md). |
| `kasan-narrowed-repro.sh` | **narrowed reset-session double-free reproduction** (KASAN kernel only) | Runs `abi-replay.sh` (MPP/RGA session churn incl. `MPP_CMD_RESET_SESSION`) then a one-shot recursive `/proc/mpp_service` snapshot, and scans the kernel log emitted during it. Isolates the [reset-session double-free](../../findings/2026-07-18-mpp-reset-session-dma-double-free-kasan.md): a first-pass KASAN hit on the unpatched fwport kernel, quiet with patch `0042`. A non-zero ABI-contract result is not itself a memory finding; the gate is `flagged_kernel_lines=0`. |
| `grd-sg-oops-repro.sh` | **GRD/RKMPP system-heap scatterlist corruption**, without RDP | Churns fresh `mpi_enc_test` H.264 encoders at the failing geometry (`2064x1296`, hstride 2112, alternating vstride 1344/1296 to mirror GRD's reconfigure), so each iteration allocates a new 24-entry system-heap output buffer and reaches `mpp_buffer_sync_partial_end()` → `DMA_BUF_IOCTL_SYNC` in ~40 ms instead of a full RDP login. Exit `0` clean, `10` kernel taint moved, `11` kernel debug report seen, `2` `mpi_enc_test` missing. Knobs `ITERS`, `INSTANCES`, `WORKDIR` (logs default to `~/Code/tmp/sg-oops-repro`, never the repo). Measured 1600 clean sessions on `6.18.40-video-port-kasan-rockchip-rk3588`; see the [non-reproduction finding](../../findings/2026-07-27-grd-sg-corruption-kasan-non-reproduction.md) and the [production repro plan](../docs/grd-sg-corruption-repro-plan.md). Coverage boundary: it generates its own frames, so it imports no external dma-buf and never involves the GPU or RGA — it cannot produce GRD's multi-attachment shape. |
| `kasan-mpp-suite.sh` | **full MPP codec matrix under KASAN** (memory-safety gate) | Drives `mpp-suite.sh` with the real decode/mt/multi/encode/slice/rc2 matrix against the tracked assets (AVS2 omitted — no asset), then scans the kernel log around it. This is the continuation past the preflight Oops that crashed forward-port run `20260717-230531`; it exercises the [reset-session `0042`](../../findings/2026-07-18-mpp-reset-session-dma-double-free-kasan.md) and [`rkvenc2_wait_result` `0043`](../../findings/2026-07-18-rkvenc2-wait-result-task-uaf-kasan.md) paths. Pass = every required case passes **and** `kernel-log-flags.txt` is empty. Override `MPP_REQUIRED_CASES` / `MPP_*_INPUT` to change the matrix. |

## Standalone security reproducers

⚠️ These are single-file proof-of-concept programs, not gates. They have no
`.sh` driver and are not run by `rewrite-conformance-run.sh`: compile one by
hand and run it on a **disposable KASAN debug board** with
`kernel.panic_on_oops=0`. Each deliberately provokes a kernel memory-safety
bug, and each is quiet once its named forward-port patch is applied. The
submission tiering for all of them is in
[`2026-07-22-bsp-bug-upstream-submission-priority.md`](../../findings/2026-07-22-bsp-bug-upstream-submission-priority.md).

| Reproducer | Patch | Proves |
|------------|-------|--------|
| [`mpp-double-init-repro.c`](./mpp-double-init-repro.c) | `0069` (was `0070`) | A second `MPP_CMD_INIT_CLIENT_TYPE` on one session double-adds `session->session_link`, persistently corrupting `queue->session_attach` and leaking the first `session->dma`; a *later* unprivileged INIT then reads a freed `struct mpp_session`. Unprivileged, escalates from a `DEBUG_LIST` WARN to a KASAN slab-use-after-free. Fixed case returns `-EBUSY`. |
| [`mpp-reg-offset-oob-repro.c`](./mpp-reg-offset-oob-repro.c) | `0055` | `mpp_extract_reg_offset_info()` bounded the request by a *floored* element count but copied the *raw* `req->size` bytes, so a size that is not a whole number of elements (e.g. 647) writes past the 80-element array into adjacent `struct mpp_task` fields — including `delayed_work`, a classic LPE write primitive. |
| [`rkvdec2-rcb-index-oob-repro.c`](./rkvdec2-rcb-index-oob-repro.c) | `0060` (was `0061`) | `mpp_set_rcbbuf()` used an attacker-controlled `elem[i].index` unbounded against `RKVDEC_REG_NUM`, writing an iova past `task->reg[]`. |
| [`rkvenc2-req-fanout-oob-repro.c`](./rkvenc2-req-fanout-oob-repro.c) | `0062` (was `0063`) | Class-spanning `SET_REG_WRITE`/`SET_REG_READ` messages push `w_req_cnt`/`r_req_cnt` past `MPP_MAX_MSG_NUM`, copying `struct mpp_request` data past the fixed array. |
| [`mpp-foreign-session-fd-repro.c`](./mpp-foreign-session-fd-repro.c) | `0059` (was `0060`) | `MPP_CMD_SET_SESSION_FD` validated an fd by comparing its `private_data` against itself — a tautology every fd passes — then used an attacker-chosen kernel object as a `struct mpp_session`: controlled type confusion, reachable by anyone in the `video` group. |
| [`mpp-clientless-release-fd-uaf.c`](./mpp-clientless-release-fd-uaf.c) | — | A session that never issues `INIT_CLIENT_TYPE` has `session->dma == NULL`, and the `MPP_CMD_RELEASE_FD` arm dereferences it with no NULL guard. See the [clientless-session crash finding](../../findings/2026-07-21-mpp-collect-msgs-clientless-session-null-deref-crash.md). |

[`ioctl-fuzz-smoke.c`](./ioctl-fuzz-smoke.c) is the mutator behind
`ioctl-fuzz-smoke.sh` above; build and run it through that wrapper rather than
directly, so the dmesg scanning and fail-nth options apply.

## Privileges

The smoke tests differ in what device access they need:

| Test | Needs |
|------|-------|
| `abi-probe.sh` | device access only for `/dev/mpp_service` and/or `/dev/rga`; with `/dev/dma_heap/*` access it also records optional dma-buf MPP translate/release and RGA import/release parity |
| `ioctl-fuzz-smoke.sh` | device access only for `/dev/mpp_service` and/or `/dev/rga`; no root requirement unless local policy restricts the nodes. It does not submit MPP register jobs or RGA blits, and does not generate raw physical RGA imports unless explicitly enabled. `IOCTL_FUZZ_FAIL_NTH_MAX` additionally needs `/proc/self/fail-nth`. |
| `test-decode.sh` | device access only: root, **or** membership in `video` with [`../scripts/99-rockchip-codec.rules`](../scripts/99-rockchip-codec.rules) installed (covers `/dev/mpp_service` **and** `/dev/dma_heap/*` — both required) |
| `librga-smoke.sh` | device access only: root, **or** membership in `video` with the codec udev rule installed for `/dev/rga` and `/dev/dma_heap/*`. `LIBRGA_SMOKE_VALIDATE_BUILD=1` is device-free. Raw physical import additionally requires explicit opt-in and must not be enabled on an unpatched forward kernel. |
| `build-gstreamer-rockchip.sh` | no device access for build; needs GStreamer development `.pc` files plus staged MPP/librga pkg-config paths for the full plugin build. `GST_EVENT_HARNESS_VALIDATE_BUILD=1` only needs `gstreamer-1.0` and `glib-2.0` development `.pc` files, and skips with `77` if they are absent. |
| `rga-mmu-debug.sh` | **root** — reads/writes RGA debugfs flags, writes `/dev/kmsg` markers, and reads full `dmesg` on systems with `kernel.dmesg_restrict=1` |
| `iommu-machinery-fuzz.sh` | **root strongly preferred** — `/dev/rga`, `/dev/mpp_service`, staged librga/MPP artifacts, full dmesg, and debugfs counters are needed for the RGA userptr-IOMMU fault and leak signal. `IOMMU_FUZZ_VALIDATE_BUILD=1` is device-free and only compiles the RGA scatter fuzzer object. |
| `rewrite-recovery-stress.sh` | **root strongly preferred** — kill/reset cases need device access, the selected `RECOVERY_WORKLOAD_CMD` artifacts, full dmesg, and debugfs counters. The `unbind` case additionally requires writable platform driver bind/unbind files and explicit `RECOVERY_UNBIND_TARGETS`; `RECOVERY_VALIDATE_ONLY=1` is device-free. |
| `mpp-debug-capture.sh` | **root strongly preferred** — reading `state`/`events`, clearing the event journal, changing `trace_mask`, and reading full dmesg are normally root-only; capture-only use can run unprivileged if debugfs permissions permit it. |
| `rga-session-uaf.sh` | device access to `/dev/rga` and a `/dev/dma_heap/*` node; no root needed for the workload itself, but reading the resulting KASAN trace from `dmesg` typically is. Destructive on a vulnerable kernel — a disposable KASAN board only. |
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
> | `MPP_AVS2_INPUT`, `MPP_AVS2_WIDTH`, `MPP_AVS2_HEIGHT` | `mpp-suite.sh` | AVS2 elementary stream and optional dimensions for the RK3588 VDPU381 AVS2 cases; unlike VP9, the wrapper cannot generate this asset with the ordinary FFmpeg toolchain |
> | `MPP_ENC_SPLIT_MODE`, `MPP_ENC_SPLIT_ARG`, `MPP_ENC_SPLIT_OUT` | `mpp-suite.sh` | low-delay slice-case settings; defaults `2`, `120`, and `1` select CTU splitting plus segmented low-delay output so `MPP_CMD_POLL_HW_IRQ` is exercised without exceeding the kernel's 256-entry per-task slice FIFO |
> | `MPP_ENC_SLICE_INSTANCES` | `mpp-suite.sh` | number of concurrent `mpi_enc_mt_test` channels for low-delay slice cases; defaults to `1` because the separate output thread, not multi-channel load, is what the polling test requires |
> | `FFMPEG_SOAK_SECONDS`, `FFMPEG_STRESS_LOOPS` | `ffmpeg-suite.sh` | tune the opt-in FFmpeg stress/soak cases enabled by `FFMPEG_RUN_STRESS=1`. |
> | `IN` | transcode | 1080p H.264 Annex-B input (default `$STAGE/testdata/input-1080p.h264`; regeneration below) |
> | `RUN_LIBRGA` | rewrite smoke | optional direct librga/im2d functional smoke (`0` by default; set `1` to run) |
> | `ABI_PROBE_ABI_ONLY` | `abi-probe.sh` | emit compile-time ioctl/structure constants without opening procfs or either device; used by the device-free syzlang marker check |
> | `ABI_PROBE_ENABLE_MPP_FOREIGN_FD` | `abi-probe.sh` / `abi-replay.sh` | pass a valid non-MPP `/dev/null` fd to `MPP_CMD_SET_SESSION_FD` and require the batch result to be `-EBADF`; opt-in because the pre-`0060` BSP path type-confuses the foreign file and can crash the kernel |
> | `ABI_PROBE_ENABLE_RGA_PHYSICAL` | `abi-probe.sh` / `abi-replay.sh` | opt into the raw physical-address import probe, which is disabled by default after the 2026-07-16 forward-port crash; do not enable it on an unpatched forward kernel |
> | `ABI_PROBE_EXPECT_RGA_PHYSICAL_REJECT` | `abi-probe.sh` / `abi-replay.sh` | enable the physical probe and require `EOPNOTSUPP`; `abi-replay.sh` sets this and `ABI_PROBE_ENABLE_RGA_PHYSICAL=1` for `PROFILE=*rewrite*` |
> | `LIBRGA_SMOKE_10BIT` | `librga-smoke.sh` | optional direct P010/P210 IM2D dma-buf conversion cases (`0` by default; set `1` when validating a patched librga/kernel pair) |
> | `LIBRGA_SMOKE_DISPLAY_TAIL` | `librga-smoke.sh` | optional public display/UI tail artifacts for BGRA/XRGB/RGB565 legacy display rotation plus BGRA partial-rectangle alpha blend (`0` by default; set `1` when validating appliance/display-style userspace) |
> | `LIBRGA_SMOKE_ENABLE_PHYSICAL_PROBE` | `librga-smoke.sh` / `librga-suite.sh` | opt into librga's raw physical-address import probe; disabled by default and enabled automatically only for `PROFILE=*rewrite*` |
> | `LIBRGA_SMOKE_EXPECT_PHYSICAL_REJECT` | `librga-smoke.sh` / `librga-suite.sh` | enable the physical probe and require rejection; `librga-suite.sh` defaults it to `1` for `PROFILE=*rewrite*` |
> | `LIBRGA_SMOKE_EXPECT_FBC_TAIL_REJECT` | `librga-smoke.sh` / `librga-suite.sh` | optional rewrite-only negative check for AFBC32x8/RFBC64x4 destination modes through public `librga` calls (`librga-suite.sh` defaults it to `1` for `PROFILE=*rewrite*`; direct smoke runs record, rather than fail, forward-port behavior) |
> | `LIBRGA_SMOKE_ARTIFACT_DIR` | `librga-smoke.sh` | optional directory for raw destination-buffer dumps; `librga-suite.sh` sets this for its required `ysp_librga_smoke` artifact case |
> | `LIBRGA_FORCE_RGA_USERPTR_IOMMU` | `librga-suite.sh` / `rewrite-conformance-run.sh` | set the RGA userptr-IOMMU `userptr_iommu/force_remap` compatibility knob (or legacy `route_b/force_remap`) during the librga suite and restore it at exit; forced counter defaults use `*:attempt`/`*:ok` so either debugfs component name is valid. `LIBRGA_FORCE_ROUTE_B` remains a legacy alias |
> | `IOCTL_FUZZ_ENABLE_RGA_PHYSICAL` | `ioctl-fuzz-smoke.sh` | opt into generation of raw physical RGA imports; disabled by default, with physical entries converted to guaranteed-unknown types |
> | `IOCTL_FUZZ_ALLOW_PARTIAL` | `ioctl-fuzz-smoke.sh` | accept fuzzing only half the surface when just one of `/dev/mpp_service` and `/dev/rga` is present. Without it the run **skips** (exit `77`) rather than reporting a pass over half the ioctl surface, which is what it used to do |
> | `IOCTL_FUZZ_FAIL_NTH_MAX` | `ioctl-fuzz-smoke.sh` | run the non-submit ioctl mutator repeatedly with `IOCTL_FUZZ_FAIL_NTH=1..N`, using `/proc/self/fail-nth` to force the Nth allocation/usercopy fault inside each ioctl; default `0` disables this debug-kernel-only mode |
> | `IOCTL_FUZZ_FAIL_NTH_REQUIRE_HIT` | `ioctl-fuzz-smoke.sh` | require each fail-nth sweep run to consume at least one injected fault; the wrapper defaults this to `1` when `IOCTL_FUZZ_FAIL_NTH_MAX` is set |
> | `IOCTL_FUZZ_OUT` | `ioctl-fuzz-smoke.sh` | optional directory for persisted fuzzer stdout/stderr and, when dmesg scanning is enabled, before/after dmesg snapshots |
> | `IOCTL_FUZZ_DMESG_SCAN`, `IOCTL_FUZZ_REQUIRE_DMESG` | `ioctl-fuzz-smoke.sh` | scan new dmesg lines for fatal signatures after each logged run; `REQUIRE_DMESG=1` also fails if dmesg is unreadable |
> | `IOMMU_FUZZ_REQUIRE_RGA_USERPTR_IOMMU_COUNTERS` | `iommu-machinery-fuzz.sh` | strict attribution mode; when set to `1`, RGA phases fail unless RGA userptr-IOMMU debugfs counters are captured, `attempt`/`ok` increase, and `active` is zero after the run. When rewrite boundary-shadow counters exist, they are always checked for positive copy traffic, zero active views, and zero setup failures. `IOMMU_FUZZ_REQUIRE_ROUTE_B_COUNTERS` remains a legacy alias |
> | `RECOVERY_CASES` | `rewrite-recovery-stress.sh` | recovery cases to run: `kill`, `reset`, `unbind`, or `list-bindings`; default `kill` |
> | `RECOVERY_WORKLOAD_CMD` | `rewrite-recovery-stress.sh` | busy workload command run in its own process group while the harness kills, resets, or unbinds around it; default is a narrowed `rewrite-conformance-run.sh` profile run |
> | `RECOVERY_UNBIND_TARGETS` | `rewrite-recovery-stress.sh` | space-separated `driver:device` platform binding specs for the opt-in unbind/rebind case; use `RECOVERY_CASES=list-bindings` to print candidates |
> | `RUN_GSTREAMER` | rewrite smoke | optional JeffyCN GStreamer plugin suite (`0` by default; set `1` to run) |
> | `GST_ENABLE_RGACONVERT_CASES`, `GST_REQUIRE_RGACONVERT_CASES`, `GST_RGACONVERT_ELEMENT` | `gstreamer-suite.sh` | opt into or require standalone `gstreamer-rga` converter diagnostics; default element name is `rgavideoconvert` |
> | `RUN_RKMPPENC_SUITE` | `rewrite-conformance-run.sh` | optional app-level `rkmppenc` suite (`0` by default; set `1` to run generated Y4M/raw RGA-resize encode probes plus a diagnostic `--avhw` transcode through `rkmppenc`) |
> | `RKMPPENC_VALIDATE_CASES` | `rkmppenc-suite.sh` | device-free optional `rkmppenc` case-list validation |
> | `REQUIRE_DIAGNOSTIC_PASS` | `rewrite-evidence-audit.sh` | set `1` when selected diagnostic cases in paired forward-port/rewrite summaries are intended to be hard pass/fail evidence |
> | `AUDIT_REQUIRED_CASES` | `rewrite-evidence-audit.sh` | whitespace-separated `suite:case` list that must be present and passing in both audited profiles, useful for opt-in `gstreamer-rga`, `videoflip`, and `rkmppenc` tails |
> | `REQUIRE_MPP_CORE_CASES`, `MPP_CORE_CASE_NAMES` | `rewrite-evidence-audit.sh` | default rewrite-candidate audit of representative official-MPP H.264/H.265/VP9/AVS2, multi-thread, multi-instance, encode, low-delay slice-poll, and RC cases, with a nonempty checksum artifact for every media case (`MPP_DUMP_OUTPUTS=1` for decode); set the former to `0` only for an explicitly narrow/legacy audit |
> | `REQUIRE_DMESG_EVIDENCE`, `REQUIRE_KUNIT_EVIDENCE` | `rewrite-evidence-audit.sh` | require clean per-suite `dmesg-scan.tsv` records on both profiles and an exact ordered 84-MPP/148-RGA booted-KUnit manifest whose run ID matches each rewrite-candidate suite; both default on for the final audit |
> | `KUNIT_EXPECTED_SOURCE_COMMIT`, `KUNIT_EXPECTED_CONFIG_SHA256`, `KUNIT_EXPECTED_PACKAGE_ID` | KUnit checker/evidence audit | bind the persisted report to the reviewed source prefix, booted config hash, and exact installed image package identity |
> | `PERF_MAX_RATIO` | suite comparators / `rewrite-evidence-audit.sh` | candidate/baseline elapsed-time ceiling for required pass/pass cases; the evidence audit defaults to `1.25`, and `0` disables the timing gate |
> | `AUDIT_COUNTER_CHECKS` | `rewrite-evidence-audit.sh` | candidate counter-content audit; defaults to `1` when `CANDIDATE` contains `rewrite`, requires the same positive hardware-start/busy-time counters as the profile runner, positive direct-librga fence-path coverage, zero MPP import/queue and RGA import/boundary-shadow/userptr-IOMMU active gauges, and present safety counters with no positive delta |
> | `RUN_COUNTER_CHECKS` | `rewrite-conformance-run.sh` | optional suite debugfs counter gate (`0` by default); with `PROFILE=*rewrite*`, the runner requires counter files, positive expected hardware/fence-path counters, zero idle gauges, and present timeout, fault, recovery-failure, spurious-IRQ, RGA2-config, and boundary-shadow setup-failure counters with no positive delta |
> | `RUN_KUNIT_CHECK` | `rewrite-conformance-run.sh` | defaults to `1` for rewrite profiles; requires the ordered 84 MPP + 148 RGA manifest with no fail/skip, a clean outer-KTAP interval, live lockdep, and source/config/package identity, then persists `$LOG_ROOT/$RUN_ID-kunit.tsv` |
> | `SUITE_DMESG_SCAN`, `SUITE_REQUIRE_DMESG`, `SUITE_DMESG_FATAL_RE` | all conformance suite wrappers | before/after kernel-log scan controls; scanning defaults on, the profile runner requires readable dmesg for rewrite runs, and the fatal regex is overrideable for controlled diagnostics |
> | `MPP_DEBUG_OUT`, `MPP_DEBUG_TRACE_MASK`, `MPP_DEBUG_CLEAR_EVENTS` | `mpp-debug-capture.sh` | output directory, optional temporary live event trace mask (`1` lifecycle, `2` IRQ, `4` errors), and whether to clear old journal entries before the wrapped reproduction |
> | `*_REQUIRED_POSITIVE_COUNTER_PREFIXES` | `rewrite-conformance-run.sh` / `debugfs-counter-check.sh` | optional multicore spread gate using `component:counter_prefix:min_positive`, e.g. `MPP_REQUIRED_POSITIVE_COUNTER_PREFIXES="mpp:started_rkvdec_core:2"` or `LIBRGA_REQUIRED_POSITIVE_COUNTER_PREFIXES="rga:started_rga3_core:2"` |
> | `REWRITE_COUNTER_DEFAULTS` | `rewrite-conformance-run.sh` | set `0` to disable the automatic rewrite counter requirements when doing a narrow diagnostic run |
> | `RUN_CONTINUE_ON_FAIL` | `rewrite-conformance-run.sh` | set `1` to record a failed suite and continue with the remaining suites instead of aborting at the first failure; the runner still exits non-zero at the end listing the failed suites |
> | `REQUIRED_ZERO_AFTER_COUNTERS` | `debugfs-counter-check.sh` | optional counter specs whose after-run value must be exactly zero; rewrite defaults cover MPP imports/queued jobs, RGA imports/boundary-shadow views, and direct-librga userptr-IOMMU activity across either `userptr_iommu` or legacy `route_b` naming |

## Run

```bash
bash rewrite-smoke.sh                 # one-command gate; use sudo when devices are present
MPP_DEBUG_VALIDATE_ONLY=1 bash mpp-debug-capture.sh  # device-free capture-workflow selftest
sudo bash mpp-debug-capture.sh -o /tmp/mpp-decode -- mpi_dec_test -i input.h264 -t 7  # focused job/event/dmesg bundle
bash abi-probe.sh                     # fast non-submit ABI probe
ABI_PROBE_ABI_ONLY=1 bash abi-probe.sh  # compile-time ABI output without device access
ABI_PROBE_ENABLE_RGA_PHYSICAL=1 bash abi-probe.sh  # patched-forward raw physical-import observation
ABI_PROBE_EXPECT_RGA_PHYSICAL_REJECT=1 bash abi-probe.sh  # rewrite-only raw physical-import negative check (also enables it)
bash abi-replay.sh                    # record normalized ABI log for this boot
bash abi-replay.sh --selftest         # device-free ABI replay normalization/filter check
IOCTL_FUZZ_VALIDATE_BUILD=1 bash ioctl-fuzz-smoke.sh  # device-free non-submit ioctl mutator compile check
IOCTL_FUZZ_ENABLE_RGA_PHYSICAL=1 bash ioctl-fuzz-smoke.sh  # raw physical generation; hardened/sacrificial kernel only
sudo IOCTL_FUZZ_OUT=../rockchip-conformance/logs/rewrite/ioctl-failnth IOCTL_FUZZ_DMESG_SCAN=1 IOCTL_FUZZ_FAIL_NTH_MAX=4 IOCTL_FUZZ_ITERS=32 bash ioctl-fuzz-smoke.sh  # debug-kernel allocation/usercopy fault-injection sweep with logs
bash librga-smoke.sh                  # direct librga/im2d smoke
LIBRGA_SMOKE_VALIDATE_BUILD=1 bash librga-smoke.sh  # device-free direct librga smoke compile check
LIBRGA_SMOKE_10BIT=1 bash librga-smoke.sh  # add P010/P210 IM2D cases
LIBRGA_SMOKE_DISPLAY_TAIL=1 bash librga-smoke.sh  # add BGRA/XRGB/RGB565 display-tail rotation plus BGRA partial alpha blend
LIBRGA_SMOKE_ENABLE_PHYSICAL_PROBE=1 bash librga-smoke.sh  # patched-forward physical-import observation
LIBRGA_SMOKE_EXPECT_PHYSICAL_REJECT=1 bash librga-smoke.sh  # rewrite-only physical-import negative check (also enables it)
LIBRGA_SMOKE_EXPECT_FBC_TAIL_REJECT=1 bash librga-smoke.sh  # rewrite-only AFBC32x8/RFBC64x4 negative check
GST_EVENT_HARNESS_VALIDATE_BUILD=1 bash build-gstreamer-rockchip.sh  # device-free GStreamer event harness build check; may skip if dev .pc files are absent
sudo env RGA_FAIL_ON_CASE_FAILURE=1 bash rga-mmu-debug.sh  # RGA3/IOMMU validation gate
IOMMU_FUZZ_VALIDATE_BUILD=1 bash iommu-machinery-fuzz.sh  # device-free RGA scatter-fuzzer compile check
sudo bash iommu-machinery-fuzz.sh  # booted RGA userptr-IOMMU/RK3588 stress gate
sudo env IOMMU_FUZZ_REQUIRE_RGA_USERPTR_IOMMU_COUNTERS=1 bash iommu-machinery-fuzz.sh  # require direct RGA userptr-IOMMU counter attribution
RECOVERY_VALIDATE_ONLY=1 bash rewrite-recovery-stress.sh  # device-free recovery harness config check
sudo RECOVERY_WORKLOAD_CMD='PROFILE=rewrite RUN_COUNTER_CHECKS=1 bash "$TEST_DIR/rewrite-conformance-run.sh"' RECOVERY_CASES="kill reset" bash rewrite-recovery-stress.sh  # kill/reset recovery stress around a busy profile run
sudo RECOVERY_CASES=list-bindings bash rewrite-recovery-stress.sh  # print rewrite platform bindings for opt-in unbind testing
MPP_VALIDATE_CASES=1 bash mpp-suite.sh  # device-free MPP official-test case-builder validation
TMPDIR=$PWD bash suite-common-selftest.sh  # device-free before/after dmesg gate selftest
TMPDIR=$PWD bash rewrite-kunit-log-check.sh --selftest  # device-free booted-KUnit parser selftest
GST_VALIDATE_CASES=1 GST_ENABLE_VIDEOFLIP_RGA_CASES=1 bash gstreamer-suite.sh  # validate opt-in videoflip/RGA external-consumer cases
GST_VALIDATE_CASES=1 GST_ENABLE_RGACONVERT_CASES=1 bash gstreamer-suite.sh  # validate opt-in standalone gstreamer-rga converter cases
RKMPPENC_VALIDATE_CASES=1 bash rkmppenc-suite.sh  # device-free optional rkmppenc case-list validation
VALIDATE_ONLY=1 bash rewrite-conformance-run.sh  # device-free runner/syzlang/syzkaller/ioctl-fuzz/librga-smoke/gstreamer-harness/iommu-fuzz/recovery/case/comparator/abi-replay wiring check
VALIDATE_ONLY=1 PROFILE=rewrite RUN_COUNTER_CHECKS=1 bash rewrite-conformance-run.sh  # also checks rewrite counter-default wiring
VALIDATE_ONLY=1 PROFILE=rewrite RUN_COUNTER_CHECKS=1 LIBRGA_FORCE_RGA_USERPTR_IOMMU=1 bash rewrite-conformance-run.sh  # also checks RGA userptr-IOMMU counter-default wiring
sudo PROFILE=rewrite bash rewrite-conformance-run.sh  # full profile run on a rewrite boot
sudo PROFILE=rewrite RUN_COUNTER_CHECKS=1 bash rewrite-conformance-run.sh  # require rewrite hardware counter deltas
sudo PROFILE=rewrite RUN_RKMPPENC_SUITE=1 RUN_COUNTER_CHECKS=1 bash rewrite-conformance-run.sh  # add optional rkmppenc app-level MPP/RGA evidence
sudo PROFILE=rewrite RUN_COUNTER_CHECKS=1 LIBRGA_FORCE_RGA_USERPTR_IOMMU=1 RUN_SYSTEM_INFO=0 RUN_ABI_REPLAY=0 RUN_MPP_SUITE=0 RUN_GSTREAMER_SUITE=0 RUN_FFMPEG_SUITE=0 RUN_LIBRGA_SUITE=1 bash rewrite-conformance-run.sh  # focused RGA userptr-IOMMU attribution gate
bash test-decode.sh                  # decoder liveness (device access is enough)
bash decode-differential.sh          # decoder correctness: bit-exact HW-vs-SW PSNR, incl. VP9 + AV1
sudo bash encode-test-tiny.sh        # encoder
sudo bash transcode-test.sh          # end-to-end (needs ffmpeg-rockchip built — see ../ffmpeg)
FFMPEG_VALIDATE_CASES=1 bash ffmpeg-suite.sh  # device-free FFmpeg case-list validation
FFMPEG_VALIDATE_CASES=1 FFMPEG_REQUIRE_AV1=1 FFMPEG_RUN_STRESS=1 FFMPEG_STRESS_LOOPS=1 bash ffmpeg-suite.sh  # validate promoted/optional FFmpeg wiring
bash ffmpeg-suite.sh                 # profile/log/comparator FFmpeg conformance
sudo FFMPEG_REQUIRE_AV1=1 FFMPEG_RUNTIME_MODES="system staged" bash ffmpeg-suite.sh  # AV1-capable board/runtime gate
bash rkmppenc-suite-compare.sh       # compare latest opt-in forward-port/rewrite rkmppenc summaries
```

For a diagnostic smoke pass in one command (the defaults match the sibling
`rockchip-conformance` and `ffmpeg/ffmpeg-rockchip` trees):

```bash
sudo bash rewrite-smoke.sh
```

The same command is valid on the BSP-derived forward-port kernel, which makes it
the quick parity check between the two implementations. Override
`CONFORMANCE_ROOT`, `MPP_BUILD`, `FFDIR`, `STAGE`, `H264_IN`, `H265_IN`, or
`IN` only for a non-default checkout or staged runtime.

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
The paired evidence audit enables equivalent candidate counter-content checks
by default for `CANDIDATE=*rewrite*`, so a stale or placeholder counter file no
longer passes the branch-level parity audit.

The official-test conformance suites (`mpp-suite.sh`, `librga-suite.sh`,
`gstreamer-suite.sh`), their comparators, the rewrite build gate, the tracked
[`conformance/`](conformance/README.md) seed, and the external
`../rockchip-conformance` runtime bundle are all documented in
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
bit-exact** on the forward-port (board build `P1c9d`) via
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
register translation/validation path and the HARD-CCU requirement that all
online decoder peers share one DMA/IOMMU domain, so the remaining gap is booted
hardware evidence rather than parser/table coverage. Rock 5B now creates that
domain through `vdec1_mmu`'s `rockchip,shared-domain-owner = <&vdec0_mmu>`;
`collect-system-info.sh` records the live decoder-master IOMMU groups so a
rewrite run can prove both masters landed in the same group.
The MPP side also covers `MPP_CMD_SET_ERR_REF_HACK` copy/discard behavior for
the current libmpp VDPU382 probe path.
On the RGA side, the rewrite pins also cover the default legacy
`RGA_BLIT_SYNC` `c_RkRgaBlit()` path used by JeffyCN GStreamer: sync submission
waits for queued completion and leaves async release-fence copy-out untouched,
plus the legacy flush/result no-op ioctl return contract used by librga's
post-blit compatibility path.

**Forward-port: VERIFIED 2026-07-04** — `decode-differential.sh` decoded VP9
bit-exact (PSNR=inf) on board build `P1c9d` (recorded in status.md row 1).
The generated GStreamer VP9 cases, the direct MPP VP9 suite case, and any
**rewrite** VP9 hardware log are still unrecorded; if you run them, record the
result in status.md.

## Observed results (reference)

- decode: 30 frames each H.264/H.265, ~1200–1600 fps @ 320×240 (original run;
  a re-run 2026-07-01 on 6.18.37 #7 passed at 1470/3765 fps — the number varies
  with clip content, the PASS gate is exit code + output size).
- **decode correctness (2026-07-04, board build `P1c9d` #8, `decode-differential.sh`):**
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
resize release fences, NV12 raster-to-AFBC16x16-to-raster,
NV12 raster-to-tile8x8-to-raster, the official Gaussian
matrix `IM_GAUSS` sample shape,
and the thread-default `imconfig(IM_CONFIG_SCHEDULER_CORE, ...)` plus
`IM_CONFIG_PRIORITY` paths seen in the public `imconfig()` API and standalone
`gstreamer-rga` core-mask usage, plus the legacy `c_RkRgaBlit()` conversion
shapes JeffyCN GStreamer uses for encoder preprocessing, decode-side fd-backed
rotate/format conversion, and planar fallback. The no-submit physical-address
probe is disabled by default; set `LIBRGA_SMOKE_ENABLE_PHYSICAL_PROBE=1` only
after booting a hardened forward kernel, or set
`LIBRGA_SMOKE_EXPECT_PHYSICAL_REJECT=1` for rewrite-only negative validation.
The AFBC32x8/RFBC64x4 destination-mode
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
