# scripts/ - repository maintenance and board ops

Cross-project validation helpers and local board-maintenance scripts that do
not belong to a single package or driver area.

| Script | Purpose |
|--------|---------|
| [`check-repo.sh`](check-repo.sh) | Runs the common repository handoff gate, in order: Markdown links and anchors, the `tests/` regression suite, ShellCheck at warning-or-higher across every maintained shell file, the documentation consistency check, and staged/unstaged/untracked whitespace. Every stage runs even if an earlier one fails, so one run reports every problem; the exit summary names the failed stages. |
| [`centralize-ccache.sh`](centralize-ccache.sh) | Points every build under `~/Code` at one shared 30 GB compiler cache, wiring both the per-project cache paths and the host ccache config to it. |
| [`check-markdown-links.py`](check-markdown-links.py) | Checks local Markdown links for missing files and missing same-repo section anchors. |
| [`check-doc-consistency.py`](check-doc-consistency.py) | Checks substantive drift and completeness only: nearest-README ownership and nested-README navigation, root patch placement, findings-index coverage and order, paired watchlist metadata, matching dashboard/ledger tracks, contiguous status-table rows, synchronized kernel package helpers, FFmpeg/GRD version pins, portable operational defaults, and the tracked-shell mode/shebang contract. It deliberately does not police status prose, dates, general ordering, or project-brief fields. |
| [`repo_files.py`](repo_files.py) | Shared Git-aware maintained Markdown/operational-file inventory for the Python checks, with a pruned source-archive fallback, plus index-mode lookup for tracked files. |
| [`tests/test_repo_checks.py`](tests/test_repo_checks.py) | Standard-library regression tests for the checks above: file inventory, link classification and repo-escaping links, findings-index and watchlist contracts, synchronized package helpers, portable defaults, the shell shebang/mode contract, operational `--help` safety, and the kernel-log fatal signature scans. |
| [`prepare-armbian-headless.sh`](prepare-armbian-headless.sh) | Prepares a mounted Armbian ROCK 5B root filesystem for Wi-Fi and root SSH key access, temporarily handling a read-only mount when needed. |
| [`rock5b-oom-protection-apply.sh`](rock5b-oom-protection-apply.sh) | Installs and configures earlyoom so memory exhaustion kills one process instead of livelocking the board. Thresholds AND available memory against free swap (`-m 12,6 -s 10,5`), which is what makes it usable here — this board idles at 90-97% zram swap while completely healthy, so a swap-only trigger would fire constantly. `--status` inspects without root or writes; `--dry-run` prints the intended config; `--revert` disables the service and restores the previous file. Derivation in [`../findings/2026-07-25-rock5b-zram-thrash-livelock-wedge.md`](../findings/2026-07-25-rock5b-zram-thrash-livelock-wedge.md). |
| [`rock5b-passive-cooling-apply.sh`](rock5b-passive-cooling-apply.sh) | Applies and persists a reversible passive CPU/NVMe cooling profile for the fanless ROCK 5B. |
| [`rock5b-passive-cooling-revert.sh`](rock5b-passive-cooling-revert.sh) | Removes the passive-cooling service and restores its captured stock CPU/NVMe settings. |
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

## Centralize ccache

`centralize-ccache.sh` points every known build at one shared store,
`~/Code/.ccache`, capped at 30 GB with `compiler_check = content` and a
group-writable umask. Setup is idempotent, and `bootstrap-workspaces.sh` calls
it so a fresh machine is wired automatically.

Separate per-project caches buy nothing. ccache keys are content-addressed over
compiler identity, the full command line, and the preprocessed source, so an
aarch64 kernel cross-compile and a native Mesa build cannot collide in one
store. The only real cost of sharing is LRU competition, which is a sizing
question, not an argument for splitting.

Inspect the current layout without root access or writes:

```bash
bash scripts/centralize-ccache.sh --status
```

Create the store and wire every build:

```bash
bash scripts/centralize-ccache.sh
```

It refuses to delete a real cache directory still sitting at a wired path;
`--replace` opts into that. Root is needed only when such a path is not writable
by the invoking user — the Armbian container compiles as root, so its cache tree
usually is not.

The wiring is two symlinks, because ccache reads exactly one config file and
which one depends on whether `CCACHE_DIR` is set:

```text
~/.cache/ccache               -> ~/Code/.ccache
~/.config/ccache/ccache.conf  -> ~/Code/.ccache/ccache.conf
```

`~/.cache/ccache/ccache.conf` is never read, so linking only the cache directory
would leave host builds on ccache's 5 GiB / `mtime` defaults. Full reasoning in
[`../kernel-drivers/docs/kernel-build-ccache.md`](../kernel-drivers/docs/kernel-build-ccache.md).

## ROCK 5B passive cooling

The audited ROCK 5B is entirely passively cooled. Older kernels expose one
`soc-thermal` zone and map its trips to an absent PWM fan. Current Rockchip64
kernels expose `package-thermal` plus separate big- and little-core zones; the
CPU zones have cpufreq cooling bindings, but their first passive trip is 85 C.
`rock5b-passive-cooling-apply.sh` supplies a more conservative reversible
userspace policy. It takes the maximum of the hottest recognized CPU-zone
reading and the NVMe composite temperature plus 3 C. Accelerator-only zones
remain excluded from the CPU policy:

| Effective temperature | A55 ceiling | A76 ceiling |
|-----------------------|-------------|-------------|
| below 65 C | 1.800 GHz | 2.400 GHz |
| 65-69 C | 1.608 GHz | 2.208 GHz |
| 70-74 C | 1.416 GHz | 2.016 GHz |
| 75-79 C | 1.200 GHz | 1.800 GHz |
| 80-84 C | 1.008 GHz | 1.608 GHz |
| 85-89 C | 816 MHz | 1.416 GHz |
| 90-94 C | 600 MHz | 1.200 GHz |
| 95 C or higher | 408 MHz | 816 MHz |

Heating crosses those boundaries immediately. Cooling uses 2 C of hysteresis:
after entering a level, the effective temperature must fall 2 C below that
level's entry threshold before the script relaxes it. For example, level 3
starts at 75 C but remains active until the effective temperature reaches
73 C. This prevents repeated 2.016/1.800 GHz changes near 75 C.

The NVMe input is the controller's composite hwmon sensor at
`/sys/class/nvme/nvmeN/hwmon*/temp1_input`. A missing or malformed CPU or NVMe
temperature stops the monitor rather than silently dropping that input;
systemd then retries it after five seconds.

The script also restores every cpufreq minimum to its hardware minimum and
sets the NVMe Host Controlled Thermal Management thresholds to 65 C (light)
and 68 C (strong). It verifies that the controller supports those thresholds
before making changes. The default invocation saves the controller setting and
installs `rock5b-passive-cooling.service`, which reasserts the CPU policy every
five seconds and after each boot. The service retries on failure until its NVMe
controller is available; it does not wait on a systemd device unit because the
NVMe controller character device is not systemd-ready on the audited kernel:

```bash
sudo bash scripts/rock5b-passive-cooling-apply.sh
```

The first application writes a root-only stock snapshot under
`/var/lib/rock5b-passive-cooling/`. It is deliberately not overwritten by
later applications. Preview the current temperature level without writes, or
apply settings only until the next reboot:

```bash
bash scripts/rock5b-passive-cooling-apply.sh --dry-run
sudo bash scripts/rock5b-passive-cooling-apply.sh --once
```

Restore the exact cpufreq limits and saved NVMe HCTM value captured by the
first application, then remove the service and snapshot:

```bash
sudo bash scripts/rock5b-passive-cooling-revert.sh --dry-run
sudo bash scripts/rock5b-passive-cooling-revert.sh
```

These controls reduce hardware power but do not alter the parent shell's build
environment. Keep large kernel package builds at two jobs:

```bash
DEB_BUILD_OPTIONS=parallel=2 packaging/ppa/build-source-packages.sh ...
```

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
