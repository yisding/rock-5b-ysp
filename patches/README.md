# patches/

Two patches. Together they add the vendor MPP encoder + decoder and the RGA
accelerator to a Linux 6.18 kernel and wire them into the ROCK 5B device tree.
They are generated against **pristine mainline `v6.18`** (two commits on top of
the `v6.18` tag).

| File | Size | Contents | Detail |
|------|------|----------|--------|
| `rk3588-rkvenc2-01-vcodec-rga-drivers.patch` | ~980 KB | The vendor MPP (`rk_vcodec`) + RGA (`multi_rga`) **drivers**, forward-ported to 6.18 (58 files: compat shims, hack files, API + bring-up fixes, Kconfig). | [`docs/05`](../docs/05-vendor-forward-port.md) |
| `rk3588-rkvenc2-02-vcodec-rga-dt.patch` | ~16 KB | **Device tree**: encoder + RGA nodes inline, decoder via convert-in-place override, board enables. | [`docs/07`](../docs/07-device-tree.md), [`docs/08`](../docs/08-armbian-packaging.md) |

They map to the two dev-tree commits:
```
video: rockchip: RK3588 vendor MPP (rkvenc2/rkvdec2) + RGA3/RGA2 drivers   → patch 01
arm64: dts: rockchip: rk3588: VEPU580 encoder, rkvdec2 decoder, RGA3 nodes → patch 02
```

## Apply — Armbian (the intended path)

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

## Regenerating

The patches are `git format-patch v6.18..HEAD` from the dev tree. If you re-sync
the vendor code or change the DT, regenerate both and re-copy them here and into
the Armbian userpatch dir.
