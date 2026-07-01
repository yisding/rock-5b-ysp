# rock-5b-ysp — RK3588 hardware video codecs + RGA on mainline-ish Linux 6.18

Forward-port of the Rockchip **vendor MPP** hardware video codec stack and the
**RGA** 2D accelerator from the Rockchip 6.1 BSP to **Linux 6.18**, packaged for
**Armbian** on the **Radxa ROCK 5B** (RK3588), plus a working
[`ffmpeg-rockchip`](https://github.com/nyanmisaka/ffmpeg-rockchip) userspace.

The result is a single Armbian kernel with all three accelerators **built in
(`=y`)** and **validated on real hardware**:

| Accelerator | Block | Nodes | Status |
|-------------|-------|-------|--------|
| **Encoder** | VEPU580 / `rkvenc2` | `fdbd0000`, `fdbe0000` | ✅ H.264 + H.265, 256² + 720p, PSNR 47–62 dB |
| **Decoder** | VDPU381 / `rkvdec2` | CCU `fdc30000`, cores `fdc38000` / `fdc40000` | ✅ H.264 + H.265 decode, both cores |
| **RGA** | RGA3 ×2 + RGA2 | `fdb60000`, `fdb70000`, `fdb80000` | ✅ probes + IOMMU + scale/CSC via ffmpeg |
| **End-to-end** | ffmpeg-rockchip | `h264_rkmpp` / `hevc_rkmpp` / `scale_rkrga` | ✅ full HW transcode (decode → RGA → encode) |

Userspace talks to the vendor MPP framework via `/dev/mpp_service` (the
Rockchip `rockchip-linux/mpp` library — **not** V4L2) and to RGA via `/dev/rga`
(the prebuilt `librga`). This is the same stack `ffmpeg-rockchip` expects.

For a **real application** built on all of this, see
[`gnome-remote-desktop/`](gnome-remote-desktop/): a hardware H.264 encode backend
for GNOME Remote Desktop, so an RDP session is encoded on the VEPU580 — plus the
three-bug debugging story (no-IDR freeze, the 2.5 Mbps quality ceiling, and the
GDM greeter's device permissions) that maps upstream FFmpeg 8.1.2's
`h264_rkmpp` quirks.

> **Why the vendor stack and not mainline V4L2?** Mainline's `hantro`/`rkvdec`
> V4L2 drivers don't cover H.265 **encode**, and the RGA3 V4L2 driver is still
> a subset (scale/CSC only) and not yet merged for RK3588. The vendor MPP +
> RGA stack gives the full feature set today. See
> [`docs/09-vanilla-kernel.md`](docs/09-vanilla-kernel.md) for the mainline-V4L2
> alternative and its trade-offs.

## Glossary

The acronyms that recur throughout (the linked doc has the depth):

- **MPP** — Rockchip *Media Process Platform*: the vendor hardware-codec framework
  (kernel `rk_vcodec.ko` + userspace `librockchip_mpp`), reached via
  `/dev/mpp_service`. **Not** V4L2.
- **VEPU580 / `rkvenc2`** — the H.264/H.265 hardware **encoder** block / its driver.
- **VDPU381 / `rkvdec2`** — the H.264/H.265/VP9 hardware **decoder** block / its driver.
- **RGA3 / RGA2** — *Raster Graphic Acceleration*, the 2D engine (scale, colour-convert,
  rotate, blend), via `/dev/rga`.
- **CCU** — the per-cluster *coordination unit* that picks an idle core and shares
  clocks/IOMMU. The decoder's is a real MMIO block; the encoder's is software-only
  (**DCHS** = dual-core hand-shake). See [docs/01](docs/01-how-the-drivers-work.md) §7.
- **dma-buf** — a kernel-shared buffer passed by **fd**, zero-copy, between drivers.
- **dma-heap** — `/dev/dma_heap/*`, the userspace DMABUF allocator `rkmpp` draws
  frame/stream buffers from (the post-ION mainline allocator). See [docs/10](docs/10-gotchas.md).
- **IOMMU / MMU** — the codec's own address translator: gives a dma-buf a device-side
  address (an *IOVA*) so the hardware can read/write it.
- **RCB** — *Row Cache Buffer*, per-row scratch the codec keeps in fast memory; the
  decoder backs it with on-chip **SRAM**, the encoder with DRAM.
- **taskqueue / core-mask** — a cluster's work queue / the DT bitmask naming its cores.
- **DVFS / OPP / PVTM / devfreq** — dynamic voltage-&-frequency scaling and its kernel
  machinery; **off** in this port (cores run at a fixed clock).
- **power-domain (PD)** — an SoC power island that must be on for a block to run.
- **convert-in-place** — the packaging trick of *retyping* Armbian's existing V4L2
  decoder DT nodes to the vendor binding instead of adding new ones. See [docs/08](docs/08-armbian-packaging.md).
- **media-0001** — Armbian's backport patch that adds the V4L2 `vdec` DT nodes this
  port collides with.
- **V4L2** — mainline *Video4Linux2*, the codec API this port deliberately does **not**
  use (see the box above).

## Repository map

```
patches/        The two Armbian userpatches (the deliverable) + how they map to commits
  rk3588-rkvenc2-01-vcodec-rga-drivers.patch   vendor MPP + RGA drivers, forward-ported to 6.18 (58 files)
  rk3588-rkvenc2-02-vcodec-rga-dt.patch        device tree: encoder/decoder/RGA + convert-in-place
  cleanup-draft/                               machine-generated draft fixes for the BSP audit (docs/11) — review before use
scripts/        build / install / validate the combined kernel, + the udev rule
packaging/      standalone .debs — codec-udev (video-group rule) + gdm-hwenc (greeter codec ACL for GRD) + dkms (the drivers, for stock kernels 6.18-7.2)
tests/          on-hardware smoke tests: decode, encode, full transcode
ffmpeg/         building ffmpeg-rockchip + FFmpeg architecture/comparison/backport notes
gnome-remote-desktop/  a real app on the stack: HW-accelerated RDP encode (VEPU580)
  README.md   the runtime story + the 3 shipping bugs (no-IDR freeze, bitrate ceiling, greeter perms)
  DESIGN.md   why FFmpeg (vs VA-API / direct MPP) + the panvk hardware-enablement journey
  patches/    the full 7-patch backend series (applies on pristine GRD 50.1)
ppa/            building the userspace stack (MPP + RGA + FFmpeg 8.1.2 + GRD) as Launchpad source packages
docs/
  01-how-the-drivers-work.md  ⭐ START HERE — illustrated tour of the KERNEL drivers (any audience)
  02-how-the-userspace-libs-work.md  the companion: how libmpp + librga work, app→kernel
  03-dev-uapis.md         the /dev/mpp_service + /dev/rga ioctl ABIs (user-friendly + technical)
  04-status.md            what's done, what's skipped, known limitations
  05-vendor-forward-port.md  what we changed in the vendor code to build on 6.18
  06-vendor-delta.md      line-level accounting: ~98% Rockchip / ~2% ours, every change
  07-device-tree.md       the DT design: addresses, aliases, CCU, SRAM/RCB
  08-armbian-packaging.md Armbian's media-0001 backport conflict + the convert-in-place fix
  09-vanilla-kernel.md    applying this to vanilla mainline (no Armbian)
  10-gotchas.md           every gotcha + workaround found during the port
  11-bsp-audit.md         multi-agent audit of the BSP code: 89 verified findings + draft fixes
  12-resyncing.md         re-syncing the port to a newer BSP / newer kernel (forward-compat hazards)
```

> Numbered in reading order — start at `01` and work down, or jump to what you
> need. The how-it-works trio (`01`–`03`) is the recommended entry point.

## Quickstart (Armbian, ROCK 5B)

The patches drop into an Armbian build tree as **userpatches** (zero edits to
Armbian's own files — see [`docs/08`](docs/08-armbian-packaging.md)):

```bash
# 1. Place the patches in your Armbian build tree:
cp patches/rk3588-rkvenc2-0*.patch \
   <armbian-build>/userpatches/kernel/archive/rockchip64-6.18/

# 2. Build (ccache ON; USE_CCACHE must be an ARG, not an env var — see docs/10):
bash scripts/build-combined-kernel.sh        # wraps ./compile.sh ... USE_CCACHE=yes

# 3. Install + reboot + validate on the board:
sudo bash scripts/install-combined-kernel.sh # dpkg -i the image/dtb/headers debs
sudo reboot
sudo bash scripts/validate-combined.sh       # checks /dev/mpp_service, 4 cores, /dev/rga

# 4. (optional) run ffmpeg-rockchip without sudo — grants the `video` group
#    /dev/mpp_service + /dev/dma_heap/* (rkmpp's buffer allocator) + /dev/rga.
#    NB: dma_heap is required, not just mpp_service (see docs/10):
sudo cp scripts/99-rockchip-codec.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

A green `validate-combined.sh` shows `rkvenc-core0/1`, `rkvdec-core0/1`, and
`/dev/rga`. Then `tests/` exercises real frames.

## Provenance & licensing

- The driver code is forward-ported from Rockchip's GPL-2.0 BSP MPP framework
  (`rockchip-kernel` `drivers/video/rockchip/mpp/`) and `airockchip/librga`'s
  kernel driver. It is GPL-2.0, like the kernel.
- `librga`'s **userspace** library **is** open source (Apache-2.0) — the official
  `airockchip/librga` repo only ships a prebuilt `.so`, so we link that for
  convenience, but the source is published (JeffyCN mirror lineage) and you can
  build from it. Full lineage in [`docs/10`](docs/10-gotchas.md); build notes in
  [`ffmpeg/README.md`](ffmpeg/README.md).
- The mainline RGA-in-U-Boot / RGA-V4L2 context is courtesy of Collabora's
  RK3588 upstreaming work.

This repo is the *integration + analysis*; the heavy lifting on the drivers is
Rockchip's.
