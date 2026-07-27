# RK3588 ramoops retention across reset

On this ROCK 5B and its inspected Armbian firmware stack, the Linux ramoops
window at `0x118000–0x1e7fff` does not retain a record across a software warm
reset. The next kernel sees the interval as all-zero. Treat serial or
netconsole as mandatory for a crash that may reset or hard-lock the board.

The actor that changes the bytes is not yet identified. Exact TPL, SPL, BL31,
and U-Boot audits found no ordinary CPU write into the interval. DDR
initialization is therefore the leading unresolved *phase*, but controller or
PHY initialization has not been observed destroying the data and must not be
reported as the proven cause.

## Current evidence contract

| Classification | What the evidence supports |
|----------------|----------------------------|
| **Measured** | The configured ramoops interval returns all-zero after a warm `panic=10` reboot on the inspected firmware stack. |
| **Measured** | A continuously written 512 KiB console zone and explicit `/dev/mem` markers both disappear. Ramoops's Reed-Solomon header checks report no corrupt record, which is consistent with an all-zero codeword rather than random residue. |
| **Binary/source inspected** | Recovered direct writes from the exact DDR/TPL blob, exact SPL, BL31, and U-Boot proper do not overlap `0x118000–0x1e7fff`. |
| **Leading inference** | The transition probably occurs no later than the DDR/early-loader phase because later recovered writers are disjoint. |
| **Unverified** | Which operation changes the bytes, whether any official BSP stack retains ramoops on RK3588, and whether a different firmware pair or reset path can preserve the interval. |

This distinction is the stable result. “DDR initialization is the remaining
phase to instrument” is not the same claim as “DDR training zeroes ramoops.”

## The tested layout

The debug DTB reserves:

```text
ramoops: 0x118000–0x1e7fff (832 KiB)
  record:  0x40000
  console: 0x80000
  pmsg:    0x10000
  ECC:     16 bytes per persistent-RAM zone
```

The address deliberately excludes the adjacent vendor areas:

| Physical range | Inspected use |
|----------------|---------------|
| `0x100000–0x10ffff` | BL31 shared-memory pool |
| `0x110000–0x117fff` | DDR firmware `DBGC` ring |
| `0x118000–0x1e7fff` | Linux ramoops window under test |
| `0x1f0000–0x1fffff` | BSP minidump/reserved tail; ATAGS writes begin at `0x1fe000` |
| `0x200000+` | Ordinary Linux RAM |

The running stack audited in the dated evidence is:

```text
ddr-v1.20-b8ce94f14b
bl31-v1.48
uboot-rmbian-201-06/05/2026
```

The exact component hashes, source pins, extraction offsets, and reproduction
commands remain in the linked findings below.

## Why this is a retention failure

The Linux side registered normally: the live DT node, zone sizes, ECC setting,
ramoops backend, pstore mount, panic timeout, and console backend were all
verified. Three observations then separate retention failure from a panic
dumper that simply did not run:

1. A clean warm reboot followed a boot that had written enough eligible
   console messages to wrap the 512 KiB console persistent-RAM zone. The next
   boot recovered no console record.
2. With `ecc-size = <16>`, every zone header is Reed-Solomon checked before its
   signature is accepted. Across repeated boots there were no bad-header,
   invalid-buffer, or ECC-failure messages. Random residue would almost
   certainly fail; all-zero content is a valid empty codeword.
3. With the ramoops driver kept away from the interval, explicit marker writes
   verified before reboot returned as zeros after the warm reset.

Together these show that useful bytes do not reach the next Linux instance at
this address. A device-tree property change cannot recover a signature that is
already gone before the next ramoops reader examines it.

## What the firmware audit ruled out

| Stage | Result |
|-------|--------|
| DDR/TPL blob | The exact v1.20 image and comparison v1.13/v1.15/v1.18/v1.22 images contain recovered low-DRAM writes, but their resolved ranges stop below `0x118000` or start above `0x1e7fff`. The `DBGC` writer is bounded to `0x110000–0x117fff`. |
| SPL | The exact SPI-resident SPL was reconstructed closely enough to map all bulk operations, fixed destinations, materialized low-DRAM addresses, and hundreds of inline zero stores. None overlaps the interval. |
| BL31 | The inspected shared-memory pool ends at `0x10ffff`; no recovered BL31 writer reaches ramoops. |
| U-Boot proper | The relevant pstore/minidump features are not enabled and the inspected allocations/load destinations are disjoint. |

This closes the recovered ordinary CPU-zeroer theory. It does not rule out:

- controller-assisted training or a memory-test engine;
- refresh interruption or a reset-state transition;
- a write whose address is computed in a way the static recovery missed;
- a BootROM-side effect; or
- early behavior observable only before normal SPL execution.

The all-zero 832 KiB result is also a poor fit for casual sparse training
traffic or simple random retention decay. Only a before/after checkpoint can
settle the mechanism.

## Corrections to earlier explanations

Do not repeat these superseded claims:

- **“All DRAM is lost across reset.”** Only selected regions and trials were
  measured; the current proof is about the tested interval.
- **“DDR scrambling re-keyed the contents.”** The RK3588 TRM says scrambling
  is bypassed by default, and an all-zero result is not evidence of re-keying.
- **“BL31's shared-memory pool is the zeroer.”** Its inspected range ends
  exactly below the vendor firmware ring and well below this ramoops window.
- **“The BSP preserves this address.”** BSP device trees provision ramoops,
  but no inspected public result demonstrates recovery of a prior RK3588
  `dmesg-ramoops` or `console-ramoops` record.
- **“A cold power-off is safer for recovery.”** Cold power removal guarantees
  DRAM loss. Warm reset is the only tested path with any chance of retention.
- **“No address or firmware can work.”** The tested address/stack fails; the
  broader universal claim was not measured.

## Operational rule

For any validation gate that can panic, reset, or hard-lock the kernel:

1. Attach `ttyS2` serial at 1,500,000 baud or configure netconsole before the
   test.
2. Keep persistent journald for the pre-crash userspace/kernel tail, but expect
   a hard fault to stop logging before the PC/LR/call trace is flushed.
3. Keep `panic_on_oops=0` when a process-context oops can be allowed to print
   without rebooting; use the destructive panic path only with off-board
   capture and recovery staged.
4. Do not cite an empty `/sys/fs/pstore` as evidence that no oops occurred.

The ramoops DT/config remains useful for reproducing the known failure and for
future firmware experiments. It is not a proven crash-capture channel on this
stack.

## Next causal experiment

The highest-value observation is an earliest-safe SPL-entry witness: inspect
page-unique markers immediately after the DDR TPL/BootROM path and before
normal SPL allocation or payload loading.

The maintained experiment order is:

1. characterize multiple pages with address-bearing PRBS/checksum patterns,
   guard pages, warm/cold controls, and full binary dumps;
2. emit an SPL-entry checksum/histogram over UART or SRAM;
3. if the bytes have already changed, vary only the DDR blob in a RAM-loaded
   diagnostic image;
4. checkpoint controller reset, DRAM initialization, refresh, PHY training,
   geometry detection, and memory-test phases with JTAG or small trampolines.

Success means observing the same page-specific marker immediately before and
after the first operation that changes it. A blob A/B that merely changes the
final result proves dependency, not mechanism. The complete controls and
safety boundaries are in the
[dated experiment plan](../../findings/2026-07-27-rk3588-ramoops-next-experiment-plan.md).

Testing whether an installed BSP kernel or official Radxa image recovers
ramoops is a separate premise test. A success would justify a controlled stack
differential; a failure would weaken the BSP premise but would not identify the
current stack's zero mechanism.

## Evidence ledger

| Date | Evidence | Role in the current conclusion |
|------|----------|--------------------------------|
| 2026-07-21 | [Warm-reset retention failure](../../findings/2026-07-21-ramoops-not-preserved-across-warm-reset-rk3588.md) | Initial measured failure; several mechanism claims were later corrected. |
| 2026-07-24 | [BSP/Armbian comparison and consolidated audit](../../findings/2026-07-24-bsp-vs-armbian-ramoops-gap.md) | Strengthened the all-zero proof, corrected the BSP premise, and eliminated several proposed causes. |
| 2026-07-26 | [Exact DDR/TPL binary audit](../../findings/2026-07-26-rk3588-ddr-blob-ramoops-static-audit.md) | Bounded recovered TPL writes and ruled out a direct DDR-blob clear of the interval. |
| 2026-07-27 | [Exact SPL binary audit](../../findings/2026-07-27-rk3588-spl-ramoops-binary-audit.md) | Closed the last recovered ordinary CPU-write candidate without claiming a DDR mechanism. |
| 2026-07-27 | [Next experiment plan](../../findings/2026-07-27-rk3588-ramoops-next-experiment-plan.md) | Defines the direct temporal witness needed to move beyond phase inference. |

These findings remain the dated forensic record. This page is the maintained
current explanation and operational boundary.
