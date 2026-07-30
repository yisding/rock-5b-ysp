# The installed SPI is not U-Boot-incompatible with Radxa BSP images; the real gap is the firmware blob generation

> Scope: ROCK 5B boot firmware (SPI NOR), Radxa BSP Debian/Android images, [`boot-firmware/`](../boot-firmware/README.md) track 12
> Source: live ROCK 5B `/dev/mtdblock0`; `/usr/lib/linux-u-boot-current-rock-5b/rkspi_loader.img`; `~/Code/rock-5b/radxa-images/` (fetched 2026-07-24) — `loaders/rock-5b-spi-image-gd1cf491-20240523.img`, `loaders/rk3588_spl_loader_v1.15.113.bin`, `debian-r6/rock-5b_bookworm_kde_r6.output_512.img.xz`, `android/Rock5B_Android12_rkr14_20240419-gpt.zip`
> Date: 2026-07-24
> Trust: MEASURED (hashes, GPT layouts, blob identity strings, filesystem contents) / CODE-INSPECTED (U-Boot default environment, control DTB, Radxa `setup.sh`) / INFERRED (blob-generation consequence) / HYPOTHESIS (the `ttyFIQ0` silent-serial symptom)

## Result

The working assumption behind "the current SPI is incompatible with Radxa's BSP
images" — that Armbian's SPI U-Boot cannot boot a Radxa BSP OS — **is not
supported by the artifacts.** For the current Radxa Debian BSP (rsdk r6), the
U-Boot in SPI and the U-Boot the BSP image ships are the same U-Boot for every
property that governs OS discovery.

Measured equivalences between the installed SPI loader and the r6 BSP loader:

- **Same vendor source commit.** Armbian's build stamps `S39cd`; the r6 SPL and
  U-Boot proper stamp `rk2410-2017.09-64-39cd993-g58d424f`. Both are
  `radxa/u-boot` `39cd993e5d6296635438e84f4576b3a9bf76f86e`, the pin already
  recorded as "Armbian 26.5.1 current" in the
  [version comparison](../boot-firmware/docs/version-comparison.md).
- **Byte-identical default environment.** All 51 compiled-in variables match in
  name and value, including `bootcmd`, `boot_targets`, `distro_bootcmd`,
  `scan_dev_for_boot_part` (with its `boot_android ${devtype} ${devnum}` call),
  `scan_dev_for_extlinux`, `boot_prefixes=/ /boot/`, and
  `fdtfile=rockchip/rk3588-rock-5b.dtb`.
- **Functionally identical U-Boot control DTB.** Both are 12,752 bytes; the
  decompiled diff is 28 changed lines that move `crypto@fe370000` and
  `rng@fe378000` between two positions. No property, status, or node set differs.
- **Same SPI layout.** The installed SPI and Radxa's official 2024 SPI image
  carry the identical 7-partition GPT (`idbloader` s64, `vnvm` s7168,
  `reserved_space` s7680, `reserved1` s8064, `uboot_env` s8128, `reserved2`
  s8192, `uboot` s16384). Radxa's own r6 installer, `setup.sh:build_spinor`,
  writes `idbloader.img` at seek 64 and `u-boot.itb` at seek 16384 into a 16 MiB
  image — the same offsets.

The earlier `bootcmd` divergence (`boot_android` at top level vs inside
`scan_dev_for_boot_part`) is real but is against the **2024** Radxa SPI image,
not the current BSP. Armbian tracks the current Radxa environment exactly.

### What does differ: a firmware blob generation gap

| | Installed SPI (Armbian) | Radxa SPI image | Radxa Debian BSP r6 |
|---|---|---|---|
| Built | 2026-06-05 | 2024-05-23 | 2026-07-24 |
| SPL | `2017.09_armbian-…-S39cd-…` | `2017.09-gd1cf49135ee-220414` | `rk2410-2017.09-64-39cd993-g58d424f` |
| DDR | v1.20 `b8ce94f14b` (2025-09-26) | v1.16 `9fffbe1e78` (2024-02-04) | **v1.22 `d4bf75a5a6` (2026-07-23)** |
| BL31 | **v1.48, 204,860 B @ `0x40000`** | v1.45, 204,220 B @ `0x40000` | **v1.54, 149,020 B @ `0x60000`** |
| U-Boot proper | 1,179,864 B | 1,173,992 B | 1,204,736 B |
| Control DTB | 12,752 B | 11,452 B | 12,752 B |

BL31 moved its load base `0x40000` → `0x60000` and shrank by 55,840 bytes
between v1.48 and v1.54. `atf-2` (`0xff100000`) and `atf-3` (`0x000f0000`) are
unchanged in size across all three. Radxa's official MaskROM loader
`rk3588_spl_loader_v1.15.113.bin` carries DDR v1.15 `d5483af87d` (2023-11-23),
older than all three.

**The mechanism that makes the gap bite:** with SPI populated, BootROM runs the
SPI chain, so the BSP image's own `idbloader` (DDR v1.22) at sector 64 and
`u-boot.itb` (BL31 v1.54) at sector 16384 are never executed. A Radxa BSP OS
therefore runs on DDR v1.20 + BL31 v1.48 — a firmware generation it was not
built against — while its own matching blobs sit unused on the boot medium.

### Ruled out as causes

- **extlinux resolution.** The r6 `extlinux.conf` uses
  `fdtdir /usr/lib/linux-image-6.1.84-8-rk2410/`, and
  `rockchip/rk3588-rock-5b.dtb` (272,376 B) exists there, matching the
  `fdtfile` both U-Boots compile in.
- **ext4 feature support.** The r6 rootfs has `orphan_file metadata_csum_seed
  64bit metadata_csum`; the NVMe rootfs this board boots today through this same
  SPI U-Boot carries all of those *plus* `needs_recovery` and `orphan_present`.
- **UEFI.** The r6 "efi" partition (300 MiB, FAT16) is empty apart from its
  volume label; boot is extlinux. Neither U-Boot contains an EFI loader.
- **GPT bootable attributes.** r6 p2 and p3 both set attribute bit 2, so
  `part list … -bootable` yields a non-empty `devplist`.
- **Saved environment.** The SPI `uboot_env` partition is 32,768 zero bytes, so
  nothing persisted is steering boot.

## Evidence and reproduction

- **Identity:** ROCK 5B, booting Armbian from NVMe (`nvme0n1p1` on `/`), kernel
  `6.18.38-ysp-rockchip64`, SPI NOR exposed as `mtd0` (`spi5.0`, 16 MiB,
  4 KiB erase).
- **Detection:** live SPI read through `/dev/mtdblock0` (group `disk`, no root
  needed); read-only, nothing was written to the board.
- **Exercise:**
  ```bash
  dd if=/dev/mtdblock0 of=live-spi.bin bs=1M
  sha256sum live-spi.bin spi-rock5b-20260706.bin \
    /usr/lib/linux-u-boot-current-rock-5b/rkspi_loader.img

  # SPI component split (both SPI images share this layout)
  dd if=<img> of=idbloader.bin bs=512 skip=64    count=7104
  dd if=<img> of=uboot.bin     bs=512 skip=16384 count=16351
  dd if=<img> of=env.bin       bs=512 skip=8128  count=64

  # BSP image: raw loader gap and filesystems
  xz -dc rock-5b_bookworm_kde_r6.output_512.img.xz > debian-r6.img
  sgdisk -p debian-r6.img
  dd if=debian-r6.img of=r6-idbloader.bin bs=512 skip=64    count=640
  dd if=debian-r6.img of=r6-uboot.bin     bs=512 skip=16384 count=8192

  # FIT components are EXTERNAL-data (data-offset/data-size, base 2048);
  # `dumpimage -p N` silently writes zeros here — parse the FDT instead.
  mkimage -l r6-uboot.bin

  # BSP rootfs at byte offset 679936*512 = 348127232
  debugfs -R "cat /boot/extlinux/extlinux.conf" "debian-r6.img?offset=348127232"
  debugfs -R "stats -h"                          "debian-r6.img?offset=348127232"
  ```
- **Pass/fail signal:**
  - Live SPI, repo dump, and Armbian package all
    `38b40ad14ec672899ff51118d65d10970f026f366a5c10afdbb82851b89aeacf` — the
    2026-07-06 dump is still what is flashed, re-verified 2026-07-24.
  - Radxa 2024 SPI image:
    `153e4b55f5a4b9db174fcacc7785fbb16970a4e83bd28fac385f3cce06138186`.
  - BL31 (`atf-1`) component hashes: Armbian `7612223b82b9…`, Radxa 2024
    `a7d1d8d19101…`, r6 `f99c6f8fb692…`.
  - Control DTB hashes: Armbian `6ed9a9d75157…`, r6 `39d5f029f862…`, Radxa 2024
    `5bee414074a1…`.
  - `/usr/lib/u-boot/rock-5b/{idbloader.img,u-boot.itb}` in the r6 rootfs are
    **byte-identical** (325,632 B and 1,430,528 B) to the copies written raw at
    sectors 64 and 16384 of the same image — so `update_spinor` would flash
    exactly this blob set.
- **Artifacts:** none committed. Working copies were built in a session
  scratchpad (including the 7.7 GB decompressed r6 image) and are reproducible
  from `~/Code/rock-5b/radxa-images/` with the commands above.

## Boundary

This evidence is entirely static analysis of firmware and image contents. It
establishes what the artifacts *are*; it does **not** establish what happens at
runtime.

Specifically untested: no Radxa BSP image was written to any medium, no boot was
attempted, and no serial capture exists. Whether BL31 v1.48 actually breaks a
BSP boot — as opposed to degrading individual SIP-dependent features — is
**unproven**; the r6 kernel contains no hard "trusted firmware too old" gate in
its strings, only per-feature SIP call sites (`rockchip_sip_config_dram_init`,
`…config_mcu_start`, share-memory ioremap). The DDR v1.20-vs-v1.22 delta is
noted but has no evidenced OS-visible consequence: DDR training is board RAM
bring-up and v1.20 demonstrably works on this board.

The Android packages were inspected only at the partition-table level (rkr14
GPT, and the rkr10 `SSFW` container header). No AVB key, `vbmeta`, or rollback
state was compared, so "Armbian's AVB keys differ from Radxa's" remains an
untested expectation rather than a measured fact.

## Why it matters / follow-up

The practical correction: **do not reflash SPI on the theory that its U-Boot
cannot parse BSP images.** For the r6 Debian BSP that theory is falsified — same
source commit, same environment, same DTB, same layout. If a BSP image fails to
boot here, the cause lies below U-Boot (BL31/DDR generation) or above it
(kernel/init), not in OS discovery.

One symptom worth ruling out before deeper work: the r6 cmdline leads with
`console=ttyFIQ0,1500000n8`, and the vendor FIQ debugger needs a BL31
share-memory SIP call — the r6 kernel carries a
`fiq debugger request share memory failed: %d` error path. Under the older BL31
that call can fail, leaving the serial line silent while the kernel continues on
`tty1`/HDMI (also in the same cmdline). A boot judged dead by UART silence may
therefore be progressing. **HYPOTHESIS** — discriminate by watching HDMI, or by
appending `console=ttyS2,1500000n8` to the append line.

Next proof, in increasing cost:

1. Write the r6 image to a spare medium, boot with the current SPI untouched,
   and capture HDMI *and* `ttyS2`. This alone settles whether an incompatibility
   exists at all.
2. If it fails after `Starting kernel`, flash the BSP's own blob set to SPI with
   the BSP's own installer — `/usr/lib/u-boot/rock-5b/setup.sh update_spinor`
   (`flash_erase` + `flashcp` to `/dev/mtd0`) — which raises BL31 to v1.54 and
   DDR to v1.22, then retest. Keep the verified restore path in
   [`scripts/`](../scripts/README.md) and the
   [SPI/SD boot-chain finding](2026-07-07-rock5b-spi-sd-boot-chain.md) available
   first; note `build_spinor` writes a **GPT-less** 16 MiB image, dropping the
   named `vnvm`/`uboot_env`/`reserved*` partitions the current SPI has.
3. Android is a separate question and should not be folded into the Debian
   result: rkr14 uses the full Rockchip Android GPT (`security` s8192, `uboot`
   s16384, `trust` s24576, `misc`, `dtbo`, `vbmeta`, `boot`, `recovery`,
   `backup`, `cache`, `metadata`, `baseparameter`, `super`, `userdata`) with
   split `uboot`+`trust` rather than a combined `.itb`, and depends on
   `boot_android` plus AVB against Radxa's keys and `vnvm` rollback state.

This finding does not by itself change [`status.md`](../status.md) track 12,
whose public state (SPI → NVMe works; zero-DTB FIT explanation) is unaffected —
note only that the **installed** SPI carries a valid 12,752-byte control DTB, so
the zero-DTB failure class does not apply to it.
