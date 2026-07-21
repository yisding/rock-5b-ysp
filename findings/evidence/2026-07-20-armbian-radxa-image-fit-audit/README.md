# Armbian Radxa image FIT audit evidence

Captured from the 38 board pages in the
[Armbian Radxa catalog](https://armbian.com/vendors/radxa) on 2026-07-20.

- [`catalog.tsv`](catalog.tsv) contains every direct image link from the 21
  `rk35xx` and `rockchip-rk3588` board pages: 244 resolved filenames and
  Armbian-published SHA-256 identities. `CLEAN` and `BROKEN` are direct FIT
  observations; `INDETERMINATE` means the FIT at the vendor raw offset had no
  Flat Device Tree component to test.
- [`source-excluded-boards.tsv`](source-excluded-boards.tsv) covers all 79
  image links on the other 17 board pages. Their board families do not select
  `legacy/u-boot-radxa-rk35xx`, so issue #8227 does not apply to them.

An image URL is `https://dl.armbian.com/` followed by the row's `alias`. The
SHA-256 value is read from that alias's `.sha` file; it identifies the
published artifact but was not recomputed because the full image was not
downloaded.

The audit scripts are
[`audit-armbian-rockchip-fit.sh`](../../../boot-firmware/scripts/audit-armbian-rockchip-fit.sh)
and
[`audit-armbian-radxa-catalog.sh`](../../../boot-firmware/scripts/audit-armbian-radxa-catalog.sh).
The first script streams only enough compressed input to extract the 4 MiB
window beginning at raw sector 16384 (8 MiB), then checks every FIT component
whose type is `Flat Device Tree`.
