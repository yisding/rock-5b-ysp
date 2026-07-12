# Captured Armbian ROCK 5B U-Boot packages

Forensic inputs for
[`findings/2026-07-11-rock5b-u-boot-four-way-comparison.md`](../../findings/2026-07-11-rock5b-u-boot-four-way-comparison.md).

## Package files

```text
ab6111a66ba3f8631170313b95d4bf95eaa8586a830fec6eb77ceb2b244552cf  linux-u-boot-rock-5b-current_26.5.1_arm64.deb
3a2f025554447e00b903bc32eeea7582fa01e65ec56327b48251a32b54bb74da  linux-u-boot-rock-5b-vendor_26.5.1_arm64.deb
```

The `extract-current-26.5.1/` and `extract-vendor-26.5.1/` directories are
direct package extractions. `extract-sd-26.2.1-raw/` holds the two raw boot
artifacts extracted from the verified official 26.2.1 image described in the
finding and in the reconstructed source tree's `ARMBIAN-SOURCE.md`.

## Firmware hashes

| Source | File | Bytes | SHA-256 |
|---|---|---:|---|
| 26.2.1 vendor raw SD | `idbloader.img` | 321,536 | `961f208930865f1096b4f0f947b06b3ce47f1c443c945d7fd04c7727f5334f8b` |
| 26.2.1 vendor raw SD | `u-boot.itb` | 1,448,960 | `54350eaf2ae3a616ffe5cbb804878eb05971161509c6f09cb1cba22680ab6c44` |
| 26.5.1 current | `idbloader.img` | 323,584 | `f9dbc3b5fa6178bd68b756ac8203f05dbd78c2086d794d4d9bbbf805dcad4f72` |
| 26.5.1 current | `u-boot.itb` | 1,461,760 | `98e2c8af220907929221c1677c4c09dc9be3bdec5fa43ded738a124763988779` |
| 26.5.1 current | `rkspi_loader.img` | 16,777,216 | `38b40ad14ec672899ff51118d65d10970f026f366a5c10afdbb82851b89aeacf` |
| 26.5.1 vendor | `idbloader.img` | 323,584 | `231daff55395352b7d58adf0125c5d937c4b30a8d642d50a0d8ec8c3ae00b3a6` |
| 26.5.1 vendor | `u-boot.itb` | 1,448,960 | `7596ed37016291a4f588cb0e5ecbeefc2d92851e907ba0436174139c2c0a5c5d` |
| 26.5.1 vendor | `rkspi_loader.img` | 16,777,216 | `9b649375c2501078df6a0c5cfc12b88d44ab829e175c3fbeccce0af4b2d0880e` |

## High-value inspection result

`dumpimage -l` reports a zero-byte `fdt` component in the 26.2.1 and 26.5.1
vendor ITBs. The 26.5.1 current ITB contains a 12,752-byte `fdt` component with
SHA-256 `6ed9a9d75157ca30d7fcff27670b782a335cfa949dc446d6b9dfebc1fec39078`.
The three ATF/BL31 component hashes match across all images.

Recheck without extracting anything:

```bash
dumpimage -l extract-current-26.5.1/usr/lib/linux-u-boot-current-rock-5b/u-boot.itb
dumpimage -l extract-vendor-26.5.1/usr/lib/linux-u-boot-vendor-rock-5b/u-boot.itb
dumpimage -l extract-sd-26.2.1-raw/u-boot.itb
```
