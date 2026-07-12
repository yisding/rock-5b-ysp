# Boot-firmware key words

Short definitions for reading the ROCK 5B U-Boot docs. The full stage and
artifact relationships live in [`docs/u-boot-primer.md`](docs/u-boot-primer.md).

- **BootROM** — immutable code inside the RK3588 that chooses a ROM-supported
  boot source, reads a Rockchip image header/ID block, and starts the earliest
  external stage.
- **boot source** — the medium from which BootROM/SPL/U-Boot firmware executes,
  such as SPI, raw SD, or raw eMMC. Not necessarily the Linux/root medium.
- **OS target** — the device/filesystem from which U-Boot loads Linux, such as
  NVMe or an SD partition.
- **TPL** — U-Boot's tertiary program loader, an optional stage earlier than
  SPL. On examined RK3588 builds a proprietary Rockchip DDR binary fulfills the
  early DRAM-initialization role and is passed to upstream as `ROCKCHIP_TPL`.
- **DDR blob** — executable Rockchip firmware that configures/trains DRAM.
  Its version and hash are part of the bootloader identity.
- **SPL** — secondary program loader, a constrained U-Boot build that initializes
  enough hardware to load TF-A and U-Boot proper.
- **TF-A** — Trusted Firmware-A, Arm's secure-firmware project.
- **BL31** — TF-A's EL3 runtime firmware. It provides secure services/PSCI and
  transfers to the normal-world BL33 payload.
- **BL32** — optional trusted-world payload, commonly OP-TEE.
- **BL33** — normal-world payload entered by BL31; U-Boot proper here.
- **U-Boot proper** — the full firmware program with driver model, environment,
  commands, OS discovery, and Linux handoff.
- **control DTB** — the device tree consumed by SPL/U-Boot to run firmware
  drivers. Distinct from the kernel DTB passed to Linux.
- **kernel DTB** — the device tree U-Boot loads/fixes up and gives to Linux.
- **`idbloader.img`** — Rockchip ID-block artifact; in the examined vendor path
  it combines the DDR binary and U-Boot SPL.
- **FIT / `u-boot.itb`** — Flattened Image Tree container holding U-Boot proper,
  BL31 segments, a control DTB, hashes, and a chosen configuration.
- **binman** — upstream U-Boot's final image assembler. It places built stages,
  external blobs, FITs, offsets, and padding into board/SoC images.
- **environment** — U-Boot key/value state containing settings and scripts.
  It can be compiled-only or persisted in flash/MMC/another backend.
- **distro boot** — legacy environment-script machinery that scans devices and
  filesystems for distribution-provided boot descriptions.
- **Bootstd / Standard Boot** — upstream's driver-model OS discovery framework.
- **bootdev** — a device through which Bootstd can access possible OS content.
- **bootmeth** — one method for discovering a bootflow, such as extlinux or EFI.
- **bootflow** — one concrete OS boot description discovered by a bootmeth on a
  bootdev.
- **extlinux** — BootLoaderSpec-style text configuration that names a kernel,
  initrd, kernel DTB/directory, and command line.
- **boot script** — U-Boot commands compiled by `mkimage`, commonly stored as
  `boot.scr` with editable source in `boot.cmd`.
- **EFI loader** — U-Boot facility that runs EFI applications and optionally an
  EFI boot manager.
- **RockUSB** — Rockchip's USB download protocol implemented by U-Boot tooling.
- **maskrom mode** — BootROM USB recovery mode used when normal boot sources do
  not yield a bootable path or recovery is explicitly requested.
- **SPL relocation** — copying SPL to its configured runtime address before
  continuing. Radxa tip explicitly enables this where the examined Armbian
  effective configuration skips it.
- **secure boot** — an enforced authentication chain rooted in trusted state.
  Enabled hashing/RSA commands or an unsigned FIT signature node are not, by
  themselves, secure boot.
