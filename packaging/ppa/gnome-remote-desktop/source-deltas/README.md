# gnome-remote-desktop source deltas

The normal package export no longer uses a source delta. It archives the clean
release commit directly:

```text
GRD_COMMIT=24f4392bb0daa40b9c411de1b1bcb9d0078e506a
GRD_UPSTREAM_VERSION=50.2+rkmpp+git20260729.14.24f4392
GRD_DELTA=
```

That commit is the public `release/50.2-rkmpp` branch: upstream 50.2 commit
`60423c8` plus 16 release commits, including the promoted full-range BT.709
AVC signaling fix. The older 50.1 reconstruction remains
available as the 16 root-level patches under
[`../../../../apps/gnome-remote-desktop/patches/`](../../../../apps/gnome-remote-desktop/patches/README.md).
Investigation patches under `patches/archive/` are deliberately excluded.

`GRD_DELTA` remains supported only for historical reconstruction. It accepts
colon-separated patch paths and applies them in order before the orig tarball
is created.

## Historical dirty snapshot

[`dirty20260706-worktree.patch`](dirty20260706-worktree.patch) preserves the
tracked-file delta used by the old normal-PPA package based on
`a59c904c99088235eb4de31ca340747d334494f3`. It is not part of the release.

```bash
GRD_REPO=/path/to/gnome-remote-desktop \
GRD_COMMIT=a59c904c99088235eb4de31ca340747d334494f3 \
GRD_UPSTREAM_VERSION=50.1+rkmpp+git20260630.a59c904+dirty20260706 \
GRD_DELTA="$PWD/packaging/ppa/gnome-remote-desktop/source-deltas/dirty20260706-worktree.patch" \
bash packaging/ppa/build-source-packages.sh grd
```

The audio-format and pipeline investigation patches used by later experimental
packages are preserved under
[`apps/gnome-remote-desktop/patches/archive/`](../../../../apps/gnome-remote-desktop/patches/archive/README.md),
not here.
