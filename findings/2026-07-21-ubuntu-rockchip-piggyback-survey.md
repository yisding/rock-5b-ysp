# ubuntu-rockchip (Joshua Riek) survey: a working Chromium V4L2-stateful-over-MPP bridge exists, the project is archived, and per-app reuse is now mapped

> Scope: Joshua Riek's ubuntu-rockchip image builder, both Launchpad PPAs
> (`ppa:jjriek/rockchip`, `ppa:jjriek/rockchip-multimedia`), the
> `linux-rockchip` kernel branches, `ubuntu-rockchip-settings`, and the
> extracted debian packaging of the multimedia stack (chromium-browser
> `+rkmpp7`, libv4l-rkmpp 1.6.0, v4l-utils `+noble4`, ffmpeg
> `+git20240717`, mpv `+noble4`, kodi `+gles1`, vlc, obs-studio,
> gstreamer1.0-rockchip, gst-plugins-base, rockchip-multimedia-config)
> Source: `github.com/Joshua-Riek/ubuntu-rockchip@38dfb49` (clone at
> `~/Code/rock-5b/ubuntu-rockchip`), `~/Code/rock-5b/ubuntu-rockchip-settings`, PPA source
> packages extracted under `downloads/ubuntu-rockchip-ppa/x/` (git-ignored),
> Launchpad + GitHub API queries of 2026-07-21
> Date: 2026-07-21
> Trust: SOURCE-INSPECTED / CONFIG-INSPECTED for everything read in the
> packaging; INFERRED for modern-Chromium/mpv/Kodi portability judgments;
> UNVERIFIED for upstream-Chromium code-removal timelines (from model
> knowledge, not diffed against Chromium trees)

## Result

ubuntu-rockchip solved the hardest problem in the
[app enablement map](../docs/app-enablement.md) — Chromium hardware decode on
a vendor-BSP kernel — with a **userspace V4L2-stateful-over-MPP bridge**
(`libv4l-rkmpp`), not a kernel driver and not VA-API. The bridge is
board/kernel-agnostic userspace over `librockchip_mpp` and would run on the
ysp 6.18 forward-port kernel as-is. The Chromium-side patches, however, target
the legacy VDA path deleted from upstream Chromium (~M121–126), so the browser
integration must be re-targeted, not rebased. The project itself is **archived
and frozen** (GitHub-archived ~2025-09, multimedia PPA frozen mid-2024,
kernels last touched 2025-03), so it is a static quarry, not a moving target.
Their modern-Ubuntu images (oracular/plucky, mainline 6.11) dropped the BSP
video stack entirely — all hardware-video value is in the jammy/noble line.

## 1. Project state

- `ubuntu-rockchip` GitHub repo: archived, last push 2025-09-13, last
  substantive commit 2025-04-06.
- `ppa:jjriek/rockchip`: kernels `linux-rockchip` 5.10 (jammy), 6.1 (noble),
  6.11 (oracular/plucky, shared build), u-boot packages, firmware, meta.
- `ppa:jjriek/rockchip-multimedia`: the whole app stack, **jammy/noble only**,
  frozen mid-2024.
- oracular/plucky (mainline 6.11): `CONFIG_VIDEO_HANTRO` + mainline V4L2 RGA +
  Panthor, **no MPP/mpp_service, no multimedia PPA builds** — those images
  have no hardware video path at all.

## 2. The browser stack (the headline finding)

Architecture, with the interface at each seam:

```
Chromium 114 GPU process
  V4L2VideoDecodeAccelerator (legacy stateful VDA; direct-VD force-disabled)
    │ seam 1: v4l2_open/ioctl/mmap on /dev/video-dec0|enc0 via dlopen'd libv4l2
patched libv4l2 (v4l-utils + 6 Rockchip patches; plugin-ops ABI gains .mmap)
    │ seam 2: libv4l_dev_ops plugin ABI
libv4l-rkmpp (userspace emulation of the V4L2 stateful M2M contract)
    │ seam 3: MPP mpi API (decode_put_packet/get_frame, buffer groups, enc cfg)
librockchip_mpp
    │ seam 4: vendor ioctls on /dev/mpp_service (+ dma-heap, optional /dev/rga)
BSP kernel
```

Key mechanics (all SOURCE-INSPECTED in `libv4l-rkmpp` 1.6.0):

- The "device nodes" `/dev/video-dec0`/`/dev/video-enc0` are **plain text
  files** written by a udev-triggered script when `/dev/mpp_service` appears
  (`rockchip-multimedia-config`); contents are plugin options
  (`type=dec`, `codecs=VP8:VP9:H.264:H.265:AV1`, `max-width=7680`, …). The
  plugin refuses real char devices and replaces the fd with an epoll-wrapped
  eventfd via `dup2()` so application `poll()` works.
- Decode: H.264/HEVC/VP8/VP9/AV1 → **NV12 only**; buffers are internal MPP DRM
  buffers; `EXPBUF` returns a dup of the MPP dmabuf fd, so **zero-copy DRM
  PRIME export is real** (MMAP+EXPBUF path). DMABUF/USERPTR queue memory falls
  back to RGA-blit or memcpy.
- Encode: NV12M/YUV420M/YUYV/UYVY → **H.264 and VP8 only, max 1920×1088**,
  with a rich V4L2-ctrl → `mpp_enc_cfg` mapping.
- **Chromium-114-specific hacks are baked in**: flush is detected by
  Chromium's magic `-2` timestamp, `VIDIOC_DECODER_CMD` (`V4L2_DEC_CMD_STOP`,
  the standard stateful flush) is unimplemented, `V4L2_BUF_FLAG_LAST` is
  absent. README says outright it may not work for other apps.
- **No kernel-V4L2 dependency whatsoever** — requirements are exactly: working
  `librockchip_mpp` over `/dev/mpp_service`, mmap-able dmabuf MPP buffers,
  dma-heap permissions, optional legacy `/dev/rga`. Portability to the ysp
  6.18 forward-port kernel is by construction.
- Requires the **patched libv4l2**: v4l-utils patch 1 extends the libv4l
  plugin ops struct with `.mmap` (ABI extension); stock distro libv4l2 cannot
  drive the plugin. Five further patches add DMABUF/EXPBUF pass-through,
  mplane filtering, builtin plugins, and conversion-off-by-default.
- Deployment glue also includes an ugly load-bearing hack: `postinst` copies
  `libv4l2.so.0.0.0` to `/usr/lib64/libv4l2.so` because Chromium dlopens the
  unversioned name.
- Upstream `JeffyCN/libv4l-rkmpp` is newer than Riek's pin: 1.8.0
  (2025-01-08), last push 2025-04-30 (seek fix, VP9 alignment). Riek ships
  1.6.0~git20240104.

Chromium side: ~20 patches (authored by Jeffy Chen / Rockchip, one by Igalia,
lineage shared with JeffyCN meta-rockchip — not FydeOS), GN args
`use_v4l2_codec=true use_v4lplugin=true use_linux_v4l2_only=true`, and a hard
package dependency on `libv4l-rkmpp`. Roughly: 5 patches enable/extend the
legacy VDA on Linux (incl. HEVC and AV1 fourcc mappings), 3 wire libv4l2 into
the V4L2 device layer (mmap, POLLIN-instead-of-POLLPRI for the eventfd), 6 are
Mali-blob/ozone workarounds (force validating GL decoder, disable modifiers,
fence workarounds), the rest camera/build fixes.

**Why it does not rebase**: the patches pin Chromium's legacy
`V4L2VideoDecodeAccelerator` path and force-disable the ChromeOS direct video
decoder. Upstream deleted the VDA path (~M121–126; UNVERIFIED timeline) and
also removed libv4l2 support and `generic_v4l2_device.cc`. The modern
replacement, `V4L2StatefulVideoDecoder`, speaks exactly the stateful contract
the plugin emulates — so a **re-target** is plausible: re-add a small libv4l2
(or open/ioctl-redirect) shim in `media/gpu/v4l2`, enable V4L2 stateful on
desktop arm64, and implement real `DECODER_CMD`/`FLAG_LAST`/EOS semantics in
libv4l-rkmpp. Rough estimate: 2–4 weeks Chromium-side + 1–2 weeks plugin-side
for someone comfortable in `media/gpu`, plus a permanent per-milestone rebase
tax and hours-long arm64 Chromium builds per iteration (INFERRED).

**Firefox cannot ride this bridge**: its ARM hardware path is FFmpeg
`v4l2m2m`, which raw-`open()`s `/dev/video*` char devices and never routes
through libv4l2 plugins; the plugin also explicitly rejects char devices. Both
ends would need work; Firefox remains VA-API-or-nothing in practice.

### V4L2-stateful bridge vs a VA-API bridge (decision framing)

| | V4L2 stateful bridge (libv4l-rkmpp) | VA-API bridge (hypothetical) |
|---|---|---|
| Semantic fit to MPP | Near 1:1 (MPP is itself stateful packet-in/frame-out) — thin shim, ~4k lines | Mismatch: caller parses slices and owns surface/DPB management; bridge must reconstruct bitstream and lash MPP's internal buffer lifecycle to caller-owned surfaces |
| Bridge-side effort | Exists; modernization ~1–2 weeks | Months, per-codec |
| App-side effort | Large and perpetual: Chromium patch stack, rebased every milestone; other V4L2 consumers (FFmpeg v4l2m2m, GStreamer v4l2) bypass libv4l2 and cannot reach it | Zero: libva's sanctioned plugin point is a userspace driver `.so`; every VA-API app (Firefox, Chromium, VLC, mpv, GStreamer, OBS, Electron) works unpatched |
| Deployment | Patched system libv4l2 + fake /dev text files + custom Chromium builds | One driver `.so` |
| Practical reach | Chromium only | The Linux desktop |

Third option unchanged: a real kernel V4L2 *stateless* driver (mainline
rkvdec2, the maxline track) makes stock Chromium/GStreamer work with zero
patches, at the cost of leaving the BSP kernel.

## 3. Per-app packaging findings and reuse verdicts

| Package (theirs) | What they actually did | Reuse for ysp |
|---|---|---|
| ffmpeg `6.1.1+git20240717` | nyanmisaka ffmpeg-rockchip as a 54-patch quilt series (half are fixups) on Ubuntu's source; same binary names/SONAMEs, archive version override, no symbols churn; `--enable-rkmpp --enable-rkrga` | Nothing technical — ysp's 8.x fork is the same lineage, newer. Confirms the PPA version-override discipline ysp already uses |
| mpv `0.36+noble4` | Rebuild + 4 small patches: reorder `add_all_hwdec_methods()` so `AV_CODEC_HW_CONFIG_METHOD_INTERNAL` wins (this is what makes `--hwdec=rkmpp` register), NV16/P010/P210 drmprime formats; ships `/etc/mpv/mpv.conf`: `hwdec=rkmpp`, `vo=gpu`, `gpu-context=x11egl`, `vf-add=scale_rkrga=force_yuv=auto` (their 10-bit/HDR fix) | High value, 1–2 days: re-diff the method-priority patch against current mpv (hwdec selection reworked post-0.37; formats may be upstream), re-evaluate `x11egl` for Wayland, keep the conf-defaults idea. `force_yuv=auto` intersects the ysp RGA 10-bit work (W13) |
| Kodi `20.4+gles1` | One binary with `-DCORE_PLATFORM_NAME="x11 wayland gbm"`, `APP_RENDER_SYSTEM=gles` on arm64 (stock Debian behavior), system ffmpeg; **two boogie/hbiyik patches**: GBM dynamic DRM-plane selection by format/modifier + zpos, and AFBC crop-offset passthrough to `SRC_X/SRC_Y` plane props; a wayland-session desktop file | The two boogie patches address exactly what the ysp `apps/kodi` GBM/DRMPRIME tty1 gate will hit; check Kodi 22 upstream absorption first (plane selection was reworked). AFBC-crop only matters if rkmpp decoders emit AFBC. Rules pattern liftable; ysp can build GBM-only, simpler |
| VLC `3.0.18-4` | **Plain rebuild for ffmpeg 6.0, zero rockchip patches** (verified against changelog + full series) | Nothing. Independently confirms the app-enablement verdict: VLC HW decode is from-scratch work nobody has done |
| gstreamer1.0-rockchip `1.14+git240423` | rockchip-linux/JeffyCN gstreamer-rockchip snapshot: `mppvideodec`, `mppjpegdec`, `mpph264enc`, `mpph265enc`, `mppvp8enc`, `mppjpegenc` at `GST_RANK_PRIMARY+1`, plus `rkximagesink`, `kmssrc`; no rgaconvert element; AFBC off by default; crude dh9 packaging | Source is the standard GStreamer-MPP choice; ~1 day to repackage cleanly and test against GStreamer 1.26. Decide deliberately whether PRIMARY+1 (auto-hijacks playbin) is wanted on a GNOME desktop |
| gst-plugins-base `+noble` | Single Jeffy Chen patch: RGA fast-path inside `video-converter.c`, env-gated `GST_VIDEO_CONVERT_USE_RGA=1`, off by default; links libgstvideo against librga | Skip — soft-forks a core library for an off-by-default path |
| obs-studio `30.0.2+noble` / obs-gstreamer | OBS changelog claims "Add rockchip patches" but the tarball contains **none** (verified) — rebuild only. Encode there = user-constructed `mpph264enc` pipelines via stock obs-gstreamer | Nothing to take; confirms OBS encode needs a (small) new obs-ffmpeg patch whitelisting `h264_rkmpp`/`hevc_rkmpp` against the ysp fork |
| celluloid / clapper | Pure rebuilds against their mpv/gstreamer | Pattern only |
| rockchip-multimedia-config | udev: `/dev/mpp_service` → group video 0660 + RUN script creating the text "device nodes"; `rga` + dma-heap nodes (`system`, `cma`, `system-dma32`, `system-uncached*`) opened up; `/usr/lib64/libv4l2.so` loader hack | The udev/dma-heap permission contract is worth comparing against ysp `packaging/codec-udev`; the rest only matters if the bridge is revived |

## 4. Kernel, U-Boot, settings

- `linux-rockchip` branches: jammy=5.10.209 BSP, noble/cm3=6.1.75 BSP (full
  vendor `drivers/video/rockchip`: mpp, rga2/3, iep, rve, …,
  `ROCKCHIP_MPP_SERVICE=y`, Mali blob KMD built in), oracular=**mainline
  v6.11 + a one-day stack of ~40–60 enablement patches committed 2024-09-16**
  including Detlev Casanova's V4L2 stateless rkvdec2 series, RK3588
  Hantro VEPU121, Synopsys HDMI RX, hdptx PHY clock patches. No plucky branch
  (reuses oracular build).
  - Reuse: the noble branch is an Ubuntu-packaged reference of the vendor
    MPP/RGA stack with a known-good config (comparison baseline for the ysp
    forward-port; it is Rockchip's own 6.1 content, not a port beyond 6.1).
    The oracular branch is a compact curated list of pre-6.12 mainline RK3588
    enablement to diff against the maxline 7.2-rc3 manifest.
  - Packaging: real Ubuntu-native kernel packaging (`debian.rockchip/`,
    ABI-versioned `Ubuntu-rockchip-6.1.0-1027.27`) — an alternative pattern to
    the Armbian-based ysp kernel packaging.
- U-Boot (`u-boot-radxa-rk3588`, vendor 2017.09 `next-dev-v2024.03` + pinned
  rkbin): `debian/rules` builds per-board `idbloader.img`/`u-boot.itb` **and a
  16MiB `rkspi_loader.img` containing a GPT with Radxa's SPI layout**
  (idbloader @s64, `vnvm`, `uboot_env` @s8128, uboot @s16384); every deb ships
  `/usr/bin/u-boot-install` (dd, image offsets) and `u-boot-install-mtd`
  (`flashcp --partition … /dev/mtd0`). Image layout: GPT, root at 16MiB
  (partition typed as ESP so u-boot bootstd scans it), u-boot raw in the gap,
  **u-boot-menu/extlinux** (no grub/flash-kernel), `x-systemd.growfs`.
  Directly comparable material for the boot-firmware SPI/SD investigation.
- `ubuntu-rockchip-settings`: no hidden Chromium GPU/V4L2 launch flags (only
  first-run prefs; acceleration lives entirely in the patched packages).
  Stealable bits: HDMI/DP/es8316 udev `SOUND_DESCRIPTION` naming rules,
  CPU/GPU performance-governor oneshots (jammy/noble only), and
  `ubuntu-rockchip-install`, a running-system → SD/eMMC/NVMe copier that
  writes u-boot at the same offsets.

## 5. Consequences for the ysp app-enablement map

Recorded in [`docs/app-enablement.md`](../docs/app-enablement.md) (revised
2026-07-21):

1. "No V4L2 bridge exists" was wrong in a useful way: a Chromium-scoped
   **userspace stateful bridge exists and is kernel-agnostic**; the browser
   question on the BSP kernel becomes "modernize libv4l-rkmpp + re-target
   modern Chromium" (~3–6 weeks + rebase tax) vs "write a VA-API bridge"
   (months, whole desktop) vs "maxline kernel + stock Chromium".
2. mpv and Kodi enablement now have concrete, tested patch material to start
   from rather than blank-page estimates.
3. VLC and OBS non-support is independently confirmed — ubuntu-rockchip
   shipped rebuilds and never solved either.
4. GStreamer has a packaged known-working plugin source (gstreamer-rockchip)
   one clean repackage away.

## Local artifacts

- Builder clone: `~/Code/rock-5b/ubuntu-rockchip@38dfb49` (archived upstream).
- Settings clone: `~/Code/rock-5b/ubuntu-rockchip-settings`.
- All PPA packaging + extracted trees:
  `downloads/ubuntu-rockchip-ppa/` (`x/` holds extractions; git-ignored).
  Reconstruction: Launchpad API `getPublishedSources` on the two PPAs named
  in the Scope, then `sourceFileUrls` per publication.
