# RK3588 DDR blobs do not directly clear the Linux ramoops window

> Maintained current synthesis:
> [`boot-firmware/docs/ramoops-retention.md`](../boot-firmware/docs/ramoops-retention.md).
> This finding remains the exact TPL binary-audit evidence.

> **Followed up 2026-07-27 by**
> [`2026-07-27-rk3588-spl-ramoops-binary-audit.md`](2026-07-27-rk3588-spl-ramoops-binary-audit.md).
> The exact SPL's bulk operations, inline zero stores, fixed allocations, and
> FIT destinations are also disjoint from ramoops. With the last ordinary
> CPU-write candidate closed, DDR initialization remains the leading unresolved
> phase. The successor does not prove that PHY/controller initialization itself
> destroys the contents.

> Scope: ROCK 5B running SPI firmware `ddr-v1.20-b8ce94f14b`; static comparison
> against RK3588 DDR blobs v1.13, v1.15, v1.18, v1.20, and v1.22
> Source: exact TPL extracted from `spi-rock5b-20260706.bin`
> (`sha256:38b40ad14ec672899ff51118d65d10970f026f366a5c10afdbb82851b89aeacf`);
> `radxa/rkbin` at `da0efd5be712`, `b1599ee3c6e8`, `b9183559cabe`,
> `bb96b4f54cd4`, and `02931bbd3f97`; AArch64 disassembly and radare2
> decompiler output loaded at `CONFIG_TPL_TEXT_BASE=0xff001000`
> Date: 2026-07-26
> Trust: **BINARY-INSPECTED** / **CONFIG-INSPECTED** / **INFERRED**

## Result

The exact DDR/TPL code running on this board does **not** contain a statically
resolved write that overlaps the Linux ramoops window at
`0x118000–0x1e7fff`.

The blob does touch low DRAM, but the recovered ranges are disjoint:

| Physical range | Recovered use | Relation to our ramoops |
|---|---|---|
| `0x000000–0x003fff` | destructive 16 KiB default memory test for channel 0 / CS0 | ends 1.1 MiB below |
| `0x100000–0x10213f` | copy or clear an 8,512-byte DDR handoff/scratch block | ends 89 KiB below |
| `0x104000–0x104157` | copy a 344-byte handoff structure | ends 80 KiB below |
| `0x110000–0x117fff` | 32 KiB firmware `DBGC` log ring | ends exactly one byte below |
| `0x1fe000–0x1fe32b` | ATAGS construction/conditional clear | starts 88 KiB above |

This falsifies two proposed *direct* mechanisms for the current node:

1. The firmware-log initializer does not overshoot its advertised 32 KiB size.
2. No CPU `memset`, `memcpy`, or statically recovered memory-test descriptor
   spans `0x118000–0x1e7fff`.

It does **not** exonerate DDR initialization as an *indirect* cause. The entry
path resets and configures the DDR controller/PHY, trains every detected
channel/rank, and runs destructive memory tests on every invocation. No
warm-reset or retained-DRAM fast path was found. Controller/PHY reinitialization
or a hardware training operation can therefore destroy prior cell contents
without appearing as an AArch64 store to the ramoops addresses.

The important narrower conclusion is:

> The DDR blob rebuilds DRAM from scratch, but its decompiled CPU-side logic does
> not contain an 832 KiB direct clear. The successor exact-SPL audit also found
> no such writer. That leaves DDR initialization as the leading unproven phase;
> it does not assign the destructive effect to PHY/controller initialization.

## Exact running image

The SPI image stores an RK3588 v2 idbloader at sector 64. Its header reports:

```
Init Data Size: 77824 bytes
Boot Data Size: 243712 bytes
```

The init/TPL component begins at SPI byte `0x8800` and hashes to:

```
fb44e494c18b2472c5afe0ae6887ad147303a3924760c3f3c87245c37df60758
```

It embeds `ddr-v1.20-b8ce94f14b`. It is 1,344 bytes longer than the v1.20 file
at the rkbin release commit, but `cmp` shows that the first 68,731 bytes are
byte-identical. That prefix contains the complete recovered DDR init/training
function, memory-test function, low-DRAM copy/clear sites, and firmware-ring
writer discussed below. The first differences are in the trailing
version/configuration data, not those routines.

The exact running image's parameter dump is:

```
link_ecc_en=0
pstore_base_addr=0x11
pstore_buf_size=0x8
uboot_log_en=1
atf_log_en=1
optee_log_en=1
spl_log_en=1
tpl_log_en=1
```

## Downloaded comparison set

The raw binaries were downloaded into the ignored
`downloads/rk3588-ddr-ramoops-analysis/` workspace. They are ordinary raw
AArch64 images, not encrypted or compressed.

| Blob | Pinned rkbin commit | Size | SHA-256 |
|---|---|---:|---|
| v1.13 `25cee80c4f` | `da0efd5be7125d159a1284dea3243807aefe776c` | 72,912 | `6a4caa38bfe5485d654f654a9645781e4bb77fbafef827782a5e2eb13e652cda` |
| v1.15 `d5483af87d` | `b1599ee3c6e84f76d3a066a4da51e0bfa2976168` | 73,232 | `a8385c213d7d24a51ad07ae7702845467c7c66c675354729fe42d8194deec49d` |
| v1.18 `9fa84341ce` | `b9183559cabebed120ad431a614b291fee04c498` | 75,320 | `d89d40a8183b099589bfcffc5cc2ce9d874eb5b1d19b78bdad2cfcf45b9cb68f` |
| v1.20 `b8ce94f14b` | `bb96b4f54cd41390aeee56edc55874792439d721` | 76,480 | `d03cc98fccae96bde4bbdc9ed7b6c213a7946793eab33f03429589f0f8ff82f8` |
| v1.22 `d4bf75a5a6` | `02931bbd3f9756cbad556d73f6447b9a5b3fc240` | 78,024 | `99a44b3544c2c42ea3ab003732f52e1b4cb01e3870dd705785c831d24819da3b` |

For v1.13 through v1.20, `ddrbin_tool.py` reports the same pstore address,
size, five enabled log bits, and `link_ecc_en=0`. V1.22 keeps the same address
and size but sets all five log bits to zero, matching its release note that
pstore is disabled by default.

There is consequently no old-BSP-only preservation switch hidden in these
parameter blocks. V1.22 disables firmware logging; it does not introduce an
obvious retained-memory boot path.

## Decompiled firmware-ring writer

The v1.20 log routine is at `0xff01166c–0xff011798`; homologous routines are at
`0xff0110c4` in v1.13, `0xff0111dc` in v1.15, and `0xff011364` in v1.18.
Function matching scores the v1.18 and v1.20 implementations at 98% similarity.

Its input is the packed parameter word `0x0011801f`. In simplified pseudocode:

```c
void flush_tpl_log(uint32_t cfg)
{
        uint32_t total = cfg & 0xf000;
        uintptr_t base = cfg & 0xffff0000;

        if (!total)
                total = 0x10000;
        if (!base || !(cfg & 1))       /* tpl_log_en */
                return;

        uint32_t capacity = total - 12;
        struct ring *r = (void *)base;

        if (r->magic != 0x43474244) {  /* little-endian "DBGC" */
                r->magic = 0x43474244;
                r->cursor = 0;
                r->used = 0;
        }

        clamp_header_fields(r, capacity);
        append_with_wrap(r->data, capacity, (void *)0xff100000,
                         buffered_tpl_log_length);
}
```

For `0x0011801f`, `base=0x110000`, `total=0x8000`, and payload capacity is
`0x7ff4` after the 12-byte header. Every possible store is therefore contained
within `0x110000–0x117fff`.

The initializer is also preservation-aware: a valid `DBGC` ring is retained and
appended to. If the magic is absent, it writes a 12-byte empty header; it does
not zero all 32 KiB. This makes it a poor match for the observed all-zero Linux
window.

There is one layout caveat. Rockchip's BSP ramoops node starts at `0x110000`, so
the firmware ring intentionally occupies its first 32 KiB. Android exposes that
slice as `boot-log`; a Linux build without the BSP boot-log extension can instead
interpret it as part of a dmesg zone and see firmware overwrite. Our node starts
at `0x118000` specifically to avoid that collision.

## Other low-DRAM writes

The v1.20 top-level DDR function is recovered at
`0xff00a868–0xff00cc2f`. Relevant sites:

- `0xff00c5b0` constructs the first memory-test base as
  `channel_index << 33`; channel 0 therefore starts at physical zero.
  `0xff00c5f8–0xff00c60c` sets the test length to `0x4000`, and
  `0xff00c62c` calls the hardware-assisted destructive test. Other descriptors
  begin at channel or chip-select boundaries, not in the ramoops window.
- `0xff00c798–0xff00c7a8` copies `0x2140` bytes into `0x100000`.
  The alternate path at `0xff00c93c–0xff00c95c` zeroes the same physical range
  and its internal source buffer.
- `0xff00cbd8–0xff00cbf0` copies a `0x158`-byte structure to `0x104000`.
- `0xff00cc04–0xff00cc08` loads the packed pstore word from the configuration
  structure and invokes the ring writer above.
- `0xff0019d0–0xff0019f0` conditionally zeroes `0x32c` bytes at `0x1fe000`
  when the expected ATAG magic is present.

V1.22 retains homologous `0x100000/0x2140`, `0x104000`, and `0x4000`
memory-test behavior even though all firmware log bits default to off.

## What this changes

The previous investigation was right to keep DDR initialization in scope, but
wrong to call the closed TPL the sole likely *direct* zero-writer before
disassembling it.

At the time, this audit promoted SPL direct clear/allocation to the leading
ordinary-CPU-write candidate and kept DDR controller/PHY reinitialization as the
indirect candidate. The 2026-07-27 successor audited the exact SPL and falsified
that direct-write branch. The resulting disposition is:

1. **DDR initialization or an unrecovered hardware-side effect** — leading
   unresolved hypothesis because the blob has no recovered retained-memory path
   and all later direct writers are disjoint. PHY calibration alone is not
   inherently destructive, and no internal controller write was observed.
2. **SPL direct clear or allocation** — falsified by the exact-binary audit.
3. **TPL direct clear of `0x118000–0x1e7fff`** — falsified by this audit.
4. **TPL pstore-ring overshoot** — falsified; its upper bound is `0x117fff`.

The most discriminating safe runtime read remains the firmware ring at
`0x110000–0x117fff` before Linux modifies it. If a prior-boot `DBGC` header and
payload survive while Linux's adjacent signature does not, DRAM is retained
through TPL and the zeroing happens later. If both disappear together, the
controller-reinitialization explanation remains viable.

## Reproduction

Extract the exact running TPL:

```bash
dumpimage -l spi-rock5b-20260706.bin
dd if=spi-rock5b-20260706.bin \
   of=downloads/rk3588-ddr-ramoops-analysis/running-tpl-v1.20.bin \
   bs=1 skip=34816 count=77824 status=none
sha256sum downloads/rk3588-ddr-ramoops-analysis/running-tpl-v1.20.bin
```

Dump its parameter block:

```bash
~/Code/u-boot/rkbin/tools/ddrbin_tool.py rk3588 \
  -g downloads/rk3588-ddr-ramoops-analysis/running-v1.20-config.txt \
  downloads/rk3588-ddr-ramoops-analysis/running-tpl-v1.20.bin
```

Disassemble at the TPL link address:

```bash
aarch64-linux-gnu-objdump -D -b binary -m aarch64 \
  --adjust-vma=0xff001000 \
  downloads/rk3588-ddr-ramoops-analysis/running-tpl-v1.20.bin
```

The independent decompiler pass used radare2 6.0.7 with:

```bash
radare2 -q -a arm -b 64 -m 0xff001000 \
  -e anal.in=io.maps \
  -c 'aaa; pdc @ 0xff00a868; pdc @ 0xff01166c' \
  downloads/rk3588-ddr-ramoops-analysis/running-tpl-v1.20.bin
```

## Boundary

This is a static binary audit, not a warm-reset hardware trace. Computed
addresses were followed through the recovered memory-test and copy call sites,
but a closed DDR controller can issue writes internally after MMIO programming.
The absence of a recovered CPU store into ramoops is not proof that the bytes
survive controller reset/training.

The exact SPL boundary was closed by the linked 2026-07-27 successor. No
firmware was rebuilt, flashed, or boot-tested as part of this finding. BSP
ramoops persistence on RK3588 also remains unproven.
