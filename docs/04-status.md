# Status — done, skipped, limitations

Target: Radxa ROCK 5B (RK3588), Armbian, kernel **6.18.37** (`rockchip64-current`).
Validated build hash: `Pb6ab-Cb831` (and its functionally-identical predecessor
`P8c75`). That hash is baked into the Armbian `.deb` package name — `P####` hashes
the applied kernel patch set, `C####` hashes the kernel config — so the pair names
the *exact* build we validated (the installer matches debs on it; see
`scripts/install-combined-kernel.sh`).

## ✅ Done — validated on real hardware

| Item | Evidence |
|------|----------|
| **H.264/H.265 encode** (VEPU580, both cores) | `mpi_enc_test`: 256² + 1280×720, PSNR 47–62 dB, NAL-correct, no IOMMU fault. Both cores `attach ccu as core 0/1` (CCU = the clock/coordination unit the paired cores share). |
| **H.264/H.265 decode** (VDPU381/rkvdec2, both cores) | `mpi_dec_test`: decoded 30 frames each of software-encoded H.264 + H.265 to NV12, ~1200–1600 fps @ 320×240. Both `rkvdec-core0/1` bound at `fdc38000`/`fdc40000`. |
| **RGA** (RGA3 ×2 + RGA2) | probes at boot, `/dev/rga` present, IOMMU bound; exercised functionally via `scale_rkrga` in the transcode (1080p→720p and 720p→480p). |
| **Combined in-tree kernel** | all three accelerators `=y`, present at boot — **no overlay, no insmod**. |
| **ffmpeg-rockchip** | built (`nyanmisaka` fork) with `h264_rkmpp`/`hevc_rkmpp` decode+encode and `scale_rkrga`. Full HW transcode passes both directions. |
| **Zero-edit Armbian packaging** | `media-0001` (Armbian's mainline media/codec backport patch series) and the kernel config both stay **pristine**; everything lives in two userpatches (see `docs/08`). |
| **Quality-of-life** | udev rule for non-sudo `/dev/mpp_service` + `/dev/dma_heap/*` + `/dev/rga` (the dma-heap rule is **required** — rkmpp allocates buffers there, so `mpp_service` alone leaves the encoder dead; upstreamed as [armbian/build#10085](https://github.com/armbian/build/pull/10085)); ccache-correct build wrapper. |

## ⏭️ Skipped / deferred (intentionally)

| Item | Why |
|------|-----|
| **Encoder/decoder DVFS** (`*_DEVFREQ`, OPP, system-monitor) | DVFS (dynamic voltage/frequency scaling) here rides on vendor BSP-only services — PVTM (the on-chip process-voltage-temperature monitor that drives voltage scaling), `rockchip_system_monitor`, `rockchip_opp_select` — none of which exist upstream. The OPP (operating performance point — one voltage/frequency pair) service is stubbed, so the concrete loss is **no PVTM voltage/leakage scaling**: the cores stay at the fixed DT `assigned-clock-rates` (enc 800 MHz, dec 800 MHz), which is plenty fast and fine at every load we tested. The devfreq (the Linux dynamic-frequency framework) islands are tier-2 Kconfigs — the project's off-by-default "nice-to-have" tier — defaulting `n`. See `docs/05`. |
| **VP9 decode** | The decoder driver builds VP9 support; we only validated H.264/H.265. Should work (same data path) but untested here. |
| **JPEG encode/decode, AV1** | `mjpeg_rkmpp`/`av1_rkmpp` exist in ffmpeg but weren't a goal; the vendor JPEG encoder block isn't wired in the DT. |
| **RGA standalone functional test** | RGA is validated *through* ffmpeg's `scale_rkrga`; no dedicated `librga` sample run. |
| **OPP/voltage scaling, RGA genpool** (`ROCKCHIP_RGA_GENPOOL`) | gen_pool (the kernel `genalloc` carved-out memory allocator) is an alternate RGA buffer path; not needed for correctness. |
| **Netboot / diskless** | Possible on current mainline U-Boot (RTL8125B + PCIe are upstream now) but needs a U-Boot config rebuild + ~100 Mbps; not worth it vs `scp` deb + reboot. |
| **Second encoder devfreq island, thermal throttling** | Tier-2; encoder is static-clock. |

## ⚠️ Known limitations

- **We link `airockchip/librga`'s prebuilt `.so` for convenience — but librga is
  open source** (Apache-2.0): the *official* repo just ships a prebuilt `.so`, so
  it looks closed, but the real source is published (JeffyCN mirror lineage) and
  you *can* build a fully-from-source userspace. The kernel `/dev/rga` driver we
  ported *is* GPL source. Full lineage + repo pointers in
  [`docs/10`](10-gotchas.md) (§ Userspace).
- **The decoder DT is Armbian-specific in convert-in-place form** — *convert-in-place*
  meaning we override Armbian's existing DT nodes where they sit, rather than adding
  or replacing nodes (see [`docs/08`](08-armbian-packaging.md)). It retypes
  Armbian's `media-0001` `vdec0/vdec1` nodes to the vendor binding. For vanilla
  mainline (no `media-0001`) use the inline-node form — see `docs/09`.
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
  cast on any kernel bump — see [`docs/12`](12-resyncing.md).
- **Single static clock.** No thermal/DVFS management: the clock is pinned by the
  DT `assigned-clock-rates` (~800 MHz) and never moves, so sustained max-load
  workloads should be watched (fine in tests so far). Re-enabling DVFS takes *two*
  changes, not one — set `CONFIG_ROCKCHIP_MPP_RKVENC2_DEVFREQ` (default `n`) **and**
  replace the OPP shim: as shipped, `rockchip_init_opp_table()` returns
  `-EOPNOTSUPP`, so even with the Kconfig on, devfreq init bails and the clock stays
  static.

## What "done" means here

The forward-port is **functionally complete**: you can run
`ffmpeg -hwaccel rkmpp -c:v hevc_rkmpp ...` on a stock-ish Armbian 6.18 kernel
and it uses the hardware. The remaining items are performance polish (DVFS) and
breadth (more codecs), not blockers.
