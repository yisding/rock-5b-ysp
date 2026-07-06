# ppa/ - Launchpad source packages for the userspace stack

This directory holds the reproducible Debian packaging for the ROCK 5B
userspace media stack intended for `ppa:yi-ding/ubuntu-rock-5b`.

The kernel side still ships through Armbian userpatches and standalone local
`.debs`; this PPA is for userspace packages that should be built by Launchpad
and installed by `apt`: MPP, librga, FFmpeg with RKMPP/RKRGA, and GRD. The
greeter ACL package remains a local deb or future native PPA wrapper.

## Current State

Last recorded in the public APT indexes and Launchpad API at
`2026-07-06T16:43:41-07:00` and in
[`2026-07-06-ubuntu-rock-5b-upload-log.md`](2026-07-06-ubuntu-rock-5b-upload-log.md):

| Package | Version in this repo | Public PPA state | Notes |
|---------|----------------------|------------------|-------|
| `mpp` | `1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1` | Source index publishes `-0ubuntu2~rk1`; public binary indexes are still empty. | Repacked to remove unused Windows binaries; includes a GCC 15 pthread test fix. |
| `librga` | `2.2.0+git20260703.a632217-0ubuntu3~rk1` | Public APT source index still publishes `-0ubuntu2~rk1`; public binary indexes are still empty. | Launchpad API shows the `-0ubuntu3~rk1` retry source publication as `Pending`, so it had not reached the public APT source index at the last check. |
| `ffmpeg` | `7:8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk1` | Rockchip-81 source package generated, lintian-checked, signed, and held; not in the public PPA source index. | A separate upstream FFmpeg `7:8.1.2-1+rk1` baseline upload is `Pending` in Launchpad's API view, but no FFmpeg source was visible in the public APT source index at the last check. Upload the higher-version Rockchip-81 source only after dependencies and the baseline path settle. |
| `gnome-remote-desktop` | `50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1` | Source packaging imported, source lintian passed, and a local `nocheck` binary build passed against upstream FFmpeg `7:8.1.2-1+rk1`; not uploaded and not public in the PPA source index. | Reconstructed from `GRD_COMMIT` plus [`gnome-remote-desktop/source-deltas/`](gnome-remote-desktop/source-deltas/README.md), so it no longer depends on a dirty dev-box worktree. Wait for the FFmpeg dependency chain before upload, then rebuild once against upstream FFmpeg and once after `ffmpeg-rockchip-81` supersedes it. |
| `gnome-remote-desktop-gdm-hwenc` | local native package exists | Future wave or standalone local deb. | Source lives under [`../gdm-hwenc/`](../gdm-hwenc/README.md). |

Install-facing state: **do not tell users to install from this PPA yet**. The
public `binary-arm64/Packages.gz` and `binary-amd64/Packages.gz` indexes were
empty at the last check, so `apt` cannot install the package set even though
source publications exist.

The PPA targets **resolute** (Ubuntu 26.04 / Armbian userspace) on **arm64**.
The PPA was corrected from its initial amd64-only setup during the 2026-07-06
run; package metadata now marks the imported binary packages as `Architecture:
arm64`.

## Directory Contents

| Path | Purpose |
|------|---------|
| [`build-source-packages.sh`](build-source-packages.sh) | Exports clean upstream git snapshots, overlays the packaging in this repo, and creates unsigned source packages under `/tmp/ubuntu-rock-5b-ppa/artifacts` by default. |
| [`mpp/debian/`](mpp/debian/changelog) | Debian packaging for Rockchip MPP from `mpp-rockchip` commit `1375813c`. |
| [`librga/debian/`](librga/debian/changelog) | Debian packaging for the local `librga-fork` commit `a632217`, including the P010/P210 work. |
| [`ffmpeg/debian/`](ffmpeg/debian/changelog) | Ubuntu/Debian FFmpeg packaging retargeted to the `ffmpeg-rockchip-81` forward-port at `75638e7f0b17`. |
| [`gnome-remote-desktop/debian/`](gnome-remote-desktop/debian/changelog) | Ubuntu/Debian GRD packaging retargeted to the `GRD_COMMIT` + `GRD_DELTA` source snapshot with `-Dffmpeg=enabled`. |
| [`gnome-remote-desktop/source-deltas/`](gnome-remote-desktop/source-deltas/README.md) | Captured tracked-file GRD deltas needed to reconstruct dirty source-package snapshots. |
| [`2026-07-06-ubuntu-rock-5b-upload-log.md`](2026-07-06-ubuntu-rock-5b-upload-log.md) | The detailed build, lintian, signing, upload, Launchpad, and retry log for the current run. |

Generated `.dsc`, `.changes`, `.buildinfo`, orig tarballs, `.deb`, `.ddeb`, and
build directories are intentionally not committed. The script writes them under
`/tmp` unless `OUT=` is set.

## Source Inputs

The helper uses these default local source trees and commits. Override the paths
or pins with the matching environment variables when reproducing the export on a
different machine.

| Source | Default variable | Default value |
|--------|------------------|---------------|
| MPP repo | `MPP_REPO` | `/home/yi/Code/rockchip-userspace/mpp-rockchip` |
| MPP commit | `MPP_COMMIT` | `1375813c` |
| librga repo | `LIBRGA_REPO` | `/home/yi/Code/rockchip-userspace/librga-fork` |
| librga commit | `LIBRGA_COMMIT` | `a632217` |
| FFmpeg repo | `FFMPEG_REPO` | `/home/yi/Code/ffmpeg/ffmpeg-rockchip-81` |
| FFmpeg commit | `FFMPEG_COMMIT` | `75638e7f0b1775193381af0c3187838f6c51dbd1` |
| GRD repo | `GRD_REPO` | `/home/yi/Code/gnome/grd/grd-ffmpeg` |
| GRD commit | `GRD_COMMIT` | `a59c904c99088235eb4de31ca340747d334494f3` |
| GRD dirty delta | `GRD_DELTA` | [`source-deltas/dirty20260706-worktree.patch`](gnome-remote-desktop/source-deltas/dirty20260706-worktree.patch) |

Version strings can also be overridden with `MPP_UPSTREAM_VERSION`,
`LIBRGA_UPSTREAM_VERSION`, `FFMPEG_UPSTREAM_VERSION`, and
`GRD_UPSTREAM_VERSION`.

## Build Source Packages

Build all imported source packages:

```bash
bash packaging/ppa/build-source-packages.sh
```

Build a subset:

```bash
bash packaging/ppa/build-source-packages.sh mpp librga
bash packaging/ppa/build-source-packages.sh ffmpeg
bash packaging/ppa/build-source-packages.sh gnome-remote-desktop
bash packaging/ppa/build-source-packages.sh grd
```

Use a different output directory or source checkout:

```bash
OUT=/tmp/rock5b-ppa \
MPP_REPO=/path/to/mpp-rockchip \
LIBRGA_REPO=/path/to/librga-fork \
FFMPEG_REPO=/path/to/ffmpeg-rockchip-81 \
GRD_REPO=/path/to/grd-ffmpeg \
bash packaging/ppa/build-source-packages.sh
```

The script reuses an existing orig tarball from the artifact directory unless
`FORCE_ORIG=1` is set. That is required for Launchpad: every Debian revision
for the same upstream version must reference byte-identical orig tarball
contents. Before reuse, the helper extracts the existing orig tarball and checks
that its contents match the freshly exported source tree; stale orig tarballs
fail loudly instead of silently changing the source-package delta.

The GRD exporter archives `GRD_COMMIT` and applies `GRD_DELTA` before creating
the orig tarball, because the validation source is marked by the
`dirty20260706` version string. Override `GRD_REPO`, `GRD_COMMIT`, and
`GRD_DELTA` together when rebuilding from a different GRD source state.

## Upload Order

Respect the build-dependency chain:

```text
Wave A  mpp, librga
          wait for librockchip-mpp-dev and librga-dev to publish on arm64
Wave B  ffmpeg-rockchip-81
          wait for libavcodec-dev/libavutil-dev/etc. to publish
Wave C  gnome-remote-desktop
Wave D  gnome-remote-desktop-gdm-hwenc
```

For the normal Rockchip-enabled package flow, do not upload the higher-version
`ffmpeg-rockchip-81` source package until the corrected MPP and librga
development packages are published in the PPA. Launchpad does not automatically
retry builds that fail before dependencies exist. The 2026-07-06 run made one
explicit exception: an upstream FFmpeg `7:8.1.2-1+rk1` baseline source upload
was submitted first so Launchpad could start the baseline path while the
Rockchip-81 source remained held.

Signing and upload are deliberately outside the helper:

```bash
debsign -k <fingerprint> /tmp/ubuntu-rock-5b-ppa/artifacts/*_source.changes
dput ppa:yi-ding/ubuntu-rock-5b /tmp/ubuntu-rock-5b-ppa/artifacts/<package>_source.changes
```

Use the exact files from the artifact directory; the upload log records the
fingerprint and package-specific retry history from the 2026-07-06 run.

## Package Notes

### MPP

The MPP package is based on `mpp-rockchip` tag `1.0.12` / commit `1375813c`.
The source is repacked as `+ds` because unused upstream Windows binaries are
removed before orig tarball creation. The runtime packages are:

- `librockchip-mpp1`
- `librockchip-vpu1`
- `librockchip-vpu0` transitional package
- `rockchip-mpp-demos`
- `librockchip-mpp-dev`

The packaging keeps unversioned linker symlinks in `-dev`, adds a small quilt
patch for GCC 15 pthread start-routine type checking in a test helper, and lists
the upstream static archive in `debian/not-installed` rather than shipping it.

### librga

The librga package is based on the local `librga-fork` commit `a632217`, carrying
the P010/P210 request-generation support recorded under
[`../../vendor-libraries/rga/`](../../vendor-libraries/rga/README.md). It builds:

- `librga2`
- `librga-dev`

The upstream project reports Meson version `2.1.0`, while the package version is
`2.2.0+git20260703.a632217-*`; the built shared library keeps SONAME
`librga.so.2`.

### FFmpeg

The FFmpeg package uses the full Ubuntu/Debian packaging surface, not the smaller
local `/opt` package under [`../ffmpeg-rockchip81/`](../ffmpeg-rockchip81/README.md).
It is built from the `ffmpeg-rockchip-81` forward-port branch at `75638e7f0b17`
and enables:

- `--enable-rkmpp`
- `--enable-rkrga`
- `--enable-libdrm`
- `--enable-version3`

This source produces the ABI from that branch: `libavcodec63`, `libavutil61`,
`libavformat63`, `libavfilter12`, `libavdevice63`, `libswscale10`, and
`libswresample7`.

### GNOME Remote Desktop

The GRD package is based on `GRD_COMMIT` plus the captured
[`source-deltas/dirty20260706-worktree.patch`](gnome-remote-desktop/source-deltas/dirty20260706-worktree.patch),
not a clean commit archive. `build-source-packages.sh` exports a clean git
archive, applies that delta, removes generated `*.spv` shader outputs, overlays
[`gnome-remote-desktop/debian/`](gnome-remote-desktop/debian/changelog), and
builds a `3.0 (quilt)` source package. The packaging enables the FFmpeg backend
with `-Dffmpeg=enabled`, restricts the binary package to `Architecture: arm64`,
and depends on the PPA's FFmpeg 8.1.2 development packages.

This package has not been uploaded to the PPA or Launchpad-build-validated from
this repo snapshot. Local source-package validation passed, and a local
`DEB_BUILD_OPTIONS=nocheck` binary build succeeded against the upstream FFmpeg
8.1.2 baseline (`libavcodec62` / `libavutil60`) after sanitizing `PATH` so
`a2x` used `/usr/bin/python3` instead of a user-level `mise` Python. Treat GRD
as staged behind the MPP/librga/FFmpeg dependency chain, with a second binary
validation still required after `ffmpeg-rockchip-81` publishes the fork ABI
(`libavcodec63` / `libavutil61`).

## What Is Still Not In This Repo

- A PPA-native `gnome-remote-desktop-gdm-hwenc` source-package wrapper, if that
  package is uploaded through Launchpad instead of shipped as the existing local
  native deb.
- The original dev-box `UPLOAD.md` runbook. The current run is captured in
  [`2026-07-06-ubuntu-rock-5b-upload-log.md`](2026-07-06-ubuntu-rock-5b-upload-log.md)
  instead.
- Signed upload artifacts, orig tarballs, `.changes`, `.dsc`, binary packages,
  and Launchpad credentials.

## See Also

- [`../README.md`](../README.md) - deploy hub and binary policy.
- [`../../status.md`](../../status.md) - project-wide scoreboard.
- [`../ffmpeg-rockchip81/`](../ffmpeg-rockchip81/README.md) - self-contained
  local `/opt` FFmpeg package, separate from this PPA replacement package.
- [`../../video-libraries/ffmpeg/`](../../video-libraries/ffmpeg/README.md) -
  FFmpeg implementation notes and patch context.
