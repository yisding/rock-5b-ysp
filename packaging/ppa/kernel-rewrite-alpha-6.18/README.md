# kernel-rewrite-alpha-6.18/ - Armbian-based rewrite kernel package

This directory defines the co-installable ROCK 5B 6.18 rewrite kernel package.
The replacement package now uses the exact Armbian current/forward-port source
line first, then applies the clean-room rewrite series.

> **Historical package boundary (2026-08-04):** this fixed package pin predates
> maintained rewrite tip `33c30ec6989e`, the source VPU981 AV1 backend, and the
> current 92+152 KUnit manifest. Its publication/build result must not be cited
> as current-source build, boot, or architecture evidence.

## Package shape

| Field | Value |
|-------|-------|
| PPA | `ppa:yi-ding/rock5b-kernel618-rewrite` |
| Source package | `linux-rockchip64-ysp-alpha-6.18` |
| Binary packages | `linux-image-ysp-alpha-6.18-rockchip64`, `linux-dtb-ysp-alpha-6.18-rockchip64`, `linux-headers-ysp-alpha-6.18-rockchip64` |
| Kernel release | `6.18.38-ysp-alpha-6.18-rockchip64` |
| Debian version | `6.18.38+rk3588rewritealpha20260715-0ubuntu1` |
| Publication state | Source publication [`18623665`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel618-rewrite/+sourcepub/18623665), successful arm64 build [`33406491`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel618-rewrite/+build/33406491), and the exact replacement binaries are Published. |

## Source inputs

| Layer | Pin |
|-------|-----|
| Linux/Armbian/forward-port snapshot | Linux 6.18.38, snapshot commit `2ff6303a64ce` |
| Rewrite series source | `rk3588-rewrite-6.18` at `563f329dd8c4` |
| Composite branch | `rk3588-rewrite-armbian-6.18.38` |
| Composite package head | `8daf5e9513b8aa9de018dad7754b6efacfd0fd49` |
| Default repository | `$WORKSPACE_ROOT/kernel/linux-6.18-rkvenc`; the exporter archives the composite commit directly, independent of the checked-out branch |
| Config | Armbian `linux-rockchip64-current.config` plus rewrite/KUnit enablement and conflicting MPP/RGA drivers disabled |

The base snapshot is the same patched Linux 6.18.38 worktree used to export the
forward-port kernel package. That means this package inherits Armbian's
`rockchip64-current` patches and the forward-port source additions before the
rewrite commits are applied.

## Build

```sh
bash kernel-drivers/scripts/build-kernel.sh ppa-rewrite-6.18
# (delegates to packaging/ppa/build-source-packages.sh kernel-alpha-6.18)
```

`build-source-packages.sh` archives the composite package pin above directly;
the repository's checked-out branch does not affect the export.

## Validation

The clean archive build gate passes warning-free at the composite head for the
Rockchip IOMMU provider, both KUnit-enabled rewrite objects, and the ROCK 5B
DTB. The source package and full native arm64 image, DTB, and headers builds
pass. The resolved package config keeps the rewrite drivers and KUnit suites
built in and disables the conflicting vendor MPP/RGA drivers. The full build's
warnings are confined to inherited Armbian DRM and external Wi-Fi sources; the
focused rewrite gate is warning-free. Hardware install, boot, rollback, and
recovery validation remain required.

## Runtime behavior and post-reboot validation

When this package's `6.18.38-ysp-alpha-6.18-rockchip64` kernel is booted,
`CONFIG_ROCKCHIP_MPP_REWRITE=y` and `CONFIG_ROCKCHIP_RGA_REWRITE=y` make the
rewrite drivers the built-in owners of `/dev/mpp_service` and `/dev/rga`. The
conflicting vendor MPP service and RGA drivers are disabled. Installing the
co-installable package is not sufficient evidence by itself: verify the
running release, rewrite debugfs ownership, boot log, hardware smoke workloads,
and counter deltas after reboot.

The exact preflight, quick smoke command for the maintained sibling-worktree
layout, standalone full suite, and forward-port-vs-rewrite comparison are in
[`rewrite-conformance.md`](../../../kernel-drivers/tests/rewrite-conformance.md#rewrite-acceptance-one-command).
Keep the existing Armbian or forward-port kernel available as the recovery boot
until this checklist passes.

The Debian helpers
[`install-kernel-packages.sh`](debian/scripts/install-kernel-packages.sh) and
[`write-maintainer-scripts.sh`](debian/scripts/write-maintainer-scripts.sh) are
kept byte-identical with the forward-port package and the other rewrite
package; `scripts/check-doc-consistency.py` enforces that invariant.
