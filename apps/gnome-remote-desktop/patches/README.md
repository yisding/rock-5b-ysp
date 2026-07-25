# gnome-remote-desktop release patches

> **OUTDATED — this directory is not what the package builds, and it is a
> release behind.** These patches target **50.1**; the shipped package is
> **50.2**, built directly from branch `release/50.2-rkmpp` at
> `cf60b4d9d2c5adb6ea9f4b7f3397449895f069f2` with **no source delta applied**.
> Parts of the replay are now actively wrong against the current base: upstream
> 50.2 already contains the reconnect revert that patch `0009` exists to apply.
>
> Editing anything here changes nothing about the package. Keep it for porting
> the work to another base and for reading what the delta *was*. To change what
> ships, commit on `release/50.2-rkmpp` and update `GRD_COMMIT` /
> `GRD_UPSTREAM_VERSION` in
> [`packaging/ppa/build-source-packages.sh`](../../../packaging/ppa/build-source-packages.sh);
> see [`packaging/userspace-patches.md`](../../../packaging/userspace-patches.md).

This directory contains the portable **16-patch 50.1 replay** for the RK3588
FFmpeg/rkmpp backend, RDP handover/reconnect fixes, and the two bounded runtime
recoveries retained after hardware validation.

The current package source is public branch `release/50.2-rkmpp` at
`cf60b4d9d2c5adb6ea9f4b7f3397449895f069f2`: 15 authored release commits on
upstream 50.2 commit `60423c896a54e3eacb65bd93167e91c1ce5e648c`. Upstream
50.2 already contains the reconnect revert represented by replay patch `0009`,
so the package archives that branch directly and does not apply this directory.

The series applies to upstream gnome-remote-desktop commit
`c14e09ef67e916ae83a4eddee6a56591078e78e0` (`50.1` plus 16 commits). It does
not apply to the pristine `50.1` tag: the base includes the VA-API revert needed
by `0003` and the GNOME 50 reconnect change that `0009` reverts.

The replay tip is `5f61bb6` on branch `release/50.1-rkmpp`. The root of this
directory intentionally contains only the portable release replay.
Investigation-only watchdogs and audio probes are preserved under
[`archive/`](archive/) and are not applied by the package build.

> These patches change gnome-remote-desktop userspace. The kernel drivers that
> provide `/dev/mpp_service` live under
> [`kernel-drivers/patches`](../../../kernel-drivers/patches).

## Release series

| Range | Purpose |
|---|---|
| `0001`–`0003` | Add, initialize, and select the FFmpeg/rkmpp H.264 encode backend after VA-API. |
| `0004`–`0006` | Make the backend usable with panvk/panfrost: base DRM modifier queries, dma-heap NV12 surfaces, and an uncached host-memory fallback. |
| `0007` | Configure the mainline rkmpp encoder for usable first-frame and VBR output. Its startup recreation is superseded by `0015` when using the matching packaged FFmpeg. |
| `0008` | Bound hardware-encoder backpressure, drop stale work, and temporarily fall back to software before retrying AVC. |
| `0009`–`0013` | Restore the GNOME 50 handover protocol and fix variant ownership, socket lifetime, timeout cleanup, and pending-connection coalescing. |
| `0014` | Fix the RK3588 readback cliff by copying an imported texture into cached driver-owned storage before `glReadPixels`. |
| `0015` | Reuse the smoke-tested encoder, request IDRs without recreating MPP, and turn hardware encode failures into the existing bounded software cooldown. Requires the matching bounded-wait FFmpeg package (`540657970e` or newer). |
| `0016` | After a real RDPGFX acknowledgement resume, recover only if decoded-frame progress remains stalled for two seconds; clear stale ACK history and force a full refresh. |

`0014` is the hardware-verified root fix for the Firefox/readback wedge. The
periodic pipeline monitor that helped find it was deliberately removed from the
release series. `0016` retains only the progress-gated recovery and its warning
when recovery actually fires; routine suspend/resume logging was removed.

The release also restores the upstream AAC/Opus/PCM audio offer. It contains no
per-format dump, no end-to-end audio tracing, no Opus suppression, and no
runtime legacy-format probe.

## Validation

- Applying the 16 patches to `c14e09e` reproduces the release branch tree
  exactly.
- Debian source and native arm64 binary package builds pass with the system
  multiarch `pkg-config` metadata.
- The RDP integration test passes. TPM and hardware-EGL tests skip as expected
  on the build host; no test fails.
- Packaged-string inspection confirms the investigation log/probe strings are
  absent, and Lintian reports only long-filename warnings.

## Apply

```bash
cd gnome-remote-desktop
git checkout c14e09ef67e916ae83a4eddee6a56591078e78e0
git am /path/to/rock-5b-ysp/apps/gnome-remote-desktop/patches/00*.patch
```

For Debian quilt packaging, copy only the root-level patches:

```bash
cp /path/to/rock-5b-ysp/apps/gnome-remote-desktop/patches/00*.patch \
  debian/patches/
find debian/patches -maxdepth 1 -name '00*.patch' -printf '%f\n' | sort \
  >> debian/patches/series
```

The async-PBO and memfd experiments in [`reference/`](reference/) are raw
working-tree diffs, not release commits.

## Reconnect boundary

The obsolete `rdp-handover-reconnect@a3a1a32` experiment treated a routing
token as globally single-use and preserved displays on abort. That broke the
normal two-leg GDM-to-session transition. The release series instead restores
GNOME's 50.2 protocol revert in `0009` and coalesces duplicates only while a
socket is awaiting `TakeClient` in `0013`. Consuming the socket clears pending
state, so the routing token remains reusable for the legitimate next leg.
