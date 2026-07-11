# ppa/ - Launchpad source packages

This directory holds the reproducible Debian packaging for the ROCK 5B
media stack intended for `ppa:yi-ding/ubuntu-rock-5b`.

The PPA's implemented source packages are built by Launchpad and installed by
`apt`: MPP, librga, FFmpeg with RKMPP/RKRGA, the co-installable nyanmisaka
FFmpeg 6.1 fork, GRD, and kernel source packages. The forward-port kernel has a
tracked PPA source package under
[`kernel-forward-port/`](kernel-forward-port/README.md); its local arm64 binary
build and normalized Armbian payload comparison pass, its Launchpad source is
published, and its Launchpad arm64 build is in progress. The alpha clean-room
rewrite kernels have separate co-installable source packages under
[`kernel-rewrite-alpha-6.18/`](kernel-rewrite-alpha-6.18/README.md) and
[`kernel-rewrite-alpha-7.2-rc2/`](kernel-rewrite-alpha-7.2-rc2/README.md);
their source uploads are accepted by Launchpad and waiting for publication/build
completion. Kernel board install/revert gates are still pending. The optional
greeter ACL package has both the existing local deb source and a native PPA
source wrapper under
[`gdm-hwenc/`](gdm-hwenc/README.md).

## Current State

Last recorded in the public APT indexes and Launchpad API at
`2026-07-10T23:05:42-07:00` and in
[`2026-07-06-ubuntu-rock-5b-upload-log.md`](2026-07-06-ubuntu-rock-5b-upload-log.md):

| Package | Version in this repo | Public PPA state | Notes |
|---------|----------------------|------------------|-------|
| `mpp` | `1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1` | Source and arm64 binaries are published in the public PPA indexes. | Repacked to remove unused Windows binaries; includes a GCC 15 pthread test fix. |
| `librga` | `2.2.0+git20260703.a632217-0ubuntu3~rk1` | Source and arm64 binaries are published in the public PPA indexes; `-0ubuntu2~rk1` is superseded. | The `-0ubuntu3~rk1` retry succeeded after the earlier arm64 builder failure. |
| `ffmpeg` | `7:8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk3` | Published `~rk2` source publication `18614542` failed arm64 build `33387355` during configure; local `~rk3` packaging is prepared but not uploaded. | `~rk3` drops `--disable-omx`, which the forward-port branch no longer exposes as a configure option. The higher-version `~rk2` source already superseded the baseline `ffmpeg` source publication once it published. |
| `ffmpeg` (baseline) | `7:8.1.2-1+rk2` in [`ffmpeg-baseline/`](ffmpeg-baseline/README.md) | Fixed arm64 build `33381225` completed successfully on 2026-07-10 UTC. | The `7:8.1.2-1+rk1` baseline upload published, but arm64 build `33366878` failed in the FATE frei0r tests. `-1+rk2` adds the `frei0r-plugins` build-dependency and still sorts below the Rockchip-81 forward-port. |
| `ffmpeg-rockchip` | `6.1+git20260423.40c412dacc-0ubuntu1~rk1` under [`ffmpeg-rockchip/`](ffmpeg-rockchip/README.md) | Co-installable source packaging imported; source package builds and lintian passes, local binary validation is in progress. | Packages nyanmisaka's FFmpeg 6.1 fork as `/opt/ffmpeg-rockchip` plus `ffmpeg-rockchip`/`ffprobe-rockchip`/`ffplay-rockchip`, not as the system `ffmpeg`; it can coexist with Ubuntu 26.04 FFmpeg 8.x and the Rockchip-81 replacement package because source and binary package names do not collide. |
| `gnome-remote-desktop` | `50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1` | Source packaging imported, source lintian passed, and a local `nocheck` binary build passed against upstream FFmpeg `7:8.1.2-1+rk1`; not uploaded and not public in the PPA source index. | Reconstructed from `GRD_COMMIT` plus [`gnome-remote-desktop/source-deltas/`](gnome-remote-desktop/source-deltas/README.md), so it no longer depends on a dirty dev-box worktree. Wait for the FFmpeg dependency chain before upload, then rebuild once against upstream FFmpeg and once after `ffmpeg-rockchip-81` supersedes it. |
| forward-port kernel | `6.18.38+rk3588av1fwport20260709-0ubuntu1~rk1` under [`kernel-forward-port/`](kernel-forward-port/README.md) | Source publication `18614540` is `Published`; arm64 build `33387353` is `Currently building` on `bos03-arm64-094`. | Builds co-installable `linux-image-ysp-rockchip64`, `linux-dtb-ysp-rockchip64`, and `linux-headers-ysp-rockchip64`. Normalized module and DTB file lists match the local Armbian `6.18.38-current-rockchip64` debs; board install/revert validation is still pending. |
| alpha rewrite kernel 6.18 | `6.18.0+rk3588rewritealpha20260710-0ubuntu1~rk1` under [`kernel-rewrite-alpha-6.18/`](kernel-rewrite-alpha-6.18/README.md) | Source publication `18614549` is `Pending`; arm64 build `33387366` is `Needs building`. | Builds co-installable `linux-image-ysp-alpha-6.18-rockchip64`, `linux-dtb-ysp-alpha-6.18-rockchip64`, and `linux-headers-ysp-alpha-6.18-rockchip64`. Generated source extracts and reaches `olddefconfig`; local binary, payload comparison, and board validation are pending. |
| alpha rewrite kernel 7.2-rc2 | `7.2.0~rc2+rk3588rewritealpha20260710-0ubuntu1~rk1` under [`kernel-rewrite-alpha-7.2-rc2/`](kernel-rewrite-alpha-7.2-rc2/README.md) | Source publication `18614550` is `Pending`; arm64 build `33387367` is `Needs building`. | Built from `rk3588-rewrite-mainline` rebased to official kernel.org `v7.2-rc2` at `083bdb98e715`. Generated source extracts and reaches `olddefconfig`; local binary, payload comparison, and board validation are pending. |
| `gnome-remote-desktop-gdm-hwenc` | `1.0` under [`gdm-hwenc/`](gdm-hwenc/README.md) | Native source wrapper imported; not uploaded. | Optional greeter ACL package. The canonical rule also feeds the local deb source under [`../gdm-hwenc/`](../gdm-hwenc/README.md). |

Install-facing state: **do not tell users to install the full stack from this
PPA yet**. The public arm64 index now has MPP and librga binaries, but FFmpeg
needs a `~rk3` retry and the kernel packages are still building or pending, so
the package set is not complete.

The PPA targets **resolute** (Ubuntu 26.04 / Armbian userspace) on **arm64**.
The PPA was corrected from its initial amd64-only setup during the 2026-07-06
run; package metadata now marks the imported binary packages as `Architecture:
arm64`.

## Directory Contents

| Path | Purpose |
|------|---------|
| [`build-source-packages.sh`](build-source-packages.sh) | Exports clean upstream git snapshots, overlays the packaging in this repo, and creates unsigned source packages under `packaging/ppa/out/artifacts/` by default. |
| [`mpp/debian/`](mpp/debian/changelog) | Debian packaging for Rockchip MPP from `mpp-rockchip` commit `1375813c`. |
| [`librga/debian/`](librga/debian/changelog) | Debian packaging for the local `librga-fork` commit `a632217`, including the P010/P210 work. |
| [`ffmpeg/debian/`](ffmpeg/debian/changelog) | Ubuntu/Debian FFmpeg packaging retargeted to the `ffmpeg-rockchip-81` forward-port at `75638e7f0b17`. |
| [`ffmpeg-rockchip/debian/`](ffmpeg-rockchip/debian/changelog) | Co-installable `/opt/ffmpeg-rockchip` packaging for nyanmisaka's FFmpeg 6.1 Rockchip fork at `40c412daccf0`. |
| [`gnome-remote-desktop/debian/`](gnome-remote-desktop/debian/changelog) | Ubuntu/Debian GRD packaging retargeted to the `GRD_COMMIT` + `GRD_DELTA` source snapshot with `-Dffmpeg=enabled`. |
| [`gnome-remote-desktop/source-deltas/`](gnome-remote-desktop/source-deltas/README.md) | Captured tracked-file GRD deltas needed to reconstruct dirty source-package snapshots. |
| [`gdm-hwenc/`](gdm-hwenc/README.md) | Native source-package wrapper for the optional GDM greeter hardware-encode ACL rule. |
| [`kernel-forward-port/`](kernel-forward-port/README.md) | Launchpad source-package track for the forward-port kernel; records source inputs, packaging shape, generated artifacts, and remaining binary/board validation gates. |
| [`kernel-rewrite-alpha-6.18/`](kernel-rewrite-alpha-6.18/README.md) | Launchpad source-package track for the 6.18 alpha clean-room rewrite kernel. |
| [`kernel-rewrite-alpha-7.2-rc2/`](kernel-rewrite-alpha-7.2-rc2/README.md) | Launchpad source-package track for the 7.2-rc2 alpha clean-room rewrite kernel. |
| [`2026-07-06-ubuntu-rock-5b-upload-log.md`](2026-07-06-ubuntu-rock-5b-upload-log.md) | The detailed build, lintian, signing, upload, Launchpad, and retry log for the current run. |

Generated `.dsc`, `.changes`, `.buildinfo`, orig tarballs, `.deb`, `.ddeb`, and
build directories are intentionally not committed. The script writes them under
`packaging/ppa/out/` by default; that directory is ignored. Set `OUT=` to use a
different output root.

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
| nyanmisaka FFmpeg Rockchip repo | `FFMPEG_ROCKCHIP_REPO` | `/home/yi/Code/ffmpeg/ffmpeg-rockchip` |
| nyanmisaka FFmpeg Rockchip commit | `FFMPEG_ROCKCHIP_COMMIT` | `40c412daccf08164493da0de990eb99a8948116b` |
| GRD repo | `GRD_REPO` | `/home/yi/Code/gnome/grd/grd-ffmpeg` |
| GRD commit | `GRD_COMMIT` | `a59c904c99088235eb4de31ca340747d334494f3` |
| GRD dirty delta | `GRD_DELTA` | [`source-deltas/dirty20260706-worktree.patch`](gnome-remote-desktop/source-deltas/dirty20260706-worktree.patch) |
| Forward-port kernel worktree | `KERNEL_PPA_REPO` | `/home/yi/Code/kernel/rock5b-kernel-build/armbian-build/cache/sources/linux-kernel-worktree/6.18__rockchip64__arm64` |
| Forward-port kernel config | `KERNEL_PPA_CONFIG` | `$KERNEL_PPA_REPO/.config` |
| Forward-port kernel source version | `KERNEL_PPA_UPSTREAM_VERSION` | `6.18.38+rk3588av1fwport20260709` |
| Alpha rewrite 6.18 kernel worktree | `KERNEL_ALPHA_618_REPO` | `/home/yi/Code/kernel/linux-6.18-rkvenc` |
| Alpha rewrite 6.18 kernel config | `KERNEL_ALPHA_618_CONFIG` | [`kernel-rewrite-alpha-6.18/debian/config/arm64-rockchip64.config`](kernel-rewrite-alpha-6.18/debian/config/arm64-rockchip64.config) |
| Alpha rewrite 6.18 kernel source version | `KERNEL_ALPHA_618_UPSTREAM_VERSION` | `6.18.0+rk3588rewritealpha20260710` |
| Alpha rewrite 7.2-rc2 kernel worktree | `KERNEL_ALPHA_72RC2_REPO` | `/home/yi/Code/kernel/linux` |
| Alpha rewrite 7.2-rc2 kernel config | `KERNEL_ALPHA_72RC2_CONFIG` | [`kernel-rewrite-alpha-7.2-rc2/debian/config/arm64-rockchip64.config`](kernel-rewrite-alpha-7.2-rc2/debian/config/arm64-rockchip64.config) |
| Alpha rewrite 7.2-rc2 kernel source version | `KERNEL_ALPHA_72RC2_UPSTREAM_VERSION` | `7.2.0~rc2+rk3588rewritealpha20260710` |
| GDM greeter ACL rule | `GDM_HWENC_RULE` | [`../gdm-hwenc/root/usr/lib/udev/rules.d/70-gnome-remote-desktop-gdm-hwenc.rules`](../gdm-hwenc/root/usr/lib/udev/rules.d/70-gnome-remote-desktop-gdm-hwenc.rules) |

Version strings can also be overridden with `MPP_UPSTREAM_VERSION`,
`LIBRGA_UPSTREAM_VERSION`, `FFMPEG_UPSTREAM_VERSION`,
`FFMPEG_ROCKCHIP_UPSTREAM_VERSION`, and `GRD_UPSTREAM_VERSION`. The kernel
source name can be overridden with `KERNEL_PPA_SOURCE`, though
`linux-rockchip64-ysp` is the current forward-port package name. The alpha
kernel source names can be overridden with `KERNEL_ALPHA_618_SOURCE` and
`KERNEL_ALPHA_72RC2_SOURCE`. The native greeter ACL source package name/version
can be overridden with `GDM_HWENC_SOURCE` and `GDM_HWENC_VERSION`.

## Build Source Packages

Build the default userspace dependency chain:

```bash
bash packaging/ppa/build-source-packages.sh
```

Build a subset:

```bash
bash packaging/ppa/build-source-packages.sh mpp librga
bash packaging/ppa/build-source-packages.sh ffmpeg
bash packaging/ppa/build-source-packages.sh ffmpeg-rockchip
bash packaging/ppa/build-source-packages.sh gnome-remote-desktop
bash packaging/ppa/build-source-packages.sh grd
bash packaging/ppa/build-source-packages.sh gdm-hwenc
bash packaging/ppa/build-source-packages.sh kernel
bash packaging/ppa/build-source-packages.sh kernel-alpha-6.18
bash packaging/ppa/build-source-packages.sh kernel-alpha-7.2-rc2
```

The kernel target exports the patched Armbian kernel worktree rather than using
`git archive`, because Armbian applies its patch stack into a dirty worktree.
It is intentionally not part of the no-argument default set because the orig
tarball is large.

Use a different output directory or source checkout:

```bash
OUT=/path/to/rock5b-ppa \
MPP_REPO=/path/to/mpp-rockchip \
LIBRGA_REPO=/path/to/librga-fork \
FFMPEG_REPO=/path/to/ffmpeg-rockchip-81 \
FFMPEG_ROCKCHIP_REPO=/path/to/ffmpeg-rockchip \
GRD_REPO=/path/to/grd-ffmpeg \
bash packaging/ppa/build-source-packages.sh
```

For the forward-port kernel:

```bash
KERNEL_PPA_REPO=/path/to/armbian/cache/sources/linux-kernel-worktree/6.18__rockchip64__arm64 \
KERNEL_PPA_CONFIG=/path/to/resolved/.config \
bash packaging/ppa/build-source-packages.sh kernel
```

For the alpha rewrite kernels:

```bash
KERNEL_ALPHA_618_REPO=/path/to/linux-6.18-rkvenc \
KERNEL_ALPHA_72RC2_REPO=/path/to/linux-mainline-rewrite \
bash packaging/ppa/build-source-packages.sh kernel-alpha-6.18 kernel-alpha-7.2-rc2
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

The `gdm-hwenc` target is a native source package. It copies the canonical udev
rule from [`../gdm-hwenc/`](../gdm-hwenc/README.md) into the generated source
tree and does not create an orig tarball.

## Upload Order

Respect the build-dependency chain:

```text
Wave A  mpp, librga
          wait for librockchip-mpp-dev and librga-dev to publish on arm64
Wave B  ffmpeg-rockchip-81
          wait for libavcodec-dev/libavutil-dev/etc. to publish
Wave B' ffmpeg-rockchip
          optional co-installable tool package; can build once MPP/librga
          development packages are published because it does not replace
          system ffmpeg/libav* packages
Wave C  gnome-remote-desktop
Wave D  gnome-remote-desktop-gdm-hwenc (optional greeter ACL)
Wave K  forward-port kernel and alpha rewrite kernels. These were uploaded by
        explicit request before board validation; do not give install guidance
        until Launchpad builds and board install/revert validation pass.
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
debsign -k <fingerprint> packaging/ppa/out/artifacts/*_source.changes
dput ppa:yi-ding/ubuntu-rock-5b packaging/ppa/out/artifacts/<package>_source.changes
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

Prepared source artifacts for the held Rockchip-81 upload live under
`packaging/ppa/out/artifacts/` when generated locally. As of 2026-07-09,
`ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2_source.changes`
has been regenerated and source-lintian checked, but it is intentionally not
signed or uploaded until the upstream-baseline `7:8.1.2-1+rk2` build gives a
useful result. The Rockchip-81 version sorts above the baseline version, so a
later upload supersedes the baseline `ffmpeg`/`libav*` packages in the PPA.

Private FFmpeg helper packages are a separate case: a package such as
`gnome-remote-desktop-ffmpeg-rk` that installs FFmpeg 6 libraries under
`/usr/lib/gnome-remote-desktop/ffmpeg-rk/` does not conflict with this PPA
`ffmpeg` source or its distro-style `libav*` binaries. A source package named
`ffmpeg` that produces `ffmpeg`/`libav*` binaries would not coexist; it would be
ordered by Debian version and either supersede or be superseded.

### FFmpeg Rockchip 6.1 Tool Package

The `ffmpeg-rockchip` package is based on nyanmisaka's FFmpeg Rockchip fork at
`40c412daccf0`, whose `RELEASE` is `6.1`. It is too old to be the normal
Ubuntu 26.04 system FFmpeg because resolute publishes FFmpeg 8.x and the fork
uses the older FFmpeg 6.1 ABI family (`libavcodec60`, `libavutil58`,
`libavformat60`, `libavfilter9`, `libavdevice60`, `libswscale7`,
`libswresample4`, `libpostproc57`).

To avoid collisions, the source package is named `ffmpeg-rockchip` and the
binary package installs only private command tools:

- `/opt/ffmpeg-rockchip/bin/ffmpeg`
- `/opt/ffmpeg-rockchip/bin/ffprobe`
- `/opt/ffmpeg-rockchip/bin/ffplay`
- `/usr/bin/ffmpeg-rockchip`
- `/usr/bin/ffprobe-rockchip`
- `/usr/bin/ffplay-rockchip`

It does not provide `ffmpeg`, `libavcodec-dev`, or any system `libav*` package
name, so it can be published in the same PPA without changing apt's selected
system FFmpeg. The package builds with `--disable-autodetect` and explicitly
enables only the external Rockchip path plus basic compression/SDL support:
`--enable-version3 --enable-libdrm --enable-rkmpp --enable-rkrga --enable-zlib
--enable-bzlib --enable-sdl2`.

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

### GDM Greeter Hardware Encode ACL

The `gdm-hwenc` target builds a small `3.0 (native)` source package for
`gnome-remote-desktop-gdm-hwenc`. It installs the same udev rule as the local
package under [`../gdm-hwenc/`](../gdm-hwenc/README.md), granting group `gdm`
access to the codec nodes so the pre-login greeter can hardware-encode.

This package is opt-in because it widens video-codec access to the whole `gdm`
group. It should be uploaded only after the GRD package path is otherwise ready.

## What Is Still Not In This Repo

- Board install/revert validation for the PPA-native forward-port kernel source
  package in [`kernel-forward-port/`](kernel-forward-port/README.md).
- Local binary-build, payload-comparison, and board install/revert validation
  for the alpha rewrite kernel source packages in
  [`kernel-rewrite-alpha-6.18/`](kernel-rewrite-alpha-6.18/README.md) and
  [`kernel-rewrite-alpha-7.2-rc2/`](kernel-rewrite-alpha-7.2-rc2/README.md).
  Current local Armbian binary `.deb`s are still not valid PPA upload inputs.
- The original dev-box `UPLOAD.md` runbook. The current run is captured in
  [`2026-07-06-ubuntu-rock-5b-upload-log.md`](2026-07-06-ubuntu-rock-5b-upload-log.md)
  instead.
- Signed upload artifacts, orig tarballs, `.changes`, `.dsc`, binary packages,
  and Launchpad credentials.

## See Also

- [`../README.md`](../README.md) - deploy hub and binary policy.
- [`../../status.md`](../../status.md) - project-wide dashboard.
- [`../ffmpeg-rockchip81/`](../ffmpeg-rockchip81/README.md) - self-contained
  local `/opt` FFmpeg package, separate from this PPA replacement package.
- [`../../video-libraries/ffmpeg/`](../../video-libraries/ffmpeg/README.md) -
  FFmpeg implementation notes and patch context.
