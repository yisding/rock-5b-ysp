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
patch `0040` booted but is not validated: its first conformance run Oopsed
during preflight. A later KASAN build verifies the resulting `0041` and `0042`
lifetime fixes with clean memory-safety scans. Exact-6.18.38 production build
`Pf558-Cb831` and its fresh unsigned PPA source extraction now carry both fixes
with the expected non-debug config, but the Published package still predates
them. Corrected isolated and full official-MPP runs are now functionally green
on the KASAN build; full conformance remains open because RGA2 DMA-debug found
an invalid page-table sync and the host lacks the GStreamer development stack.
Patches `0043`/`0044` fix the two persistent RGA ABI replay gaps; the rebuilt
booted KASAN debug kernel `Pb999-C4ad2` passes the full ABI replay
(`abi_status=0`) with a clean memory scan. The same `Pb999` boot re-ran the
12-case MPP matrix (`20260721-042445-kasan-mpp-suite`) and the full FFmpeg
codec suite including the H.264/H.265/VP9 bit-exact PSNR gates
(`20260721-042631-ffmpeg-codec-suite`) — all required cases pass with clean
kernel scans, so the complete current patch tip `0001`–`0044` is
hardware-validated for those gates. The librga im2d smoke's chronic
`no core match` failures were root-caused (RGA3's 68-pixel minimum width ×
RGA2's below-4G limit on a kernel without dma32 heaps) and fixed in the
harness; 13 cases including every dmabuf path now pass. New source patches
`0045`–`0047` fix the legacy-blit virtual-address `EFAULT` (a `0044`
validation regression), report the under-4G exclusion as `EOPNOTSUPP` with a
clear log, and program byte-literal 10-bit raster strides (the measured
incompact-P010 corruption, stock BSP behavior). All three passed their
booted gates on rebuilt debug build `P63dd-C4ad2`: legacy blits succeed
with content match, the exclusion probe returns `EOPNOTSUPP` with the
explanatory log, P010 luma is bit-exact, the librga smoke is fully green
for the first time (28 cases with `LIBRGA_SMOKE_10BIT=1`), and the ABI
replay (`20260721-081456`), 12-case MPP matrix (`20260721-081639`), and
FFmpeg suite (`20260721-081448`, 14/14 required + bit-exact AV1 PSNR) all
pass with clean kernel scans. The `0047` gate exposed one further 10-bit
defect — `rga_convert_addr()` derives UV plane offsets at 1 byte/pixel, so
P010 chroma was read from and written into the Y plane — fixed by
`0048@6c7eb3efa3f0`. Patches `0049@c4bf430d907f` (RGA2 page-table DMA
ownership, closing the July 20 DMA-debug finding, plus the missing
`dma_set_max_seg_size()` and a page-preserving swiotlb min-align mask) and
`0050@afcd69845942` (over-4G memory served on RGA2 through DMA-API
mappings that swiotlb-bounce below 4G, with `EOPNOTSUPP` fallback) round
out the series. On debug build `P9636-C4ad2` (`#5`, `0048`–`0050`) the
`0048` and `0049` gates pass: P010 copies bit-exact including chroma,
FFmpeg `hevc_main10_p010_rga` bit-exact (PSNR inf, run `20260721-110029`),
and the smoke (28 ok) / MPP (12/12) / ABI (`20260721-110007`) sweep runs
with a completely clean DMA-debug/KASAN journal — the page-table splat and
segment-size warning are gone. The `0050` over-4G probe ran on RGA2 (no
more `EOPNOTSUPP`) but read back a stale destination on two successive
debug builds, exposing two copy-back defects: the post-clean skipped
IOMMU-mapped (default-map-core) origins (fixed on `P9636`, keyed on
bounce direction), and — first-order, exposed by the `P9412` (`#6`)
re-run — the transient dst bounce was mapped with the channel get-side
`DMA_TO_DEVICE`, so swiotlb never copied the device output back at
unmap. Fixed in the amended `0050@afcd69845942` (every transient
bounce mapped `DMA_BIDIRECTIONAL`, matching the persistent mappings);
its content-exact gate awaits the next debug build. A mixed-heap
differential matrix on `P9412` isolates the defect to the dst leg
alone (src-only and userptr bounce legs content-exact) and closes the
mapping-failure fallback gate: 128 MiB over-4G buffers fail cleanly
with `EOPNOTSUPP` and the explanatory log — swiotlb's 256 KiB
per-mapping cap (not pool exhaustion) is the practical bound, so
over-4G buffers with ≥1 MiB exporter chunks always take the fallback.
The same boot also closed the last `0047` caveat: the compact-NV15
raster leg is hardware-validated by `rga-nv15-test` (semantic
NV15→NV12 read, CPU-unpacked P010→NV15 write, bit-exact NV15 copy at
256/320/1920 widths, clean journal). On debug build `P7589-C4ad2`
(`#7`, carrying the amended `0050`) the gate CLOSES: the full
differential matrix is content-exact — including the primary
system→system 64×64 both-legs bounce, the previously-failing dst-only
leg, and userptr bounces — the mapping-failure fallback stays a clean
`EOPNOTSUPP`, and the same-boot smoke (28 ok / 0 FAIL), P010/NV15
probes, KASAN ABI replay (`20260721-145234`, `abi_status=0 clean=1`),
MPP suite (`20260721-145243`, `suite_status=0 clean=1`), and FFmpeg
suite (`20260721-145258`, 24/24, Main10→P010 PSNR inf) are all green
with a zero-flagged-line journal — `0043`–`0050` are BOOT-VERIFIED on
one kernel. (Watchlist note: `P7589`'s *first* boot attempt hung ~2
min in with no oops/panic/pstore capture and needed a hard reset; the
second boot of the identical kernel was clean, and `0050` touches no
boot path — watching for recurrence.)
See the
[conformance root-cause finding](../../findings/2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md)
and the
[DMA scope finding](../../findings/2026-07-21-rga2-dma-api-ownership-and-over-4g-scope.md).

A later KASAN build, `6.18.40-video-port-kasan-rockchip-rk3588 #2`, verifies
the post-production `0074`/`0075` tail on 2026-07-25. Broad conformance run
`20260725-194940` keeps ABI, MPP 12/12, and FFmpeg 24/24 green with AV1
required; GStreamer still has two required userspace/harness failures, and the
official librga sample matrix still has fixture/environment failures. The
targeted gates close the kernel questions: raw RGA 10-bit stride/UV-offset gate
`20260725-195821-rga-10bit-gates` passes on cores 1, 2, 4, and default; fresh
librga P010/NV15 gate `20260725-200145-rga-im2d-10bit-current-gates` passes;
and the RKVENC2 forced `split_arg=4` gate `20260725-195350-mpp-suite` passes
H.264/H.265 with the expected merge warnings. KASAN narrowed and MPP runs report
zero flagged kernel lines, non-submit ioctl fuzz passes, and root gates pass
5/5 with `mpp-debug-capture` skipped as expected. See the
[6.18.40 KASAN validation finding](../../findings/2026-07-25-forward-port-6-18-40-kasan-full-validation.md).

Patches `0051`–`0057` close the remaining lifetime/robustness gaps found by
the KASAN sweep after `0050`, and the full conformance sweep now passes on one
booted debug build. `0051` fixes the RGA request-completion-vs-session-close
refcount; `0052`–`0055` harden the MPP session teardown/collect paths;
`0056@dea09c9d02cd` holds a session refcount for a job's lifetime, closing a
second, distinct RGA use-after-free (the async-completion `job->session` deref,
separate from the `0051` request refcount); and `0057@09030239b5e4` rejects a
`MPP_CMD_RELEASE_FD` on a client-less session (`session->dma == NULL`) instead
of NULL-dereferencing `mpp_dma_release_fd` — an unprivileged local DoS that
`RESET_SESSION` could set up. On booted KASAN debug build **`Pd222-C4ad2`**
(`#4`, patches `0001`–`0057`; vmlinuz md5 matched the deb;
`panic_on_oops=0`) the complete sweep is GREEN with a zero-flagged journal:
the `0057` deterministic reproducer returns `EINVAL` with the guard log and no
`mpp_dma_release_fd` fault; the `0056` RGA cross-session UAF reproducer (that
harness is now kept in the private `rock-5b-security` repository, but the result
below stands as recorded)
runs `async_submits=256000 dedup_shared=4000 submit_fail=0` with zero KASAN/UAF
lines; and the regression + conformance gates all pass — MPP suite
(`20260722-073705`, 12/12 `clean=1`), librga smoke (green), KASAN ABI replay
(`20260722-073858`, `abi_status=0 clean=1`), and FFmpeg codec suite
(`20260722-073958`, **24/24** including AV1 decode/transcode/PSNR, HEVC/VP9
bit-exact PSNR inf, Main10→P010 RGA, and resolution-change). A whole-session
root journal sweep found zero KASAN/BUG/Oops/iommu-fault signatures. So the
complete patch tip `0001`–`0057` is hardware-validated for the memory-safety,
ABI, and codec-conformance gates on `Pd222`. Both former distribution blockers
are cleared — see the
[RGA job-vs-session UAF finding](../../findings/2026-07-21-rga-job-vs-session-close-uaf-kasan.md)
and the
[MPP client-less RELEASE_FD finding](../../findings/2026-07-21-mpp-collect-msgs-clientless-session-null-deref-crash.md).

**`0076`–`0079` (2026-07-29) carry no hardware evidence at all.** The
[WARN/oops audit sweep](../../findings/2026-07-29-forward-port-warn-oops-audit-and-fixes.md)
added 18 fixes — 12 unprivileged-reachable, five of them kernel-heap
corruption — and every one is **compile-verified only**: `make W=1` clean, the
patches replay to a byte-identical tree, and nothing has been booted or
exercised by a reproducer, pre-fix or post-fix. Three change observable
behaviour (`mpp_check_req()` now rejects requests the old sloppy clamp let
through; the RGA IOMMU fault handler holds `irq_lock` across a ~1 ms
`soft_reset()` busy-wait; the RGA request debugfs dump holds `request->lock`
across up to 256 `seq_printf()` groups), so the boot that gates them must run
full conformance, not just a smoke test. Nothing in the "Done" table below
covers this range.

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
| **RK3588 AV1 decode** | **Supplied by the forward port and hardware-validated.** The vendor `mpp_av1dec.c` backend plus the VSI-IOMMU provider are part of the single maintained series (`0007` + `0005`); the early build `Pb6ab` predates them. Board build `P1c9d` (kernel `6.18.37 #8`) exposes AV1 through `/dev/mpp_service` (`supports-device` → `AV1DEC HW_ID:0x80019000`) and decodes **bit-exact (PSNR=inf) vs a software reference** (`mpi_dec_test -t 16777224`, 2026-07-04). The separate upstream Hantro/V4L2-stateless AV1 path (also `vsi-iommu`-backed) still exists as the mainline alternative. Full write-up + the `av1_rkmpp` distro-lib caveat: [AV1 note](../av1/docs/av1-rk3588.md) § 2026-07-04 update. |
| **Expanded MPP/RGA/GStreamer/FFmpeg conformance** | RGA is validated *through* ffmpeg's `scale_rkrga`, and the in-repo `librga-smoke.sh` covers direct im2d paths including virtual-address imports, dma-buf fd imports, RKNN/RKNPU-style RGB/NV12/NV21 preprocessing, GStreamer-style legacy `c_RkRgaBlit()` conversions, a no-submit physical-address import probe, forced-core/pre-intr submission, and async fences. The support repo now has wrappers and comparators for the official MPP tests, official `airockchip/librga` sample suite, JeffyCN GStreamer Rockchip plugin, and ffmpeg-rockchip CLI coverage under `../rockchip-conformance`, including generated VP9 IVF decode, generated H.265 Main10 decode/RGA/fallback coverage, optional generated H.265 4:2:2 10-bit coverage, encoder force-key-unit events, explicit encoder control-property pipelines, codec-specific H.264/H.265 QP controls, H.264 profile/level plus max-pending and unaligned-vstride controls, MPP-only `GST_MPP_NO_RGA=1` encode/decode, strict decoder-property pipelines plus env-default decoder control, DMA-feature, output-format coverage, and external-media H.265 10-bit fallback coverage for `GST_MPP_DEC_DISABLE_NV12_10`/`GST_MPP_DEC_DISABLE_NV16_10`, required parallel encode/decode/transcode pipelines for multicore scheduling evidence, diagnostic decoder crop-meta, env-default FBC output, RFBC caps negotiation via `GST_MPP_DEC_FBC_IS_RFBC=1`, diagnostic VP8/JPEG/VPx-alpha GStreamer element visibility including VP8 QP and JPEG quality-factor property setters, opt-in Rockchip display/DMABuf sink cases including `KMSSINK_DISABLE_VSYNC=1`, `GST_RKXIMAGE_USE_COLORKEY=1`, and `GST_KMSSRC_DMA_FEATURE=1` KMS capture, plus FFmpeg decoder-option, `scale_rkrga` forced-core/async/AFBC-output, `vpp_rkrga` crop/transpose, diagnostic decoder `afbc=rga`, and `overlay_rkrga` alpha-composition cases. MPP test binaries and the full librga sample build helper have been staged locally. **The GStreamer suite now RUNS on the forward-port kernel (`Pd222-C4ad2`, 2026-07-22):** after installing the GStreamer dev/tools packages (`libgstreamer1.0-dev`, `libgstreamer-plugins-base1.0-dev`, `gstreamer1.0-tools`, `gstreamer1.0-plugins-bad` for the `h264/h265/vp9/av1/ivf` parsers) and building the JeffyCN `libgstrockchipmpp.so` (build script now pins `--libdir lib`), the suite scores **98/102 required pass with a completely clean kernel journal** (zero KASAN/BUG/Oops/iommu-fault) — H.264/H.265 encode/decode/transcode/roundtrip, all 8-bit RGA color/rotate/scale, caps renegotiation, EOS/flush on encode, force-key events, parallel encode, 10-bit decode, AFBC, mp4, and VP9 decode all pass. Two harness bugs were fixed in the process: VP9 input generation used a non-existent `ivfmux` (now generates IVF via the ffmpeg `libvpx-vp9` path like AV1), and the force-key-unit event harness sent the upstream event to a downstream sink pad (now sent to the encoder src pad). The **4 remaining required failures are all userspace (plugin/harness/librga), not kernel** — see the [GStreamer conformance finding](../../findings/2026-07-22-gstreamer-suite-forward-port-userspace-gaps.md): the JeffyCN plugin's internal legacy-`c_RkRgaBlit` 10-bit convert path returns `EACCES` from librga (2 cases; kernel RGA is fine — 8-bit legacy passes and 10-bit P010 is bit-exact via ffmpeg im2d), the `dma-feature=true` transcode caps-negotiates as `not-negotiated` (plain transcode passes), and the decoder flush harness injects a raw `flush_stop(reset_time=TRUE)` with no following SEGMENT (encode flush passes). None of these expanded suites has paired forward-port/rewrite hardware logs yet, but the forward-port GStreamer gate is now green modulo the four documented userspace gaps. |
| **OPP/voltage scaling, RGA genpool** (`ROCKCHIP_RGA_GENPOOL`) | gen_pool (the kernel `genalloc` carved-out memory allocator) is an alternate RGA buffer path; not needed for correctness. |
| **Netboot / diskless** | Possible on current mainline U-Boot (RTL8125B + PCIe are upstream now) but needs a U-Boot config rebuild + ~100 Mbps; not worth it vs `scp` deb + reboot. |
| **Second encoder devfreq island, thermal throttling** | Tier-2; encoder is static-clock. |

## ⚠️ Known limitations

- **RESOLVED — VERIFIED FIXED on `Pd222-C4ad2` (2026-07-22) — `rga_request`
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
  force-free `0039` fixed** (which the `leak` mode confirms quiet) and is
  reachable by any process that closes `/dev/rga` while an async RGA job is
  still completing. Fixed by `0051@039d880127e7` (a `rga_request_release_ref()`
  helper that drops the initial reference exactly once under the
  pending-request-manager lock). **Booted gate PASSED on `Pd222-C4ad2`:** the
  `cross` reproducer ran `async_submits=256000 dedup_shared=4000 submit_fail=0`
  with zero KASAN/UAF lines and no `refcount_t` underflow. (The same `cross`
  run also validates the distinct `0056` job-vs-session UAF, since both faults
  are exercised by the async-completion path it drives.) See the
  [request-completion UAF finding](../../findings/2026-07-21-rga-request-completion-vs-session-close-uaf-kasan.md)
  and the
  [job-vs-session UAF finding](../../findings/2026-07-21-rga-job-vs-session-close-uaf-kasan.md).
- **BSP-audit HIGH fixes are ported and boot-validated as a series; 3 of 11 are
  individually hostile-gated (PARTIAL, 2026-07-22 + production 2026-07-24).**
  The audit's 16 HIGH reviewer rows collapse to 13 distinct bugs. Later
  forward-port work independently fixed the RKVENC2 probe unwind and the
  duplicated RGA request-submit reference leak, leaving **13 rows / 11 bugs in
  the booted `Pd222-C4ad2` kernel**. Those 11 are ported around the current RGA2
  bounce/lifetime code as forward-port patches `0058`-`0068` (post-renumber
  numbering); every commit is checkpatch-clean and the native
  `drivers/video/rockchip/` build passes. KASAN/lockdep debug package
  `Pabd5-C4ad2` was **installed and booted 2026-07-22**, and the same tail
  shipped in the Published production kernel that passed the full conformance set
  and root gates 2026-07-24. On that boot the series carried a bit-exact
  four-codec differential, FFmpeg 24/24, GStreamer 129/4, ABI replay `rc=0`, and
  a clean KASAN MPP suite.

  Be precise about which HIGH bugs have *targeted* hostile evidence, because it
  is 3 of 11: `0059` (foreign-fd `SET_SESSION_FD` — batch returns `-EBADF`),
  `0060` (RKVDEC2 RCB register index — PoC reaches the guard), and `0062`
  (RKVENC2 class request arrays — PoC reaches the overflow reject). The other
  destructive rungs that ran on that boot exercise fixes **outside** the HIGH set
  — `0039` physical import, `0042` RESET_SESSION, `0057` clientless RELEASE_FD,
  `0052`/`0056` cross-session UAF (64,000 async submits, 0 KASAN flags). Four
  HIGH gates named in the port record have **never run**: async acquire-fence
  stress (`0063`), queued-job shutdown outside `irq_lock` (`0064`), missing
  required multi-plane handle (`0065`), and partial-handle unwind (`0067`).
  Evidence-quality caveat for that boot: the `0055` PoC tripped the double-init
  UAF mid-ladder, so `session_attach` was corrupted for the rest of it — later
  rungs ran against a knowingly-poisoned list.

  The trusted-input-only caveat this bullet used to carry is nonetheless retired,
  because every clause of it was false: the package *was* installed, booted,
  KASAN-tested, hostile-ioctl tested, and codec/RGA regression-tested. What
  replaces it is the narrower statement above. Note that `/dev/mpp_service` and
  `/dev/rga` are still granted to the `video` group by udev, and that group
  remains a security boundary. MEDIUM/LOW findings such
  as the `mpp_check_req()` overflow-clamp bug remain outside this HIGH-only
  port; their historical full fix set is the 65-patch
  [`cleanup-split`](../patches/cleanup-split) series, whose strengthened form
  still has the documented verification and compile caveats.
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
- **MPP procfs session dumps before forward-port patch `0040` race session
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
  KASAN now verifies `0041`, and a second forward-port UAF is fixed/verified as
  `0042`.** The first
  booted `0039`/`0040` validation on PPA kernel
  `6.18.38+rk3588av1fwport20260717-0ubuntu1~rk1` Oopsed after ABI replay with no
  call trace, which initially read as a `/proc/mpp_service` snapshot race. The
  KASAN+ramoops rebuild (`P712f-C40aa`) reproduced it on the first narrowed pass
  and overturned that: `MPP_CMD_RESET_SESSION` (`mpp_common.c:1414`) calls
  `mpp_dma_session_destroy(session->dma)` without clearing the pointer — unlike
  the two other destroy sites — so the async `rkvdec2_soft_ccu_worker` teardown
  re-destroys the freed `mpp_dma_session` and faults on `dma->list_mutex`
  (slab-use-after-free). The defect is byte-identical in the pristine Rockchip
  BSP (`develop-6.1`), so it is vendor-original, not forward-port-introduced.
  Patch `0041` adds `session->dma = NULL`; rebuilt run
  `20260718-093751-kasan-narrowed` exercises RESET_SESSION with zero flagged
  lines. That boot then exposed a separate forward-port-introduced post-free
  `task->state` read in `rkvenc2_wait_result`. Patch `0042` samples the abort
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
- **High-count low-delay H.264 could overflow RKVENC2's 256-entry slice FIFO and
  lose the terminal marker — fixed and hardware-verified 2026-07-25.** Both
  `kfifo_in()` calls ignored failure, while the MPP VEPU580 H.264 HAL ignored
  poll errors and looped on an uninitialized `slice_last`. Kernel `0075`
  (`12a7da02bea8`) reserves the last FIFO slot for the terminal record and
  carries a dropped record's length into the next stored one, so the stream
  always terminates and the byte offsets stay exact; an overflowing frame is
  still complete and decodable, so the condition is counted and warned about
  rather than returned as an error. MPP `0002`/`0003` harden all eight vepu5xx
  poll loops, bound empty polls, gate the terminal `ENC_OUTPUT_FINISH` callback
  on a per-frame flag instead of the frame-persistent `ctx->output_cb->cmd`, and
  close a latent single-cfg out-of-bounds index in `hal_h264e_vepu511a.c`. Both
  sides were first compile-verified (`W=1` clean, checkpatch clean), then the
  booted `6.18.40-video-port-kasan-rockchip-rk3588` validation run
  `20260725-195350-mpp-suite` passed the forced `split_arg=4` H.264/H.265 slice
  cases with the expected `slice fifo full (256), merged N record(s)` and
  `session ... merged N slice record(s)` warnings. The follow-on ordinary KASAN
  MPP suite `20260725-195451-kasan-mpp-suite` passed all 12 required cases with
  `flagged_kernel_lines=0`. The conformance suite still defaults to the safe
  `split_arg=120`. See the
  [slice-FIFO finding](../../findings/2026-07-20-rkvenc2-slice-fifo-terminal-drop.md).
- **RGA2 syncs page-table memory through an address that was never DMA-mapped
  — RESOLVED — VERIFIED FIXED (closed by `0050`, booted on `P7589-C4ad2`).**
  The direct dma-buf smoke on the DMA-debug KASAN kernel produced a complete
  `debug_dma_sync_single_for_device` warning through
  `rga_dma_sync_flush_range()` and `rga_set_mmu_base()`. RGA2 page-table
  allocation must retain a valid DMA address/lifetime; disabling the warning is
  not a fix. The splat is gone on the booted fix (see this file's
  earlier RGA2 page-table section and the finding's own resolution block). See the
  [RGA2 DMA-sync finding](../../findings/2026-07-20-rga2-unmapped-page-table-dma-sync.md).
- **The two persistent RGA ABI replay gaps are fixed and pass booted replay.**
  Patch `0043@bb15076cd6fa` accepts legacy `RGA2_GET_RESULT` as a no-op.
  Patch `0044@2d6367ad0b05` rejects malformed/unknown staged task descriptors,
  blocks replacement while a request runs, and frees the prior staged list.
  Rebuilt KASAN debug build `Pb999-C4ad2` booted and passed run
  `20260721-034716-kasan-narrowed` with `abi_status=0` and a clean memory scan —
  the first fully green ABI replay on a forward-port kernel. The production
  package still predates these patches. See the
  [RGA ABI finding](../../findings/2026-07-21-rga-forward-port-abi-gaps.md).
- **Direct RGA3 im2d virtual-buffer samples exposed RGA/IOMMU forward-port
  gaps.** The upstream `airockchip/librga` copy/resize/rotate samples import
  malloc-backed buffers and can trigger `RGA3_core0 INTR[0x2]`, the RGA MMU
  interrupt, on board build `P1c9d`. The debugfs run in
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
absorbs `0041`/`0042` but predates the `0043`/`0044` ABI fixes, which now pass
booted KASAN ABI replay; publication, board boot/conformance, and rollback
still need resolution. The MPP functional failures and RGA ABI gaps are closed
on the KASAN build, but the RGA2 DMA ownership warning, GStreamer dependency
gate, and broader audit series still have compile/runtime work. DVFS and codec
breadth are optional polish; memory safety, regression conformance, and recovery
are release blockers.
