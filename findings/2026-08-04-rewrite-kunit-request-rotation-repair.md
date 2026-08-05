# Current rewrite tips repair request cleanup and rotation KUnit contracts

> Scope: clean-room MPP/RGA rewrite source parity and current-tip focused build
> Source: `rk3588-rewrite-6.18@33c30ec6989eb6e2a4025e69c9873374d2f8949b`;
> `rk3588-rewrite-mainline@9e503f6b16dfe3f054533b15c9a405075311ca01`;
> `rga_rewrite.c` `rk_rga_request_config()` and the RGA3 rotation KUnit cases
> Date: 2026-08-04
> Trust: **CODE-INSPECTED**, **COMPILE-VERIFIED**, **PARTIAL**

> **Followed 2026-08-04 by** [the `v6.18.42` / `v7.2-rc6` rebase and build finding](2026-08-04-rewrite-kernel-rebase-6-18-42-7-2-rc6.md).
> The repair remains patch-equivalent at the rebased tips; this finding keeps
> the original commit identities and build evidence.

## Result

The maintained 6.18 and mainline rewrite branches now carry the same final
repair. `rk_rga_request_config()` can reach its shared exit without having
consumed a prior configured request; it now calls `rk_rga_request_free()` only
when `consumed` is non-NULL. This closes a KUnit-path NULL dereference without
changing terminal replacement cleanup.

The same commit repairs stale rotation oracles. RGA3 pattern-blend rotation
still returns `-EOPNOTSUPP` because its BSP wire/canvas contract is unresolved.
The negative cases now assert that rejection, while the existing positive
rotation path clears the pattern descriptor before emission. The change does
not increase or reduce the manifest: it remains exactly **92 MPP + 152 RGA =
244** cases.

The tracked MPP/RGA C sources, Kconfig, Makefiles, ABI ledgers, and UAPI are
byte-identical between 6.18 `33c30ec6989e` and mainline `9e503f6b16df`. Both
tips pass the warning-fatal clean-archive `normal` build, including Rockchip
and VSI IOMMU support, both KUnit-enabled rewrite objects, and the ROCK 5B DTB.
The source audit reports **305 known signals, zero new, and zero absent** on
both trees.

## Architecture boundary

This repair changes test correctness and one cleanup guard; it does not change
the as-built ownership architecture. Shared MPP decoder state remains divided
among service, hardware, reset-domain mutex, and DMA-group objects, while an
RGA job still carries the selected hardware, task mappings, command buffer,
and activation generation for its current task. The proposed
`rk_mpp_cluster`, `rk_mpp_activation`, `rk_rga_task_exec`, and
`rk_rga_acquire_set` types are absent from both maintained trees. They remain
the target described by the
[ownership refactor plan](../kernel-drivers/docs/rewrite-ownership-refactor-plan.md),
not properties of the current implementation.

The source also contains the VPU981 AV1 backend and VSI-IOMMU integration.
That is implementation/build scope, not a hardware result.

## Evidence and reproduction

- **Identity:** 6.18 branch `rk3588-rewrite-6.18` at full commit
  `33c30ec6989eb6e2a4025e69c9873374d2f8949b`; mainline branch
  `rk3588-rewrite-mainline` at full commit
  `9e503f6b16dfe3f054533b15c9a405075311ca01`.
- **Code inspection:** `git show` of the two tips, targeted symbol searches,
  and byte comparison of the tracked rewrite source/config/ABI/UAPI set.
- **Audit:** `bash kernel-drivers/tests/rewrite-build-gate.sh audit` — pass on
  both branches, 305/0/0 known/new/absent signals.
- **Build reproduction:** use disposable state under
  `../rock-5b/build/rewrite-doc-refresh` and the sole shared cache at
  `~/Code/.ccache`:

  ```sh
  CCACHE_DIR=~/Code/.ccache \
  CROSS_COMPILE='ccache aarch64-linux-gnu-' \
  REWRITE_BUILD_TMP_ROOT=../rock-5b/build/rewrite-doc-refresh \
  JOBS=16 ALLOW_DIRTY=1 REWRITE_BUILD_PROFILES=normal \
    bash kernel-drivers/tests/rewrite-build-gate.sh all
  ```

  The recorded `normal` result is PASS at `33c30ec6989e` and `9e503f6b16df`,
  warning-free for the focused profile. That completed run predates the
  repository's single-cache-path correction; cache placement does not alter
  the archived source or compiler output. A repeat using `~/Code/.ccache` was
  stopped by operator request before completion and is not claimed as a second
  pass. `ALLOW_DIRTY=1` was required because the external worktrees' indexes
  reported stale modifications while `git diff` was empty; the gate archived
  the named commits rather than building uncommitted source.

## Boundary

No current-tip kernel was packaged, installed, or booted. The test-disabled,
memory, race, and ABI-mutation profiles were not rerun at these tips. This
finding therefore does not establish booted 244-case KUnit, live lockdep,
kmemleak, codec/RGA output, AV1/VSI behavior, recovery, performance, fuzz, or
soak. Boot `#29` (`g8042f13c5459`) and installed-but-never-booted package `#30`
both predate the current source.
