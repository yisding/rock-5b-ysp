# Armbian Radxa catalog: 21 zero-DTB images, 207 clean, 95 not applicable

> Scope: all 323 image links exposed by the 38 board pages in the
> [Armbian Radxa catalog](https://armbian.com/vendors/radxa), checked for the
> zero-byte U-Boot FIT DTB signature from Armbian build
> [issue #8227](https://github.com/armbian/build/issues/8227)
> Source: Armbian board catalogs captured 2026-07-20; `armbian/build` board
> configs and `legacy/u-boot-radxa-rk35xx` dependency fix at local commit
> `88f02f40a`; upstream fix
> [PR #10196](https://github.com/armbian/build/pull/10196)
> Date: 2026-07-20
> Trust: MEASURED / CONFIG-INSPECTED / SOURCE-INSPECTED

## Result

The catalog contains **21 broken images** with the exact issue #8227
signature: at least one `Flat Device Tree` component in the raw U-Boot FIT has
`Data Size: 0 Bytes`. Another **207 images are clean**: every FDT component in
the same FIT is nonzero. The remaining **95 are not applicable** to this race:
16 current/edge images use a mainline U-Boot layout without an FDT component
at the affected FIT target, and 79 images belong to board families that do not
use the affected Radxa U-Boot source at all.

No full OS image was downloaded or retained. For the 244 potentially affected
image links, the checker streamed only enough xz data to recover the 4 MiB
U-Boot window at raw offset 8 MiB. It transferred 3,196,074,913 compressed
bytes in total, 12,615,680 to 20,971,520 bytes per image.

### Potentially affected Radxa families

| Board | Broken | Clean | Not applicable |
|---|---:|---:|---:|
| Radxa CM4 IO | 0 | 10 | 0 |
| Radxa CM5 IO | 4 | 6 | 0 |
| Radxa E20C | 0 | 3 | 0 |
| Radxa E24C | 4 | 7 | 1 |
| Radxa E25 | 0 | 15 | 0 |
| Radxa E52C | 0 | 2 | 8 |
| Radxa E54C | 0 | 10 | 0 |
| Radxa ROCK 4D | 0 | 8 | 7 |
| Radxa Zero 3 | 0 | 16 | 0 |
| ROCK 2A | 4 | 7 | 0 |
| ROCK 2F | 0 | 11 | 0 |
| ROCK 3A | 0 | 16 | 0 |
| ROCK 3C | 0 | 11 | 0 |
| ROCK 5A | 0 | 16 | 0 |
| ROCK 5B | 9 | 7 | 0 |
| ROCK 5B+ | 0 | 14 | 0 |
| ROCK 5C | 0 | 14 | 0 |
| ROCK 5 CMIO | 0 | 3 | 0 |
| ROCK 5 CM in RPi CM4 IO | 0 | 3 | 0 |
| ROCK 5 ITX | 0 | 14 | 0 |
| ROCK 5T | 0 | 14 | 0 |
| **Total** | **21** | **207** | **16** |

The 16 not-applicable rows are one Radxa E24C `edge` image, all eight Radxa
E52C `current` images, and all seven Radxa ROCK 4D `edge` images. Their exact
filenames remain in the evidence catalog with the raw checker result
`INDETERMINATE`; board configuration inspection is what establishes that the
affected vendor Makefile rule is not in their build path.

### Broken image list

Radxa CM5 IO:

- `Armbian_26.5.1_Radxa-cm5-io_resolute_vendor_6.1.115_gnome_desktop.img.xz`
- `Armbian_26.5.1_Radxa-cm5-io_resolute_vendor_6.1.115_kde-plasma_desktop.img.xz`
- `Armbian_26.5.1_Radxa-cm5-io_resolute_vendor_6.1.115_minimal.img.xz`
- `Armbian_26.5.1_Radxa-cm5-io_trixie_vendor_6.1.115_minimal.img.xz`

Radxa E24C:

- `Armbian_26.2.1_Radxa-e24c_sid_vendor_6.1.115-kali.img.xz`
- `Armbian_26.2.1_Radxa-e24c_trixie_vendor_6.1.115-homeassistant.img.xz`
- `Armbian_26.2.1_Radxa-e24c_trixie_vendor_6.1.115-omv_minimal.img.xz`
- `Armbian_26.2.1_Radxa-e24c_trixie_vendor_6.1.115-openhab.img.xz`

ROCK 2A:

- `Armbian_26.2.1_Rock-2a_sid_vendor_6.1.115-kali.img.xz`
- `Armbian_26.2.1_Rock-2a_trixie_vendor_6.1.115-homeassistant.img.xz`
- `Armbian_26.2.1_Rock-2a_trixie_vendor_6.1.115-omv_minimal.img.xz`
- `Armbian_26.2.5_Rock-2a_resolute_vendor_6.1.115_minimal.img.xz`

ROCK 5B:

- `Armbian_26.2.1_Rock-5b_noble_vendor_6.1.115_gnome_desktop.img.xz`
- `Armbian_26.2.1_Rock-5b_noble_vendor_6.1.115_kde-neon_desktop.img.xz`
- `Armbian_26.2.1_Rock-5b_noble_vendor_6.1.115_minimal.img.xz`
- `Armbian_26.2.1_Rock-5b_sid_vendor_6.1.115-kali.img.xz`
- `Armbian_26.2.1_Rock-5b_trixie_vendor_6.1.115-homeassistant.img.xz`
- `Armbian_26.2.1_Rock-5b_trixie_vendor_6.1.115_minimal.img.xz`
- `Armbian_26.2.1_Rock-5b_trixie_vendor_6.1.115-omv_minimal.img.xz`
- `Armbian_26.2.1_Rock-5b_trixie_vendor_6.1.115-openhab.img.xz`
- `Armbian_26.2.5_Rock-5b_resolute_vendor_6.1.115_minimal.img.xz`

Every other `CLEAN` filename, published checksum, FDT size, FIT creation time,
catalog alias, and compressed byte count is in the
[244-row evidence catalog](evidence/2026-07-20-armbian-radxa-image-fit-audit/catalog.tsv).

### Source-excluded Radxa families

These 17 board pages expose 79 images, all **not affected by issue #8227**
because their configs select another U-Boot family:

| Family | Boards | Image links |
|---|---|---:|
| `sun60iw2` | Cubie A7Z | 1 |
| `sun55iw3` | Radxa Cubie A5E | 1 |
| `qcs6490` | Radxa Dragon Q6A | 8 |
| `sc8280xp` | Radxa Dragon Q8B | 2 |
| `genio` | Radxa NIO 12L | 16 |
| `meson-g12a` | Radxa Zero | 9 |
| `meson-g12b` | Radxa Zero 2 | 2 |
| `rockchip64` | ROCK 4SE; ROCK Pi 4A, 4B, 4B+, 4C, 4C+; ROCK Pi E, N10, S; ROCK S0 | 40 |
| **Total** | **17 boards** | **79** |

The exact board slugs and counts are preserved in
[`source-excluded-boards.tsv`](evidence/2026-07-20-armbian-radxa-image-fit-audit/source-excluded-boards.tsv).

## Evidence and reproduction

- **Identity:** each row records the filename returned by its alias's `.sha`
  file and Armbian's published SHA-256 value. The hash is an identity record,
  not a local full-file verification.
- **Detection:** `dumpimage -l` on the raw FIT window; `BROKEN` if any component
  with `Type: Flat Device Tree` has a zero-byte data size, `CLEAN` if every FDT
  is nonzero.
- **Exercise:**
  `boot-firmware/scripts/audit-armbian-radxa-catalog.sh <board-slug> [...]`.
- **Pass/fail signal:** the per-image checker exits 0 for clean, 10 for broken,
  and 11 when there is no FDT component to classify.
- **Artifacts:**
  [`catalog.tsv`](evidence/2026-07-20-armbian-radxa-image-fit-audit/catalog.tsv)
  (`sha256:56f7b7fe30b2b4a5c853501a12da304368fa212217b670abdd19e2dec88332f7`).

## Boundary

`CLEAN` proves only that the published artifact does not contain the zero-DTB
FIT signature. It does not prove that the image boots or that every other FIT
payload is valid. Catalog aliases are mutable, so the result is a 2026-07-20
snapshot; the recorded filenames and checksums identify what was checked.

The 79 source-excluded images were classified from their board-family configs
without streaming their image data. The 16 mainline current/edge images were
streamed, but their FIT layout has no FDT component at the affected target;
their not-applicable classification depends on source/config inspection rather
than the FIT size test.
