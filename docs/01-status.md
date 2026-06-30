# Status — done, skipped, limitations

Target: Radxa ROCK 5B (RK3588), Armbian, kernel **6.18.37** (`rockchip64-current`).
Validated build hash: `Pb6ab-Cb831` (and its functionally-identical predecessor
`P8c75`).

## ✅ Done — validated on real hardware

| Item | Evidence |
|------|----------|
| **H.264/H.265 encode** (VEPU580, both cores) | `mpi_enc_test`: 256² + 1280×720, PSNR 47–62 dB, NAL-correct, no IOMMU fault. Both cores `attach ccu as core 0/1`. |
| **H.264/H.265 decode** (VDPU381/rkvdec2, both cores) | `mpi_dec_test`: decoded 30 frames each of software-encoded H.264 + H.265 to NV12, ~1200–1600 fps @ 320×240. Both `rkvdec-core0/1` bound at `fdc38000`/`fdc40000`. |
| **RGA** (RGA3 ×2 + RGA2) | probes at boot, `/dev/rga` present, IOMMU bound; exercised functionally via `scale_rkrga` in the transcode (1080p→720p and 720p→480p). |
| **Combined in-tree kernel** | all three accelerators `=y`, present at boot — **no overlay, no insmod**. |
| **ffmpeg-rockchip** | built (`nyanmisaka` fork) with `h264_rkmpp`/`hevc_rkmpp` decode+encode and `scale_rkrga`. Full HW transcode passes both directions. |
| **Zero-edit Armbian packaging** | `media-0001` backport patch + kernel config both **pristine**; everything lives in two userpatches (see `docs/04`). |
| **Quality-of-life** | udev rule for non-sudo `/dev/mpp_service` + `/dev/dma_heap/*` + `/dev/rga` (the dma-heap rule is **required** — rkmpp allocates buffers there, so `mpp_service` alone leaves the encoder dead; upstreamed as [armbian/build#10085](https://github.com/armbian/build/pull/10085)); ccache-correct build wrapper. |

## ⏭️ Skipped / deferred (intentionally)

| Item | Why |
|------|-----|
| **Encoder/decoder DVFS** (`*_DEVFREQ`, OPP, system-monitor) | Vendor BSP-only services (PVTM voltage scaling, `rockchip_system_monitor`, `rockchip_opp_select`). The cores run at fixed DT `assigned-clock-rates` (enc 800 MHz, dec 800 MHz) — plenty fast. Tier-2 Kconfigs default `n`; the BSP OPP service is stubbed. See `docs/02`. |
| **VP9 decode** | The decoder driver builds VP9 support; we only validated H.264/H.265. Should work (same data path) but untested here. |
| **JPEG encode/decode, AV1** | `mjpeg_rkmpp`/`av1_rkmpp` exist in ffmpeg but weren't a goal; the vendor JPEG encoder block isn't wired in the DT. |
| **RGA standalone functional test** | RGA is validated *through* ffmpeg's `scale_rkrga`; no dedicated `librga` sample run. |
| **OPP/voltage scaling, RGA genpool** (`ROCKCHIP_RGA_GENPOOL`) | Not needed for correctness. |
| **Netboot / diskless** | Possible on current mainline U-Boot (RTL8125B + PCIe are upstream now) but needs a U-Boot config rebuild + ~100 Mbps; not worth it vs `scp` deb + reboot. |
| **Second encoder devfreq island, thermal throttling** | Tier-2; encoder is static-clock. |

## ⚠️ Known limitations

- **We link `airockchip/librga`'s prebuilt `.so` for convenience — but librga is
  open source.** Rockchip's *official* `airockchip/librga` repo ships only a
  prebuilt `.so` + headers + samples (no library source), which makes it look
  closed. The actual library source is published (Apache-2.0) in the JeffyCN
  mirror lineage — `JeffyCN/mirrors:linux-rga-multi`, maintained as
  `tsukumijima/librga-rockchip` (full `core/` + `im2d_api/`, CMake/Meson, Debian
  packages) and `madisongh/rockchip-librga`. So you *can* build a fully-from-source
  userspace; we just linked the prebuilt because it works as-is. The kernel
  `/dev/rga` driver we ported *is* GPL source. See `docs/06`.
- **The decoder DT is Armbian-specific in convert-in-place form.** It overrides
  Armbian's `media-0001` `vdec0/vdec1` nodes. For vanilla mainline (no
  `media-0001`) use the inline-node form — see `docs/05`.
- **API-pinned to ~6.18.** A few forward-port fixes track 6.18 kernel APIs
  (notably the IOMMU `cookie_type` guard). Newer kernels may need a re-check.
- **Single static clock.** No thermal/DVFS management; sustained max-load
  workloads should be watched (it has been fine in tests).

## What "done" means here

The forward-port is **functionally complete**: you can run
`ffmpeg -hwaccel rkmpp -c:v hevc_rkmpp ...` on a stock-ish Armbian 6.18 kernel
and it uses the hardware. The remaining items are performance polish (DVFS) and
breadth (more codecs), not blockers.
