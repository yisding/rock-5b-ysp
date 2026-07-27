# Exact SPL audit closes the ramoops zero-writer: cold DDR reinitialization destroys retention

> Scope: ROCK 5B running SPI firmware
> `ddr-v1.20-b8ce94f14b / bl31-v1.48 / uboot-rmbian-201-06/05/2026`
> Source: exact SPL extracted from `spi-rock5b-20260706.bin`
> (`sha256:38b40ad14ec672899ff51118d65d10970f026f366a5c10afdbb82851b89aeacf`);
> installed `u-boot.itb`; Radxa U-Boot
> `39cd993e5d6296635438e84f4576b3a9bf76f86e`; installed Armbian `.config`
> `sha256:d778912ca41725fb3f2cf8c92ef162f254b6c4ac61eb4a33d3cb940e7c3378cd`
> Date: 2026-07-27
> Trust: **BINARY-INSPECTED** / **SOURCE-INSPECTED** /
> **CONFIG-INSPECTED** / **INFERRED** / **ROOT-CAUSED**

## Result

The exact SPL that follows the DDR blob does **not** write Linux's ramoops
window at `0x118000–0x1e7fff`. Its fixed allocations, load destinations, bulk
memory operations, inline zero stores, and materialized low-DRAM addresses are
all disjoint from that interval.

Together with the prior exact-binary audits of the DDR/TPL blob, BL31, and
U-Boot proper, this closes the last ordinary CPU-write candidate. The root cause
is the firmware reset design:

> A software warm reboot re-enters a DDR TPL that has only a cold-start path.
> It resets and reconfigures the DDR controller/PHY and retrains DRAM on every
> invocation. That reinitialization destroys the previous cell contents, so a
> DRAM-backed ramoops buffer cannot retain data even though no boot-stage
> `memset` targets it.

This pins the responsible stage and mechanism class, not the individual DDRC or
PHY register operation that turns the prior contents into zeros. A trace or an
A/B blob with a retained-memory path would be needed to distinguish controller
reset, refresh interruption, training, and another internally issued operation.
That narrower boundary does not reopen SPL, BL31, U-Boot, or a DT layout error
as causes.

## Exact running SPL

The RK3588 v2 idbloader header reports:

```text
Init Data Size: 77824 bytes
Boot Data Size: 243712 bytes
```

Image 0 begins at idbloader byte `0x800`; image 1 begins at byte `0x13800`.
Because the idbloader itself starts at SPI sector 64, the exact SPL begins at
SPI byte `0x1b800`. The extracted image is:

```text
7a5aa9e68037ae5be25272c172905db87f88b5c4129c1b85ba4edfdc658415e0  running-spl.bin
```

The SPL is linked at zero. Its executable/data prefix ends at `0x39dc8`; its
BSS is `0x03fe0000–0x03fe09ff`. The following 5,124-byte control DTB is
byte-identical to the DTB produced from the installed source and configuration.

## Symbol recovery without pretending the rebuild is identical

The exact installed compiler was not recorded. The pinned source and installed
configuration were rebuilt with native AArch64 cross GCC 13.4, 14.3, and 15.
Their pre-DTB endpoints were:

| Compiler | Rebuilt endpoint | Difference from running `0x39dc8` |
|---|---:|---:|
| GCC 13.4 | `0x39dc0` | 8 bytes |
| GCC 14.3 | `0x39ae0` | 744 bytes |
| GCC 15 | `0x394c0` | 2,312 bytes |

All three builds generated the exact running DTB. GCC 13 also yielded 323
byte-identical function matches. The running binary acquires a four-byte shift
near `0x213c` and an eight-byte shift near `0x2848`; matched functions after
that point consistently follow the eight-byte displacement. In particular, the
rebuilt `memset`, `memcpy`, and `memmove` at `0x7cb8`, `0x7cd4`, and `0x7d40`
match the running functions byte-for-byte at `0x7cc0`, `0x7cdc`, and `0x7d48`.

Symbols and source lines were transferred only after a function or local
instruction-sequence match. The GCC 13 output was not treated as a
byte-identical substitute for the running SPL.

## Write audit

### Fixed runtime regions and FIT destinations

The exact SPL code, BSS, stack/early allocator, FIT read buffer, and installed
FIT payload destinations form this map:

| Use | Physical range or base |
|---|---|
| SPL text/data | `0x000000–0x039dc7` |
| BL31 primary image | `0x040000` load base |
| BL31 third segment | `0x0f0000–0x0f5fff` |
| BL31 shared-memory pool | `0x100000–0x10ffff` |
| DDR firmware log ring | `0x110000–0x117fff` |
| **Linux ramoops** | **`0x118000–0x1e7fff`** |
| ATAGS | `0x1fe000–0x1fffff` |
| U-Boot proper | `0x200000` load base |
| SPL stack, BSS, early malloc, page tables | near `0x03fe0000` |
| FIT read buffer | `0x10000000` |
| BL31 SRAM segment | `0xff100000` |

The only generic payload copy that could have made an arbitrary large write is
`spl_fit_load_image()`'s `memcpy((void *)load_addr, src, length)`. The exact
installed FIT lists U-Boot at `0x200000`, BL31 at `0x40000`, `0xff100000`, and
`0xf0000`, and the FDT as metadata. None overlaps ramoops.

### Bulk operations

The running binary contains 34 direct calls to `memset`, 69 to `memcpy`, and
one to `memmove`.

- The only fixed low-DRAM `memset` destination is the ATAGS structure at
  `0x1fe000`.
- Page-table clears use the SPL early allocator below the stack at
  `0x03fe0000`.
- The other clears operate on the SPL image/BL31 parameter structures in BSS or
  on stack, heap, FDT, crypto, driver-private, storage, and OOB structures.
- The copies likewise operate on ATAGS, stack/heap structures, FDT edits,
  crypto data, storage buffers, or the FIT destinations listed above.
- The sole `memmove` is libfdt's in-buffer splice.

There is no pstore or minidump path hidden behind a generic API:

```text
# CONFIG_PSTORE is not set
# CONFIG_ROCKCHIP_MINIDUMP is not set
```

### Inline stores and constructed constants

The disassembly has 236 explicit `str wzr`, `str xzr`, `stp xzr, xzr`, or
equivalent inline zero-store instructions. Mapping them back to the matched
GCC 13 functions accounts for the BSS loop, GIC/peripheral MMIO, stack
temporaries, heap/driver structures, storage buffers, and crypto workspaces.
The BSS loop itself loads the exact endpoints `0x03fe0000` and `0x03fe0a00`.

No instruction materializes an address in `0x118000–0x1e7fff`. The apparent
nearby constants are not pointers:

- `0x160000`-class values are global-data flag fields;
- `0x180000`-class values are BL31 SPSR parameter fields;
- `0x1d0000` is written as a value to an eMMC controller register;
- `0x1f0000`-class values are masks or sizes.

The actual materialized low-DRAM pointer constants are `0x1fe000` for ATAGS and
`0x200000` for U-Boot, both above the interval. Other computed write pointers
come from the known BSS/stack/heap arenas, device MMIO bases, storage buffers,
or the exact FIT load addresses.

## Why this is enough to assign the root-cause layer

The evidence chain is now:

1. A prior-boot persistent-RAM signature and a heavily written console zone
   return all-zero after a software warm reset.
2. BootROM reaches the DDR TPL before any later stage can use DRAM.
3. The exact TPL has no retained-memory fast path. It resets/configures the
   controller and PHY, trains every detected channel/rank, and performs
   destructive tests each time.
4. The exact TPL's recovered CPU writes stop below `0x118000` or start above
   `0x1e7fff`.
5. This audit removes the exact SPL as the last unaudited ordinary-store
   candidate.
6. BL31 and U-Boot proper were already removed by binary/source write maps.

The common event capable of destroying the buffer before all of those safe
destinations are used is therefore DDR controller/PHY cold reinitialization.
The all-zero result is an effect of that hardware-driven reinitialization, not
evidence of an undiscovered 832 KiB software clear.

Practically, changing ramoops properties or moving it within DRAM cannot fix
retention. The boot firmware would need a warm/retained-DRAM path, or crash
capture must leave DRAM before reset.

## Reproduction

Extract the two v2 idbloader components:

```bash
dd if=spi-rock5b-20260706.bin \
  of=downloads/rk3588-ddr-ramoops-analysis/running-idbloader.img \
  bs=512 skip=64 count=640 status=none
dd if=downloads/rk3588-ddr-ramoops-analysis/running-idbloader.img \
  of=downloads/rk3588-ddr-ramoops-analysis/running-spl.bin \
  bs=1 skip=79872 count=243712 status=none
```

Disassemble the exact SPL at its link address:

```bash
aarch64-linux-gnu-objdump -D -b binary -m aarch64 \
  downloads/rk3588-ddr-ramoops-analysis/running-spl.bin
```

Inspect the exact installed FIT destinations:

```bash
dumpimage -l /usr/lib/linux-u-boot-current-rock-5b/u-boot.itb
```

The ignored analysis workspace preserves the raw disassembly, function matcher
output, and mapped bulk/inline store callsites under
`downloads/rk3588-ddr-ramoops-analysis/`.

## Boundary

This was a static exact-binary audit, not a DDR bus or register trace. It proves
that the last plausible CPU-side boot stage does not target ramoops and closes
that causal branch. It does not identify which internal controller/PHY action
destroys the cells or whether another DDR blob generation implements retention
differently.

The documented read-only `/dev/mem` boundary experiment could not be run in this
session: `/dev/mem` was not exposed and `sudo` required an interactive password.
No firmware was rebuilt, flashed, or boot-tested.
