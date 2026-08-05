# kernel-rewrite-alpha-7.2-rc5/ - Armbian-based rewrite kernel package

This directory defines the co-installable ROCK 5B 7.2-rc5 rewrite kernel
package. It applies Armbian's `rockchip64-bleedingedge` patch layer to official
`v7.2-rc5`, then applies the clean-room rewrite series. It supersedes
[`kernel-rewrite-alpha-7.2-rc3/`](../kernel-rewrite-alpha-7.2-rc3/README.md)
as the intended successor package line; the rc3 package remains the last one
with Published binaries.

> **Deferred package boundary (2026-08-04):** this definition is pinned to an
> older rewrite snapshot and has not been uploaded. Maintained mainline tip
> `b296374b7520` on `v7.2-rc6` includes later AV1, ownership/recovery, and KUnit work. Rebase
> and revalidate this package before treating it as the current package line;
> its pins remain here only for reproducibility.

## Package shape

| Field | Value |
|-------|-------|
| PPA | `ppa:yi-ding/rock5b-kernel72rc2-rewrite` (legacy archive name) |
| Source package | `linux-rockchip64-ysp-alpha-7.2-rc5` |
| Binary packages | `linux-image-ysp-alpha-7.2-rc5-rockchip64`, `linux-dtb-ysp-alpha-7.2-rc5-rockchip64`, `linux-headers-ysp-alpha-7.2-rc5-rockchip64` |
| Kernel release | `7.2.0-rc5-ysp-alpha-7.2-rc5-rockchip64` |
| Debian version | `7.2.0~rc5+rk3588rewritealpha20260729-0ubuntu1` |
| Publication state | Not yet uploaded; see [`status.md`](../../../status.md). |

## Source inputs

| Layer | Pin |
|-------|-----|
| Official base | kernel.org `v7.2-rc5`, commit `f5098b6bae761` |
| Armbian patch layer | snapshot commit `d883b0b6a73b3` — harness-produced (`./compile.sh kernel-patches-to-git BOARD=rock-5b BRANCH=bleedingedge KERNELBRANCH=tag:v7.2-rc5`) from armbian/build checkout `53552811` (origin/main pulled 2026-07-29); per-patch worktree HEAD `d634cebc9438`; includes the 2026-07 `rockchip64-7.2` archive drift (rk3576 PWM v5 series, RK3588 CAN update, rk3328 dmc fix, overlays) |
| Rewrite series source | `rk3588-rewrite-mainline` at `2cf0126529c1c` (includes the 2026-07-29 atomic-safe fault-handler setter split) |
| Composite branch | `rk3588-rewrite-armbian-7.2-rc5` |
| Composite package head | `876f5583d65754b28beff1b364e305746c107a6e` |
| Default repository | `$WORKSPACE_ROOT/kernel/linux`; the exporter archives the composite commit directly, independent of the checked-out branch |
| Config | carried over from the rc3 package (`debian/config/arm64-rockchip64.config`); `olddefconfig` resolves new rc5 symbols at build time |

The rebased rewrite payload is byte-identical to the `rk3588-rewrite-mainline`
tip for both rewrite driver directories, `rockchip-iommu.c`, the
`soc/rockchip` headers, and `rk-mpp.h`. The rewrite series is the final layer
in the composite branch.

## Build

```sh
bash kernel-drivers/scripts/build-kernel.sh ppa-rewrite-7.2-rc5
# (delegates to packaging/ppa/build-source-packages.sh kernel-alpha-7.2-rc5)
```

`build-source-packages.sh` archives the composite package pin above directly;
the repository's checked-out branch does not affect the export.

## Validation

The focused clean-archive build gate (Rockchip IOMMU provider, both
KUnit-enabled rewrite objects, ROCK 5B DTB) is run against the composite head
via `KERNEL_MAINLINE=<composite checkout> rewrite-build-gate.sh mainline`;
record its result in `status.md` before uploading. Full source-package build,
Launchpad build, hardware install, boot, rollback, and recovery validation
remain required, as does a harness-regenerated Armbian snapshot if rc5-specific
patch drift is ever suspected.

## Runtime behavior and post-reboot validation

When this package's `7.2.0-rc5-ysp-alpha-7.2-rc5-rockchip64` kernel is booted,
the MPP and RGA rewrite drivers are built in and own `/dev/mpp_service` and
`/dev/rga`; the conflicting stock RGA driver is disabled. Installing the
co-installable package does not prove that this release is running.

Use the package-identity, debugfs-owner, boot-log, smoke, full-suite, and paired
comparison checklist in
[`rewrite-conformance.md`](../../../kernel-drivers/tests/rewrite-conformance.md#rewrite-acceptance-one-command),
and retain a known-good recovery kernel until the runtime gate passes.

The Debian helpers
[`install-kernel-packages.sh`](debian/scripts/install-kernel-packages.sh) and
[`write-maintainer-scripts.sh`](debian/scripts/write-maintainer-scripts.sh) are
kept byte-identical with the forward-port package and the other rewrite
package; `scripts/check-doc-consistency.py` enforces that invariant.
