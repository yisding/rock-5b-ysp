# patches/

The kernel-side patch deliverables of this repo:

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Choose the frozen validated base pair, the actively maintained AV1 forward-port series, or the stock-kernel DKMS source without confusing their different validation states. |
| Developer focus | Review the forward-port artifacts, the RK3588 DT patch, and the BSP-audit cleanup series without losing provenance. |
| Owns | The generated forward-port patches, debug-only DT patch, `cleanup-split/`, and the historical `cleanup-draft/` verification record. |
| Depends on | Source-tree pins in [`docs/source-trees.md`](../../docs/source-trees.md), kernel-driver explanations in [`kernel-drivers/README.md`](../README.md), and maintenance workflow in [`kernel-drivers/docs/resyncing.md`](../docs/resyncing.md). |
| Current state | The frozen two-patch non-AV1 base remains the July 4 hardware baseline and DKMS source. The maintained AV1/PPA series now runs through `0043`; KASAN verifies its two newest lifetime fixes, while a production rebuild and isolated functional conformance remain open. The cleanup series is staged and currently fails its compile gate. See [`status.md`](../../status.md). |

| Path | What it is | Detail |
|------|------------|--------|
| `rk3588-rkvenc2-01-vcodec-rga-drivers.patch` | ~980 KB — the vendor MPP (`rk_vcodec`) + RGA (`multi_rga`) **drivers**, forward-ported to 6.18 (58 files: compat shims, hack files, API + bring-up fixes, Kconfig). | [forward-port guide](../../kernel-versions/docs/vendor-forward-port.md) |
| `rk3588-rkvenc2-02-vcodec-rga-dt.patch` | ~16 KB — **device tree**: encoder + RGA nodes inline, decoder via convert-in-place override, board enables. | [device-tree guide](../docs/device-tree.md), [Armbian packaging guide](../../packaging/docs/armbian-packaging.md) |
| [`cleanup-split/`](cleanup-split) | **THE reviewable BSP-audit fix series** — 65 one-issue-per-patch mailbox patches fixing the [BSP audit](../docs/bsp-audit.md) findings on top of the forward-port. Apply/review **this**, not the draft. | [`cleanup-split/README.md`](cleanup-split/README.md) |
| [`cleanup-draft/`](cleanup-draft) | **Historical** per-file fix bundles (15 patches) + [`verification.md`](./cleanup-draft/verification.md), the adversarial-verification **record** for the same fixes. Kept as the audit's provenance trail; superseded for application by `cleanup-split/`. | [`cleanup-draft/README.md`](cleanup-draft/README.md) |
| [`rga-userptr-iommu/`](rga-userptr-iommu) | **RGA3 scattered-userptr IOMMU fallback** — forward-port and rewrite patches that map scattered pinned userptr through a driver-owned contiguous IOVA span in the translated RGA domain. | [`rga-userptr-iommu/README.md`](rga-userptr-iommu/README.md) |
| [`forward-port-rk3588-av1/`](forward-port-rk3588-av1) | Actively maintained 42-file RK3588 MPP/RGA/AV1 forward-port series (`0001`–`0043`, with `0012` omitted), including the current KASAN-derived `0042`/`0043` lifetime fixes. This is the PPA/build source line; generated `.deb`s and worktrees stay outside git. | [`forward-port-rk3588-av1/README.md`](forward-port-rk3588-av1/README.md) |
| [`debug-kernel/`](debug-kernel) | Debug-build-only ROCK 5B DT patch reserving the BSP-derived persistent low-memory window for upstream ramoops. Staged automatically by the debug-kernel builder; not part of production forward-port packages. | [debug-kernel guide](../docs/debug-kernel.md) |
| [`iommu-debug/`](iommu-debug/README.md) | Archived opt-in RK3588 IOMMU/RGA diagnostic instrumentation and config wiring for the IOMMU machinery fuzzer; excluded from clean production builds. | [`iommu-debug/README.md`](iommu-debug/README.md) |

> **⚠️ Runtime gate PENDING** — the runtime codec regression test (encode/decode/transcode plus the targeted triggers listed in `patches/cleanup-draft/verification.md`) has **never been run** on a kernel carrying these fixes. Compile status alone is not verification. Do not ship the series without the runtime gate; track it in `status.md` and record the result in `patches/cleanup-draft/verification.md` when run.

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
