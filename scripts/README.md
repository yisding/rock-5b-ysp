# scripts/ - repository maintenance and board ops

Cross-project validation helpers and local board-maintenance scripts that do
not belong to a single package or driver area.

| Script | Purpose |
|--------|---------|
| [`check-repo.sh`](check-repo.sh) | Runs the common repository handoff gate: Markdown links, documentation contracts, and staged/unstaged/untracked whitespace. |
| [`check-markdown-links.py`](check-markdown-links.py) | Checks local Markdown links for missing files and missing same-repo section anchors. |
| [`check-doc-consistency.py`](check-doc-consistency.py) | Checks README ownership, finding metadata/index order, dashboard/next-gate/ledger alignment, watchlist index/detail contracts, stable support-coverage rows, and selected load-bearing terminology invariants. |
| [`repo_files.py`](repo_files.py) | Shared Git-aware maintained-file inventory for the Python checks, with a pruned source-archive fallback. |
| [`tests/test_repo_checks.py`](tests/test_repo_checks.py) | Standard-library regression tests for file inventory, link classification, dashboard/watchlist contracts, and the support-coverage schema. |
| [`rock5b-spi-erase.sh`](rock5b-spi-erase.sh) | Backs up and erases the ROCK 5B SPI NOR so BootROM falls through to microSD/eMMC bootloader paths. |
| [`rock5b-spi-restore-armbian.sh`](rock5b-spi-restore-armbian.sh) | Restores and verifies the Armbian ROCK 5B SPI bootloader image. |

Run the canonical handoff check from the repository root:

```bash
bash scripts/check-repo.sh
```

The individual Python checks remain available for focused debugging. The full
update workflow and project-specific test expectations are in
[`../CONTRIBUTING.md`](../CONTRIBUTING.md). The read-only
[`repository-checks` workflow](../.github/workflows/repository-checks.yml) runs
the same command on pushes and pull requests.

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
