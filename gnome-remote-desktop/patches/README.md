# gnome-remote-desktop/patches/

The GRD source changes, as `git format-patch` of the two commits on the
`ffmpeg-rkmpp-encode-backend` branch (GNOME `yding/` fork). These are the
`debian/patches/` (3.0 quilt) carried by the `gnome-remote-desktop 50.1+rkmpp-2`
package — they apply on top of upstream **50.1 + the rkmpp encode backend**.

> These are *not* kernel patches. The kernel drivers are in the top-level
> [`patches/`](../../patches/). These change the gnome-remote-desktop userspace.

| File | Fixes | Detail |
|------|-------|--------|
| `0001-Revert-rdp-make-handover-reconnect-cleanup-robust.patch` | Reverts a cherry-picked handover-reconnect change (`4e0d599`) that broke the basic GDM→session handover (stall, refcount underflow, zombie displays). | Back to stock 50.1 handover. |
| `0002-encode-session-ffmpeg-make-the-mainline-rkmpp-encode.patch` | The two mainline-rkmpp fixes: **first-frame IDR** (recreate the encoder after the smoke test) and **VBR quality** (`rc_max_rate`/`rc_min_rate` + higher target). | [`../README.md`](../README.md) bugs #1 and #2 |

Both changes live in `src/grd-encode-session-ffmpeg.c` (patch 02) and the
handover daemons (patch 01). They are **no-ops on the ffmpeg-rockchip fork**,
which already does fixed-QP and honours forced IDR — see the mainline-vs-fork
table in [`../README.md`](../README.md).

## Apply

```bash
# On top of an upstream gnome-remote-desktop 50.1 tree that already carries the
# rkmpp encode backend (GrdEncodeSessionFfmpeg / GrdHwAccelFfmpeg):
cd gnome-remote-desktop
git am /path/to/000{1,2}-*.patch
# or, as quilt patches in a Debian source package:
cp 000{1,2}-*.patch debian/patches/ && \
  printf '%s\n' 000{1,2}-*.patch | sed 's#.*/##' >> debian/patches/series
```

The bug **#3** greeter fix is not here — it is a udev rule, packaged separately as
[`packaging/gdm-hwenc/`](../../packaging/gdm-hwenc/).
