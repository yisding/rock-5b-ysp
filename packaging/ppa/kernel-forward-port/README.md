# kernel-forward-port/ - PPA kernel source package

This directory tracks the Launchpad PPA path for the ROCK 5B forward-port
kernel. The first Launchpad arm64 build failed because `mkimage` was missing
while generating the Rockchip overlay fixup script. Retry source publication
`18614559` added the `u-boot-tools` build dependency and produced successful
arm64 build `33387391`. The source and image/DTB/header binaries are now
Published in the recreated main PPA as source publication `18619788`.
Replacement version `6.18.38+rk3588av1fwport20260716-0ubuntu1~rk1`, carrying
the Rockchip 5.10 RGA reconciliation and RKVENC2 multi-slice error fix, was
accepted as source publication `18624245`. Hardened version
`6.18.38+rk3588av1fwport20260716.1-0ubuntu1~rk1` additionally validates every
raw RGA physical-import page before DMA cache maintenance and makes the unsafe
raw-address probes opt-in. Its full Armbian integration build and exact
PPA-source arm64 binary build both pass. Launchpad accepted the signed source
as pending publication `18624583` and started arm64 build `33407863` on
`bos03-arm64-036`; it was `Currently building` at the 2026-07-16 22:52 PDT
check. Board install/revert validation remains pending.

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
| Upload state | Initial arm64 build `33387353` failed on missing `mkimage`. Retry build `33387391` succeeded. The 5.10-reconciled source is publication `18624245` / successful build `33407351`. Hardened `.1` source is pending publication `18624583`; arm64 build `33407863` is running. |

## Source Inputs

The local build wrapper currently owns these inputs:
`WORKSPACE_ROOT` defaults to the parent of this repository.

| Input | Default |
|-------|---------|
| Patched Armbian kernel worktree | `KERNEL_PPA_REPO=$WORKSPACE_ROOT/kernel/rock5b-kernel-build/armbian-build/cache/sources/linux-kernel-worktree/6.18__rockchip64__arm64` |
| Resolved kernel config | `KERNEL_PPA_CONFIG=$KERNEL_PPA_REPO/.config` |
| Source package name | `KERNEL_PPA_SOURCE=linux-rockchip64-ysp` |
| Upstream version | `KERNEL_PPA_UPSTREAM_VERSION=6.18.38+rk3588av1fwport20260716.1` |

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

The original source was generated on 2026-07-09, signed/uploaded on 2026-07-10
local time, then rebuilt as `~rk2` with `u-boot-tools` in Build-Depends. The
current physical-import-hardened source was generated, validated, signed, and
uploaded on 2026-07-16:

```text
packaging/ppa/out/artifacts/linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260716.1.orig.tar.gz
packaging/ppa/out/artifacts/linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260716.1-0ubuntu1~rk1.debian.tar.xz
packaging/ppa/out/artifacts/linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260716.1-0ubuntu1~rk1.dsc
packaging/ppa/out/artifacts/linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260716.1-0ubuntu1~rk1_source.changes
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
- Fresh-main API check on 2026-07-14 20:28 PDT: copied source publication
  `18619788` and all three copied arm64 binaries are Published in
  `ppa:yi-ding/ubuntu-rock-5b`.
- The 2026-07-16 production Armbian integration build applied the 37-patch
  forward-port series to 6.18.38, compiled and packaged image/DTB/headers/libc
  development packages successfully, and reported build identity
  `Pf618-Cb831`.
- The replacement source helper completed `dpkg-buildpackage -S -sa`, and
  `dpkg-source -x` verified every source checksum. Inspection of the extracted
  source confirmed the RGA low-voltage, config-error, sequential, shadow-page,
  IOMMU/register fixes; the RKVENC2 multi-slice terminal-error fix; AV1/VSI
  IOMMU; and the production config.
- `debsign` signed the replacement `.dsc`, `.buildinfo`, and `.changes` with
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`; direct GPG verification passed.
  `dput` uploaded all five artifacts, and Launchpad accepted upload `38666840`
  as source publication
  [`18624245`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18624245).
  Arm64 build
  [`33407351`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33407351)
  was `Currently building` at 16:07 PDT.
- The physical-import hardening increased the Armbian forward-port series to
  38 patches. A Docker-backed full integration build completed image, DTB, and
  headers packages with build identity `P4825-Cb831`. The patch was present in
  the applied worktree, and `rga_mm.o` compiled successfully.
- Source version
  `6.18.38+rk3588av1fwport20260716.1-0ubuntu1~rk1` completed
  `dpkg-buildpackage -S -sa`; `dscverify --nosigcheck` and a fresh
  `dpkg-source -x` validated the source archive. Inspection of that extracted
  source confirmed the per-page linear-map check and both overflow guards.
- A cold, full arm64 binary build from the freshly extracted `.dsc` completed
  with exit code 0. Its stable local artifacts are under
  `packaging/ppa/out/artifacts/local-binaries/6.18.38+rk3588av1fwport20260716.1/`:
  - image: `960ee91fdbde134f5b2fe0aa86410d51f0b0b8c491311ef1c5ef7ca45ed2ed57`;
  - DTB: `7a6f656345067ddfee40e9f35270f4e9f203776fe01b7d1467ab33afd606e4c6`;
  - headers: `7a54115d43907d12ca4f1f31adc71bdf50c77b98c5dec3043c1cfb70249461d3`.
- `debsign` signed the hardened `.dsc`, source `.buildinfo`, and source
  `.changes` with `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`.
  Direct `gpg --verify` reported good signatures from
  `Yi Ding <yi.s.ding@gmail.com>` on all three files. `dput` passed its
  pre-upload checks and transferred all five source artifacts to the main PPA.
- Launchpad accepted the hardened upload as pending source publication
  [`18624583`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18624583)
  and started arm64 build
  [`33407863`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33407863)
  on `bos03-arm64-036`. It was `Currently building` at 22:52 PDT.

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
- Full `lintian`; both source and binary scans were stopped after several
  minutes with no output because traversing the kernel archive/payload was
  taking too long.
- Booted-board confirmation that an invalid raw RGA physical import returns an
  errno without a warning, oops, or reboot. Do not enable the raw physical
  probes on the older `20260716` kernel.

## Remaining Checklist

1. Validate install, reboot, rollback, and `kernel-revert.sh` recovery on the
   board before giving install guidance.
