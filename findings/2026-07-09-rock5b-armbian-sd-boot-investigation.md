# ROCK 5B Armbian SD boot investigation summary

> Scope: ROCK 5B Armbian SD/NVMe/SPI boot interaction
> Source: user UART capture, live ROCK 5B package/artifact inspection, mounted
> Armbian 26.2.1 SD image, Armbian source and Radxa U-Boot source inspection,
> SD raw-loader overwrite/zeroing experiments
> Date: 2026-07-09
> Trust: MEASURED for observed boot behavior and local artifacts;
> SOURCE-INSPECTED for code/package deltas; HYPOTHESIS where the exact BootROM
> or SPL preemption mechanism is named without a fresh UART capture

## Short version

The Armbian 26.2.1 Minimal Debian 13 / vendor 6.1.115 image is not failing
because the SD card was written badly, because `/boot` is missing, or because the
vendor kernel cannot run on this ROCK 5B. The strongest evidence points to the
raw boot firmware area on the SD card.

The decisive test was:

1. With SD raw loader present, the board did not boot the SD image and did not
   fall through cleanly to the working NVMe install.
2. After backing up and zeroing only sectors 64..32767 on the SD card, leaving
   the rootfs and `/boot` intact, the same SD card booted successfully through
   the known-good SPI U-Boot path.

That proves the SD filesystem payload is bootable when loaded by the current SPI
bootloader. It also proves the raw loader gap can be the blocker.

## Known-good baseline

The board's currently working SPI bootloader is Armbian/Radxa `current` 26.5.1:

```text
linux-u-boot-rock-5b-current 26.5.1
/usr/lib/linux-u-boot-current-rock-5b/rkspi_loader.img
sha256: 38b40ad14ec672899ff51118d65d10970f026f366a5c10afdbb82851b89aeacf
fwver: ddr-v1.20-b8ce94f14b,bl31-v1.48,uboot-rmbian-201-06/05/2026
```

That SPI loader boots the existing NVMe install. The NVMe install can boot both
the Armbian current/mainline kernel and the Armbian vendor `6.1.115` kernel, so
the vendor kernel itself is not intrinsically dead on this hardware.

The same SPI path also boots the Armbian 26.2.1 SD rootfs once the SD raw loader
gap is zeroed.

## Original failure

The original UART capture from the Armbian 26.2.1 Minimal SD image stopped here:

```text
DDR ... fwver: v1.18 ...
NOTICE: BL31: ... fwver: v1.48
WARNING: No OPTEE provided by BL2 boot loader ...
ERROR: Error initializing runtime service opteed_fast
INFO: BL31: Preparing for EL3 exit to normal world
INFO: Entry point address = 0x200000
INFO: SPSR = 0x3c9
```

The OP-TEE warning is not sufficient to explain the failure because BL31 reports
that it is continuing to the normal-world handoff. Also, this vendor U-Boot path
has `CONFIG_DISABLE_CONSOLE=y`, so lack of U-Boot serial text after BL31 is not
by itself proof that U-Boot crashed.

The important fingerprint is the DDR line: this failure used `ddr-v1.18`, which
belongs to the 26.2.1 raw SD boot chain.

## SD image integrity

The inserted SD card matched the downloaded image where it matters:

```text
/dev/mmcblk1p1: ext4 LABEL=armbi_root UUID=e0d1f6a8-8612-4976-9917-533ffb94268f
root partition sha256:        4dbef87e58b51e39d7762d737ed31a336d4ad9caf517f40424bc19e591552909
pre-rootfs 32768-sector sha256: 5de53d9f916d37552748933a7f8139be382e18344469f00d22af465afe85a8cc
downloaded xz sha256:         ff6e002c5909deea13f6f5328f8bada646544c5222cb997c049dc9eb162b8e03
```

The SD `/boot` payload was present and structurally valid:

```text
/boot/boot.scr                         ARM Linux Script image
/boot/vmlinuz-6.1.115-vendor-rk35xx    ARM64 boot executable Image
/boot/uInitrd-6.1.115-vendor-rk35xx    AArch64 RAMDisk image
/boot/dtb/rockchip/rk3588-rock-5b.dtb  valid FDT, model "Radxa ROCK 5B"
```

The root UUID in `armbianEnv.txt` matched the ext4 filesystem UUID:

```text
rootdev=UUID=e0d1f6a8-8612-4976-9917-533ffb94268f
rootfstype=ext4
```

So the basic image-write, root UUID, kernel, initrd, and DTB-at-rest checks all
passed.

## Kernel transplant result

The SD rootfs was expanded and updated with Armbian 26.5.1 vendor kernel/DTB
packages:

```text
linux-image-vendor-rk35xx 26.5.1
linux-dtb-vendor-rk35xx   26.5.1
```

The chroot regenerated a fresh U-Boot initrd and set the boot symlinks:

```text
/boot/Image   -> vmlinuz-6.1.115-vendor-rk35xx
/boot/uInitrd -> uInitrd-6.1.115-vendor-rk35xx
/boot/dtb     -> dtb-6.1.115-vendor-rk35xx
```

That still did not boot while the SD raw loader was intact. Disabling only
`/boot/boot.scr` also did not restore NVMe fallback. This moved suspicion away
from the SD filesystem boot script and away from the kernel package alone.

## Raw loader experiments

The SD raw loader gap was backed up:

```text
backup: downloads/sd-bootarea-backups/mmcblk1-raw-loader-20260709-063319.bin
sha256: 1a548204772cc3b7a68ecc2d6e917f7305e28a2ec25ddadc1a1a72b55e236311
range:  sectors 64..32767, 16744448 bytes
```

Then sectors 64..32767 were zeroed. After that, the board booted from the SD
successfully, using the SPI U-Boot path to load the SD filesystem payload.

Next, newer Armbian 26.5.1 `vendor` raw artifacts were written to the SD:

```text
downloads/armbian-rock5b-uboot-compare/extract-vendor-26.5.1/usr/lib/linux-u-boot-vendor-rock-5b/idbloader.img
sha256: 231daff55395352b7d58adf0125c5d937c4b30a8d642d50a0d8ec8c3ae00b3a6

downloads/armbian-rock5b-uboot-compare/extract-vendor-26.5.1/usr/lib/linux-u-boot-vendor-rock-5b/u-boot.itb
sha256: 7596ed37016291a4f588cb0e5ecbeefc2d92851e907ba0436174139c2c0a5c5d
```

That still did not complete boot, but HDMI did initialize. That is materially
different from the original no-HDMI 26.2.1 failure and suggests the newer vendor
raw path reaches U-Boot proper or an early video-capable kernel stage before
failing.

## Source inspection

The 26.2.1 image identifies:

```text
BUILD_REPOSITORY_URL=https://github.com/armbian/build
BUILD_REPOSITORY_COMMIT=5abb97453
VERSION=26.2.1
linux-u-boot-rock-5b-vendor git revision: 6c807ac5008722e240f5282229c15a40aba4918f
```

The 26.2.1 raw loader contains:

```text
ddr-v1.18-9fa84341ce
U-Boot SPL 2017.09_armbian-2017.09-S6c80-Pb178-Hd3bb-Vb338-B2eb2-R448a
```

The 26.5.1 vendor loader contains:

```text
ddr-v1.20-b8ce94f14b
U-Boot SPL ... S39cd-P1ff0-H08b3-V4b6d-Bd0d2-R448a
```

Radxa U-Boot source comparison from `6c807ac500...` to `39cd993e5d...` did not
show ROCK 5B defconfig or DTS changes. The non-doc source delta was small and
RK3576/CM5-related.

The clear Armbian build-side change is commit `1bac6d977217039cae7193a1d6c19ae5b50c2c5f`:

```text
RK3588: Switch to 1.20 DDR_BLOB
rk35/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.18.bin
  -> rk35/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.20_20250926.bin
```

So the best source-backed explanation for the original no-HDMI failure is not an
identified ROCK 5B U-Boot source logic bug. It is the 26.2.1 raw boot firmware
bundle, with the DDR/SPL blob selection as the strongest suspect.

## Current interpretation

1. The original 26.2.1 no-HDMI failure is early in the raw SD boot chain:
   `ddr-v1.18` / SPL / BL31 / silent U-Boot boundary.
2. The SD rootfs and `/boot` are usable. They boot when the board is forced onto
   the known-good SPI `current` path.
3. The vendor kernel is usable on this board. It boots from NVMe under the
   current SPI loader.
4. The 26.5.1 vendor raw loader moves the failure downstream because HDMI
   initializes, but it still does not complete the boot.
5. The remaining untested discriminator is the 26.5.1 `current` raw loader on
   the SD card, because that matches the known-good SPI loader family rather
   than the `vendor` U-Boot package family.

## Still unknown

These points are not proven without another UART capture or a more detailed
BootROM/SPL trace:

1. The exact reason an intact SD raw loader can block NVMe fallback even when a
   valid SPI loader is installed.
2. Whether the 26.5.1 vendor raw-loader HDMI output is U-Boot video, kernel
   video, or an error screen from the boot script path.
3. Whether the 26.5.1 `current` raw artifacts behave like the known-good SPI
   image when placed on SD.

## Practical commands

Before any destructive write to the SD raw-loader area, confirm the target and
save the current sectors:

```bash
lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINTS /dev/mmcblk1

mkdir -p /home/yi/Code/rock-5b-ysp/downloads/sd-bootarea-backups
BACKUP=/home/yi/Code/rock-5b-ysp/downloads/sd-bootarea-backups/mmcblk1-raw-loader-$(date +%Y%m%d-%H%M%S).bin

sudo dd if=/dev/mmcblk1 of="$BACKUP" bs=512 skip=64 count=32704 status=progress
sha256sum "$BACKUP"
```

Known-good practical workaround: keep the SD rootfs, but remove the SD raw
loader so the board uses SPI U-Boot to load `/boot` from SD:

```bash
sudo dd if=/dev/zero of=/dev/mmcblk1 bs=512 seek=64 count=32704 conv=notrunc,fsync status=progress
sudo sync
```

To test the 26.5.1 `current` raw loader on SD:

```bash
lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINTS /dev/mmcblk1

UBOOT=/usr/lib/linux-u-boot-current-rock-5b
sha256sum "$UBOOT"/idbloader.img "$UBOOT"/u-boot.itb

sudo dd if=/dev/zero of=/dev/mmcblk1 bs=512 seek=64 count=32704 conv=notrunc,fsync status=progress
sudo dd if="$UBOOT/idbloader.img" of=/dev/mmcblk1 bs=512 seek=64 conv=notrunc,fsync status=progress
sudo dd if="$UBOOT/u-boot.itb" of=/dev/mmcblk1 bs=512 seek=16384 conv=notrunc,fsync status=progress
sudo sync
```

Expected `current` raw artifact hashes:

```text
/usr/lib/linux-u-boot-current-rock-5b/idbloader.img
sha256: f9dbc3b5fa6178bd68b756ac8203f05dbd78c2086d794d4d9bbbf805dcad4f72

/usr/lib/linux-u-boot-current-rock-5b/u-boot.itb
sha256: 98e2c8af220907929221c1677c4c09dc9be3bdec5fa43ded738a124763988779
```

## Potential next steps

1. Test the 26.5.1 `current` raw loader on the SD card.
   - If it boots, the problem is specific to the `vendor` raw U-Boot path or its
     environment/configuration.
   - If it hangs but HDMI appears, compare the HDMI output and classify where it
     stops: U-Boot menu, boot script, initramfs, or kernel console.
   - If it hangs with no HDMI, then raw SD boot is still failing earlier than the
     SPI path even with the known-good loader family.

2. If the `current` raw loader fails, restore the known-good practical state by
   zeroing sectors 64..32767 again and booting SD through SPI.

3. If HDMI displays a U-Boot prompt, boot menu, or error, photograph or transcribe
   it. That may be enough to debug without UART.

4. If UART is later available, capture one boot for each of these states:
   original 26.2.1 raw loader, 26.5.1 vendor raw loader, 26.5.1 current raw
   loader, and zeroed raw loader via SPI. The most useful markers are the first
   DDR line, BL31 handoff, whether U-Boot scans `/boot/boot.scr`, and the final
   line before the hang.

5. If the `current` raw loader boots but `vendor` raw does not, compare their
   compiled U-Boot environments and boot targets. Pay particular attention to
   console choices (`ttyS2` versus `ttyFIQ0`), distro boot target ordering, and
   Armbian boot script handling.

6. If both 26.5.1 raw loaders fail but zeroed raw works through SPI, stop trying
   to make this SD standalone for now. The reliable operational mode is: keep
   SPI installed, keep the SD raw loader gap zeroed, and treat the SD as a
   rootfs/bootfs that the SPI loader owns.

## Related notes

- [`2026-07-08-armbian-26.2.1-bl31-handoff-hang.md`](2026-07-08-armbian-26.2.1-bl31-handoff-hang.md)
- [`2026-07-07-rock5b-spi-sd-boot-chain.md`](2026-07-07-rock5b-spi-sd-boot-chain.md)
