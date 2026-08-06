# kernel-rewrite-alpha-7.2-rc3/ - Armbian-based rewrite kernel package

This directory defines the co-installable ROCK 5B 7.2-rc3 rewrite kernel
package. It applies Armbian's `rockchip64-bleedingedge` patch layer to official
`v7.2-rc3`, then applies the clean-room rewrite series.

> **Historical package boundary (2026-08-04):** this fixed package pin predates
> maintained mainline rewrite tip `b296374b7520`, the source VPU981 AV1 backend,
> and the current 92+152 KUnit manifest. Its publication/build result must not
> be cited as current-source build, boot, or architecture evidence.

## Package shape

| Field | Value |
|-------|-------|
| PPA | `ppa:yi-ding/rock5b-kernel72rc2-rewrite` (legacy archive name) |
| Source package | `linux-rockchip64-ysp-alpha-7.2-rc3` |
| Binary packages | `linux-image-ysp-alpha-7.2-rc3-rockchip64`, `linux-dtb-ysp-alpha-7.2-rc3-rockchip64`, `linux-headers-ysp-alpha-7.2-rc3-rockchip64` |
| Kernel release | `7.2.0-rc3-ysp-alpha-7.2-rc3-rockchip64` |
| Debian version | `7.2.0~rc3+rk3588rewritealpha20260715-0ubuntu1` |
| Publication state | Source publication [`18623666`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel72rc2-rewrite/+sourcepub/18623666), successful arm64 build [`33406492`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel72rc2-rewrite/+build/33406492), and the exact replacement binaries are Published. |

## Source inputs

| Layer | Pin |
|-------|-----|
| Official base | kernel.org `v7.2-rc3`, commit `a13c140cc289c0b7b3770bce5b3ad42ab35074aa` |
| Armbian patch source | build checkout `5cbc1c59c`, `rockchip64-bleedingedge` patch set |
| Armbian patch identity | `7.2-rc3-Sa13c-D398d-P86f0-Cd50f-H8200-HK01ba-Vc222-B5272-R448a` |
| Armbian-patched snapshot | `2657f01c9b9acc566431729c8da89e1dd7f3b5a1` |
| Rewrite series source | `rk3588-rewrite-mainline` at `856743fc3c3d` |
| Composite branch | `rk3588-rewrite-armbian-7.2-rc3` |
| Composite package head | `24f7424fb9589ea2118127084a5f2748aa762b63` |
| Default repository | `$WORKSPACE_ROOT/kernel/linux`; the exporter archives the composite commit directly, independent of the checked-out branch |
| Config | Armbian `linux-rockchip64-bleedingedge.config` plus rewrite/KUnit enablement and the conflicting stock RGA driver disabled |

The Armbian snapshot includes both the normal patch archive and the generated
external-driver patch payload selected by the Armbian build harness. Patcher
backup files (`*.orig`/`*.rej`) are excluded. The rewrite series is the final
layer in the composite branch.

## Build

```sh
bash kernel-drivers/scripts/build-kernel.sh ppa-rewrite-7.2-rc3
# (delegates to packaging/ppa/build-source-packages.sh kernel-alpha-7.2-rc3)
```

`build-source-packages.sh` archives the composite package pin above directly;
the repository's checked-out branch does not affect the export.

## Validation

The clean archive build gate passes warning-free at the composite head for the
Rockchip IOMMU provider, both KUnit-enabled rewrite objects, and the ROCK 5B
DTB. The source package and full native arm64 image, DTB, and headers builds
pass. The resolved package config keeps the rewrite drivers and KUnit suites
built in and disables the conflicting stock RGA driver. The full build reports
inherited warnings in the Rockchip DDR clock helper and Armbian's generated
external Wi-Fi driver payload; the focused rewrite gate is warning-free.
Hardware install, boot, rollback, and recovery validation remain required.

## Runtime behavior and post-reboot validation

When this package's `7.2.0-rc3-ysp-alpha-7.2-rc3-rockchip64` kernel is booted,
the MPP and RGA rewrite drivers are built in and own `/dev/mpp_service` and
`/dev/rga`; the conflicting stock RGA driver is disabled. Installing the
co-installable package does not prove that this release is running.

Use the package-identity, debugfs-owner, boot-log, smoke, full-suite, and paired
comparison checklist in
[`conformance.md`](../../../kernel-drivers/tests/conformance.md#rewrite-acceptance-one-command),
and retain a known-good recovery kernel until the runtime gate passes.

The Debian helpers
[`install-kernel-packages.sh`](debian/scripts/install-kernel-packages.sh) and
[`write-maintainer-scripts.sh`](debian/scripts/write-maintainer-scripts.sh) are
kept byte-identical with the forward-port package and the other rewrite
package; `scripts/check-doc-consistency.py` enforces that invariant.
