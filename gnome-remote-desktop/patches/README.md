# gnome-remote-desktop/patches/

The **complete** patch set that adds the FFmpeg/rkmpp H.264 encode backend to
gnome-remote-desktop — seven commits from the `ffmpeg-rkmpp-encode-backend`
branch (GNOME `yding/` fork), as `git format-patch`. They apply, in order, on
**pristine upstream GRD 50.1** (verified with `git am`).

> These change the gnome-remote-desktop **userspace**. The *kernel* drivers that
> make `/dev/mpp_service` exist are the top-level [`patches/`](../../patches/).

| # | Patch | Files | What |
|---|-------|:-----:|------|
| 0001 | `…-Add-FFmpeg-rkmpp-H.264-encode-…` | 10 | The backend: `GrdEncodeSessionFfmpeg` + `GrdHwAccelFfmpeg` — h264_rkmpp via the libavcodec C API, DRM-PRIME NV12 zero-copy, 1-in-1-out, fixed-QP intent, the `-Dffmpeg` meson feature. |
| 0002 | `rdp-renderer-Initialize-…` | 2 | Bring the FFmpeg hwaccel up in the renderer alongside VA-API/NVENC. |
| 0003 | `rdp-render-context-Select-…` | 1 | Pick the FFmpeg session **after** VA-API (VA-API stays preferred); the gate that falls back to RFX. |
| 0004 | `hwaccel-vulkan-Query-the-base-DRM-format-modifier-list` | 1 | **Unblocks the Mali GPU.** Query the base `VkDrmFormatModifierPropertiesListEXT`, not the `…List2` variant panvk leaves empty. See [`../DESIGN.md`](../DESIGN.md) §journey. |
| 0005 | `encode-session-ffmpeg-Allocate-NV12-surfaces-from-the-dma-heap` | 1 | panfrost GBM can't allocate NV12 → allocate from the dma-heap, lay out Y/UV by hand, 64-byte stride align (panvk + MPP). |
| 0006 | `rdp-view-creator-avc-Fall-back-when-HOST_CACHED-…` | 1 | Retry the readback buffer without `HOST_CACHED` (panvk has no cached host memory type). |
| 0007 | `encode-session-ffmpeg-make-the-mainline-rkmpp-encoder-…` | 1 | The two **mainline-rkmpp** runtime fixes: first-frame IDR (recreate the encoder) + VBR quality (`rc_max_rate`/`rc_min_rate` + target). See [`../README.md`](../README.md) #1, #2. |

`0001`–`0003` are the backend; `0004`–`0006` are the panvk/hardware-enablement
fixes ([`../DESIGN.md`](../DESIGN.md)); `0007` is the mainline-rkmpp runtime fix
([`../README.md`](../README.md)). Patch `0007` is a **no-op on the ffmpeg-rockchip
fork**, which already does fixed-QP and honours forced IDR.

## Apply

```bash
# on a pristine gnome-remote-desktop 50.1 checkout:
cd gnome-remote-desktop
git am /path/to/000*-*.patch          # all seven, in order
# — or as quilt patches in a Debian source package:
cp 000*-*.patch debian/patches/ && ls 000*-*.patch | sed 's#.*/##' >> debian/patches/series
```

## What's *not* here

- **Bug #3 (greeter access)** is a udev rule, not code — packaged separately as
  [`../../packaging/gdm-hwenc/`](../../packaging/gdm-hwenc/).
- **The handover-reconnect revert.** The branch also cherry-picked an unrelated
  handover-reconnect change that broke GDM→session handover, then reverted it
  (net zero), so it isn't in this backend series. The **deb** still carries the
  revert as a quilt patch, because its `orig` snapshot happened to include the
  cherry-pick — see [`../../ppa/`](../../ppa/).
