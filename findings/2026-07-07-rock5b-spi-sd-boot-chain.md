# ROCK 5B SPI U-Boot changes how Radxa SD images boot

> Scope: ROCK 5B board firmware, SPI NOR, Armbian NVMe boot, Radxa Debian SD boot
> Source: live ROCK 5B (`/proc/cmdline`, `/proc/mtd`, `lsblk`, SPI dump), Armbian `/usr/lib/linux-u-boot-current-rock-5b/rkspi_loader.img`, mounted Radxa Bookworm SD card (`/mnt/radxa-root`)
> Date: 2026-07-07
> Trust: MEASURED for SPI/SD layout and restore prerequisites; INFERRED for the exact boot-loop cause until serial is captured

## The fact

The ROCK 5B currently boots Armbian from NVMe through a valid Armbian/Radxa SPI
bootloader. The kernel command line reports:

```text
androidboot.fwver=ddr-v1.20-b8ce94f14b,bl31-v1.48,uboot-rmbian-201-06/05/2026
```

Linux exposes the SPI NOR as one 16 MiB MTD:

```text
mtd0: 01000000 00001000 "spi5.0"
type=nor, size=16777216, erasesize=4096
```

A read-only dump was taken at repo root:

```text
spi-rock5b-20260706.bin
sha256: 38b40ad14ec672899ff51118d65d10970f026f366a5c10afdbb82851b89aeacf
```

That dump exactly matches Armbian's packaged SPI loader:

```text
/usr/lib/linux-u-boot-current-rock-5b/rkspi_loader.img
sha256: 38b40ad14ec672899ff51118d65d10970f026f366a5c10afdbb82851b89aeacf
```

The SPI image is GPT-partitioned:

```text
1: sector    64.. 7167  idbloader   3.5 MiB
2: sector  7168.. 7679  vnvm        256 KiB
3: sector  7680.. 8063  reserved    192 KiB
4: sector  8064.. 8127  reserved1    32 KiB
5: sector  8128.. 8191  uboot_env    32 KiB
6: sector  8192..16383  reserved2     4 MiB
7: sector 16384..32734  uboot         8 MiB
```

The `uboot_env` partition is all zeroes, so no saved environment is forcing the
observed boot behavior. The compiled default environment contains:

```text
boot_targets=usb0 mmc1 nvme0 nvme1 mmc0 mtd2 mtd1 mtd0 pxe dhcp
scan_dev_for_boot_part=part list ${devtype} ${devnum} -bootable devplist;
                       env exists devplist || setenv devplist 1;
                       boot_android ${devtype} ${devnum};
                       for distro_bootpart in ${devplist}; do ...
```

This means SPI U-Boot should scan bootable SD partitions before NVMe, but it
does not run the SD card's raw bootloader stages in the pre-partition gap.
BootROM already loaded SPL/U-Boot from SPI.

Correction from the follow-up Armbian 26.2.1 SD experiment: this "should
bypass" model is not reliable as a practical assumption on this board. A later
test showed that an Armbian SD card with an intact-but-bad raw Rockchip loader
blocked both SD boot and NVMe fallback, while backing up and zeroing only the SD
raw-loader gap at sectors 64..32767 made the same SD rootfs boot successfully
via the known-good SPI path. Treat the exact priority/preemption mechanism here
as unresolved without UART or boot-order source confirmation; see
[`2026-07-08-armbian-26.2.1-bl31-handoff-hang.md`](2026-07-08-armbian-26.2.1-bl31-handoff-hang.md).

The Radxa Debian Bookworm SD card layout observed with `parted` / `lsblk`:

```text
p1  16.8MB..33.6MB    16 MiB  vfat  LABEL=config  not legacy_boot
p2  33.6MB..348MB    300 MiB  vfat  LABEL=efi     legacy_boot
p3  348MB..7516MB    6.7 GiB  ext4  LABEL=rootfs  legacy_boot
```

The unused-space GPT warning is because a ~7.5 GiB image was written to a
larger 64 GiB card; it is not the primary boot issue.

Partition 3 contains a standard extlinux file:

```text
/boot/extlinux/extlinux.conf
linux  /boot/vmlinuz-6.1.43-15-rk2312
initrd /boot/initrd.img-6.1.43-15-rk2312
fdtdir /usr/lib/linux-image-6.1.43-15-rk2312/
append root=UUID=2e6a37fe-c35a-4fa1-b3e6-932217ec4dcb ...
```

The root UUID matches the filesystem:

```text
/dev/mmcblk1p3 UUID="2e6a37fe-c35a-4fa1-b3e6-932217ec4dcb"
```

The expected Rock 5B DTB exists on the SD rootfs:

```text
/usr/lib/linux-image-6.1.43-15-rk2312/rockchip/rk3588-rock-5b.dtb
```

Strings in that DTB show the SPI NOR node is present:

```text
/spi@fe2b0000
rockchip,sfc
spi-flash@0
jedec,spi-nor
spi5
```

The SD rootfs already has `mtd-utils` installed, including both `flashcp` and
`flash_erase`, so it can restore SPI if it boots and exposes `/dev/mtd0`.

## Why it matters / follow-up

The evidence narrows the boot-loop explanation. It is not simply that SPI U-Boot
cannot see a bootable SD card: the SD has a bootable ext4 partition with a
standard `/boot/extlinux/extlinux.conf`, a matching root UUID, and the expected
Rock 5B DTB.

The original suspected boundary was that SPI U-Boot bypasses the Radxa SD
card's raw Rockchip boot chain in the pre-partition gap and then attempts the
extlinux boot from p3. The later Armbian SD result above weakens that
assumption. Remaining failure possibilities are therefore:

1. DTB load/selection mismatch at U-Boot `sysboot` time.
2. Vendor BSP kernel start or early firmware handoff mismatch when booted by the
   Armbian/Radxa SPI U-Boot rather than the SD's own loader.
3. Console confusion after kernel handoff: the Radxa cmdline uses
   `console=ttyFIQ0,1500000n8`, while the Armbian boot path uses `ttyS2`.
4. A later init/rootfs issue, though the root UUID itself is correct.

Serial capture is the next proof step. Expected useful markers:

```text
Found /boot/extlinux/extlinux.conf
Retrieving file: /boot/vmlinuz-6.1.43-15-rk2312
Retrieving file: /boot/initrd.img-6.1.43-15-rk2312
Retrieving file: /usr/lib/linux-image-6.1.43-15-rk2312/rockchip/rk3588-rock-5b.dtb
Starting kernel ...
```

If SPI is erased, BootROM should fall through and run the SD card's own raw
Rockchip bootloader stages. The local scripts for this workflow are:

```text
scripts/rock5b-spi-erase.sh
scripts/rock5b-spi-restore-armbian.sh
```

For SD-side recovery, copy the restore kit under `/opt/spi-restore` on the Radxa
rootfs:

```bash
sudo mount -o remount,rw /mnt/radxa-root
sudo mkdir -p /mnt/radxa-root/opt/spi-restore
sudo install -m 0755 scripts/rock5b-spi-restore-armbian.sh /mnt/radxa-root/opt/spi-restore/
sudo install -m 0644 spi-rock5b-20260706.bin /mnt/radxa-root/opt/spi-restore/
sudo sha256sum spi-rock5b-20260706.bin /mnt/radxa-root/opt/spi-restore/spi-rock5b-20260706.bin
sync
sudo mount -o remount,ro /mnt/radxa-root
```

After booting the SD card, restore SPI with:

```bash
sudo bash /opt/spi-restore/rock5b-spi-restore-armbian.sh \
  --image /opt/spi-restore/spi-rock5b-20260706.bin
```
