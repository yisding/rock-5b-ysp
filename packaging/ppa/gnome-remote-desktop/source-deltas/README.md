# GRD source deltas

This directory preserves source changes needed to reconstruct historical PPA
snapshots that were exported from dirty local GRD worktrees. The tracked file
below is historical; current packaging instead applies the numbered diagnostic
patches from `apps/gnome-remote-desktop/patches/`.

## Current exporter pin

The helper currently archives clean
`GRD_COMMIT=3e4480e066d30ba44015ae1b8cb3bbb92fe6414e`, applies tracked diagnostic
patches `0020` and `0021`, and exports
`50.1+rkmpp+git20260721.10.3e4480e+audiotrace1`. The clean commit is published on
the fork's `main`; the diagnostic package's compiled source is reproducible
from base `c14e09ef67e916ae83a4eddee6a56591078e78e0` plus tracked patches
`0001`–`0021` under
[`../../../../apps/gnome-remote-desktop/patches/`](../../../../apps/gnome-remote-desktop/patches/README.md).

Use Launchpad source publication `18626586` for a byte-exact reconstruction of
the historical `~exp3@2571326` source package. The current default helper needs
a checkout containing `3e4480e` (available on `yding/main`); the tracked
21-patch replay is the portable code-review boundary but is not a
byte-for-byte replacement for the local orig tarball because the source
checkout also contains documentation-only history.
Override
`GRD_REPO`, `GRD_COMMIT`, `GRD_UPSTREAM_VERSION`, and `GRD_DELTA` together for
any other snapshot. `GRD_DELTA` accepts colon-separated patch paths and applies
them in order. Set `GRD_DELTA=` explicitly to omit `0020` and `0021` from a
custom export; also supply the matching upstream version and Debian packaging
when reconstructing an older package such as `exp7`.

## dirty20260706-worktree.patch

Applies to:

```text
repo:   gitlab.gnome.org/yding/gnome-remote-desktop
branch: ffmpeg-rkmpp-encode-backend
commit: a59c904c99088235eb4de31ca340747d334494f3
```

Purpose: the `50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1`
PPA source-package snapshot. It adds the hardware-encode cooldown/fallback,
stale-frame filtering, and full-refresh recovery changes that were present in
the local `grd-ffmpeg` worktree when the source package was generated.

Reconstruction:

```bash
git clone https://gitlab.gnome.org/yding/gnome-remote-desktop grd-ffmpeg
cd grd-ffmpeg
git checkout a59c904c99088235eb4de31ca340747d334494f3
git apply /path/to/rock-5b-ysp/packaging/ppa/gnome-remote-desktop/source-deltas/dirty20260706-worktree.patch
```

To reconstruct that historical snapshot with the current helper, opt in to the
legacy delta explicitly:

```bash
GRD_REPO=/path/to/grd-ffmpeg \
GRD_COMMIT=a59c904c99088235eb4de31ca340747d334494f3 \
GRD_UPSTREAM_VERSION=50.1+rkmpp+git20260630.a59c904+dirty20260706 \
GRD_DELTA="$PWD/packaging/ppa/gnome-remote-desktop/source-deltas/dirty20260706-worktree.patch" \
bash packaging/ppa/build-source-packages.sh grd
```

The default helper instead exports the `3e4480e` snapshot documented above and
uses the colon-separated `0020-rdp-log-every-client-audio-format.patch` and
`0021-rdp-trace-audio-playback-and-disable-opus-offer.patch` series as
`GRD_DELTA`.
