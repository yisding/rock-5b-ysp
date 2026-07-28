# Getting started — from a bare ROCK 5B to a known-good baseline

This is the short path for a new ROCK 5B owner. It gets the board to a
reproducible Linux baseline, explains what this repository can prove, and then
routes you to the right deeper guide. It does **not** replace Radxa's physical
setup instructions or Armbian's image and first-login documentation.

## What this repository is—and is not

This repository is an evidence-backed support record for the Radxa **ROCK 5B**
on Armbian, with its deepest validation on Ubuntu 26.04 Resolute and the RK3588
media stack. It is not an operating-system image, a general ROCK 5B manual, or
proof that every connector and peripheral works.

Choose your starting point by outcome:

| Goal | Start with |
|------|------------|
| Run a stable general-purpose Armbian system | The current **Recommended** image on [Armbian's ROCK 5B page](https://armbian.com/boards/rock-5b), then [Armbian's first-boot guide](https://docs.armbian.com/User-Guide_Getting-Started/). |
| Reproduce this repository's results | An Armbian Ubuntu 26.04 Resolute image, then identify the exact kernel and package path below before comparing results. |
| Run a Radxa-provided Debian or Android image | [Radxa's ROCK 5B installation guide](https://docs.radxa.com/en/rock5/rock5b/getting-started/install-os); treat its boot and userspace behavior as a separate baseline. |
| Add the repository's hardware-codec stack | Establish a working, recoverable baseline first, then use [`../install.md`](../install.md). |

Image lists and kernel versions change independently of this repository. Read
the live board page when selecting an image; use [`../status.md`](../status.md)
only for the dated state of the work tracked here.

## 1. Prepare the board without modifying firmware

Before power-on:

1. Confirm the board is a ROCK 5B, not a ROCK 5B+ or ROCK 5A. Similar names do
   not imply interchangeable images, device trees, or power requirements.
2. Follow Radxa's current [power-supply guidance](https://docs.radxa.com/en/rock5/rock5b/getting-started/power-supply).
   A marginal USB-C supply or cable can look like a kernel, storage, or
   bootloader failure.
3. Fit cooling appropriate to the workload. A heatsink is a sensible baseline;
   sustained compilation, GPU, NPU, or codec work needs temperature monitoring.
4. Start with Ethernet when possible. The ROCK 5B has no onboard Wi-Fi; Wi-Fi
   requires a supported M.2 E-key module or USB adapter.
5. Keep one independently bootable, known-good microSD card as rescue media.
   Do not make SPI, bootloader, and kernel changes at the same time.

Download and verify the image using its publisher's checksum or signature, then
flash only the intended removable device. Radxa documents the board-specific
storage paths; Armbian documents its own imager and first-boot behavior.

> **Stop before raw writes.** Do not copy a loader to an arbitrary offset,
> erase SPI, or install a replacement kernel merely to see whether it helps.
> First prove which stage is failing and prepare a recovery path. This
> repository's known SD/SPI boundary is in
> [`../status.md` track 12](../status.md#dashboard).

## 2. Complete one ordinary first boot

For the first boot, attach the simplest useful console:

- HDMI plus keyboard for an interactive setup;
- Ethernet plus SSH after the image's documented first-login flow; or
- a correctly wired 3.3 V serial adapter when diagnosing an early boot failure.

Let the image finish its first-run provisioning before removing power. On
Armbian, complete the password change and create the normal sudo-enabled user
described by the [first-login guide](https://docs.armbian.com/User-Guide_Getting-Started/#first-login).
Use that account for daily work.

If you must prepare a card for unattended Wi-Fi and SSH, read
[`../scripts/README.md`](../scripts/README.md#prepare-a-mounted-armbian-image-for-headless-access)
before using `prepare-armbian-headless.sh`. The helper requires a separate
Wi-Fi adapter, uses SSH keys, supports a dry run, and validates that the mounted
root belongs to a ROCK 5B Armbian image. It cannot prove that the board's raw-SD
loader path works.

## 3. Record what actually booted

“ROCK 5B running Armbian” is not enough identity for troubleshooting. Before
upgrading the kernel or installing accelerator packages, record the board,
boot medium, OS, kernel, and failed units:

```bash
tr -d '\0' </sys/firmware/devicetree/base/model
printf '\n'
uname -a
cat /etc/os-release
findmnt /
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
systemctl --failed
ip -brief link
```

Then use the repository's fuller, privacy-conscious collector:

```bash
PROFILE=initial \
  bash kernel-drivers/tests/conformance/scripts/collect-system-info.sh
```

The collector writes into an ignored `logs/` directory and records much more
than the short command set, including boot configuration, packages, thermal
zones, storage, PCI/USB topology, network drivers, DRM, audio, media devices,
and relevant kernel logs. Review the output before sharing it. The exact field
contract and privacy boundary are in
[`system-baseline.md`](system-baseline.md).

Save the output alongside three facts the machine cannot discover reliably:

- the board revision and RAM size;
- the power supply, storage, display, and optional adapters attached; and
- whether the boot firmware came from SPI, SD, eMMC, or another path.

The last item is different from the Linux root device. For example,
`SPI → NVMe` means firmware started from SPI and later loaded Linux from NVMe.
The [U-Boot primer](../boot-firmware/docs/u-boot-primer.md) explains the stages
and the two device trees without assuming firmware experience.

## 4. Decide whether the baseline is good enough

A usable baseline proves more than discovery:

| Question | Minimum useful signal |
|----------|-----------------------|
| Did it boot the intended system? | Board model, OS, kernel, root mount, and boot path match what you selected. |
| Is it stable at idle? | No failed required service, repeated reset, I/O error, thermal alarm, or new fatal kernel line during a bounded observation. |
| Does the needed hardware work? | A real operation moved data through the selected interface and produced correct output—not merely a device node or bound driver. |
| Can you recover? | The rescue medium boots independently and can reach or replace the installed system. |

Do not generalize one pass. An NVMe-root boot does not prove storage integrity;
an HDMI desktop does not prove every display output; `/dev/rga` does not prove
an RGA job completed. [`support-coverage.md`](support-coverage.md) says which
whole-board areas this repository tracks, has only narrow evidence for, or has
not assessed at all.

## 5. Choose the next learning or operating path

| What you want to do next | Read in this order |
|--------------------------|--------------------|
| Understand what this project has actually validated | [`../status.md`](../status.md) → [`support-coverage.md`](support-coverage.md) |
| Understand the board's boot chain or diagnose a no-boot | [U-Boot primer](../boot-firmware/docs/u-boot-primer.md) → [boot debugging](../boot-firmware/docs/debugging.md) |
| Enable MPP/RGA hardware codecs | [`../install.md`](../install.md) → [`../kernel-drivers/tests/`](../kernel-drivers/tests/README.md) |
| Understand the kernel and userspace media stack | [`work-packages.md`](work-packages.md) → [kernel driver guide](../kernel-drivers/docs/how-the-drivers-work.md) → [userspace library guide](../vendor-libraries/docs/how-the-userspace-libs-work.md) |
| Diagnose a known integration trap | [`gotchas.md`](gotchas.md) |
| Test an unassessed connector or subsystem | [`support-coverage.md`](support-coverage.md) → [`system-baseline.md`](system-baseline.md) → [`../findings/TEMPLATE.md`](../findings/TEMPLATE.md) |

Read dated claims literally. A green result on one named kernel/package set is
not an endorsement of a later package, a different Armbian kernel family, or a
Radxa image.

## 6. Make one change at a time

Use this order when extending the baseline:

1. Preserve the initial identity capture and a known-good rescue path.
2. Change one layer: image, firmware, kernel, device tree/overlay, userspace
   package set, or peripheral.
3. Reboot when that layer requires it.
4. Capture identity again and exercise the actual feature.
5. Compare correctness, logs, and recovery behavior with the initial baseline.

Kernel replacement has extra recovery requirements and no boot-menu safety net
on the documented Armbian path. Follow
[`../install.md` §3](../install.md#3-prepare-recovery-and-capture-the-old-baseline)
before installing any repository kernel. SPI operations are more invasive
still; use only the dry-run, backup, target verification, and restore workflow
in [`../scripts/README.md`](../scripts/README.md#rock-5b-spi-bootloader).

## First-hour checklist

- [ ] Confirm the exact board model and attached storage.
- [ ] Use an appropriate power supply, cable, and cooling setup.
- [ ] Verify the downloaded image before flashing.
- [ ] Complete first-run provisioning without interrupting power.
- [ ] Create and use a normal sudo-enabled account.
- [ ] Capture board, boot, OS, kernel, and peripheral identity.
- [ ] Check required services and relevant logs.
- [ ] Boot the rescue medium before changing firmware or kernels.
- [ ] Read the dated status and coverage boundary for the feature you need.
- [ ] Change and validate only one layer at a time.
