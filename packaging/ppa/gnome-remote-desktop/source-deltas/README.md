# GRD source deltas

This directory preserves source changes needed to reconstruct historical PPA
snapshots that were exported from dirty local GRD worktrees. The tracked file
below is historical; current packaging does not apply a source delta by
default.

## Current exporter pin

The helper currently archives
`GRD_COMMIT=2571326322c754de7608ef4afb1dff8e4d031cbd` as
`50.1+rkmpp+git20260717.2571326`. That commit is clean, but it is not advertised
by a public branch or tag: a 2026-07-19 `git ls-remote` check found the public
reconnect base only at `rdp-handover-reconnect-v2@eb91daf476dc`.

Use Launchpad source publication `18626586` for a byte-exact reconstruction of
the `~exp3` source package. For code review, the public
`c14e09ef67e916ae83a4eddee6a56591078e78e0` base plus tracked patches
`0001`–`0015` under
[`../../../../apps/gnome-remote-desktop/patches/`](../../../../apps/gnome-remote-desktop/patches/README.md)
recreates the compiled source. It intentionally lacks two documentation-only
changes from the GRD checkout and therefore is not a replacement orig tarball.
The default helper still needs a checkout containing `2571326`; override
`GRD_REPO`, `GRD_COMMIT`, `GRD_UPSTREAM_VERSION`, and `GRD_DELTA` together for
any other snapshot.

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

The default helper instead exports the `2571326` snapshot documented above,
with an empty `GRD_DELTA`.
