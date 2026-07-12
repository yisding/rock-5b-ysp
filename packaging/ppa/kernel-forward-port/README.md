# kernel-forward-port/ - PPA kernel source package

This directory tracks the Launchpad PPA path for the ROCK 5B forward-port
kernel. The first Launchpad arm64 build failed because `mkimage` was missing
while generating the Rockchip overlay fixup script. Retry source publication
`18614559` adds the `u-boot-tools` build dependency; arm64 build `33387391`
succeeded and the image/DTB/header packages are public. The local arm64 binary
package build also passes; board install/revert validation remains pending.

The current kernel delivery path is still the Armbian wrapper in
[`../../../kernel-drivers/scripts/build-armbian-deb.sh`](../../../kernel-drivers/scripts/build-armbian-deb.sh),
which produces local binary `.deb`s under the external Armbian build workspace.
Launchpad PPAs accept source uploads (`.dsc` + `*_source.changes`), not arbitrary
prebuilt binary kernel `.deb`s, so those local artifacts cannot be added to
`ppa:yi-ding/ubuntu-rock-5b` directly.

## Target

First PPA kernel package should be conservative and recovery-friendly:

| Field | Decision |
|-------|----------|
| Source package | `linux-rockchip64-ysp`; do not reuse Armbian's source name until the upgrade/recovery behavior is proven. |
| Binary packages | Co-installable names first: `linux-image-ysp-rockchip64`, `linux-dtb-ysp-rockchip64`, and `linux-headers-ysp-rockchip64`. A later drop-in package can replace `linux-image-current-rockchip64` after boot/revert testing. |
| Architecture | `arm64` only. |
| Kernel variant | Armbian `rockchip64-current` 6.18.38 worktree with the self-contained-DT RK3588 MPP/RGA/AV1 forward-port applied. The older convert-in-place combined kernel can use the same source-package shape later if needed. |
| Upload state | Initial arm64 build `33387353` failed on missing `mkimage`. Retry source publication `18614559` is Published; arm64 build `33387391` succeeded, and all three binary packages are in the public index. |

## Source Inputs

The local build wrapper currently owns these inputs:
`WORKSPACE_ROOT` defaults to the parent of this repository.

| Input | Default |
|-------|---------|
| Patched Armbian kernel worktree | `KERNEL_PPA_REPO=$WORKSPACE_ROOT/kernel/rock5b-kernel-build/armbian-build/cache/sources/linux-kernel-worktree/6.18__rockchip64__arm64` |
| Resolved kernel config | `KERNEL_PPA_CONFIG=$KERNEL_PPA_REPO/.config` |
| Source package name | `KERNEL_PPA_SOURCE=linux-rockchip64-ysp` |
| Upstream version | `KERNEL_PPA_UPSTREAM_VERSION=6.18.38+rk3588av1fwport20260709` |

The exporter copies the patched worktree contents, including Armbian patch
changes and untracked patch-added files, while excluding `.git`, `.config`,
build products, `.orig` backups, and `debian/`. It then overlays this directory's
`debian/` packaging and copies the resolved config into
`debian/config/arm64-rockchip64.config`.

## Debian helper scripts

These helpers are invoked by `debian/rules`, not directly by board users. The
same source-package-local copies ship in both alpha-kernel directories so every
export is self-contained; `scripts/check-doc-consistency.py` enforces that all
three copies remain byte-identical.

| Helper | Role |
|--------|------|
| [`debian/scripts/install-kernel-packages.sh`](debian/scripts/install-kernel-packages.sh) | Stages the image/modules, DTBs, and buildable headers into their three binary-package roots. |
| [`debian/scripts/write-maintainer-scripts.sh`](debian/scripts/write-maintainer-scripts.sh) | Generates image/DTB/header maintainer scripts with Armbian-compatible `/boot`, initramfs, symlink, and header-prepare behavior. |

## Launchpad Constraints

- Build from source in the Launchpad build chroot. Do not upload the Armbian
  output `.deb`s as PPA inputs.
- Do not depend on network access during `debian/rules build`.
- Do not depend on Docker, privileged mounts, or the interactive Armbian
  `compile.sh` relaunch path inside Launchpad.
- Keep all source, generated patches, config, and Debian packaging in the source
  package or in build-dependencies available from Ubuntu/the PPA.
- Preserve Armbian-compatible boot hooks, initramfs generation, DTB placement,
  and recovery behavior before publishing a package that can supersede the stock
  Armbian kernel.

## Build Source Package

```bash
bash packaging/ppa/build-source-packages.sh kernel
```

Generated on 2026-07-09, signed/uploaded on 2026-07-10 local time, then rebuilt as `~rk2` with `u-boot-tools` in Build-Depends:

```text
packaging/ppa/out/artifacts/linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260709.orig.tar.gz
packaging/ppa/out/artifacts/linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260709-0ubuntu1~rk2.debian.tar.xz
packaging/ppa/out/artifacts/linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260709-0ubuntu1~rk2.dsc
packaging/ppa/out/artifacts/linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260709-0ubuntu1~rk2_source.changes
```

The orig tarball is large (`272M` in the first export), so the kernel target is
not part of the no-argument `build-source-packages.sh` default.

## Validation Status

Passed:

- `dpkg-buildpackage -S -sa -us -uc -d` through the helper.
- `dpkg-source -x` of the generated `.dsc`.
- `debian/rules override_dh_auto_configure` in the extracted source, proving the
  packaged config reaches `olddefconfig`.
- Full local arm64 binary build from the regenerated source package:
  - `linux-image-ysp-rockchip64_6.18.38+rk3588av1fwport20260709-0ubuntu1~rk1_arm64.deb`
  - `linux-dtb-ysp-rockchip64_6.18.38+rk3588av1fwport20260709-0ubuntu1~rk1_arm64.deb`
  - `linux-headers-ysp-rockchip64_6.18.38+rk3588av1fwport20260709-0ubuntu1~rk1_arm64.deb`
- Normalized payload comparison against the matching local Armbian
  `6.18.38-current-rockchip64` debs:
  - module file list: `3574` vs `3574`, no normalized path differences;
  - DTB package file list: `390` vs `390`, no normalized path differences;
  - in-image DTB copy file list: `390` vs `390`, no normalized path differences;
  - Rockchip MPP AV1 config is enabled in both builds:
    `CONFIG_ROCKCHIP_MPP_AV1DEC=y`.
- Maintainer-script comparison against the matching local Armbian debs:
  - image scripts run the same `/etc/kernel/*.d` hook families with the YSP
    release string, update `/boot/Image`, and preserve the FAT `/boot` path;
  - DTB scripts use the same `/boot/dtb` symlink-or-move behavior with the YSP
    release string;
  - header scripts use the same prepare flow, with one intentional tolerance:
    `tools/bpf/resolve_btfids` failure is non-fatal in the YSP package.
- `debsign` signed the `.dsc`, `.buildinfo`, and `.changes` with
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`.
- `dput ppa:yi-ding/ubuntu-rock-5b` completed client-side upload of the signed
  source package.
- Launchpad API/log check on 2026-07-10 23:30 PDT: source publication
  `18614540` is `Published`; arm64 build `33387353` `Failed to build` because
  `/bin/sh: 1: mkimage: not found` while generating
  `arch/arm64/boot/dts/rockchip/overlay/rockchip-fixup.scr`.
- Retry `~rk2` adds `u-boot-tools` to Build-Depends, extracts cleanly from the
  generated `.dsc`, signs successfully, and was uploaded with `dput`.
- Launchpad API check on 2026-07-10 23:49 PDT: retry source publication
  `18614559` is `Pending`; arm64 build `33387391` is `Currently building` on `bos03-arm64-047`.
- Launchpad API/public-index check on 2026-07-11 21:44 PDT: retry source
  publication `18614559` is Published, build `33387391` is `Successfully
  built`, and the image, DTB, and headers packages are public.

Notes:

- The PPA packages deliberately use co-installable names and release strings:
  `6.18.38-ysp-rockchip64` instead of Armbian's
  `6.18.38-current-rockchip64`.
- Binary hashes differ from the Armbian debs because the local PPA build used
  the host resolute toolchain (`gcc 15`, binutils `2.46`, pahole `1.31`), while
  the comparison Armbian deb was built with Ubuntu 24.04-era `gcc 13`,
  binutils `2.42`, and pahole `1.25`.
- Header package file lists differ by `92` paths, primarily generated
  `include/config/*` entries that follow the compiler/config probe differences.

Not done yet:

- Board install, reboot, rollback, and `kernel-revert.sh` recovery validation.
- Full `lintian`; the source lint run was stopped after several minutes with no
  output because the kernel orig tarball scan was taking too long.

## Remaining Checklist

1. Validate install, reboot, rollback, and `kernel-revert.sh` recovery on the
   board before giving install guidance.
