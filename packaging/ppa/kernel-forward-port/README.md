# kernel-forward-port/ - PPA kernel source package

This directory owns the source-package path for the co-installable ROCK 5B
forward-port kernel. The current published candidate is:

| Field | Current evidence |
|-------|------------------|
| Version | `6.18.38+rk3588av1fwport20260717-0ubuntu1~rk1` |
| Launchpad | Source publication `18626523`; successful arm64 build `33412608`; exact image present in the live PPA index. |
| Contents | RGA session-close reference lifetime fix, early MPP procfs unlink, the preceding raw-import hardening, and the full MPP/RGA/AV1 forward port. |
| Board result | Package install and boot passed. The first conformance preflight Oopsed before a media case, so driver conformance and rollback remain unproven. |
| Newer source | Tracked forward-port patches `0042`/`0043` fix the KASAN-traced RESET_SESSION and RKVENC2 lifetime bugs and pass their memory-safety reruns. They are not in this Published package. |

Earlier package iterations established the packaging path: the initial build
failed because `mkimage` was absent; retry `18614559`/`33387391` added
`u-boot-tools`; recreated-main publication `18619788` copied the working
image/DTB/header set; and the 2026-07-16 replacements added the Rockchip 5.10
RGA reconciliation, RKVENC2 multi-slice fix, and raw physical-import hardening.
Their exact IDs and dated transitions remain in [Validation Status](#validation-status)
and the [upload log](../2026-07-06-ubuntu-rock-5b-upload-log.md), instead of
being mixed into the current-state summary.

The current kernel delivery path is still the Armbian wrapper in
[`../../../kernel-drivers/scripts/build-armbian-deb.sh`](../../../kernel-drivers/scripts/build-armbian-deb.sh),
which produces local binary `.deb`s under the external Armbian build workspace.
Launchpad PPAs accept source uploads (`.dsc` + `*_source.changes`), not arbitrary
prebuilt binary kernel `.deb`s, so those local artifacts cannot be added to
`ppa:yi-ding/ubuntu-rock-5b` directly.

## Packaging policy

The package remains conservative and recovery-friendly:

| Field | Decision |
|-------|----------|
| Source package | `linux-rockchip64-ysp`; do not reuse Armbian's source name until the upgrade/recovery behavior is proven. |
| Binary packages | Co-installable names first: `linux-image-ysp-rockchip64`, `linux-dtb-ysp-rockchip64`, and `linux-headers-ysp-rockchip64`. A later drop-in package can replace `linux-image-current-rockchip64` after boot/revert testing. |
| Architecture | `arm64` only. |
| Kernel variant | Armbian `rockchip64-current` 6.18.38 worktree with the self-contained-DT RK3588 MPP/RGA/AV1 forward-port applied. The older convert-in-place combined kernel can use the same source-package shape later if needed. |
| Upload state | Initial arm64 build `33387353` failed on missing `mkimage`; retry `33387391` succeeded. The 5.10-reconciled build `33407351`, physical-import-hardened build `33407863`, and session-lifetime build `33412608` all succeeded. |

## Source Inputs

The local build wrapper currently owns these inputs:
`WORKSPACE_ROOT` defaults to the parent of this repository.

| Input | Default |
|-------|---------|
| Patched Armbian kernel worktree | `KERNEL_PPA_REPO=$WORKSPACE_ROOT/kernel/rock5b-kernel-build/armbian-build/cache/sources/linux-kernel-worktree/6.18__rockchip64__arm64` |
| Resolved kernel config | `KERNEL_PPA_CONFIG=$KERNEL_PPA_REPO/.config` |
| Source package name | `KERNEL_PPA_SOURCE=linux-rockchip64-ysp` |
| Upstream version | `KERNEL_PPA_UPSTREAM_VERSION=6.18.38+rk3588av1fwport20260717` |

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
current session-lifetime source was generated, validated, signed, and uploaded
on 2026-07-17:

```text
packaging/ppa/out/artifacts/linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260717.orig.tar.gz
packaging/ppa/out/artifacts/linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260717-0ubuntu1~rk1.debian.tar.xz
packaging/ppa/out/artifacts/linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260717-0ubuntu1~rk1.dsc
packaging/ppa/out/artifacts/linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260717-0ubuntu1~rk1_source.changes
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
- The 2026-07-17 production integration build applied the complete 40-patch
  shipped series (41 forward-port commits minus the libbpf fix already present
  in Armbian), rebuilt `mpp_service.o` and `rga_mm.o`, and completed image,
  modules, DTBs, headers, and Debian packaging in eight minutes with build
  identity `Pbc61-C40aa`.
- Source version
  `6.18.38+rk3588av1fwport20260717-0ubuntu1~rk1` completed
  `dpkg-buildpackage -S -sa`. `dscverify --nosigcheck` and a fresh
  `dpkg-source -x` passed. Inspection of the extracted source confirmed the
  kref-based RGA session release, early MPP service-list unlink, and defensive
  RKVENC diagnostic guard; regenerating the packaged config with
  `olddefconfig` retained `CONFIG_ROCKCHIP_MPP_AV1DEC=y` and
  `CONFIG_VIDEO_ROCKCHIP_RGA=m`.
- The `.dsc`, source `.buildinfo`, and source `.changes` carry good signatures
  from `Yi Ding <yi.s.ding@gmail.com>`. `dput` uploaded all five artifacts;
  Launchpad accepted pending source publication
  [`18626523`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18626523)
  and started arm64 build
  [`33412608`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33412608).
- Build `33412608` completed successfully in 41m45s. The live arm64 PPA index
  contains the exact `linux-image-ysp-rockchip64` version and pool artifact.
- KASAN successor run `20260718-093751-kasan-narrowed` verifies forward-port
  patch `0042`: RESET_SESSION completed and the original double-free signature
  produced zero flagged kernel lines.
- KASAN codec-matrix run `20260718-103917-kasan-mpp-suite` verifies the memory
  paths through patches `0042`/`0043`: both kernel-log scans were empty and the
  ordinary H.264/H.265 encode cases passed. This was a later Armbian debug
  build, not a rebuild of the Published PPA package.

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

- Rollback and `kernel-revert.sh` recovery validation. Install and reboot of
  the 20260717 image passed; conformance did not.
- A production source/binary rebuild carrying tracked patches `0042` and
  `0043`. The current Published package stops at `0041`.
- An isolated rerun of the KASAN suite's functional failures:
  `mpi_dec_multi_h265` returned `EINVAL`, and the H.264/H.265 slice cases timed
  out while GRD's uncached-readback contention was active. Empty KASAN scans do
  not turn those cases into passes.
- Full `lintian`; both source and binary scans were stopped after several
  minutes with no output because traversing the kernel archive/payload was
  taking too long.
- Booted-board confirmation that an invalid raw RGA physical import returns an
  errno without a warning, oops, or reboot. Do not enable the raw physical
  probes on the older `20260716` kernel.

## Remaining Checklist

1. Re-run multi-instance H.265 and both slice-encode cases without concurrent
   GRD contention; preserve the functional logs and clean KASAN scan.
2. Rebuild/package the production forward-port with `0042`/`0043`, then run the
   full conformance gate on that exact image.
3. Validate rollback and `kernel-revert.sh` recovery on the board before giving
   install guidance. Install and reboot of the 20260717 image already pass.
