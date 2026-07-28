# RK3588 ramoops retention across reset

On this ROCK 5B, the Linux ramoops window at `0x118000–0x1e7fff` **retains
records across a software warm reset on every 6.18.40-era kernel measured
(2026-07-26 onward)** — repeated cross-reset recoveries are on record,
including a full oops dump. The all-zero retention failure documented here
between 2026-07-21 and 2026-07-24 was real, but it is now **scoped to the
6.18.38-era kernels**: the failure disappeared with the 2026-07-25 rebuild
wave (repo `49b115e`) while the firmware stack, the DTB node, the cmdline, and
userspace were held constant. The zeroing actor was therefore almost certainly
in that kernel generation, not in the boot firmware — which the exhaustive
TPL/SPL/BL31/U-Boot audits corroborate by having found no firmware writer.

The exact fixing change is not yet identified, and "6.18.38 still fails
today" has not been re-confirmed; both are covered by the pending kernel A/B
(below). Details and full evidence:
[2026-07-28 finding](../../findings/2026-07-28-ramoops-retention-works-on-6-18-40-kernels.md).

## Current evidence contract

| Classification | What the evidence supports |
|----------------|----------------------------|
| **Measured** | ≥9 cross-reset recoveries on 6.18.40-era kernels, 2026-07-26..27, same firmware (`ddr-v1.20-b8ce94f14b / bl31-v1.48 / uboot-rmbian-201`); the 2026-07-27 19:38 GRD-SG oops dump crossed a clean warm reboot and is archived in `/var/lib/systemd/pstore/`. |
| **Measured (historical)** | On the 6.18.38-era kernels, 2026-07-21..24, the window came back all-zero after warm resets: marker probe ZEROED, Reed-Solomon silence, wrapped-console loss, with `systemd-pstore … skipped (ConditionDirectoryNotEmpty)` proving pstore genuinely empty on those boots. |
| **Config-inspected** | The ramoops DT node is byte-identical between the failing-era and working-era DTBs; systemd-pstore enabled-stock in both eras; cmdline identical; firmware stamp unchanged. |
| **Leading inference** | The zeroer was kernel-generation-scoped (6.18.38-era, gone in 6.18.40-era). The firmware-phase hypothesis is retired. |
| **Unverified** | Which change (upstream 6.18.39/40 stable, Armbian family patch refresh, or repo patchset revision — they moved together) fixed it; whether 6.18.38 still fails on today's board state. |

## The tested layout

The DTB (all repo kernel flavors, and the still-installed
`6.18.38-current-rockchip64` debug DTB — byte-identical nodes) reserves:

```text
ramoops: 0x118000–0x1e7fff (832 KiB)
  record:  0x40000
  console: 0x80000
  pmsg:    0x10000
  ECC:     16 bytes per persistent-RAM zone
```

| Physical range | Inspected use |
|----------------|---------------|
| `0x100000–0x10ffff` | BL31 shared-memory pool |
| `0x110000–0x117fff` | DDR firmware `DBGC` ring (static TPL bound) |
| `0x118000–0x1e7fff` | Linux ramoops window |
| `0x1f0000–0x1fffff` | BSP minidump/reserved tail; ATAGS writes begin at `0x1fe000` |
| `0x200000+` | Ordinary Linux RAM |

Two overlap cautions when interpreting DRAM dumps or retention runs:

- **The BSP kernel (`6.1.115-vendor-rk35xx`) uses `0xe0000@0x110000`, which
  contains this whole window** and corrupts its zones on every BSP boot. Any
  retention comparison interleaved with a BSP boot is confounded.
- pstore's zone signature `PERSISTENT_RAM_SIG` is the ASCII bytes `DBGC` —
  the same tag as the TPL debug ring — so `DBGC` at `0x110000+` in a dump
  taken after a BSP boot may be pstore's own headers, not the firmware ring.

## What the firmware audit ruled out

These binary/source results stand, and under the kernel-scoped reading their
null results are the expected outcome rather than an anomaly:

| Stage | Result |
|-------|--------|
| DDR/TPL blob | Exact v1.20 and four comparison generations: recovered low-DRAM writes stop below `0x118000` or start above `0x1e7fff`; the `DBGC` writer is bounded to `0x110000–0x117fff`. |
| SPL | Exact SPI-resident SPL: all bulk operations, fixed destinations, materialized low-DRAM addresses, and inline zero stores are disjoint from the interval. |
| BL31 | Shared-memory pool ends at `0x10ffff`; no recovered writer reaches the window. |
| U-Boot proper | pstore/minidump features disabled; allocations/load destinations disjoint. |

The PMIC RST_FUN, `GLB_SRST_SND`, DDR-scrambling, minidump, and userspace
hypotheses remain refuted exactly as recorded in the
[2026-07-24 finding §3.2](../../findings/2026-07-24-bsp-vs-armbian-ramoops-gap.md).

## Corrections to earlier explanations

Do not repeat these superseded claims (each was reasonable on the evidence of
its day; the dated findings retain the full history):

- **"The window is always all-zero after a warm reset on this firmware
  stack."** True only on the 6.18.38-era kernels. Current kernels retain.
- **"DDR initialization is the leading unresolved phase."** Retired. The
  leading hypothesis is a 6.18.38-era kernel-side actor.
- **"No address inside `0x110000–0x1f0000` can survive under this
  firmware."** `0x118000` demonstrably carries records today.
- **"Serial or netconsole is mandatory because ramoops cannot work here."**
  Softened — see the operational rules below.
- **"An empty `/sys/fs/pstore` means nothing was captured."**
  `systemd-pstore.service` archives to `/var/lib/systemd/pstore/` and erases
  the DRAM zones within seconds of boot; `/sys/fs/pstore` is empty by the
  time anyone looks. This blind spot is how the working channel went
  unnoticed for two days.
- The pre-2026-07-24 corrections (DRAM-wide loss, scrambling re-key, BL31
  pool, "the BSP preserves this address", "cold power-off is safer") remain
  corrected as before.

## Operational rules

For any validation gate that can oops, panic, reset, or hard-lock the kernel:

1. **After every reboot, check `journalctl -b -u systemd-pstore` and
   `/var/lib/systemd/pstore/` (root) for recovered records.** Never treat an
   empty `/sys/fs/pstore` as meaning anything.
2. Ramoops on the current kernels is a working capture channel for
   oops/panic records across clean warm reboots. Keep serial (`ttyS2`,
   1,500,000 baud) or netconsole staged for the cases DRAM cannot cover:
   hard locks that force a power cycle, and anything before ramoops
   registers.
3. Cold power removal still forfeits DRAM contents; prefer warm resets when a
   record matters.
4. Do not boot the BSP kernel between a crash and the recovery attempt — its
   overlapping window destroys the zones.
5. `panic_on_oops=0` remains the debug-build policy (journald captures the
   live trace and the session survives); the panic-path capture is expected
   to work but is part of the pending A/B qualification.

## Next causal experiment

The priority experiment is the kernel A/B — it replaces the SPL-entry
witness, because the target is no longer firmware instrumentation. The failing
kernel is still installed; four reboots settle the scoping:

1. `6.18.40-ysp`: `ramoops-persistence-probe.sh write` → warm reboot → `read`
   (expected INTACT).
2. Repoint `/boot/Image`/`uInitrd`/`dtb` at `6.18.38-current-rockchip64`,
   boot, `write` → warm reboot → `read`.

ZEROED-on-38 + INTACT-on-40 confirms the kernel-side actor; then split
upstream-stable vs patchset (6.18.38 base + new patches, or 6.18.40 base +
old patches) before considering a commit bisect of the 2113-commit stable
range. INTACT-on-38 means the 07-21..24 environment carried a hidden
confound; reopen from the archived evidence. The SPL-entry temporal witness
([2026-07-27 plan](../../findings/2026-07-27-rk3588-ramoops-next-experiment-plan.md))
is only worth running if the A/B contradicts the kernel-scoped reading.

## Evidence ledger

| Date | Evidence | Role in the current conclusion |
|------|----------|--------------------------------|
| 2026-07-21 | [Warm-reset retention failure](../../findings/2026-07-21-ramoops-not-preserved-across-warm-reset-rk3588.md) | Initial measured failure (6.18.38 era); several mechanism claims corrected 07-24. |
| 2026-07-24 | [BSP/Armbian comparison and consolidated audit](../../findings/2026-07-24-bsp-vs-armbian-ramoops-gap.md) | Strengthened the (era-scoped) all-zero proof; killed the PMIC/reset/DT hypotheses; its refutations stand. |
| 2026-07-26 | [Exact DDR/TPL binary audit](../../findings/2026-07-26-rk3588-ddr-blob-ramoops-static-audit.md) | No TPL writer into the interval — now corroborates the kernel-scoped reading. |
| 2026-07-27 | [Exact SPL binary audit](../../findings/2026-07-27-rk3588-spl-ramoops-binary-audit.md) | Closed the last recovered firmware CPU-write candidate — same corroboration. |
| 2026-07-27 | [Next experiment plan](../../findings/2026-07-27-rk3588-ramoops-next-experiment-plan.md) | SPL-entry witness design; demoted to contingency by the 07-28 reversal. |
| 2026-07-28 | [Retention works on 6.18.40-era kernels](../../findings/2026-07-28-ramoops-retention-works-on-6-18-40-kernels.md) | The reversal: measured recoveries, flip timeline, blind-spot analysis, kernel A/B gate. |

These findings remain the dated forensic record. This page is the maintained
current explanation and operational boundary.
