# Rewrite kernels rebased cleanly onto v6.18.42 and v7.2-rc6

> Scope: clean-room rewrite kernel source and focused cross-kernel validation
> Source: `rk3588-rewrite-6.18@19634f4eebbae75fce53efc850849cdbe55587c7` on `v6.18.42@856a9b51680c`; `rk3588-rewrite-mainline@b296374b752056d87d9d3a066d953682491168dd` on `v7.2-rc6@075b74841bd0`
> Date: 2026-08-04
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

Kernel.org's stable tag namespace ended at `v6.18.42`, and the 7.2 tag
namespace ended at `v7.2-rc6`; no final `v7.2` tag existed when queried. Both
linear rewrite branches were rebased onto those tags without a manual conflict:

- the 6.18 replay maps 384 commits exactly by `git range-diff`; Git dropped the
  old `tools: libbpf: make kallsyms helpers const-correct` commit because its
  patch was already present in `v6.18.42`;
- the mainline replay maps all 310 commits exactly by `git range-diff`;
- the tracked MPP/RGA implementation, Kconfig, ABI, and UAPI files remain
  byte-identical between the rebased branches;
- both branches retain the exact 92 MPP + 152 RGA KUnit manifest, and the source
  audit reports 305 known signals, zero new signals, and zero absent signals.

The warning-fatal clean-archive `normal` gate passed on both rebased tips. It
built `rockchip-iommu.o`, `vsi-iommu.o`, both KUnit-enabled rewrite objects, and
`rk3588-rock-5b.dtb`. The build used the only allowed compiler-cache store,
`~/Code/.ccache`, through a task-local compiler-launcher symlink; all scratch
state lived under `~/Code/rock-5b/build/rewrite-rebase-20260804/` and the gate
removed its archive/build directories after passing.

Local recovery branches preserve the pre-rebase tips:

- `ysp-backup/rk3588-rewrite-6.18-before-6.18.42-20260804` at
  `33c30ec6989eb6e2a4025e69c9873374d2f8949b`;
- `ysp-backup/rk3588-rewrite-mainline-before-7.2-rc6-20260804` at
  `9e503f6b16dfe3f054533b15c9a405075311ca01`.

## Evidence and reproduction

The authoritative tag query was:

```bash
git ls-remote --tags --refs stable 'v6.18.*'
git ls-remote --tags --refs stable 'v7.2*'
```

The exact validation command was:

```bash
mkdir -p ~/Code/rock-5b/build/rewrite-rebase-20260804/ccache-wrappers
ln -s /usr/bin/ccache \
  ~/Code/rock-5b/build/rewrite-rebase-20260804/ccache-wrappers/aarch64-linux-gnu-gcc
PATH=~/Code/rock-5b/build/rewrite-rebase-20260804/ccache-wrappers:/usr/sbin:/usr/bin:/sbin:/bin \
CCACHE_DIR=~/Code/.ccache \
REWRITE_BUILD_TMP_ROOT=~/Code/rock-5b/build/rewrite-rebase-20260804 \
bash kernel-drivers/tests/rewrite-build-gate.sh all
```

The fetched tags are annotated kernel.org tag objects. Local `git tag -v`
could display their metadata but could not authenticate either signature
because the corresponding public keys were not installed, so this finding does
not claim a local cryptographic signature verification.

## Boundary

This is source, range-equivalence, manifest, audit, and focused compile evidence.
It does not prove boot, KUnit execution, codec/RGA behavior, AV1/VSI behavior,
fault recovery, performance, fuzzing, or soak stability on hardware. The older
boot and package evidence cannot be promoted to these rebased tips.
