# patches/

The kernel-side patch deliverables of this repo:

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Build the forward-port kernel from the single maintained series, or use the stock-kernel DKMS source, without confusing their different validation states. |
| Developer focus | Review the forward-port artifacts, the RK3588 DT patch, and the BSP-audit cleanup series without losing provenance. |
| Owns | The generated forward-port patches, debug-only DT patch, `cleanup-split/`, and the historical `cleanup-draft/` verification record. |
| Depends on | Source-tree pins in [`docs/source-trees.md`](../../docs/source-trees.md), kernel-driver explanations in [`kernel-drivers/README.md`](../README.md), and maintenance workflow in [`kernel-drivers/docs/resyncing.md`](../docs/resyncing.md). |
| Current state | There is one forward-port kernel line: the contiguous `0001`–`0075` series under [`forward-port-rk3588/`](forward-port-rk3588/README.md), with AV1 included. The frozen two-patch pair below is the superseded July 4 import retained for DKMS and provenance, not a second kernel choice. The cleanup series remains historical audit work. See the validation boundary below and [`status.md`](../../status.md) for what is actually boot-proven. |

| Path | What it is | Detail |
|------|------------|--------|
| `rk3588-rkvenc2-01-vcodec-rga-drivers.patch` | ~980 KB — the vendor MPP (`rk_vcodec`) + RGA (`multi_rga`) **drivers**, forward-ported to 6.18 (58 files: compat shims, hack files, API + bring-up fixes, Kconfig). | [forward-port guide](../../kernel-versions/docs/vendor-forward-port.md) |
| `rk3588-rkvenc2-02-vcodec-rga-dt.patch` | ~16 KB — **device tree**: encoder + RGA nodes inline, decoder via convert-in-place override, board enables. | [device-tree guide](../docs/device-tree.md), [Armbian packaging guide](../../packaging/docs/armbian-packaging.md) |
| [`cleanup-split/`](cleanup-split) | The original-tree, reviewable 65-patch BSP-audit series. The 11 HIGH fixes still missing after later forward-port work were ported to the evolved source as `forward-port-rk3588/0058`-`0068`; use this older series for the unported MEDIUM/LOW/cleanup work and its audit history. | [`cleanup-split/README.md`](cleanup-split/README.md) |
| [`cleanup-draft/`](cleanup-draft) | **Historical** per-file fix bundles (15 patches) + [`verification.md`](./cleanup-draft/verification.md), the adversarial-verification **record** for the same fixes. Kept as the audit's provenance trail; superseded for application by `cleanup-split/`. | [`cleanup-draft/README.md`](cleanup-draft/README.md) |
| [`rga-userptr-iommu/`](rga-userptr-iommu) | **RGA3 scattered-userptr IOMMU fallback** — forward-port and rewrite patches that map scattered pinned userptr through a driver-owned contiguous IOVA span in the translated RGA domain. | [`rga-userptr-iommu/README.md`](rga-userptr-iommu/README.md) |
| [`forward-port-rk3588/`](forward-port-rk3588) | **The** 75-file RK3588 MPP/RGA/AV1 forward-port series and PPA/build source line. Its README is the mechanical index; the patch catalog owns provenance and BSP-backport classification. Generated `.deb`s and worktrees stay outside git. | [`forward-port-rk3588/README.md`](forward-port-rk3588/README.md), [per-patch provenance/backport catalog](../docs/patch-catalog.md) |
| [`debug-kernel/`](debug-kernel) | Debug-build-only ROCK 5B DT patch reserving the BSP-derived persistent low-memory window for upstream ramoops. Staged automatically by the debug-kernel builder; not part of production forward-port packages. | [debug-kernel guide](../docs/debug-kernel.md) |
| [`iommu-debug/`](iommu-debug/README.md) | Archived opt-in RK3588 IOMMU/RGA diagnostic instrumentation and config wiring for the IOMMU machinery fuzzer; excluded from clean production builds. | [`iommu-debug/README.md`](iommu-debug/README.md) |

> **⚠️ Runtime gate OWED for `0072`-`0075`** — compile status alone is not
> verification, and here it has already been caught out: the `0072` gate was run
> on-board and *failed*, which is what `0074` exists to fix. Do not treat the
> 10-bit RGA stride tail as shipped until its gate is green; the gate is spelled
> out in the [UV-offset finding](../../findings/2026-07-24-rga-10bit-uv-plane-offset-still-pixel-scaled.md).
> The BSP-audit HIGH subset `0058`-`0068` **has** passed its targeted triggers and
> the codec/RGA regression sweep on booted `Pabd5-C4ad2` (see
> [`status.md`](../../status.md)); the historical full cleanup series has still
> never completed its runtime gate.

The generic Armbian apply flow below is for the two frozen base patches named
`rk3588-rkvenc2-0*.patch`. Do not drop `rga-userptr-iommu/*.patch` into
Armbian's patch archive as a pair: the RGA userptr-IOMMU patches have a
separate consumption flow in
[`rga-userptr-iommu/runtime-validation.md`](rga-userptr-iommu/runtime-validation.md).
Patch 0001 is applied to the forward-port source tree and regenerated through
`KERNEL_TREE=...`; patch 0002 is rewrite-only.

The two base patches are generated against **pristine mainline `v6.18`** (two
commits on top of the `v6.18` tag) and map to the two dev-tree commits:

```
video: rockchip: RK3588 vendor MPP (rkvenc2/rkvdec2) + RGA3/RGA2 drivers   → patch 01
arm64: dts: rockchip: rk3588: VEPU580 encoder, rkvdec2 decoder, RGA3 nodes → patch 02
```

The tree they produce (`git checkout v6.18 && git am rk3588-rkvenc2-0*.patch`,
tip `5614909e5803`) is the anchor tree for
[source-tree pins](../../docs/source-trees.md) and the base the cleanup series applies to.

## Apply — Armbian (the intended path)

The canonical end-to-end walkthrough (prerequisites, build, install, validate,
userspace handoff) is [`install.md`](../../install.md). The patches-specific facts:

Drop both into the kernel patch archive for your branch; Armbian applies
`userpatches/` automatically. **No edits to Armbian's own files are needed** — the
config is carried by the patch's Kconfig defaults and the decoder DT overrides
Armbian's `media-0001` nodes in place ([Armbian packaging guide](../../packaging/docs/armbian-packaging.md)).

```bash
cp rk3588-rkvenc2-0*.patch \
   <armbian-build>/userpatches/kernel/archive/rockchip64-6.18/
cd <armbian-build>
./compile.sh kernel BOARD=rock-5b BRANCH=current KERNEL_CONFIGURE=no USE_CCACHE=yes
```

> Patch **02** assumes Armbian's `media-0001-Add-rkvdec-Support-v5.patch` is
> present (it overrides that patch's `vdec0/vdec1` nodes). On a different
> Armbian branch, confirm those node labels still exist.

## Apply — vanilla mainline 6.18

```bash
cd linux-6.18
git apply /path/to/rk3588-rkvenc2-01-vcodec-rga-drivers.patch   # driver: applies as-is
```
For the **device tree**, patch 02 won't apply unmodified — vanilla has no
`vdec0/vdec1` nodes to override. Use the **inline** decoder DT form instead; see
[vanilla-kernel guide](../../kernel-versions/docs/vanilla-kernel.md).

## Consuming patch 01 without a kernel rebuild

The driver source in patch 01 is also packaged as an out-of-tree **DKMS** module
pair (`rk_vcodec.ko` + `rga3.ko`) for stock 6.18+ kernels — see
[`packaging/dkms`](../../packaging/dkms). **Mutually exclusive** with a kernel
that already carries the drivers `=y` (modpost fails with "exported twice");
choose one delivery model via [`install.md`](../../install.md).

## Regenerating

The patches are `git format-patch v6.18..HEAD` from the dev tree. If you re-sync
the vendor code or change the DT, regenerate both and re-copy them here and into
the Armbian userpatch dir ([resyncing guide](../docs/resyncing.md) is the resync
checklist; the cleanup series and `packaging/dkms/` consume the same source and
must be refreshed too).
