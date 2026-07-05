# Status — done, skipped, limitations

> **Scope.** This doc is the scorecard for the **kernel codec forward-port**
> only. The repo now spans much more — ffmpeg (two lineages), the
> gnome-remote-desktop HW-encode backend, DKMS/PPA packaging, Mesa/Panfrost —
> and the whole-project dated scoreboard is [`status.md`](../../status.md) at the
> repo root.

Target: Radxa ROCK 5B (RK3588), Armbian, kernel **6.18.37** (`rockchip64-current`).
Validated build hash: `Pb6ab-Cb831` (and its functionally-identical predecessor
`P8c75`). That hash is baked into the Armbian `.deb` package name — `P####` hashes
the applied kernel patch set, `C####` hashes the kernel config — so the pair names
the *exact* build we validated (the installer matches debs on it; see
`scripts/install-combined-kernel.sh`).

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
| **Expanded MPP/RGA/GStreamer/FFmpeg conformance** | RGA is validated *through* ffmpeg's `scale_rkrga`, and the in-repo `librga-smoke.sh` covers direct im2d paths including virtual-address imports, dma-buf fd imports, GStreamer-style legacy `c_RkRgaBlit()` conversions, forced-core/pre-intr submission, and async fences. The support repo now has wrappers and comparators for the official MPP tests, official `airockchip/librga` sample suite, JeffyCN GStreamer Rockchip plugin, and ffmpeg-rockchip CLI coverage under `../rockchip-conformance`, including generated VP9 IVF decode, generated H.265 Main10 decode/RGA/fallback coverage, optional generated H.265 4:2:2 10-bit coverage, encoder force-key-unit events, explicit encoder control-property pipelines, codec-specific H.264/H.265 QP controls, H.264 profile/level plus max-pending and unaligned-vstride controls, MPP-only `GST_MPP_NO_RGA=1` encode/decode, strict decoder-property pipelines plus env-default decoder control, DMA-feature, output-format coverage, and external-media H.265 10-bit fallback coverage for `GST_MPP_DEC_DISABLE_NV12_10`/`GST_MPP_DEC_DISABLE_NV16_10`, required parallel encode/decode/transcode pipelines for multicore scheduling evidence, diagnostic decoder crop-meta, env-default FBC output, RFBC caps negotiation via `GST_MPP_DEC_FBC_IS_RFBC=1`, diagnostic VP8/JPEG/VPx-alpha GStreamer element visibility including VP8 QP and JPEG quality-factor property setters, opt-in Rockchip display/DMABuf sink cases including `KMSSINK_DISABLE_VSYNC=1`, `GST_RKXIMAGE_USE_COLORKEY=1`, and `GST_KMSSRC_DMA_FEATURE=1` KMS capture, plus FFmpeg decoder-option, `scale_rkrga` forced-core/async/AFBC-output, `vpp_rkrga` crop/transpose, diagnostic decoder `afbc=rga`, and `overlay_rkrga` alpha-composition cases. MPP test binaries and the full librga sample build helper have been staged locally; the GStreamer plugin build wrapper is present but the current host still lacks the GStreamer development `.pc` packages. None of these expanded suites has paired forward-port/rewrite hardware logs yet. |
| **OPP/voltage scaling, RGA genpool** (`ROCKCHIP_RGA_GENPOOL`) | gen_pool (the kernel `genalloc` carved-out memory allocator) is an alternate RGA buffer path; not needed for correctness. |
| **Netboot / diskless** | Possible on current mainline U-Boot (RTL8125B + PCIe are upstream now) but needs a U-Boot config rebuild + ~100 Mbps; not worth it vs `scp` deb + reboot. |
| **Second encoder devfreq island, thermal throttling** | Tier-2; encoder is static-clock. |

## ⚠️ Known limitations

- **The shipped drivers still carry every bug the BSP audit found.** This
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
  replace the OPP shim: as shipped, `rockchip_init_opp_table()` returns
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

The forward-port is **functionally complete**: you can run
`ffmpeg -hwaccel rkmpp -c:v hevc_rkmpp ...` on a stock-ish Armbian 6.18 kernel
and it uses the hardware. The remaining items are performance polish (DVFS) and
breadth (more codecs), not blockers.
