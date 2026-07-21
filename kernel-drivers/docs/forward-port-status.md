# Status — done, skipped, limitations

> **Scope.** This doc is the scorecard for the **kernel codec forward-port**
> only. The repo now spans much more — ffmpeg (two lineages), the
> gnome-remote-desktop HW-encode backend, DKMS/PPA packaging, Mesa/Panfrost —
> and the whole-project dated dashboard is [`status.md`](../../status.md) at the
> repo root.

Target: Radxa ROCK 5B (RK3588), Armbian, kernel **6.18.38** (`rockchip64-current`).
Historical validated build hash: `Pb6ab-Cb831` on 6.18.37 (and its functionally-identical predecessor
`P8c75`). That hash is baked into the Armbian `.deb` package name — `P####` hashes
the applied kernel patch set, `C####` hashes the kernel config — so the pair names
the *exact* build we validated (the installer matches debs on it; see
`scripts/install-combined-kernel.sh`). The Published 6.18.38 PPA build through
patch `0041` booted but is not validated: its first conformance run Oopsed
during preflight. A later KASAN build verifies the resulting `0042` and `0043`
lifetime fixes with clean memory-safety scans. Exact-6.18.38 production build
`Pf558-Cb831` and its fresh unsigned PPA source extraction now carry both fixes
with the expected non-debug config, but the Published package still predates
them. Corrected isolated and full official-MPP runs are now functionally green
on the KASAN build; full conformance remains open because RGA2 DMA-debug found
an invalid page-table sync and the host lacks the GStreamer development stack.
Patches `0044`/`0045` fix the two persistent RGA ABI replay gaps; the rebuilt
booted KASAN debug kernel `Pb999-C4ad2` passes the full ABI replay
(`abi_status=0`) with a clean memory scan. The same `Pb999` boot re-ran the
12-case MPP matrix (`20260721-042445-kasan-mpp-suite`) and the full FFmpeg
codec suite including the H.264/H.265/VP9 bit-exact PSNR gates
(`20260721-042631-ffmpeg-codec-suite`) — all required cases pass with clean
kernel scans, so the complete current patch tip `0001`–`0045` is
hardware-validated for those gates. The librga im2d smoke's chronic
`no core match` failures were root-caused (RGA3's 68-pixel minimum width ×
RGA2's below-4G limit on a kernel without dma32 heaps) and fixed in the
harness; 13 cases including every dmabuf path now pass. New source patches
`0046`–`0048` fix the legacy-blit virtual-address `EFAULT` (a `0045`
validation regression), report the under-4G exclusion as `EOPNOTSUPP` with a
clear log, and program byte-literal 10-bit raster strides (the measured
incompact-P010 corruption, stock BSP behavior). All three passed their
booted gates on rebuilt debug build `P63dd-C4ad2`: legacy blits succeed
with content match, the exclusion probe returns `EOPNOTSUPP` with the
explanatory log, P010 luma is bit-exact, the librga smoke is fully green
for the first time (28 cases with `LIBRGA_SMOKE_10BIT=1`), and the ABI
replay (`20260721-081456`), 12-case MPP matrix (`20260721-081639`), and
FFmpeg suite (`20260721-081448`, 14/14 required + bit-exact AV1 PSNR) all
pass with clean kernel scans. The `0048` gate exposed one further 10-bit
defect — `rga_convert_addr()` derives UV plane offsets at 1 byte/pixel, so
P010 chroma was read from and written into the Y plane — fixed by
`0049@a398364aaf8ed`. Patches `0050@473903525009a` (RGA2 page-table DMA
ownership, closing the July 20 DMA-debug finding, plus the missing
`dma_set_max_seg_size()` and a page-preserving swiotlb min-align mask) and
`0051@162edad7bb9c7` (over-4G memory served on RGA2 through DMA-API
mappings that swiotlb-bounce below 4G, with `EOPNOTSUPP` fallback) round
out the series. On debug build `P9636-C4ad2` (`#5`, `0049`–`0051`) the
`0049` and `0050` gates pass: P010 copies bit-exact including chroma,
FFmpeg `hevc_main10_p010_rga` bit-exact (PSNR inf, run `20260721-110029`),
and the smoke (28 ok) / MPP (12/12) / ABI (`20260721-110007`) sweep runs
with a completely clean DMA-debug/KASAN journal — the page-table splat and
segment-size warning are gone. The `0051` over-4G probe ran on RGA2 (no
more `EOPNOTSUPP`) but read back a stale destination on two successive
debug builds, exposing two copy-back defects: the post-clean skipped
IOMMU-mapped (default-map-core) origins (fixed on `P9636`, keyed on
bounce direction), and — first-order, exposed by the `P9412` (`#6`)
re-run — the transient dst bounce was mapped with the channel get-side
`DMA_TO_DEVICE`, so swiotlb never copied the device output back at
unmap. Fixed in the amended `0051@162edad7bb9c7` (every transient
bounce mapped `DMA_BIDIRECTIONAL`, matching the persistent mappings);
its content-exact gate awaits the next debug build. A mixed-heap
differential matrix on `P9412` isolates the defect to the dst leg
alone (src-only and userptr bounce legs content-exact) and closes the
mapping-failure fallback gate: 128 MiB over-4G buffers fail cleanly
with `EOPNOTSUPP` and the explanatory log — swiotlb's 256 KiB
per-mapping cap (not pool exhaustion) is the practical bound, so
over-4G buffers with ≥1 MiB exporter chunks always take the fallback.
The same boot also closed the last `0048` caveat: the compact-NV15
raster leg is hardware-validated by `rga-nv15-test` (semantic
NV15→NV12 read, CPU-unpacked P010→NV15 write, bit-exact NV15 copy at
256/320/1920 widths, clean journal). On debug build `P7589-C4ad2`
(`#7`, carrying the amended `0051`) the gate CLOSES: the full
differential matrix is content-exact — including the primary
system→system 64×64 both-legs bounce, the previously-failing dst-only
leg, and userptr bounces — the mapping-failure fallback stays a clean
`EOPNOTSUPP`, and the same-boot smoke (28 ok / 0 FAIL), P010/NV15
probes, KASAN ABI replay (`20260721-145234`, `abi_status=0 clean=1`),
MPP suite (`20260721-145243`, `suite_status=0 clean=1`), and FFmpeg
suite (`20260721-145258`, 24/24, Main10→P010 PSNR inf) are all green
with a zero-flagged-line journal — `0044`–`0051` are BOOT-VERIFIED on
one kernel. (Watchlist note: `P7589`'s *first* boot attempt hung ~2
min in with no oops/panic/pstore capture and needed a hard reset; the
second boot of the identical kernel was clean, and `0051` touches no
boot path — watching for recurrence.)
See the
[conformance root-cause finding](../../findings/2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md)
and the
[DMA scope finding](../../findings/2026-07-21-rga2-dma-api-ownership-and-over-4g-scope.md).

## ✅ Done — validated on real hardware

| Item | Evidence |
|------|----------|
| **H.264/H.265 encode** (VEPU580, both cores) | `mpi_enc_test`: 256² + 1280×720, PSNR 47–62 dB overall, NAL-correct, no IOMMU fault. **At 720p: H.264 PSNR 53–55 dB @ ~359 fps; H.265 PSNR 60–62 dB @ ~297 fps** ([`kernel-drivers/tests/README.md`](../tests/README.md) § Observed results). Both cores `attach ccu as core 0/1` (CCU = the Central Control Unit the paired cores share — see the [device-tree glossary](./device-tree.md)). |
| **H.264/H.265 decode** (VDPU381/rkvdec2, both cores) | `mpi_dec_test`: decoded 30 frames each of software-encoded H.264 + H.265 to NV12, ~1200–1600 fps @ 320×240. Both `rkvdec-core0/1` bound at `fdc38000`/`fdc40000`. **2026-07-04**: the shared rkvdec2 path was re-verified on the av1-fwport superset build with a *correctness* oracle — decode is **bit-exact (PSNR=inf) vs a software reference** for H.264, H.265, and now VP9 ([`tests/decode-differential.sh`](../tests/decode-differential.sh)). |
| **RGA** (RGA3 ×2 + RGA2) | probes at boot, `/dev/rga` present, IOMMU bound; exercised functionally via `scale_rkrga` in the transcode (1080p→720p and 720p→480p). |
| **Combined in-tree kernel** | all three accelerators `=y`, present at boot — **no overlay, no insmod**. |
| **ffmpeg-rockchip** | built (`nyanmisaka` fork) with `h264_rkmpp`/`hevc_rkmpp` decode+encode and `scale_rkrga`. Full HW transcode passes both directions at **17–42× realtime**, no faults ([`kernel-drivers/tests/README.md`](../tests/README.md) § Observed results). |
| **Zero-edit Armbian packaging** | `media-0001` (Armbian's mainline media/codec backport patch series) and the kernel config both stay **pristine**; everything lives in two userpatches (see `armbian-packaging.md`). |
| **Quality-of-life** | udev rule for non-sudo `/dev/mpp_service` + `/dev/dma_heap/*` + `/dev/rga` (the dma-heap rule is **required** — rkmpp allocates buffers there, so `mpp_service` alone leaves the encoder dead; upstreamed as [armbian/build#10085](https://github.com/armbian/build/pull/10085)); ccache-correct build wrapper. |

## ⏭️ Skipped / deferred (intentionally)

| Item | Why |
|------|-----|
| **Encoder/decoder DVFS** (`*_DEVFREQ`, OPP, system-monitor) | DVFS (dynamic voltage/frequency scaling) here rides on vendor BSP-only services — PVTM (the on-chip process-voltage-temperature monitor that drives voltage scaling), `rockchip_system_monitor`, `rockchip_opp_select` — none of which exist upstream. The OPP (operating performance point — one voltage/frequency pair) service is stubbed, so the concrete loss is **no PVTM voltage/leakage scaling**: the cores stay at the fixed DT `assigned-clock-rates` (enc 800 MHz, dec 800 MHz), which is plenty fast and fine at every load we tested. The devfreq (the Linux dynamic-frequency framework) islands are tier-2 Kconfigs — the project's off-by-default "nice-to-have" tier — defaulting `n`. See `vendor-forward-port.md`. |
| ~~**VP9 decode**~~ → ✅ **validated 2026-07-04** | **No longer deferred.** `mpi_dec_test -t 10` on a software-encoded VP9 IVF decoded 30/30 frames **bit-exact (PSNR=inf)** vs a software reference on the av1-fwport board build (shared rkvdec2 path); see [`tests/decode-differential.sh`](../tests/decode-differential.sh). The GStreamer/direct-MPP suite VP9 cases (generated IVF) remain the broader-coverage path; the *rewrite* still needs its own VP9 hardware log. |
| **JPEG encode/decode** | `mjpeg_rkmpp` exists in ffmpeg-rockchip but was not a goal; the vendor JPEG encoder block is not wired in the DT and no JPEG validation was run. |
| **RK3588 AV1 decode** | Not in *this* build (`Pb6ab` has no `mpp_av1dec.c`) — but **the av1-fwport variant now supplies it and is hardware-validated.** The sibling build `P1c9d` (kernel `6.18.37 #8` = this base **plus** the vendor `mpp_av1dec.c` backend + VSI-IOMMU provider) exposes AV1 through `/dev/mpp_service` (`supports-device` → `AV1DEC HW_ID:0x80019000`) and decodes **bit-exact (PSNR=inf) vs a software reference** (`mpi_dec_test -t 16777224`, 2026-07-04). The separate upstream Hantro/V4L2-stateless AV1 path (also `vsi-iommu`-backed) still exists as the mainline alternative. Full write-up + the `av1_rkmpp` distro-lib caveat: [AV1 note](../av1/docs/av1-rk3588.md) § 2026-07-04 update. |
| **Expanded MPP/RGA/GStreamer/FFmpeg conformance** | RGA is validated *through* ffmpeg's `scale_rkrga`, and the in-repo `librga-smoke.sh` covers direct im2d paths including virtual-address imports, dma-buf fd imports, RKNN/RKNPU-style RGB/NV12/NV21 preprocessing, GStreamer-style legacy `c_RkRgaBlit()` conversions, a no-submit physical-address import probe, forced-core/pre-intr submission, and async fences. The support repo now has wrappers and comparators for the official MPP tests, official `airockchip/librga` sample suite, JeffyCN GStreamer Rockchip plugin, and ffmpeg-rockchip CLI coverage under `../rockchip-conformance`, including generated VP9 IVF decode, generated H.265 Main10 decode/RGA/fallback coverage, optional generated H.265 4:2:2 10-bit coverage, encoder force-key-unit events, explicit encoder control-property pipelines, codec-specific H.264/H.265 QP controls, H.264 profile/level plus max-pending and unaligned-vstride controls, MPP-only `GST_MPP_NO_RGA=1` encode/decode, strict decoder-property pipelines plus env-default decoder control, DMA-feature, output-format coverage, and external-media H.265 10-bit fallback coverage for `GST_MPP_DEC_DISABLE_NV12_10`/`GST_MPP_DEC_DISABLE_NV16_10`, required parallel encode/decode/transcode pipelines for multicore scheduling evidence, diagnostic decoder crop-meta, env-default FBC output, RFBC caps negotiation via `GST_MPP_DEC_FBC_IS_RFBC=1`, diagnostic VP8/JPEG/VPx-alpha GStreamer element visibility including VP8 QP and JPEG quality-factor property setters, opt-in Rockchip display/DMABuf sink cases including `KMSSINK_DISABLE_VSYNC=1`, `GST_RKXIMAGE_USE_COLORKEY=1`, and `GST_KMSSRC_DMA_FEATURE=1` KMS capture, plus FFmpeg decoder-option, `scale_rkrga` forced-core/async/AFBC-output, `vpp_rkrga` crop/transpose, diagnostic decoder `afbc=rga`, and `overlay_rkrga` alpha-composition cases. MPP test binaries and the full librga sample build helper have been staged locally; the GStreamer plugin build wrapper is present but the current host still lacks the GStreamer development `.pc` packages. None of these expanded suites has paired forward-port/rewrite hardware logs yet. |
| **OPP/voltage scaling, RGA genpool** (`ROCKCHIP_RGA_GENPOOL`) | gen_pool (the kernel `genalloc` carved-out memory allocator) is an alternate RGA buffer path; not needed for correctness. |
| **Netboot / diskless** | Possible on current mainline U-Boot (RTL8125B + PCIe are upstream now) but needs a U-Boot config rebuild + ~100 Mbps; not worth it vs `scp` deb + reboot. |
| **Second encoder devfreq island, thermal throttling** | Tier-2; encoder is static-clock. |

## ⚠️ Known limitations

- **DISTRIBUTION BLOCKER (fix staged, booted gate pending) — `rga_request`
  completion vs `/dev/rga` close UAF (2026-07-21, found on `162edad7bb9c7`,
  KASAN build `P7589-C4ad2`).** The `cross` session-close reproducer tripped
  a slab-use-after-free: the RGA2 IRQ completion thread reads
  `&request->finished_wq.lock` in `wake_up()`
  (`rga_request_release_signal`) after the close path
  (`rga_request_session_destroy_abort` → `rga_request_kref_release` →
  `kfree`) freed the `rga_request`, with a concurrent `refcount_t: underflow`.
  Root cause (confirmed by tracing the full reference model): the request's
  single initial reference is dropped by **four** unserialised retire paths
  (async completion, cancel, submit-abort, owning-session close), so
  completion and close double-drop it. It is **distinct from the buffer
  force-free `0040` fixed** (which the `leak` mode confirms quiet) and is
  reachable by any process that closes `/dev/rga` while an async RGA job is
  still completing. Fixed by `0052@c46bfd6622ba6` (a `rga_request_release_ref()`
  helper that drops the initial reference exactly once under the
  pending-request-manager lock); compiled clean, **booted gate — a quiet
  `cross` run with `async_submits > 0` under KASAN — pending the next debug
  build.** See the
  [request-completion UAF finding](../../findings/2026-07-21-rga-request-completion-vs-session-close-uaf-kasan.md).
- **The validated forward-port drivers still carry every bug the BSP audit found.** This
  forward-port is deliberately conservative (~98% byte-identical BSP —
  [vendor delta](./vendor-delta.md)), so the [BSP audit](./bsp-audit.md) audit's
  **16 HIGH-severity findings remain present in the code you boot** — including
  memory-safety bugs reachable from an unprivileged ioctl (several "directly
  exploitable by any process that can open the device node", per bsp-audit.md) and
  the `mpp_check_req()` overflow-clamp bug that
  [kernel driver guide §9](./how-the-drivers-work.md) documents. Treat `/dev/mpp_service`
  and `/dev/rga` as **trusted-input-only** (the udev rule grants them to the
  `video` group — that group is a security boundary). Fixes are staged as the
  65-patch review series in [`kernel-drivers/patches/cleanup-split`](../patches/cleanup-split)
  (verification record: [`kernel-drivers/patches/cleanup-draft/verification.md`](../patches/cleanup-draft/verification.md)),
  but the **runtime regression gate is still PENDING** — the fixed series has
  not yet been rebuilt, booted, and re-run through `tests/`.
- **We link `airockchip/librga`'s prebuilt `.so` for convenience — but librga is
  open source** (Apache-2.0): the *official* repo just ships a prebuilt `.so`, so
  it looks closed, but the real source is published (JeffyCN mirror lineage) and
  you *can* build a fully-from-source userspace. The kernel `/dev/rga` driver we
  ported *is* GPL source. Full lineage + repo pointers in
  [gotchas](../../docs/gotchas.md) (§ Userspace).
- **The decoder DT is Armbian-specific in convert-in-place form** — *convert-in-place*
  meaning we override Armbian's existing DT nodes where they sit, rather than adding
  or replacing nodes (see [Armbian packaging guide](../../packaging/docs/armbian-packaging.md)). It retypes
  Armbian's `media-0001` `vdec0/vdec1` nodes to the vendor binding. For vanilla
  mainline (no `media-0001`) use the inline-node form — see `vanilla-kernel.md`.
- **API-pinned to ~6.18, with one structural-layout hazard that outranks the
  rest.** Several forward-port fixes merely track 6.18 kernel APIs (e.g. the IOMMU
  `cookie_type` guard). The genuinely fragile pin — **the #1 thing anyone
  re-syncing to a kernel newer than 6.18 should fear** — is the shadow struct
  `struct mpp_iommu_dma_cookie` (`mpp_iommu.h:26`). It reaches the IOVA allocator
  by casting `iommu_domain->iova_cookie` to that shadow and reading its first
  member (`iovad`), which is correct *only* because the **private** `struct
  iommu_dma_cookie` in `drivers/iommu/dma-iommu.c` happens to keep `iovad` at
  offset 0 on 6.18. The single guard is `BUILD_BUG_ON(offsetof(struct
  mpp_iommu_dma_cookie, iovad) != 0)` (`mpp_iommu.c:719`) — but that checks *our*
  shadow, so it catches `iovad` not being first yet **cannot** catch a future
  kernel reordering or inserting a member *ahead* of `iovad` in the real cookie.
  Such a change would silently mis-read with no build error. Re-validate this exact
  cast on any kernel bump — see [resyncing guide](./resyncing.md).
- **IOMMU helper stubs have been replaced in the 6.18 forward-port worktrees.**
  RKVDEC2/RKVENC2 still use Linux's generic DMA/IOMMU mapping path, but the old
  no-op `rockchip_iommu_*` compat header is gone: the mainline Rockchip IOMMU
  provider now exports the narrow media reset/fault helpers needed by MPP. AV1
  remains separate because its hardware maps through the VSI/AV1D provider; the
  AV1 worktree has a VSI refresh/fault hook and MPP tries Rockchip, then VSI,
  then the generic cookie-less fallback. Runtime validation of the new reset and
  fault paths is still pending.
- **Single static clock.** No thermal/DVFS management: the clock is pinned by the
  DT `assigned-clock-rates` (~800 MHz) and never moves, so sustained max-load
  workloads should be watched (fine in tests so far). Re-enabling DVFS takes *two*
  changes, not one — set `CONFIG_ROCKCHIP_MPP_RKVENC2_DEVFREQ` (default `n`) **and**
  replace the OPP shim: in the validated forward-port, `rockchip_init_opp_table()` returns
  `-EOPNOTSUPP`, so even with the Kconfig on, devfreq init bails and the clock stays
  static.
- **The board's prebuilt `/usr/lib` `librockchip_mpp` cannot drive these
  decoders.** On the running rootfs, `ffmpeg-rockchip`'s `*_rkmpp` decoders fail
  at init with `mpp_dec: mpp_parser_init parser <codec> is not registered` — a
  userspace-library capability mismatch (the distro `.so` doesn't register the
  parser table this kernel expects), **not** a kernel-driver fault. A from-source
  MPP build works: `mpi_dec_test` linked against `../rockchip-conformance`'s
  `out/mpp/lib` decodes every codec bit-exact. Point ffmpeg at that lib
  (`LD_LIBRARY_PATH`) or rebuild MPP before concluding anything about the drivers.
  The `mpp_platform: client N driver is not ready!` lines for clients 1/3/12/13/18/19
  are *also* benign — MPP's RK3588 table lists legacy VDPU/JPEG clients this DT
  deliberately doesn't wire.
- **MPP procfs session dumps before forward-port patch `0041` race session
  teardown.** A high-frequency `sessions-summary` sampler produced a complete
  NULL-dereference trace in `rkvenc_dump_session()` because teardown freed
  `session->priv`/`session->dma` before unlinking the session under
  `session_lock`. Commit `df0d7037213c` unlinks at common deinit entry before
  private teardown and compiles clean. A PPA kernel carrying the fix booted,
  but the following untraced preflight Oops prevented validation of the fix.
  Do not sample `/proc/mpp_service` during open/close stress except for the
  narrowed KASAN+ramoops reproduction. See the
  [finding](../../findings/2026-07-17-mpp-procfs-session-teardown-oops.md).
- **The preflight Oops was a pre-existing vendor `RESET_SESSION` double-free;
  KASAN now verifies `0042`, and a second forward-port UAF is fixed/verified as
  `0043`.** The first
  booted `0040`/`0041` validation on PPA kernel
  `6.18.38+rk3588av1fwport20260717-0ubuntu1~rk1` Oopsed after ABI replay with no
  call trace, which initially read as a `/proc/mpp_service` snapshot race. The
  KASAN+ramoops rebuild (`P712f-C40aa`) reproduced it on the first narrowed pass
  and overturned that: `MPP_CMD_RESET_SESSION` (`mpp_common.c:1414`) calls
  `mpp_dma_session_destroy(session->dma)` without clearing the pointer — unlike
  the two other destroy sites — so the async `rkvdec2_soft_ccu_worker` teardown
  re-destroys the freed `mpp_dma_session` and faults on `dma->list_mutex`
  (slab-use-after-free). The defect is byte-identical in the pristine Rockchip
  BSP (`develop-6.1`), so it is vendor-original, not forward-port-introduced.
  Patch `0042` adds `session->dma = NULL`; rebuilt run
  `20260718-093751-kasan-narrowed` exercises RESET_SESSION with zero flagged
  lines. That boot then exposed a separate forward-port-introduced post-free
  `task->state` read in `rkvenc2_wait_result`. Patch `0043` samples the abort
  flag before the final reference drop, and run
  `20260718-103917-kasan-mpp-suite` produced empty KASAN/fatal scans while its
  ordinary encoder cases passed. The apparent remaining failures were harness
  defects, not GRD contention: the multi-instance test returns average FPS as
  its status, and single-thread `mpi_enc_test` cannot drain low-delay slice
  callbacks. Corrected 120-frame run `20260720-213128-kasan-mpp-suite` passed
  all three cases with an empty kernel scan; full run
  `20260720-213542-mpp-suite` passed the selected 12-case MPP matrix. The
  exact-6.18.38 clean production build `Pf558-Cb831` and unsigned 20260720 PPA
  source export carry both fixes but are not the installed KASAN image; upload,
  exact-package boot/conformance, and rollback remain. See the
  [double-free finding](../../findings/2026-07-18-mpp-reset-session-dma-double-free-kasan.md),
  [RKVENC2 finding](../../findings/2026-07-18-rkvenc2-wait-result-task-uaf-kasan.md),
  and [superseded preflight finding](../../findings/2026-07-17-forward-port-conformance-preflight-oops.md).
- **High-count low-delay H.264 can overflow RKVENC2's 256-entry slice FIFO and
  lose the terminal marker.** Both `kfifo_in()` calls ignore failure, while the
  MPP VEPU580 H.264 HAL ignores poll errors and loops on an uninitialized
  `slice_last`. The conformance suite now uses the multi-thread test and a safe
  `split_arg=120`; the kernel and MPP still need explicit overflow/error
  hardening. See the
  [slice-FIFO finding](../../findings/2026-07-20-rkvenc2-slice-fifo-terminal-drop.md).
- **RGA2 syncs page-table memory through an address that was never DMA-mapped.**
  The direct dma-buf smoke on the DMA-debug KASAN kernel produced a complete
  `debug_dma_sync_single_for_device` warning through
  `rga_dma_sync_flush_range()` and `rga_set_mmu_base()`. RGA2 page-table
  allocation must retain a valid DMA address/lifetime; disabling the warning is
  not a fix. See the
  [RGA2 DMA-sync finding](../../findings/2026-07-20-rga2-unmapped-page-table-dma-sync.md).
- **The two persistent RGA ABI replay gaps are fixed and pass booted replay.**
  Patch `0044@72accfd1d5a14` accepts legacy `RGA2_GET_RESULT` as a no-op.
  Patch `0045@27452e30a2cfd` rejects malformed/unknown staged task descriptors,
  blocks replacement while a request runs, and frees the prior staged list.
  Rebuilt KASAN debug build `Pb999-C4ad2` booted and passed run
  `20260721-034716-kasan-narrowed` with `abi_status=0` and a clean memory scan —
  the first fully green ABI replay on a forward-port kernel. The production
  package still predates these patches. See the
  [RGA ABI finding](../../findings/2026-07-21-rga-forward-port-abi-gaps.md).
- **Direct RGA3 im2d virtual-buffer samples exposed RGA/IOMMU forward-port
  gaps.** The upstream `airockchip/librga` copy/resize/rotate samples import
  malloc-backed buffers and can trigger `RGA3_core0 INTR[0x2]`, the RGA MMU
  interrupt, on the av1-fwport build. The debugfs run in
  `kernel-drivers/tests/rga-mmu-debug.sh` showed the selected core, imported
  IOVAs, programmed `win0`/`wr` bases, and `rk_iommu fdb60f00.iommu` page
  faults. The first root cause is that the forward Rockchip IOMMU provider lost the
  BSP `dma_set_max_seg_size(dev, DMA_BIT_MASK(32))` setup that RGA needs because
  it stores only the first `dma_map_sg()` address while treating the whole
  sg-table as one contiguous IOVA span. Rebuilding with that fix exposed the
  second issue: RGA3 IOVAs could still be allocated at the top of the 32-bit
  aperture and wrap when the driver added plane offsets in 32-bit registers.
  The forward-kernel fixes are `13afe70c8271` (`iommu: rockchip: restore large
  DMA segment support`) and `6b9dba7abcd0` (`video: rockchip: rga: keep IOVAs
  below 32-bit wrap guard`); booted runtime validation is pending after the next
  rebuild/reboot. Separately, this kernel exposes no Rockchip DMA32 heaps; that
  is a BSP ABI/sample-compatibility gap for heap-name-specific userspace, not
  the RGA3 MMU interrupt cause.
  Evidence and rerun instructions:
  [`findings/2026-07-04-rga3-im2d-error-irq.md`](../../findings/2026-07-04-rga3-im2d-error-irq.md).

## What "done" means here

The July 4 forward-port baseline is **functionally complete for its tested,
trusted-input codec scope**: `ffmpeg -hwaccel rkmpp -c:v hevc_rkmpp ...` uses
the hardware on Armbian 6.18. That does not make the maintained source tip or
the BSP-derived ABI generally shippable. The locally built production candidate
absorbs `0042`/`0043` but predates the `0044`/`0045` ABI fixes, which now pass
booted KASAN ABI replay; publication, board boot/conformance, and rollback
still need resolution. The MPP functional failures and RGA ABI gaps are closed
on the KASAN build, but the RGA2 DMA ownership warning, GStreamer dependency
gate, and broader audit series still have compile/runtime work. DVFS and codec
breadth are optional polish; memory safety, regression conformance, and recovery
are release blockers.
