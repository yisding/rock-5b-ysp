# kernel-rewrite-alpha-6.18/ - PPA alpha rewrite kernel source package

This directory tracks the Launchpad PPA path for the ROCK 5B 6.18 alpha
clean-room rewrite kernel. It uses the same co-installable image, DTB, headers,
and maintainer-script shape as the forward-port PPA kernel, but with distinct
package names and a distinct localversion.

## Package Shape

| Field | Value |
|-------|-------|
| PPA | `ppa:yi-ding/rock5b-kernel618-rewrite` |
| Source package | `linux-rockchip64-ysp-alpha-6.18` |
| Binary image package | `linux-image-ysp-alpha-6.18-rockchip64` |
| Binary DTB package | `linux-dtb-ysp-alpha-6.18-rockchip64` |
| Binary headers package | `linux-headers-ysp-alpha-6.18-rockchip64` |
| Kernel release | `6.18.0-ysp-alpha-6.18-rockchip64` |
| Upload state | Original build `33387392` succeeded; source and binaries were copied to the dedicated PPA as source publication `18619546`. |
| Debian version | `6.18.0+rk3588rewritealpha20260710-0ubuntu1~rk2` |

## Source Inputs

`WORKSPACE_ROOT` defaults to the parent of this repository.

| Input | Value |
|-------|-------|
| Kernel worktree | `$WORKSPACE_ROOT/kernel/linux-6.18-rkvenc` (the original build used `/home/yi/Code/kernel/linux-6.18-rkvenc`) |
| Branch | `rk3588-rewrite-6.18` |
| Commit | `d1d15a3d052a` |
| Config | `debian/config/arm64-rockchip64.config`, snapshotted from the worktree `.config` |

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
bash packaging/ppa/build-source-packages.sh kernel-alpha-6.18
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
  `18614549` in `Pending` state and arm64 build `33387366` `Currently building`
  on `bos03-arm64-032`.
- Retry `~rk2` adds `u-boot-tools` to Build-Depends, extracts cleanly from the
  generated `.dsc`, signs successfully, and was uploaded with `dput`.
- Launchpad API check on 2026-07-10 23:49 PDT found retry source publication
  `18614560` in `Pending` state and retry arm64 build `33387392`
  `Currently building` on `bos03-arm64-110`.
- Launchpad API/public-index check on 2026-07-11 21:44 PDT found source
  publication `18614560` Published, build `33387392` `Successfully built`, and
  the image, DTB, and headers packages public.

Not done yet:

- Local arm64 binary build from the generated source package.
- Payload comparison against the forward-port and Armbian kernel packages.
- Board install, reboot, rollback, and `kernel-revert.sh` recovery validation.
