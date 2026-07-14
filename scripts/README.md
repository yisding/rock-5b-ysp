# scripts/ - repository maintenance and board ops

Cross-project validation helpers and local board-maintenance scripts that do
not belong to a single package or driver area.

| Script | Purpose |
|--------|---------|
| [`check-repo.sh`](check-repo.sh) | Runs the common repository handoff gate: Markdown links, documentation contracts, and staged/unstaged/untracked whitespace. |
| [`check-markdown-links.py`](check-markdown-links.py) | Checks local Markdown links for missing files and missing same-repo section anchors. |
| [`check-doc-consistency.py`](check-doc-consistency.py) | Checks Markdown and operational-file README ownership, project briefs, finding metadata/index order, dashboard/next-gate/action-path/ledger alignment, watchlist contracts, stable support-coverage rows, synchronized kernel-package helpers, and selected terminology invariants. |
| [`repo_files.py`](repo_files.py) | Shared Git-aware maintained Markdown/operational-file inventory for the Python checks, with a pruned source-archive fallback. |
| [`tests/test_repo_checks.py`](tests/test_repo_checks.py) | Standard-library regression tests for file inventory/ownership, link classification, dashboard/watchlist contracts, support coverage, and synchronized package helpers. |
| [`prepare-armbian-headless.sh`](prepare-armbian-headless.sh) | Prepares a mounted Armbian ROCK 5B root filesystem for Wi-Fi and root SSH key access, temporarily handling a read-only mount when needed. |
| [`rock5b-spi-erase.sh`](rock5b-spi-erase.sh) | Backs up and erases the ROCK 5B SPI NOR so BootROM falls through to microSD/eMMC bootloader paths. |
| [`rock5b-spi-restore-armbian.sh`](rock5b-spi-restore-armbian.sh) | Restores and verifies the Armbian ROCK 5B SPI bootloader image. |
| [`rock5b-sd-uboot-hypothesis-test.sh`](rock5b-sd-uboot-hypothesis-test.sh) | Captures a pristine 26.2.1 raw-SD loader gap, applies one controlled 26.5.1 component substitution, verifies readback, and restores the baseline. |

Run the canonical handoff check from the repository root:

```bash
bash scripts/check-repo.sh
```

The individual Python checks remain available for focused debugging. The full
update workflow and project-specific test expectations are in
[`../CONTRIBUTING.md`](../CONTRIBUTING.md). The read-only
[`repository-checks` workflow](../.github/workflows/repository-checks.yml) runs
the same command on pushes and pull requests.

## Prepare a mounted Armbian image for headless access

`prepare-armbian-headless.sh` validates that its target is a mounted Armbian
ROCK 5B root filesystem with a kernel, Netplan, and OpenSSH. It then adds a
root-only Netplan Wi-Fi definition, merges the invoking user's
`~/.ssh/authorized_keys` into the image's root account, forces public-key-only
SSH authentication, and ensures `ssh.service` is enabled. If the filesystem
was mounted read-only, the script temporarily remounts it read-write, syncs the
changes, and returns it to read-only before exiting.

Preview the target and planned files without prompting for a password:

```bash
bash scripts/prepare-armbian-headless.sh \
  --root /mnt/mmcblk1p1 \
  --ssid 'your-network' \
  --country US \
  --dry-run
```

Apply the configuration. The Wi-Fi password prompt does not echo input, and
the script deliberately does not accept a password as a command-line value:

```bash
sudo bash scripts/prepare-armbian-headless.sh \
  --root /mnt/mmcblk1p1 \
  --ssid 'your-network' \
  --country US
```

Under `sudo`, the key source defaults to the invoking user's
`~/.ssh/authorized_keys`; pass `--authorized-keys FILE` to choose another
public-key file. For automation, put the Wi-Fi password in a mode-`0600` file
and pass `--wifi-password-file FILE`. The resulting Netplan file is also mode
`0600`, because WPA credentials must remain available to the target system.

After unmounting the card and booting it, find the DHCP lease in the router and
connect with `ssh root@<board-ip>`. Armbian regenerates SSH host keys during its
first-run service, so verify and retain the final host-key fingerprint. Its
normal first-login setup may still ask for initial account choices.

The ROCK 5B has no integrated Wi-Fi radio; an installed, kernel-supported M.2
E-key module or USB adapter is required. The default interface match is `wl*`;
override it with `--interface-match` only when the adapter uses a different
name. This script validates partition-level boot files but cannot prove that
the raw SD loader area or the board's SPI-to-SD boot path works.

## ROCK 5B SPI bootloader

Read the [`U-Boot primer`](../boot-firmware/docs/u-boot-primer.md) and
[`debugging guide`](../boot-firmware/docs/debugging.md) before changing raw
firmware. They distinguish the SPI firmware source from the later OS target.

These scripts are intentionally board-specific. They refuse to run unless they
detect a Radxa ROCK 5B and a single 16 MiB NOR MTD device, unless overridden
with `--force-board` / `--mtd`.

Preview either path without root or flash writes:

```bash
bash scripts/rock5b-spi-erase.sh --dry-run --yes
bash scripts/rock5b-spi-restore-armbian.sh --dry-run --yes
```

Erase SPI after taking a timestamped backup:

```bash
sudo bash scripts/rock5b-spi-erase.sh
```

Restore Armbian's packaged SPI image:

```bash
sudo bash scripts/rock5b-spi-restore-armbian.sh
```

Restore from an explicit dump instead:

```bash
sudo bash scripts/rock5b-spi-restore-armbian.sh --image ./spi-rock5b-20260706.bin
```

The restore script defaults to
`/usr/lib/linux-u-boot-current-rock-5b/rkspi_loader.img`, checks that the image
size matches the SPI NOR, looks for U-Boot/ROCK 5B markers, writes with
`flashcp`, then compares the readback against the image.

## ROCK 5B raw-SD U-Boot hypothesis test

The SD test script separates the two differences between the failing Armbian
26.2.1 media and the audited 26.5.1 `current` candidate:

| Variant | 26.2.1 component retained | 26.5.1 component substituted | Interpretation |
|---------|---------------------------|------------------------------|----------------|
| `fit-only` | `idbloader.img` (DDR v1.18 and SPL) | `u-boot.itb` with a nonzero control DTB | A successful boot strongly supports the empty-control-DTB/BL33-package hypothesis. |
| `loader-only` | `u-boot.itb` with the empty control DTB | `idbloader.img` (DDR v1.20 and SPL) | A continued failure shows that the DDR/SPL update alone is insufficient. A success instead favors the early-loader path, subject to mixed-stage compatibility. |
| `both` | OS partitions and every byte outside the raw loader gap | Both raw boot artifacts | Positive-control candidate: tests the complete audited 26.5.1 `current` pair. |

Keep SPI contents, power, peripherals, display, and UART capture identical for
all four boots. First prove that the untouched new 26.2.1 card reproduces the
failure. Identify the SD **whole-disk** device carefully; every command below
uses `/dev/mmcblk1` only as an example.

Capture the complete raw loader gap before changing anything:

```bash
sudo bash scripts/rock5b-sd-uboot-hypothesis-test.sh capture \
  --device /dev/mmcblk1
```

The command prints the baseline filename under
`downloads/sd-bootarea-backups/`. Copy that exact path into the following
commands. The capture is 16,744,448 bytes (sectors 64 through 32767) and has
`.sha256` and `.report.txt` sidecars.

Preview the first substitution without a write:

```bash
sudo bash scripts/rock5b-sd-uboot-hypothesis-test.sh apply \
  --device /dev/mmcblk1 \
  --baseline downloads/sd-bootarea-backups/mmcblk1-armbian-26.2.1-pristine-TIMESTAMP.bin \
  --variant fit-only \
  --dry-run
```

Run one variant, boot it once, and capture UART plus HDMI observations:

```bash
sudo bash scripts/rock5b-sd-uboot-hypothesis-test.sh apply \
  --device /dev/mmcblk1 \
  --baseline downloads/sd-bootarea-backups/mmcblk1-armbian-26.2.1-pristine-TIMESTAMP.bin \
  --variant fit-only
```

Before every other variant, restore the full baseline and let the script
verify its SHA-256:

```bash
sudo bash scripts/rock5b-sd-uboot-hypothesis-test.sh restore \
  --device /dev/mmcblk1 \
  --baseline downloads/sd-bootarea-backups/mmcblk1-armbian-26.2.1-pristine-TIMESTAMP.bin
```

Use this order so every comparison begins from identical bytes:

1. untouched 26.2.1 baseline boot;
2. `fit-only`, then restore;
3. `loader-only`, then restore;
4. `both`, then restore when evidence capture is complete.

The default artifacts are the audited files in
`/usr/lib/linux-u-boot-current-rock-5b`. The script requires their known
SHA-256 values and rejects a zero-byte FIT control DTB. Use `--artifact-dir`
for a deliberately different candidate; it will still require explicit
`--allow-unpinned-artifacts` if the hashes differ.

For writes, the script rejects partitions, the running root disk, mounted child
partitions, non-512-byte logical sectors, and layouts whose first partition
overlaps the raw loader gap. It requires a removable target unless
`--force-device` is explicit, requires a typed confirmation, and verifies the
written component and the region expected to remain unchanged. It never reads
or writes SPI and does not modify partition filesystems.
