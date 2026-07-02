# gnome-remote-desktop/patches/

The **complete** patch set that adds the FFmpeg/rkmpp H.264 encode backend to
gnome-remote-desktop — seven commits from the
[`ffmpeg-rkmpp-encode-backend`](https://gitlab.gnome.org/yding/gnome-remote-desktop/-/commits/ffmpeg-rkmpp-encode-backend)
branch of the GNOME fork `gitlab.gnome.org/yding/gnome-remote-desktop`, as
`git format-patch`. They apply, in order, on **pristine upstream GRD 50.1**
(verified with `git am`). (Note this is a *different* pin than
[`../capture-path.md`](../docs/capture-path.md)'s line anchors, which resolve
against `50.1`+16 — see its header.)

> These change the gnome-remote-desktop **userspace**. The *kernel* drivers that
> make `/dev/mpp_service` exist are in [`../../kernel-drivers/patches/`](../../kernel-drivers/patches/).

| # | Patch | Files | What |
|---|-------|:-----:|------|
| 0001 | `...-add-ffmpeg-rkmpp-h.264-encode-...` | 10 | The backend: `GrdEncodeSessionFfmpeg` + `GrdHwAccelFfmpeg` — h264_rkmpp via the libavcodec C API, DRM-PRIME NV12 zero-copy, 1-in-1-out, fixed-QP intent, the `-Dffmpeg` meson feature. |
| 0002 | `rdp-renderer-initialize-...` | 2 | Bring the FFmpeg hwaccel up in the renderer alongside VA-API/NVENC. |
| 0003 | `rdp-render-context-select-...` | 1 | Pick the FFmpeg session **after** VA-API (VA-API stays preferred); the gate that falls back to RFX. |
| 0004 | `hwaccel-vulkan-query-the-base-drm-format-modifier-list` | 1 | **Unblocks the Mali GPU.** Query the base `VkDrmFormatModifierPropertiesListEXT`, not the `…List2` variant panvk leaves empty. See [`../design.md`](../docs/design.md) §journey. |
| 0005 | `encode-session-ffmpeg-allocate-nv12-surfaces-from-the-dma-heap` | 1 | panfrost GBM can't allocate NV12 → allocate from the dma-heap, lay out Y/UV by hand, 64-byte stride align (panvk + MPP). |
| 0006 | `rdp-view-creator-avc-fall-back-when-host_cached-...` | 1 | Retry the readback buffer without `HOST_CACHED` (panvk has no cached host memory type). |
| 0007 | `encode-session-ffmpeg-make-the-mainline-rkmpp-encoder-…` | 1 | The two **mainline-rkmpp** runtime fixes: first-frame IDR (recreate the encoder) + VBR quality (`rc_max_rate`/`rc_min_rate` + target). See [`../README.md`](../README.md) #1, #2. |

`0001`–`0003` are the backend; `0004`–`0006` are the panvk/hardware-enablement
fixes ([`../design.md`](../docs/design.md)); `0007` is the mainline-rkmpp runtime fix
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
- **The handover-reconnect fix (cherry-picked, broke on 50.1, reverted —
  parked on the fork awaiting upstreaming).** This is **our own fix**, not an
  unrelated upstream change: commit `a3a1a32`
  (`a3a1a32a56a3b6500b5e406c5c4b40c7f4eeef76`, 2026-06-27,
  "rdp: make handover reconnect cleanup robust"), on the fork branch
  [`rdp-handover-reconnect`](https://gitlab.gnome.org/yding/gnome-remote-desktop/-/commits/rdp-handover-reconnect).
  It hardens `GrdDaemonSystem`'s system-daemon↔handover-daemon client handoff
  (+130/−7 across `grd-daemon-system.c` + `grd-daemon-handover.c`), fixing,
  per the diff:
  - a **`GSocketConnection` ref leak** in `on_take_client_finished()`
    (`g_autoptr`);
  - `TakeClient` with no redirected connection now returns
    **`G_IO_ERROR_CLOSED`** instead of dereferencing a NULL
    `socket_connection`;
  - a **`client_taken` flag** so stale duplicate redirected connections on a
    single-use routing token (mstsc opens several connections) are discarded
    instead of spawning a second handover/duplicate session;
  - retried redirected connections **replace** the still-pending socket
    *without* re-emitting `TakeClientReady` (a second
    `TakeClient`/`GetSystemCredentials` cycle could clobber credentials), and
    each fresh connection **re-arms the abort timer**;
  - on abort: `handover_is_waiting` is cleared on **both** src/dst handover
    D-Bus interfaces, a client that already has a registered remote display is
    **preserved** rather than removed, and a direct `abort_handover()` call no
    longer leaves a live timeout source firing on the freed client.

  **History:** the identical patch body was cherry-picked onto this 50.1-based
  backend branch as `4e0d599` (2026-06-29) and reverted the next day
  (`afc8f55`, 2026-06-30) after it **broke GDM→session handover** in testing —
  net zero, so it isn't in this series. *Why* it broke on 50.1 was never
  root-caused (UNVERIFIED); a plausible factor is that the fix was authored on
  `50.1`+16 (`c14e09e`), whose upstream commit `5230bf3` ("daemon-system:
  Simplify remote display reconnection handling", −15 lines in
  `grd-daemon-system.c` incl. dropping the `SetRemoteId` API) is absent from
  the 50.1 base. The rebased fix sits on the fork branch
  above (tip `a3a1a32`, on `50.1`+16) awaiting upstream submission — status:
  [`../../status.md`](../../status.md).

  The **deb** still carries the revert as a quilt patch, because its `orig`
  snapshot happened to include the cherry-pick — see
  [`../../packaging/ppa/`](../../packaging/ppa/).
