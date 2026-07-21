# Non-Radxa Radxa-U-Boot catalog: 17 zero-DTB images, 182 clean, 4 unavailable

> Scope: every currently linked image for non-Radxa boards in Armbian's
> `rk35xx` and `rockchip-rk3588` families whose resolved board/branch
> configuration selects `https://github.com/radxa/u-boot.git`
> Source: Armbian board catalogs captured 2026-07-20; `armbian/build` config
> resolution and `legacy/u-boot-radxa-rk35xx` dependency fix at local commit
> `88f02f40a`; upstream fix
> [PR #10196](https://github.com/armbian/build/pull/10196)
> Date: 2026-07-20
> Trust: MEASURED / CONFIG-INSPECTED / SOURCE-INSPECTED

## Result

There are **203 live catalog links** whose applicable configuration uses
Radxa's U-Boot repository. Of those, 197 build the affected sibling
`u-boot.dtb` / `u-boot.itb` goals through
`legacy/u-boot-radxa-rk35xx`: **17 are broken**, **176 are clean**, and four
MekoTronics R58HD links are HTTP 404 and cannot be classified. The remaining
six links use Radxa's repository but build the independent binman
`u-boot-rockchip.bin` target; all six are clean and are not exposed to issue
[#8227](https://github.com/armbian/build/issues/8227).

That makes the requested broken/clean list **17 broken and 182 observed
clean**, with four unavailable links kept separate. The broken boards are:

| Board slug | Broken | Clean | Unavailable |
|---|---:|---:|---:|
| `bananapim5pro` | 1 | 11 | 0 |
| `imb3588` | 4 | 3 | 0 |
| `mekotronics-r58-4x4` | 4 | 4 | 0 |
| `nanopct6-lts` | 4 | 6 | 0 |
| `orangepi5-plus` | 4 | 6 | 0 |
| **Broken-board subtotal** | **17** | **30** | **0** |

The other 35 boards on the affected target contributed 146 clean images and
no broken ones:

| Board slug | Clean | Board slug | Clean |
|---|---:|---|---:|
| `armsom-aim7-io` | 3 | `armsom-cm5-io` | 3 |
| `armsom-cm5-rpi-cm4-io` | 3 | `armsom-sige1` | 3 |
| `armsom-sige3` | 3 | `armsom-sige5` | 6 |
| `armsom-sige7` | 6 | `armsom-w3` | 3 |
| `bananapim7` | 16 | `cyber-aib-rk3588` | 6 |
| `dshanpi-a1` | 3 | `firefly-itx-3588j` | 3 |
| `fxblox-rk1` | 3 | `hinlink-h28k` | 3 |
| `hinlink-h66k` | 3 | `hinlink-h68k` | 3 |
| `hinlink-h88k` | 6 | `hinlink-hnas` | 3 |
| `hinlink-ht2` | 3 | `jp-tvbox-3566` | 3 |
| `mangopi-m28k` | 3 | `mekotronics-r58-minipc` | 3 |
| `mekotronics-r58x` | 3 | `mekotronics-r58x-4g` | 3 |
| `mixtile-blade3` | 3 | `mixtile-edge2` | 3 |
| `nanopct6` | 11 | `nanopi-zero2` | 2 |
| `orangepi5b` | 6 | `orangepi5-max` | 3 |
| `orangepi5-ultra` | 6 | `retro-lite-cm5` | 3 |
| `station-m3` | 3 | `yy3568` | 3 |
| `mekotronics-r58hd` | 6 |  |  |

The six clean alternate-target images are the three current Station M2 links
and the three vendor Luckfox Core3566 links. They genuinely use
`radxa/u-boot`, but their configs select branches `rk35xx-2024.01`, patch
directories `u-boot-radxa-latest` / `u-boot-luckfox`, and the
`u-boot-rockchip.bin` goal—not the faulty `u-boot.itb` rule.

### Broken image list

Banana Pi M5 Pro:

- `Armbian_26.2.5_Bananapim5pro_resolute_edge_7.0.1_minimal.img.xz`

IMB3588:

- `Armbian_26.2.1_Imb3588_sid_vendor_6.1.115-kali.img.xz`
- `Armbian_26.2.1_Imb3588_trixie_vendor_6.1.115-homeassistant.img.xz`
- `Armbian_26.2.1_Imb3588_trixie_vendor_6.1.115-omv_minimal.img.xz`
- `Armbian_26.2.1_Imb3588_trixie_vendor_6.1.115-openhab.img.xz`

MekoTronics R58 4x4:

- `Armbian_26.5.1_Mekotronics-r58-4x4_resolute_vendor_6.1.115_gnome_desktop.img.xz`
- `Armbian_26.5.1_Mekotronics-r58-4x4_resolute_vendor_6.1.115_kde-plasma_desktop.img.xz`
- `Armbian_26.5.1_Mekotronics-r58-4x4_resolute_vendor_6.1.115_minimal.img.xz`
- `Armbian_26.5.1_Mekotronics-r58-4x4_trixie_vendor_6.1.115_minimal.img.xz`

NanoPC T6 LTS:

- `Armbian_26.2.1_Nanopct6-lts_sid_vendor_6.1.115-kali.img.xz`
- `Armbian_26.2.1_Nanopct6-lts_trixie_vendor_6.1.115-homeassistant.img.xz`
- `Armbian_26.2.1_Nanopct6-lts_trixie_vendor_6.1.115-omv_minimal.img.xz`
- `Armbian_26.2.1_Nanopct6-lts_trixie_vendor_6.1.115-openhab.img.xz`

Orange Pi 5 Plus:

- `Armbian_26.5.1_Orangepi5-plus_resolute_vendor_6.1.115_gnome_desktop.img.xz`
- `Armbian_26.5.1_Orangepi5-plus_resolute_vendor_6.1.115_kde-plasma_desktop.img.xz`
- `Armbian_26.5.1_Orangepi5-plus_resolute_vendor_6.1.115_minimal.img.xz`
- `Armbian_26.5.1_Orangepi5-plus_trixie_vendor_6.1.115_minimal.img.xz`

The final Orange Pi entry is the artifact independently reported in issue
[#8227's Orange Pi comment](https://github.com/armbian/build/issues/8227#issuecomment-4826681181).

Every clean filename, published checksum, FDT size, FIT creation time,
catalog alias, and streamed byte count is in the
[203-row evidence catalog](evidence/2026-07-20-armbian-non-radxa-radxa-uboot-audit/catalog.tsv).

## How the complete scope was found

The source-tree search started with all 95 board configs assigned to
`rk35xx` or `rockchip-rk3588`, then removed the 21 Radxa boards covered by the
earlier audit. The remaining 74 configs expose 425 links on 73 live board
pages; retired `panther-x2.eos` is the only config without a board-page link.

Armbian's own `config-dump-json` resolver was then run for all 105 distinct
board/branch combinations represented by those links. This is necessary
because the kernel branch label does not determine the bootloader source:
some `current` or `edge` images still inherit Radxa U-Boot, while other boards
override it with mainline U-Boot. The resolver found:

- 49 board/branch combinations, 197 links, on Radxa U-Boot's affected sibling
  `u-boot.itb` target;
- two combinations, six links, on Radxa U-Boot's alternate binman target;
- 54 combinations, 222 links, using another U-Boot source.

`panther-x2.eos` explicitly names `radxa/u-boot` branch
`stable-4.19-rock3`, but it is a retired source-only config with no published
image link, so there is no artifact to classify.

## Evidence and reproduction

No full OS image was downloaded or retained. For the 199 downloadable Radxa
U-Boot artifacts, the checker streamed only enough xz input to recover the
4 MiB U-Boot window at raw offset 8 MiB: 2,603,098,029 compressed bytes in
total, or 12,697,600 to 17,718,656 bytes per artifact.

- **Identity:** each downloadable row records the filename and SHA-256 value
  returned by its alias's `.sha` file. The hash identifies the published
  artifact; it is not a locally recomputed full-file hash.
- **Detection:** `dumpimage -l` on the raw FIT window; `BROKEN` if any
  `Flat Device Tree` component has a zero-byte payload, `CLEAN` if every FDT
  component is nonzero.
- **Configuration:**
  [`config-resolution.tsv`](evidence/2026-07-20-armbian-non-radxa-radxa-uboot-audit/config-resolution.tsv)
  records the resolved source, branch, patch directory, and target kind for
  all 105 published board/branch combinations.
- **Coverage:**
  [`board-scope.tsv`](evidence/2026-07-20-armbian-non-radxa-radxa-uboot-audit/board-scope.tsv)
  accounts for all 74 non-Radxa configs in the two families.
- **Exercise:**
  `boot-firmware/scripts/audit-armbian-radxa-catalog.sh <board-slug> [...]`.
- **Catalog artifact:**
  [`catalog.tsv`](evidence/2026-07-20-armbian-non-radxa-radxa-uboot-audit/catalog.tsv)
  (`sha256:b304af0afc1d8fcd8851b6f41e42a9e11f9073413d1ba324d6421216943f12a5`).

The four `UNAVAILABLE` rows are direct R58HD aliases for Resolute GNOME, KDE
Plasma, and minimal, plus Trixie minimal. Both the image alias and its `.sha`
URL returned HTTP 404 on 2026-07-20; these are dead catalog links, not observed
clean or broken artifacts.

## Boundary

`CLEAN` proves only that the published artifact has no zero-byte FIT DTB. It
does not prove that the image boots or that every other FIT payload is valid.
Catalog aliases and board configs are mutable, so this is a 2026-07-20
snapshot; filenames and published hashes identify the downloadable artifacts
that were checked.
