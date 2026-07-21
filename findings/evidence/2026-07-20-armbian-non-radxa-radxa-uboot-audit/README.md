# Non-Radxa Armbian Radxa-U-Boot audit evidence

Captured from the non-Radxa `rk35xx` and `rockchip-rk3588` board pages on
2026-07-20, with board/branch configuration resolved from local
`armbian/build` commit `88f02f40a`.

- [`board-scope.tsv`](board-scope.tsv) accounts for all 74 non-Radxa board
  configs in those families, including the retired, source-only Panther X2.
- [`config-resolution.tsv`](config-resolution.tsv) records all 105
  board/branch combinations represented by the 425 published links and the
  resolved U-Boot source, branch, patch directory, and target kind.
- [`catalog.tsv`](catalog.tsv) contains the 203 links whose resolved config
  uses `radxa/u-boot`: 17 `BROKEN`, 182 `CLEAN`, and four `UNAVAILABLE`.
  `exposure` separates the 197 affected sibling-ITB links from the six
  alternate binman-target links.

An image URL is `https://dl.armbian.com/` followed by the row's `alias`. For a
downloadable alias, `sha256` is read from its `.sha` file and identifies the
published artifact; it was not recomputed because the full image was not
downloaded. The four unavailable R58HD image and `.sha` aliases returned HTTP
404 during capture.

The audit scripts are
[`audit-armbian-rockchip-fit.sh`](../../../boot-firmware/scripts/audit-armbian-rockchip-fit.sh)
and
[`audit-armbian-radxa-catalog.sh`](../../../boot-firmware/scripts/audit-armbian-radxa-catalog.sh).
The first streams only enough compressed input to extract the 4 MiB window at
raw sector 16384 (8 MiB), then checks every FIT component whose type is
`Flat Device Tree`.
