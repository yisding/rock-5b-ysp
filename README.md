# rock-5b-ysp — RK3588 hardware video codecs + RGA on mainline-ish Linux 6.18

Forward-port of the Rockchip **vendor MPP** hardware video codec stack and the
**RGA** 2D accelerator from the Rockchip 6.1 BSP to **Linux 6.18**, packaged for
**Armbian** on the **Radxa ROCK 5B** (RK3588), plus a working
[`ffmpeg-rockchip`](https://github.com/nyanmisaka/ffmpeg-rockchip) userspace.

The result is a single Armbian kernel with all three accelerators **built in
(`=y`)** and **validated on real hardware**:

| Accelerator | Block | Nodes | Status |
|-------------|-------|-------|--------|
| **Encoder** | VEPU580 / `rkvenc2` | `fdbd0000`, `fdbe0000` | ✅ H.264 + H.265, 256p + 720p, PSNR 47–62 dB |
| **Decoder** | VDPU381 / `rkvdec2` | CCU `fdc30000`, cores `fdc38000` / `fdc40000` | ✅ H.264 + H.265 decode, both cores |
| **RGA** | RGA3 ×2 + RGA2 | `fdb60000`, `fdb70000`, `fdb80000` | ✅ probes + IOMMU + scale/CSC via ffmpeg |
| **End-to-end** | ffmpeg-rockchip | `h264_rkmpp` / `hevc_rkmpp` / `scale_rkrga` | ✅ full HW transcode (decode → RGA → encode) |

Userspace talks to the vendor MPP framework via `/dev/mpp_service` (the
Rockchip `rockchip-linux/mpp` library — **not** V4L2) and to RGA via `/dev/rga`
(the prebuilt `librga`). This is the same stack `ffmpeg-rockchip` expects.

> **Why the vendor stack and not mainline V4L2?** Mainline's `hantro`/`rkvdec`
> V4L2 drivers don't cover H.265 **encode**, and the RGA3 V4L2 driver is still
> a subset (scale/CSC only) and not yet merged for RK3588. The vendor MPP +
> RGA stack gives the full feature set today. See
> [`docs/05-vanilla-kernel.md`](docs/05-vanilla-kernel.md) for the mainline-V4L2
> alternative and its trade-offs.

## Repository map

```
patches/        The two Armbian userpatches (the deliverable) + how they map to commits
  rk3588-rkvenc2-01-vcodec-rga-drivers.patch   vendor MPP + RGA drivers, forward-ported to 6.18 (58 files)
  rk3588-rkvenc2-02-vcodec-rga-dt.patch        device tree: encoder/decoder/RGA + convert-in-place
scripts/        build / install / validate the combined kernel, + the udev rule
tests/          on-hardware smoke tests: decode, encode, full transcode
ffmpeg/         building ffmpeg-rockchip against the MPP + RGA libs (pkg-config examples)
docs/
  09-how-the-drivers-work.md  ⭐ START HERE — illustrated tour of the KERNEL drivers (any audience)
  10-how-the-userspace-libs-work.md  the companion: how libmpp + librga work, app→kernel
  11-dev-uapis.md         the /dev/mpp_service + /dev/rga ioctl ABIs (user-friendly + technical)
  01-status.md            what's done, what's skipped, known limitations
  02-vendor-forward-port.md  what we changed in the vendor code to build on 6.18
  07-vendor-delta.md      line-level accounting: ~98% Rockchip / ~2% ours, every change
  03-device-tree.md       the DT design: addresses, aliases, CCU, SRAM/RCB
  04-armbian-packaging.md Armbian's media-0001 backport conflict + the convert-in-place fix
  05-vanilla-kernel.md    applying this to vanilla mainline (no Armbian)
  06-gotchas.md           every gotcha + workaround found during the port
  08-bsp-audit.md         multi-agent audit of the BSP code: 89 verified bugs/cleanups
patches/cleanup-draft/  machine-generated draft fixes for the audit findings (review before use)
```

## Quickstart (Armbian, ROCK 5B)

The patches drop into an Armbian build tree as **userpatches** (zero edits to
Armbian's own files — see [`docs/04`](docs/04-armbian-packaging.md)):

```bash
# 1. Place the patches in your Armbian build tree:
cp patches/rk3588-rkvenc2-0*.patch \
   <armbian-build>/userpatches/kernel/archive/rockchip64-6.18/

# 2. Build (ccache ON; USE_CCACHE must be an ARG, not an env var — see docs/06):
bash scripts/build-combined-kernel.sh        # wraps ./compile.sh ... USE_CCACHE=yes

# 3. Install + reboot + validate on the board:
sudo bash scripts/install-combined-kernel.sh # dpkg -i the image/dtb/headers debs
sudo reboot
sudo bash scripts/validate-combined.sh       # checks /dev/mpp_service, 4 cores, /dev/rga

# 4. (optional) run ffmpeg-rockchip without sudo:
sudo cp scripts/99-rockchip-codec.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

A green `validate-combined.sh` shows `rkvenc-core0/1`, `rkvdec-core0/1`, and
`/dev/rga`. Then `tests/` exercises real frames.

## Provenance & licensing

- The driver code is forward-ported from Rockchip's GPL-2.0 BSP MPP framework
  (`rockchip-kernel` `drivers/video/rockchip/mpp/`) and `airockchip/librga`'s
  kernel driver. It is GPL-2.0, like the kernel.
- `librga`'s **userspace** library **is** open source (Apache-2.0) — the
  implementation is published in the JeffyCN mirror lineage
  (`JeffyCN/mirrors:linux-rga-multi`, maintained as a buildable mirror at
  `tsukumijima/librga-rockchip`). Rockchip's *official* `airockchip/librga` repo
  confusingly ships only a prebuilt `.so` + headers + samples, so we linked its
  prebuilt aarch64 `.so` for convenience — but you can build from source. See
  [`ffmpeg/README.md`](ffmpeg/README.md) and `docs/06`.
- The mainline RGA-in-U-Boot / RGA-V4L2 context is courtesy of Collabora's
  RK3588 upstreaming work.

This repo is the *integration + analysis*; the heavy lifting on the drivers is
Rockchip's.
