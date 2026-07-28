# GRD's first RKMPP frame oopses on a corrupted system-heap scatterlist entry

> Scope: ROCK 5B kernel forward-port and GNOME Remote Desktop RKMPP
> login-screen path.
>
> Source: booted production kernel `6.18.40-ysp-rockchip64` from
> `6.18.40+rk3588av1fwport20260725-0ubuntu1~rk1`; installed GNOME Remote
> Desktop `50.2+rkmpp+git20260721.13.cf60b4d`, FFmpeg
> `7:8.0.3+rockchip+git20260719.da5befc806`, and libmpp
> `1.5.0+git20260529.1375813c`; live journal, installed-binary disassembly,
> and the corresponding pinned sources.
>
> Date: 2026-07-27 PDT.
>
> Trust: **MEASURED** / **BINARY-INSPECTED** / **SOURCE-INSPECTED** /
> **INFERRED** / **PARTIAL**.

> **Corrected 2026-07-27 by**
> [`2026-07-27-grd-sg-corruption-kasan-non-reproduction.md`](2026-07-27-grd-sg-corruption-kasan-non-reproduction.md).
> Two decode corrections: `x19` is the scatterlist array **base**, not the
> failing entry (the value is 1024-aligned, which is the only alignment a
> `kmalloc-1024` object holding `kmalloc_array(24, 32)` can have; failing entry 1
> is at `…9420`); and `end_cpu_access()` syncs the per-attachment *duplicate*
> table while walking **every** mapped attachment, so the damaged table's owning
> device is not established and need not be the encoder's.
>
> The *Existing KASAN discriminator* and *Next verification gate* sections below
> are superseded. That gate was run and came back clean — 9/9 logins plus 1600
> direct encoder sessions — and KASAN is probably structurally unable to report
> this write, because the corrupt `page_link` is a well-formed `struct page`
> pointer rather than poison or garbage. See the superseding finding, and
> [`grd-sg-corruption-repro-plan.md`](../kernel-drivers/docs/grd-sg-corruption-repro-plan.md)
> for the replacement gate.

> **Corrected 2026-07-28 by**
> [`2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md`](2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md).
> **The writer is identified, and there was no corruption.** `page_link` is
> scrambled deliberately by `mangle_sg_table()` in `drivers/dma-buf/dma-buf.c`
> (~:831), compiled in only when `CONFIG_DMABUF_DEBUG=y` — which the production
> config sets and no other kernel on this board does. The core mangles the
> exporter's own per-attachment table at `dma_buf_map_attachment()` (~:1142) and
> unmangles it only around the unmap callback, so `end_cpu_access()` walks
> scrambled entries every time.
>
> Two statements below are therefore wrong. "PFN `0x1e0c1fc` cannot describe RAM
> on this machine" is true but misleading — that value is real PFN `0x1f3e00`
> (7.811 GiB, in RAM) XORed with `~0xffUL`; all eight recorded fault addresses
> invert to valid in-RAM frames. And "the entry was valid at map time and was
> corrupted before the later CPU-access-end sync" is right about the window but
> wrong about the cause: the map-time sync runs *inside* `dma_map_sgtable()`,
> before the core mangles, which is why it passed. The section *Ruled out and
> still open* correctly reports finding no vendor-driver writer — because the
> writer is in `drivers/dma-buf/`, which was not swept.

## Result

The missing RDP login screen is downstream of a kernel oops, not an RDP
authentication, GDM handover, codec-negotiation, or device-permission failure.
The system connection handed the client to a working greeter session, AVC420
was negotiated, and the GRD worker began its first RKMPP H.264 smoke frame.
The worker then died in `DMA_BUF_IOCTL_SYNC` before the first encoder hardware
job was submitted.

The immediate fault is narrowly identified: the second entry of the
24-entry scatterlist backing RKMPP's system-heap output bitstream buffer had a
corrupt `page_link`. It resolved to PFN `0x1e0c1fc`, far beyond this board's
maximum possible PFN of `0x4fffff`. The same scatterlist had already passed the
initial noncoherent-device sync during attachment, so the entry was valid at
map time and was corrupted before the later CPU-access-end sync.

The kernel writer that damaged `page_link` is **not yet identified**. This is
therefore a causal trace of the RDP failure and an immediate kernel-corruption
diagnosis, not a complete root-cause attribution.

## Connection and failure timeline

The journal orders the successful setup and the failure:

1. The system GRD connection authenticated and handed over to GDM.
2. Greeter session `c2` started with the expected render, video, and codec
   device access.
3. The client negotiated AVC420.
4. At `16:36:06.780`, Mutter added the virtual monitor.
5. At `16:36:07.287` through `16:36:07.295`, RKMPP configured H.264 at
   `2064x1296`, first with stride `2112x1344` and then `2112x1296`.
6. At `16:36:07.330`, thread `mpp_h264e_4425` (TID 5240, UID 60579) oopsed.

GRD never logged successful creation of the `h264_rkmpp` encoder. The GRD
process survived, but its smoke-test worker did not, leaving the connection
without a usable encoder session and therefore without login-screen video.

## Fault decode

The production-kernel oops begins:

```text
Unable to handle kernel paging request at virtual address ffff001e0c1fc000
ESR = 0x0000000096000145
FSC = 0x05: level 1 translation fault
Internal error: Oops: 0000000096000145 [#1] SMP
```

The stack is:

```text
dcache_clean_poc
iommu_dma_sync_sg_for_device
__dma_sync_sg_for_device
system_heap_dma_buf_end_cpu_access
dma_buf_end_cpu_access
dma_buf_ioctl
```

Register decoding against the installed kernel disassembly gives:

| Value | Meaning |
|---|---|
| `x21 = 0x18` | 24 original scatterlist entries |
| `x22 = 0` | `DMA_BIDIRECTIONAL` |
| `x23 = 1` | failing iteration is scatterlist entry 1, the second entry |
| `x0 = ffff001e0c1fc000` | invalid linear-map address derived from its page |
| `x1 = ffff001e0c2fc000` | end address, making this entry 1 MiB long |
| `x19 = ffff0001c3e59400` | ~~address of the failing scatterlist entry~~ — **corrected**: this is the array *base*; the failing entry 1 is at `…9420` (see the correction block above) |
| `x20 = fffffdffc0000000` | `vmemmap` base — makes the corrupt `page_link` recoverable as `x20 + PFN * 64` ≈ `0xfffffe0038307f00` |

The invalid virtual address corresponds to PFN `0x1e0c1fc`. The board's Normal
zone starts at PFN `0x100000` and spans `0x400000` pages, so the first PFN past
all possible RAM is `0x500000`. Device-tree memory ranges agree with that
roughly 20 GiB physical-address ceiling. PFN `0x1e0c1fc` cannot describe RAM
on this machine.

This is a CPU data abort while cleaning a cache range derived from a malformed
scatterlist page. It is not an IOMMU-reported device fault and not a userspace
virtual-address fault.

## Why this is the RKMPP output bitstream buffer

For H.264/H.265, libmpp sizes the output packet buffer from aligned
`width * height`. Here:

```text
2064 * 1296 = 2,674,944 bytes
system-heap page rounding = 2,678,784 bytes
```

The dma-buf sysfs inventory contained a `2,678,784`-byte system-heap buffer.
The heap's high-order allocation policy represents that exact size as:

```text
2 * 1 MiB + 8 * 64 KiB + 14 * 4 KiB = 2,678,784 bytes
```

That is exactly 24 scatterlist entries, and its second entry is exactly 1 MiB,
matching both `x21` and the failing address range. The independent buffer size,
entry count, allocation-order pattern, and second-entry length all identify the
faulting dma-buf as RKMPP's output packet buffer rather than GRD's imported
input framebuffer.

## When the corruption occurred

MPP attaches the output buffer to the encoder device through
`MPP_CMD_TRANS_FD_TO_IOVA`. `system_heap_map_dma_buf()` then calls
`dma_map_sgtable()` with `DMA_BIDIRECTIONAL`. For this noncoherent device,
`iommu_dma_map_sg()` synchronizes the original scatterlist before creating the
IOVA mapping.

That initial sync walks the same entries and would have faulted on the same
impossible second-entry page. It did not. The scatterlist was therefore valid
when the buffer was attached and mapped.

MPP next writes software headers and reaches `mpp_enc_hal_start()`. Before
calling the hardware-specific `start` operation, that function executes
`mpp_buffer_sync_partial_end()` for the output prefix. The installed buffer
implementation falls back to a full `DMA_BUF_IOCTL_SYNC` with `END | RW`.
That ioctl reaches `system_heap_dma_buf_end_cpu_access()`, where the second
entry now contains the impossible page.

The first frame was force-IDR, excluding libmpp's software force-pskip shortcut.
Source ordering places the crashing sync immediately before the encoder
hardware `start` call. Consequently, the encoder had not yet been submitted
for this frame and could not have performed a device-side DMA scribble into its
own descriptor metadata.

## Ruled out and still open

The evidence rules out:

- RDP authentication or GDM handover failure;
- render/video device ACL failure;
- unsupported codec negotiation;
- a bad userspace virtual address;
- a device-side IOMMU translation fault;
- corruption by the first encoder hardware job; and
- the ordinary GRD input framebuffer as the faulting dma-buf.

Inspection of system-heap, generic DMA-IOMMU, generic IOMMU, and Rockchip IOMMU
mapping paths found no intentional post-map write to `sgl[1].page_link`.
System-heap attachment locking also rules out an ordinary concurrent detach.
There was no preceding DMA-API warning or IOMMU fault in the captured journal.

What remains open is the precise kernel writer and mechanism: for example, an
out-of-bounds write or use-after-free in another kernel path, corruption of an
allocator neighbour, or less likely transient memory corruption. The
production kernel has DMA-API and slab debugging, but not KASAN or `DEBUG_SG`,
so this log records the victim access rather than the earlier write.

The oops also explains the lasting kernel state: the worker dies at the victim
access and the kernel gains the `DIE` taint bit (`128`).

## Existing KASAN discriminator

No rebuild is needed for the next test. The exact `0001` through `0075`
forward-port already has a boot-verified image:

```text
6.18.40-video-port-kasan-rockchip-rk3588
```

Its config enables KASAN generic inline mode, `DEBUG_SG`, `DEBUG_PAGEALLOC`,
`PAGE_OWNER`, DMA-API debugging, slab debugging, lockdep, and
`PROVE_LOCKING`. Its patch identity and prior clean codec/RGA gates are recorded
in the [6.18.40 KASAN validation](./2026-07-25-forward-port-6-18-40-kasan-full-validation.md).

The correct local build is identified by `P47b9-Cc271`. The neighbouring
`P0000-Cc271` artifacts are the previously diagnosed patch-free build and must
not be used.

Install/select the correct slot with:

```bash
sudo env RECOVERY_READY=1 PHASH='P47b9-Cc271' \
  bash kernel-drivers/scripts/install-kernel.sh
sudo reboot
```

After boot, `uname -r` must be exactly
`6.18.40-video-port-kasan-rockchip-rk3588`.

## Next verification gate

Make one macOS RDP login attempt at the same `2064x1296` geometry while
capturing the complete kernel journal and GRD user/session logs. Preserve the
first KASAN, `DEBUG_SG`, DMA-API, or page-owner report, including all lines
before the eventual victim access.

The outcomes mean:

- An earlier KASAN or debug report naming a writer closes or materially narrows
  the remaining attribution boundary.
- The same raw cache-clean oops reproduces the victim but does not identify the
  corrupting writer.
- A clean successful login disproves deterministic recurrence under that build,
  but does not invalidate the production-kernel trace.

Do not resume sustained focus/resume or audio validation until this first-frame
gate can create the RKMPP encoder without a kernel fault.
