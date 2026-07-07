# scripts/ - repository maintenance and board ops

Cross-project validation helpers and local board-maintenance scripts that do
not belong to a single package or driver area.

| Script | Purpose |
|--------|---------|
| [`check-markdown-links.py`](check-markdown-links.py) | Checks local Markdown links for missing files and missing same-repo section anchors. |
| [`rock5b-spi-erase.sh`](rock5b-spi-erase.sh) | Backs up and erases the ROCK 5B SPI NOR so BootROM falls through to microSD/eMMC bootloader paths. |
| [`rock5b-spi-restore-armbian.sh`](rock5b-spi-restore-armbian.sh) | Restores and verifies the Armbian ROCK 5B SPI bootloader image. |

Run these before presenting or handing off a large documentation cleanup:

```bash
python3 scripts/check-markdown-links.py
git diff --check
```

## ROCK 5B SPI bootloader

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
