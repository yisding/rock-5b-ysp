# kernel-rewrite-alpha-7.2-rc2/ - PPA alpha rewrite kernel source package

This directory tracks the Launchpad PPA path for the ROCK 5B 7.2-rc2 alpha
clean-room rewrite kernel. It uses the same co-installable image, DTB, headers,
and maintainer-script shape as the forward-port PPA kernel, but with distinct
package names and a distinct localversion.

## Package Shape

| Field | Value |
|-------|-------|
| Source package | `linux-rockchip64-ysp-alpha-7.2-rc2` |
| Binary image package | `linux-image-ysp-alpha-7.2-rc2-rockchip64` |
| Binary DTB package | `linux-dtb-ysp-alpha-7.2-rc2-rockchip64` |
| Binary headers package | `linux-headers-ysp-alpha-7.2-rc2-rockchip64` |
| Kernel release | `7.2.0-rc2-ysp-alpha-7.2-rc2-rockchip64` |
| Upload state | Retry source publication `18614561` is Published; arm64 build `33387393` succeeded, and the image/DTB/header packages are in the public index. |
| Debian version | `7.2.0~rc2+rk3588rewritealpha20260710-0ubuntu1~rk2` |

## Source Inputs

| Input | Value |
|-------|-------|
| Kernel worktree | `/home/yi/Code/kernel/linux` |
| Branch | `rk3588-rewrite-mainline` |
| Commit | `083bdb98e715` |
| Upstream base | official kernel.org `v7.2-rc2` |
| Config | `debian/config/arm64-rockchip64.config`, seeded from Armbian `linux-rockchip64-bleedingedge.config` |

The local rewrite branch was rebased from `v7.2-rc1` to the official kernel.org
`v7.2-rc2` tag before this source package was generated. A backup branch exists
in the kernel worktree as `ysp-backup/rk3588-rewrite-mainline-before-7.2-rc2`.

## Debian helper scripts

These `debian/rules` helpers are source-package-local copies of the
forward-port package helpers. Keeping the copies makes each export
self-contained; `scripts/check-doc-consistency.py` enforces byte identity
across all three kernel package directories.

| Helper | Role |
|--------|------|
| [`debian/scripts/install-kernel-packages.sh`](debian/scripts/install-kernel-packages.sh) | Stages the image/modules, DTBs, and buildable headers into their binary-package roots. |
| [`debian/scripts/write-maintainer-scripts.sh`](debian/scripts/write-maintainer-scripts.sh) | Generates the Armbian-compatible image, DTB, and header maintainer scripts. |

## Build

```sh
bash packaging/ppa/build-source-packages.sh kernel-alpha-7.2-rc2
```

## Validation Status

Passed:

- Source package helper export and `dpkg-buildpackage -S`.
- `dpkg-source -x` of the generated `.dsc`.
- `debian/rules override_dh_auto_configure` in the extracted source.
- Resolved config keeps the rewrite drivers built in:
  `CONFIG_ROCKCHIP_MPP_REWRITE=y` and `CONFIG_ROCKCHIP_RGA_REWRITE=y`.
- Resolved config keeps the rewrite KUnit suites built in and keeps
  `CONFIG_KUNIT=y`.
- Resolved config disables the stock RGA driver and keeps `CONFIG_VSI_IOMMU=y`.
- `debsign` signed the `.dsc`, `.buildinfo`, and `.changes` with
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`.
- `dput ppa:yi-ding/ubuntu-rock-5b` completed client-side upload of the signed
  source package.
- Launchpad API check on 2026-07-10 23:30 PDT found source publication
  `18614550` in `Pending` state and arm64 build `33387367` `Currently building`
  on `bos03-arm64-008`.
- Retry `~rk2` adds `u-boot-tools` to Build-Depends, extracts cleanly from the
  generated `.dsc`, signs successfully, and was uploaded with `dput`.
- Launchpad API check on 2026-07-10 23:49 PDT found retry source publication
  `18614561` in `Pending` state and retry arm64 build `33387393`
  `Currently building` on `bos03-arm64-074`.
- Launchpad API/public-index check on 2026-07-11 21:44 PDT found source
  publication `18614561` Published, build `33387393` `Successfully built`, and
  the image, DTB, and headers packages public.

Not done yet:

- Local arm64 binary build from the generated source package.
- Payload comparison against the forward-port and Armbian kernel packages.
- Board install, reboot, rollback, and `kernel-revert.sh` recovery validation.
