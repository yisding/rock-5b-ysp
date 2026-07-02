# patches/

The kernel-side deliverables of this repo, in three layers:

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Apply the kernel patch pair through Armbian userpatches or use it as the source for the DKMS path. |
| Developer focus | Review the forward-port artifacts, the RK3588 DT patch, and the BSP-audit cleanup series without losing provenance. |
| Owns | The two generated forward-port patches, `cleanup-split/`, and the historical `cleanup-draft/` verification record. |
| Depends on | Source-tree pins in [`../docs/00-source-trees.md`](../docs/00-source-trees.md), kernel-driver explanations in [`../kernel-drivers/`](../kernel-drivers/README.md), and maintenance workflow in [`../docs/12-resyncing.md`](../docs/12-resyncing.md). |
| Current state | The forward-port patch pair is the validated kernel base; the cleanup series is staged but its runtime gate remains pending. See [`../STATUS.md`](../STATUS.md). |

| Path | What it is | Detail |
|------|------------|--------|
| `rk3588-rkvenc2-01-vcodec-rga-drivers.patch` | ~980 KB — the vendor MPP (`rk_vcodec`) + RGA (`multi_rga`) **drivers**, forward-ported to 6.18 (58 files: compat shims, hack files, API + bring-up fixes, Kconfig). | [`docs/05`](../docs/05-vendor-forward-port.md) |
| `rk3588-rkvenc2-02-vcodec-rga-dt.patch` | ~16 KB — **device tree**: encoder + RGA nodes inline, decoder via convert-in-place override, board enables. | [`docs/07`](../docs/07-device-tree.md), [`docs/08`](../docs/08-armbian-packaging.md) |
| [`cleanup-split/`](cleanup-split/) | **THE reviewable BSP-audit fix series** — 65 one-issue-per-patch mailbox patches fixing the [`docs/11`](../docs/11-bsp-audit.md) findings on top of the forward-port. Apply/review **this**, not the draft. | [`cleanup-split/README.md`](cleanup-split/README.md) |
| [`cleanup-draft/`](cleanup-draft/) | **Historical** per-file fix bundles (15 patches) + [`VERIFICATION.md`](cleanup-draft/VERIFICATION.md), the adversarial-verification **record** for the same fixes. Kept as the audit's provenance trail; superseded for application by `cleanup-split/`. | [`cleanup-draft/README.md`](cleanup-draft/README.md) |

> **⚠️ Runtime gate PENDING** — the runtime codec regression test (encode/decode/transcode plus the targeted triggers listed in `patches/cleanup-draft/VERIFICATION.md`) has **never been run** on a kernel carrying these fixes. Compile status alone is not verification. Do not ship the series without the runtime gate; track it in `STATUS.md` and record the result in `patches/cleanup-draft/VERIFICATION.md` when run.

The two numbered patches are generated against **pristine mainline `v6.18`** (two
commits on top of the `v6.18` tag) and map to the two dev-tree commits:

```
video: rockchip: RK3588 vendor MPP (rkvenc2/rkvdec2) + RGA3/RGA2 drivers   → patch 01
arm64: dts: rockchip: rk3588: VEPU580 encoder, rkvdec2 decoder, RGA3 nodes → patch 02
```

The tree they produce (`git checkout v6.18 && git am rk3588-rkvenc2-0*.patch`,
tip `5614909e5803`) is the anchor tree for
[`docs/00`](../docs/00-source-trees.md) and the base the cleanup series applies to.

## Apply — Armbian (the intended path)

The canonical end-to-end walkthrough (prerequisites, build, install, validate,
userspace handoff) is [`INSTALL.md`](../INSTALL.md). The patches-specific facts:

Drop both into the kernel patch archive for your branch; Armbian applies
`userpatches/` automatically. **No edits to Armbian's own files are needed** — the
config is carried by the patch's Kconfig defaults and the decoder DT overrides
Armbian's `media-0001` nodes in place ([`docs/08`](../docs/08-armbian-packaging.md)).

```bash
cp rk3588-rkvenc2-0*.patch \
   <armbian-build>/userpatches/kernel/archive/rockchip64-6.18/
bash ../scripts/build-combined-kernel.sh
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
[`docs/09`](../docs/09-vanilla-kernel.md).

## Consuming patch 01 without a kernel rebuild

The driver source in patch 01 is also packaged as an out-of-tree **DKMS** module
pair (`rk_vcodec.ko` + `rga3.ko`) for stock 6.18+ kernels — see
[`packaging/dkms/`](../packaging/dkms/). **Mutually exclusive** with a kernel
that already carries the drivers `=y` (modpost fails with "exported twice");
choose one delivery model via [`INSTALL.md`](../INSTALL.md).

## Regenerating

The patches are `git format-patch v6.18..HEAD` from the dev tree. If you re-sync
the vendor code or change the DT, regenerate both and re-copy them here and into
the Armbian userpatch dir ([`docs/12`](../docs/12-resyncing.md) is the resync
checklist; the cleanup series and `packaging/dkms/` consume the same source and
must be refreshed too).
