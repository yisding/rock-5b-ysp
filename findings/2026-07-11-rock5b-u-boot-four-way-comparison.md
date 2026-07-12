# ROCK 5B U-Boot comparison: Armbian 26.2, Armbian 26.5, Radxa, upstream

> Scope: ROCK 5B boot firmware and the adjacent Armbian 26.5 vendor package used as a forensic control
> Source: local pinned trees and extracted packages listed below
> Date: 2026-07-11
> Trust: SOURCE-INSPECTED, CONFIG-INSPECTED, CODE-INSPECTED, INFERRED where explicitly marked

## Bottom line

The requested four names do not represent four independent U-Boot codebases.
Armbian 26.2.1 vendor and Armbian 26.5.1 current both package Radxa's heavily
modified U-Boot 2017.09 tree. The 26.5 package moves the Radxa pin by only two
commits, neither of which affects ROCK 5B, and its effective ROCK 5B
configuration is identical to 26.2 except for `CONFIG_LOCALVERSION`.

The most consequential difference is in the packaged binaries, not the board
source: the 26.2.1 vendor `u-boot.itb` has a **zero-byte U-Boot control DTB**,
whereas 26.5.1 current has a valid 12,752-byte DTB. The separately downloaded
26.5.1 vendor package also has a zero-byte control DTB. All three contain the
same-sized U-Boot payload and byte-identical BL31 segments. This is consistent
with a parallel-build dependency race in the Radxa tree and is the best current
explanation for the vendor images reaching BL31 and then apparently stopping.
It is not yet hardware-proven; the discriminating test remains booting the
26.5.1 current raw loader.

Radxa's 2026 tip remains the same vendor architecture and still contains that
dependency bug, but it changes SPL relocation and has substantial shared
RK3588/PCIe/MMC fixes. Upstream is a modern, independently evolved U-Boot with
Bootstd, EFI, Linux-synchronized DTs and binman images. It is the sensible
long-term base, but it is not a drop-in binary replacement for the vendor
package and omits several Android/vendor-only facilities.

## Exact baselines

| Name in this comparison | Exact source | Source date | Firmware inputs / package identity |
|---|---|---:|---|
| Armbian 26.2 | `radxa/u-boot` `6c807ac5008722e240f5282229c15a40aba4918f`; Armbian build `5abb97453fbabc453df560ee5b13fcc0ce31f417` | 2026-01-11 | Official `Armbian_26.2.1_Rock-5b_trixie_vendor_6.1.115_minimal`; DDR v1.18; BL31 v1.48 |
| Armbian 26.5 | `radxa/u-boot` `39cd993e5d6296635438e84f4576b3a9bf76f86e`; Armbian build `603aa92aed425c0b14e5f923259a14ccd0719379` | 2026-04-08 | Installed/downloaded `linux-u-boot-rock-5b-current` 26.5.1; DDR v1.20 (2025-09-26); BL31 v1.48 |
| Radxa | `radxa/u-boot` branch `next-dev-v2026.01` at `d9ab7ec6029573ac538b6707a0dffd0a5d049e77` | 2026-06-02 | Companion `radxa-build` currently selects DDR v1.22 and BL31 v1.54; inputs are external to U-Boot |
| Upstream | `u-boot/u-boot` `master` at `6741b0dfb41dc82a284ab1cff4c58af6ef2f3f9c` (`v2026.07-730-g6741b0dfb41`) | 2026-07-10 | External `ROCKCHIP_TPL` and `BL31`; versions are build-environment choices, not pinned by the board defconfig |

The Armbian `current` label describes the kernel/package branch, not an upstream
U-Boot lineage. Armbian 26.5.1 current still uses `radxa/u-boot` and reports
U-Boot version 2017.09.

For completeness, the downloaded `linux-u-boot-rock-5b-vendor` 26.5.1 package
is used below as a control. It pins the same `39cd993e...` U-Boot commit and the
same BL31/DDR revisions as 26.5.1 current. Its package metadata differs in
kernel serial-console naming (`ttyFIQ0` versus current's `ttyS2`) and artifact
version, but its saved U-Boot defconfig differs only in `LOCALVERSION`.

## The packaged control-DTB failure

`dumpimage -l` gives this component-level comparison:

| Package/image | U-Boot payload | U-Boot DTB | DTB SHA-256 | BL31 components |
|---|---:|---:|---|---|
| Armbian 26.2.1 vendor raw SD | 1,179,864 B | **0 B** | SHA-256 of empty data, `e3b0c442...` | identical to both 26.5 packages |
| Armbian 26.5.1 vendor control | 1,179,864 B | **0 B** | SHA-256 of empty data, `e3b0c442...` | identical |
| Armbian 26.5.1 current | 1,179,864 B | **12,752 B** | `6ed9a9d75157ca30d7fcff27670b782a335cfa949dc446d6b9dfebc1fec39078` | identical |

The three BL31 FIT segments have the same sizes, load addresses and hashes:

- 204,860 bytes at `0x00040000`, hash `7612223b...`
- 36,864 bytes at `0xff100000`, hash `70505bb7...`
- 24,576 bytes at `0x000f0000`, hash `b2af21b5...`

The U-Boot config has `CONFIG_OF_CONTROL=y`, `CONFIG_OF_SEPARATE=y`, and neither
`OF_EMBED` nor `OF_PRIOR_STAGE`. The control DTB is therefore a required input
to U-Boot proper, not an optional kernel DTB.

### Why the zero-byte DTB is probably nondeterministic

The Radxa FIT generator emits:

```dts
data = /incbin/("u-boot.dtb");
```

but its top-level Makefile declares `u-boot.itb` as dependent on `dts/dt.dtb`,
not on the copied `u-boot.dtb` that the generator actually reads:

```make
u-boot.dtb: dts/dt.dtb FORCE
	$(call cmd,copy)

u-boot.itb: u-boot-nodtb.bin dts/dt.dtb $(U_BOOT_ITS) FORCE
	$(call if_changed,mkfitimage)
```

Armbian's `spl-blobs` build requests `spl/u-boot-spl.bin u-boot.dtb u-boot.itb`
together. Under a parallel make, the copy can open/truncate `u-boot.dtb` while
`mkimage` reads it, producing a valid FIT whose FDT data is empty. The 26.5
current build happened to capture the completed 12,752-byte copy; the 26.2 and
26.5 vendor builds did not. This is a code-supported inference, not a repeated
build experiment.

The minimal source correction is to make `u-boot.itb` depend on `u-boot.dtb`
(or have the generator include its already-declared `dts/dt.dtb` input). A
packaging gate should also fail any RK3588 FIT for which `dumpimage -l` reports
the control FDT as zero bytes. Radxa tip `d9ab7ec...` still has the defective
dependency. Upstream has dropped this Rockchip FIT-generator path in favor of
binman.

### Boot-failure implication

This sharply narrows the earlier post-BL31 investigation:

- DDR initialization clearly ran, and 26.2 identifies its blob as v1.18.
- BL31 is byte-identical across the failing and candidate packages.
- BL33's control data is empty in both vendor artifacts and present in current.
- Vendor builds also set `CONFIG_DISABLE_CONSOLE=y` and `CONFIG_BOOTDELAY=0`, so
  an early BL33 failure is silent and looks exactly like a stop at BL31.

**INFERRED:** the empty control DTB is likely the immediate BL33 failure, while
the DDR v1.18-to-v1.20 change is no longer the leading explanation. The decisive
hardware test is still to write the 26.5.1 current `idbloader.img` and
`u-boot.itb` into the SD raw-loader locations and capture UART/HDMI behavior.

## Armbian 26.2 versus 26.5

The two pinned Radxa commits are separated by exactly two commits:

1. remove a USB high-speed limit on the Radxa CM5 IO board;
2. enable XMC SPI flash for RK3576 defconfigs.

Neither changes ROCK 5B source, its DTS, or its defconfig. Direct comparison
shows byte-identical `arch/arm/dts/rk3588-rock-5b.dts` and
`configs/rock-5b-rk3588_defconfig`. The reconstructed effective `.config` and
saved generated `defconfig` differ only in the Armbian local-version string.

Meaningful packaged differences are therefore:

- DDR blob v1.18 (`9fa84341ce`, built 2024-09-06) to v1.20 (`b8ce94f14b`, built
  2025-09-26);
- build timestamp/local-version identity;
- a valid control DTB in 26.5 current, caused most plausibly by build ordering;
- corresponding binary sizes and hashes.

| Artifact | 26.2.1 vendor | 26.5.1 current |
|---|---:|---:|
| `idbloader.img` size | 321,536 B | 323,584 B |
| `idbloader.img` SHA-256 | `961f208930865f1096b4f0f947b06b3ce47f1c443c945d7fd04c7727f5334f8b` | `f9dbc3b5fa6178bd68b756ac8203f05dbd78c2086d794d4d9bbbf805dcad4f72` |
| `u-boot.itb` size | 1,448,960 B | 1,461,760 B |
| `u-boot.itb` SHA-256 | `54350eaf2ae3a616ffe5cbb804878eb05971161509c6f09cb1cba22680ab6c44` | `98e2c8af220907929221c1677c4c09dc9be3bdec5fa43ded738a124763988779` |
| `rkspi_loader.img` SHA-256 | `740c95e013883f6768875d16e921672693ee95a9a5adafec854b455b84666e28` | `38b40ad14ec672899ff51118d65d10970f026f366a5c10afdbb82851b89aeacf` |

The 26.5 vendor control uses the same DDR v1.20 and source commit but still has
an empty DTB. Its artifact hashes are recorded in the companion download README.

## Armbian/Radxa vendor behavior

The effective Armbian/Radxa ROCK 5B feature profile is:

- silent, zero-delay boot (`DISABLE_CONSOLE`, `BOOTDELAY=0`);
- legacy distro scan followed by Rockchip `boot_fit` and `bootrkp` fallbacks;
- target order USB, SD, NVMe 0/1, SCSI, eMMC, MTD/RKNAND, PXE, DHCP;
- SD, eMMC, NVMe, PCIe, USB storage, RockUSB, USB mass storage, integrated
  Rockchip GMAC, fastboot, Android boot image and AVB code;
- Rockchip display/HDMI/DP drivers enabled;
- EFI loader disabled;
- environment compiled as `ENV_IS_NOWHERE`;
- separate `idbloader.img` + `u-boot.itb`, with Armbian assembling a 16 MiB
  `rkspi_loader.img` for SPI.

The FIT advertises `sha256,rsa2048:dev`, but `dumpimage` reports the signature
value as unavailable. Enabling FIT/AVB/RSA code is not evidence that these
particular artifacts establish a verified chain of trust.

## Armbian 26.5 versus the Radxa 2026 tip

From `39cd993e...` to `d9ab7ec...` there are 1,014 reachable commits and a net
tree delta of 546 files, 123,587 insertions and 35,254 deletions. The churn is
mostly new boards and shared vendor subsystems; the ROCK 5B DTS remains
byte-identical.

The direct ROCK 5B defconfig delta is one deliberate line:

```text
# CONFIG_SPL_SKIP_RELOCATE is not set
```

Armbian's effective package config has `CONFIG_SPL_SKIP_RELOCATE=y`; current
Radxa therefore relocates SPL, backed by commit `b1ffb198e90` ("rockchip: Add
spl relocate support for radxa boards"). This is a real early-boot difference
and is more important than the unchanged board DTS.

Other potentially relevant shared changes at the tip include RK3588 MMU/QoS
programming, eMMC iomux and clock fixes, PCIe retries/error handling, USB
gadget fixes, OTP-derived MAC handling and removal of OP-TEE use from Radxa
RK35xx configs. They need hardware qualification as a bundle; commit count by
itself is not evidence of better ROCK 5B stability.

The companion `radxa-build` checkout currently packages RK3588 with DDR v1.22
and BL31 v1.54, so comparing a newly built Radxa image with Armbian also changes
two closed firmware inputs. The Radxa U-Boot repository itself does not pin
those inputs.

## Vendor lineage versus upstream

The merge base of Radxa tip and upstream tip is upstream tag `v2017.09`, commit
`c98ac3487e413c71e5d36322ef3324b21c6f60f9c`. Since that point, Radxa has 9,587
lineage-only commits and upstream has 60,644 lineage-only commits. This is a
deep fork, not a normal rebasing lag; a whole-tree comparison is dominated by
6.8 million insertions, imported subtrees and architectural replacement.

| Capability | Armbian/Radxa vendor | Upstream tip |
|---|---|---|
| Board model | Generic RK3588 EVB target plus vendor board DTS | Dedicated `TARGET_ROCK5B_RK3588`; ADC/DRAM identification also selects ROCK 5B+, 5T |
| DT source | Small vendor U-Boot DTS over Rockchip SDK `rk3588.dtsi` | Linux-synchronized upstream DT (local tree contains the v6.19 DTS import) plus a small U-Boot dtsi |
| Boot framework | Legacy distro scripts + Rockchip Android/FIT fallbacks | Bootstd/bootflow with extlinux, EFI loader/boot manager, script, PXE and VBE methods |
| Console | Compiled out; delay 0 | Serial console enabled; delay 2 (header also names `vidconsole`, though video is not enabled in this defconfig) |
| EFI | disabled | enabled |
| Android / AVB / fastboot | enabled | not selected by ROCK 5B defconfig; RockUSB and UMS remain |
| Display in U-Boot | Rockchip DRM/HDMI/DP enabled | no video driver selected in ROCK 5B defconfig |
| Storage/network | SD/eMMC/NVMe/USB; vendor GMAC | SD/eMMC HS200/NVMe/AHCI/SCSI/USB; PCIe RTL8169; USB Ethernet drivers |
| USB-C | vendor Type-C changes were added then reverted | FUSB302/TCPM enabled and maintained with Linux DT |
| Image packaging | custom FIT generator, separate loader/ITB, external Armbian SPI assembly | binman creates `u-boot-rockchip.bin` and `u-boot-rockchip-spi.bin` |
| Firmware inputs | proprietary DDR + Rockchip BL31 in examined packages | external DDR TPL required; BL31 can be Rockchip binary or an appropriate TF-A build |
| Control-DTB race | present at Radxa tip | obsolete path removed |

Upstream's board history includes SPI NOR, SD/eMMC, PCIe/NVMe, PCIe SATA,
USB 2/3, RTL8169, Type-C PD, eMMC HS200, UMS and multi-model support. This is
substantially more maintainable and reviewable than the vendor SDK tree, but
upstream lacks the vendor boot UI/display and Android recovery path. A project
that needs those must either keep a qualified vendor build or port only the
required functionality.

## Recommendation

1. **Immediate boot discriminator:** test the already captured Armbian 26.5.1
   current raw artifacts. They preserve the familiar vendor behavior while
   changing the suspect control DTB from empty to valid.
2. **Make vendor builds deterministic:** correct the `u-boot.itb` dependency,
   enable console during qualification, and reject zero-length FIT FDTs in the
   package build. Do this before drawing conclusions from repeated builds.
3. **Do not attribute 26.2 versus 26.5 to U-Boot source fixes:** ROCK 5B code and
   effective configuration did not change. The DDR blob and build race did.
4. **Treat Radxa tip as a separate qualification target:** its SPL relocation
   change and newer external blobs alter early boot, while it retains the old
   boot architecture and FIT race.
5. **Use upstream for the long-term track:** start from a released upstream tag
   (Armbian's captured 26.5 framework uses v2026.01 for its `edge` mainline
   U-Boot path), preserve a vendor image for recovery, and qualify SD, eMMC,
   NVMe, SPI, USB-C, Ethernet and UMS before replacing the installed SPI image.

## Reproduction anchors

All comparisons were read from these local trees and captured files:

- `../u-boot/rock-5b-armbian-26.2.1-trixie-vendor-u-boot`
- `../u-boot/rock-5b-armbian-26.5.1-u-boot`
- `../u-boot/radxa-u-boot`
- `../u-boot/u-boot`
- `downloads/armbian-rock5b-uboot-compare/`

Useful non-building checks:

```bash
dumpimage -l path/to/u-boot.itb
strings path/to/idbloader.img | grep -E 'ddr-v|fwver|U-Boot SPL'
git diff -- configs/rock-5b-rk3588_defconfig arch/arm/dts/rk3588-rock-5b.dts
```

No build outputs from this comparison remain in `/tmp`.
