# GRD source deltas

This directory captures source changes needed to reconstruct PPA source snapshots
that were exported from dirty local GRD worktrees.

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

The PPA helper applies this patch automatically by default:

```bash
bash packaging/ppa/build-source-packages.sh grd
```

Override `GRD_REPO`, `GRD_COMMIT`, and `GRD_DELTA` together only when rebuilding
from a different GRD source state.
