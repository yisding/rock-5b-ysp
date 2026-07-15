# ppa/ - Launchpad source packages

This directory holds the reproducible Debian packaging for the ROCK 5B media
stack. The ABI-compatible system stack belongs in
`ppa:yi-ding/ubuntu-rock-5b`; ABI-changing FFmpeg builds and experimental
rewrite kernels use dedicated PPAs.

The PPA's implemented source packages are built by Launchpad and installed by
`apt`: the codec access rule, MPP, librga, FFmpeg with RKMPP/RKRGA, the
co-installable nyanmisaka FFmpeg 6.1 fork, GRD, and kernel source packages. The
forward-port kernel has a
tracked PPA source package under
[`kernel-forward-port/`](kernel-forward-port/README.md); its local arm64 binary
build and normalized Armbian payload comparison pass, its Launchpad source is
published, and its Launchpad arm64 build succeeded. The alpha clean-room
rewrite kernels have separate co-installable source packages under
[`kernel-rewrite-alpha-6.18/`](kernel-rewrite-alpha-6.18/README.md) and
[`kernel-rewrite-alpha-7.2-rc2/`](kernel-rewrite-alpha-7.2-rc2/README.md);
their source and arm64 binaries are also public. Kernel board install/revert
gates are still pending. The optional
greeter ACL package has both the existing local deb source and a native PPA
source wrapper under
[`gdm-hwenc/`](gdm-hwenc/README.md).

## PPA Layout

Each incompatible FFmpeg or rewrite-kernel line has its own archive. This
avoids Launchpad's per-archive rule that a previously accepted source version
cannot later be replaced by an earlier version, even after publications are
deleted.

| PPA | Contents |
|-----|----------|
| `ppa:yi-ding/ubuntu-rock-5b` | System stack: codec udev access, MPP, librga, FFmpeg 8.0.3 Rockchip, patched GNOME Remote Desktop, co-installable FFmpeg 6.1 tools, and the Linux 6.18 forward-port kernel. |
| `ppa:yi-ding/rock5b-ffmpeg81-upstream` | Upstream FFmpeg 8.1.2 baseline. |
| `ppa:yi-ding/rock5b-ffmpeg81-rockchip` | FFmpeg 8.1.2 with the RKMPP/RKRGA forward port. Add the system PPA as well for MPP and librga runtime packages. |
| `ppa:yi-ding/rock5b-kernel618-rewrite` | Experimental Linux 6.18 clean-room rewrite kernel. |
| `ppa:yi-ding/rock5b-kernel72rc2-rewrite` | Experimental Linux 7.2-rc2 clean-room rewrite kernel. |

`ppa:yi-ding/ubuntu-rock-5b-experimental` is a staging/holding archive, not an
install target.

For the primary 6.18 forward-port test path, run
[`install-system-stack.sh`](install-system-stack.sh) on an arm64 Resolute
system. It adds only the system PPA and installs the codec access rule, MPP/RGA
runtime and development packages, FFmpeg, patched GNOME Remote Desktop, and the
co-installable YSP kernel image, DTBs, and headers. Verify the boot entry and
recovery path before rebooting; board install/revert validation remains a test
gate.

If the machine already has one of the earlier FFmpeg 8.1, private-FFmpeg, GRD,
or rewrite-kernel test stacks, use
[`clean-install-system-stack.sh`](clean-install-system-stack.sh) instead. It
adds the system PPA and verifies that the complete replacement set is published
before removing any incompatible PPA source. It then runs an APT simulation,
rejects any removal outside the explicit conflict list, and asks for
confirmation. Shared `libav*` packages are downgraded in place to the exact
FFmpeg 8.0.3 PPA version so unrelated desktop applications are not removed;
incompatible ABI-only and private packages are purged. The machine's existing
Armbian kernel is retained as a recovery boot option.

```bash
bash packaging/ppa/clean-install-system-stack.sh
```

## Current State

Last recorded in the public APT indexes and Launchpad API at
`2026-07-14T10:23:00-07:00` and in
[`2026-07-06-ubuntu-rock-5b-upload-log.md`](2026-07-06-ubuntu-rock-5b-upload-log.md):

| Package | Version in this repo | Public PPA state | Notes |
|---------|----------------------|------------------|-------|
| `rk3588-codec-udev` | `1.1` under [`codec-udev/`](codec-udev/README.md) | Version `1.0` was accepted as fresh-main source publication [`18619789`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18619789), and arm64-hosted `Architecture: all` build [`33397244`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33397244) succeeded. The signed `1.1` review fix was uploaded on 2026-07-14 PDT; Launchpad acceptance/publication is pending. | Installs the canonical non-root MPP/RGA/DMA-heap access rule; `1.1` retriggers real sysfs devices and verifies the resulting permissions. Local source/binary builds, lintian, package installation, and live-device permission checks pass. |
| `mpp` | `1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1` | Copied into the fresh main PPA as source publication [`18619785`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18619785); publication is Pending. | Repacked to remove unused Windows binaries; includes a GCC 15 pthread test fix. |
| `librga` | `2.2.0+git20260703.a632217-0ubuntu3~rk1` | Copied into the fresh main PPA as source publication [`18619786`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18619786); publication is Pending. | The earlier arm64 builder retry succeeded; SONAME remains `librga.so.2`. |
| `ffmpeg` | `7:8.0.3+rockchip+git20260713.463f542c-0ubuntu1~rk1` | Accepted in the fresh main PPA as source publication [`18619822`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18619822); arm64 build [`33397317`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33397317) is running. | Honest 8.0.3 version and Ubuntu ABI 62/60 family; full local package/FATE/hardware validation passed. |
| `ffmpeg` 8.1.2 baseline | `7:8.1.2-1+rk2` in [`ffmpeg-baseline/`](ffmpeg-baseline/README.md) | Dedicated-PPA source publication [`18619544`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-ffmpeg81-upstream/+sourcepub/18619544) and all 29 copied binary publications are Published. | Isolated in `ppa:yi-ding/rock5b-ffmpeg81-upstream`. |
| `ffmpeg` 8.1.2 Rockchip | `7:8.1.2+rockchip81+git20260711.be367abfe6-0ubuntu1~rk1` | Dedicated-PPA source publication [`18619545`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-ffmpeg81-rockchip/+sourcepub/18619545) and all 29 copied binary publications are Published. | Isolated in `ppa:yi-ding/rock5b-ffmpeg81-rockchip`; it builds against the fresh main PPA for MPP/librga. |
| `ffmpeg-rockchip` | `6.1+git20260423.40c412dacc-0ubuntu1~rk1` under [`ffmpeg-rockchip/`](ffmpeg-rockchip/README.md) | Copied into the fresh main PPA as source publication [`18619787`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18619787); publication is Pending. | Co-installable `/opt/ffmpeg-rockchip` tools; does not replace system FFmpeg. |
| `gnome-remote-desktop` | `50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk2` | Accepted as source publication [`18619824`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18619824); arm64 build [`33397319`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33397319) is queued. | Local build links the RKMPP backend against `libavcodec.so.62`/`libavutil.so.60`; source lintian reports only long-filename warnings. |
| forward-port kernel | `6.18.38+rk3588av1fwport20260709-0ubuntu1~rk2` under [`kernel-forward-port/`](kernel-forward-port/README.md) | Copied into the fresh main PPA as source publication [`18619788`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18619788); publication is Pending. | Original arm64 build `33387391` succeeded. Packages are co-installable; board install/revert validation is pending. |
| alpha rewrite kernel 6.18 | `6.18.0+rk3588rewritealpha20260710-0ubuntu1~rk2` under [`kernel-rewrite-alpha-6.18/`](kernel-rewrite-alpha-6.18/README.md) | Dedicated-PPA source publication [`18619546`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel618-rewrite/+sourcepub/18619546) and all three copied binaries are Published. | Isolated in `ppa:yi-ding/rock5b-kernel618-rewrite`; board validation is pending. |
| alpha rewrite kernel 7.2-rc2 | `7.2.0~rc2+rk3588rewritealpha20260710-0ubuntu1~rk2` under [`kernel-rewrite-alpha-7.2-rc2/`](kernel-rewrite-alpha-7.2-rc2/README.md) | Dedicated-PPA source publication [`18619548`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel72rc2-rewrite/+sourcepub/18619548) and all three copied binaries are Published. | Isolated in `ppa:yi-ding/rock5b-kernel72rc2-rewrite`; board validation is pending. |
| `gnome-remote-desktop-gdm-hwenc` | `1.0` under [`gdm-hwenc/`](gdm-hwenc/README.md) | Native source wrapper imported; not uploaded. | Optional greeter ACL package. The canonical rule also feeds the local deb source under [`../gdm-hwenc/`](../gdm-hwenc/README.md). |

Install-facing state: **do not present this PPA as the fully validated primary
path yet**. The fresh main PPA is still publishing restored packages and
building FFmpeg/GRD, and none of the PPA kernels has passed board
install/reboot/revert validation.

The PPA targets **resolute** (Ubuntu 26.04 / Armbian userspace) on **arm64**.
The PPA is configured with only the `arm64` processor. Architecture-independent
packages are built on arm64 and published as `Architecture: all`.

## Directory Contents

| Path | Purpose |
|------|---------|
| [`build-source-packages.sh`](build-source-packages.sh) | Exports clean upstream git snapshots, overlays the packaging in this repo, and creates unsigned source packages under `packaging/ppa/out/artifacts/` by default. |
| [`clean-install-system-stack.sh`](clean-install-system-stack.sh) | Replaces earlier incompatible test packages with exact versions from the system PPA while retaining the distro kernel as a recovery path. |
| [`mpp/debian/`](mpp/debian/changelog) | Debian packaging for Rockchip MPP from `mpp-rockchip` commit `1375813c`. |
| [`librga/debian/`](librga/debian/changelog) | Debian packaging for the local `librga-fork` commit `a632217`, including the P010/P210 work. |
| [`ffmpeg/debian/`](ffmpeg/debian/changelog) | Ubuntu/Debian FFmpeg 8.0.3 packaging retargeted to the `rockchip-8.0` RKMPP/RKRGA forward port at `463f542c32`. |
| [`ffmpeg-rockchip/debian/`](ffmpeg-rockchip/debian/changelog) | Co-installable `/opt/ffmpeg-rockchip` packaging for nyanmisaka's FFmpeg 6.1 Rockchip fork at `40c412daccf0`. |
| [`gnome-remote-desktop/debian/`](gnome-remote-desktop/debian/changelog) | Ubuntu/Debian GRD packaging retargeted to the `GRD_COMMIT` + `GRD_DELTA` source snapshot with `-Dffmpeg=enabled`. |
| [`gnome-remote-desktop/source-deltas/`](gnome-remote-desktop/source-deltas/README.md) | Captured tracked-file GRD deltas needed to reconstruct dirty source-package snapshots. |
| [`codec-udev/`](codec-udev/README.md) | Native PPA source wrapper for the canonical unprivileged MPP/RGA/DMA-heap access rule. |
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

The helper resolves source checkouts below `WORKSPACE_ROOT`, which defaults to
the parent of this repository. Keep the documented sibling layout, override the
shared root, or override individual paths/pins with the matching environment
variables.

| Source | Default variable | Default value |
|--------|------------------|---------------|
| Workspace containing sibling source families | `WORKSPACE_ROOT` | Parent of the `rock-5b-ysp` checkout |
| MPP repo | `MPP_REPO` | `$WORKSPACE_ROOT/rockchip-userspace/mpp-rockchip` |
| MPP commit | `MPP_COMMIT` | `1375813c` |
| librga repo | `LIBRGA_REPO` | `$WORKSPACE_ROOT/rockchip-userspace/librga-fork` |
| librga commit | `LIBRGA_COMMIT` | `a632217` |
| FFmpeg repo | `FFMPEG_REPO` | `$WORKSPACE_ROOT/ffmpeg/ffmpeg-rockchip-81` |
| FFmpeg commit | `FFMPEG_COMMIT` | `463f542c325942f3e6b390cb940c32812570957d` |
| nyanmisaka FFmpeg Rockchip repo | `FFMPEG_ROCKCHIP_REPO` | `$WORKSPACE_ROOT/ffmpeg/ffmpeg-rockchip` |
| nyanmisaka FFmpeg Rockchip commit | `FFMPEG_ROCKCHIP_COMMIT` | `40c412daccf08164493da0de990eb99a8948116b` |
| GRD repo | `GRD_REPO` | `$WORKSPACE_ROOT/gnome/grd/grd-ffmpeg` |
| GRD commit | `GRD_COMMIT` | `a59c904c99088235eb4de31ca340747d334494f3` |
| GRD dirty delta | `GRD_DELTA` | [`source-deltas/dirty20260706-worktree.patch`](gnome-remote-desktop/source-deltas/dirty20260706-worktree.patch) |
| Forward-port kernel worktree | `KERNEL_PPA_REPO` | `$WORKSPACE_ROOT/kernel/rock5b-kernel-build/armbian-build/cache/sources/linux-kernel-worktree/6.18__rockchip64__arm64` |
| Forward-port kernel config | `KERNEL_PPA_CONFIG` | `$KERNEL_PPA_REPO/.config` |
| Forward-port kernel source version | `KERNEL_PPA_UPSTREAM_VERSION` | `6.18.38+rk3588av1fwport20260709` |
| Alpha rewrite 6.18 kernel worktree | `KERNEL_ALPHA_618_REPO` | `$WORKSPACE_ROOT/kernel/linux-6.18-rkvenc` |
| Alpha rewrite 6.18 kernel config | `KERNEL_ALPHA_618_CONFIG` | [`kernel-rewrite-alpha-6.18/debian/config/arm64-rockchip64.config`](kernel-rewrite-alpha-6.18/debian/config/arm64-rockchip64.config) |
| Alpha rewrite 6.18 kernel source version | `KERNEL_ALPHA_618_UPSTREAM_VERSION` | `6.18.0+rk3588rewritealpha20260710` |
| Alpha rewrite 7.2-rc2 kernel worktree | `KERNEL_ALPHA_72RC2_REPO` | `$WORKSPACE_ROOT/kernel/linux` |
| Alpha rewrite 7.2-rc2 kernel config | `KERNEL_ALPHA_72RC2_CONFIG` | [`kernel-rewrite-alpha-7.2-rc2/debian/config/arm64-rockchip64.config`](kernel-rewrite-alpha-7.2-rc2/debian/config/arm64-rockchip64.config) |
| Alpha rewrite 7.2-rc2 kernel source version | `KERNEL_ALPHA_72RC2_UPSTREAM_VERSION` | `7.2.0~rc2+rk3588rewritealpha20260710` |
| GDM greeter ACL rule | `GDM_HWENC_RULE` | [`../gdm-hwenc/root/usr/lib/udev/rules.d/70-gnome-remote-desktop-gdm-hwenc.rules`](../gdm-hwenc/root/usr/lib/udev/rules.d/70-gnome-remote-desktop-gdm-hwenc.rules) |
| Codec access rule | `CODEC_UDEV_RULE` | [`../../kernel-drivers/scripts/99-rockchip-codec.rules`](../../kernel-drivers/scripts/99-rockchip-codec.rules) |

Version strings can also be overridden with `MPP_UPSTREAM_VERSION`,
`LIBRGA_UPSTREAM_VERSION`, `FFMPEG_UPSTREAM_VERSION`,
`FFMPEG_ROCKCHIP_UPSTREAM_VERSION`, and `GRD_UPSTREAM_VERSION`. The kernel
source name can be overridden with `KERNEL_PPA_SOURCE`, though
`linux-rockchip64-ysp` is the current forward-port package name. The codec
access source/version can be overridden with `CODEC_UDEV_SOURCE` and
`CODEC_UDEV_VERSION`. The alpha
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
Wave A  rk3588-codec-udev, mpp, librga
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
dput ppa:yi-ding/ubuntu-rock-5b packaging/ppa/out/artifacts/<system-package>_source.changes
dput ppa:yi-ding/rock5b-ffmpeg81-upstream packaging/ppa/out/artifacts/<ffmpeg-8.1-upstream>_source.changes
dput ppa:yi-ding/rock5b-ffmpeg81-rockchip packaging/ppa/out/artifacts/<ffmpeg-8.1-rockchip>_source.changes
dput ppa:yi-ding/rock5b-kernel618-rewrite packaging/ppa/out/artifacts/<kernel-6.18-rewrite>_source.changes
dput ppa:yi-ding/rock5b-kernel72rc2-rewrite packaging/ppa/out/artifacts/<kernel-7.2-rc2-rewrite>_source.changes
```

Use the exact files from the artifact directory; the upload log records the
fingerprint and package-specific retry history from the 2026-07-06 run.

## Package Notes

### Codec device access

`rk3588-codec-udev` installs the canonical rule for `/dev/mpp_service`,
`/dev/rga`, and `/dev/dma_heap/*`. It grants the `video` group and active local
seat access and reloads/retriggers udev at installation time. This is required
for unprivileged RKMPP allocation; access to the codec node alone is not enough
when DMA-heap access is denied.

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
The system package is based on the official FFmpeg `n8.0.3` tag plus the
RKMPP/RKRGA forward-port and hardening series on branch `rockchip-8.0` at
`463f542c3259`. It enables:

- `--enable-rkmpp`
- `--enable-rkrga`
- `--enable-libdrm`
- `--enable-version3`

This source retains Ubuntu Resolute's FFmpeg 8.0 ABI family: `libavcodec62`,
`libavutil60`, `libavformat62`, `libavfilter11`, `libavdevice62`,
`libswscale9`, and `libswresample6`. It therefore replaces Ubuntu's native
FFmpeg stack without introducing the FFmpeg 8.1 SONAME transition.

Getting the original FFmpeg 8.1 forward port to build as a full Debian package
took fixing three fork bugs, one per failed Launchpad build. A fourth runtime
fix handles AV1 container extradata. These fixes were carried into the 8.0
branch and are recorded in
[`../../findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md`](../../findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md):

1. **FATE `libavcodec-avcodec`** — the `*_rkmpp` decoders declared a static
   `pix_fmts` array while flagging `AV_CODEC_CAP_HARDWARE`, which the self-test
   forbids for video decoders. Fixed directly in source commit `8356739686`,
   which drops the unused array (output format is negotiated at runtime via
   `ff_get_format`; the DRM_PRIME hw_config players rely on is untouched).
2. **`RELEASE_NOTES`** — `debian/ffmpeg.install` installed a file the fork does
   not ship (it has `RELEASE` + `Changelog`); the line was dropped.
3. **`ffmpeg-doc` architecture** — the arm64-only correction pass had flipped it
   to `arm64`, but its doxygen HTML is built only in the arch-indep pass; set
   back to `Architecture: all` (matching the baseline).
4. **AV1 MP4/Matroska extradata** — the fork queued `av1C`/`CodecPrivate` but
   did not mark the MPP packet as extradata. Source commit `be367abfe6` calls
   `mpp_packet_set_extra_data()`, selecting MPP's configuration-record
   parser so it skips the `av1C` header and consumes the sequence-header OBU.

The FFmpeg 8.1 work that found and fixed the decoder `pix_fmts`, missing
`RELEASE_NOTES`, `ffmpeg-doc`, and AV1 extradata problems remains available in
`ppa:yi-ding/rock5b-ffmpeg81-rockchip`; the upstream comparison build is in
`ppa:yi-ding/rock5b-ffmpeg81-upstream`.

Version `7:8.0.3+rockchip+git20260713.463f542c-0ubuntu1~rk1` has passed a full
local binary build, executable/media FATE tests, extracted-package smoke tests,
and RK3588 hardware tests for RKMPP encode, RKMPP decode, and the zero-copy
RKMPP-to-RGA-scale-to-RKMPP path. Source extraction and lintian also pass; the
only lintian result is the inherited newer-standards-version warning.

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

Local validation built the source package, passed source lintian, and produced an arm64 binary package after disabling LTO for resource use and disabling upstream FATE tests because HLS list generation segfaulted in this fork. Source publication `18614552` is public; arm64 build `33387375` successfully built on `bos03-arm64-043`, and the tool package is indexed.

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
