# system-heap scatterlist `page_link` guard (debug-only)

Instrumentation to attribute the corruption behind
[`findings/2026-07-27-grd-rkmpp-system-heap-sg-corruption-oops.md`](../../../findings/2026-07-27-grd-rkmpp-system-heap-sg-corruption-oops.md).
Apply it only when building a diagnostic kernel; the clean forward-port and the
production `.deb` path must not carry it.

| # | File | Adds | Runner signal |
|---|------|------|---------------|
| 1 | `drivers/dma-buf/heaps/system_heap.c` | per-attachment `page_link` snapshot + validation at attach/map/sync/unmap/detach/release, `sg_guard` + `sg_guard_panic` knobs | `SGGUARD:` dmesg lines |

## Why this and not KASAN

The existing gate assumes the `6.18.40-video-port-kasan-rockchip-rk3588` image
will name the writer. It may be structurally unable to.

`page_to_pfn()` is `(page - vmemmap) / sizeof(struct page)`. The oops recorded
PFN `0x1e0c1fc`, which places the stored value in the first ~0.1% of the 2 TiB
vmemmap window. Slab poison (`0x6b`/`0x5a`), a SLUB freelist pointer (a
linear-map address), ASCII, or zero would all decode to an astronomically larger
PFN and a correspondingly wild fault address — not the clean
`__va(0x1e0c1fc000)` that was logged. So the corrupt `page_link` is a
**well-formed `struct page` pointer**: the writer computed a page pointer from a
bad input and stored it.

If that store was in-bounds on a live sg array, then:

- **KASAN cannot see it.** KASAN reports out-of-bounds and use-after-free, not
  correct-shape stores of wrong values.
- **`DEBUG_SG` cannot see it.** This kernel's `struct scatterlist` has no magic
  field; nothing validates `page_link`.
- **A device-side DMA scribble is also invisible to KASAN**, which instruments
  CPU accesses only.

This patch checks the invariant directly instead of hoping a generic detector
trips on it.

## What it does

`dup_sg_table()` gives every attachment its own copy of the buffer's table, so
the guard snapshots that copy's `page_link` array at attach time and re-compares
it everywhere the heap touches the table. `dma_map_sgtable()` never writes
`page_link` — `__finalise_sg()` touches only `dma_address`/`dma_len`/
`offset`/`length` — so the snapshot stays valid across map and unmap and the
comparison cannot false-positive.

Checkpoints, in the order a buffer meets them:

| Checkpoint | Answers |
|---|---|
| `attach` (origin) | was `buffer->sg_table` already bad before any dup? |
| `post-map` | **proves** the left edge of the corruption window, which the finding could only infer from the fact that the map-time sync did not fault |
| `begin_cpu_access` | corruption visible before the CPU-side sync |
| `end_cpu_access` | **the loop that oopsed** |
| `pre-unmap` / `detach` | corruption that only appears late |
| `release` (origin) | refuses to hand a wild page to `__free_pages()` |

Each report names the **owning device** (`dev_name(a->dev)`). That is the actual
open question: `system_heap_dma_buf_end_cpu_access()` walks *every* mapped
attachment of the buffer, so the faulting table is not necessarily the encoder's
even though the buffer was identified as RKMPP's output packet buffer.

Reports also carry the sgl base and its offset within its slab object (the
24-entry array is `kmalloc_array(24, 32)` = 768 B in **kmalloc-1024**), the
before/after `page_link` and PFN, and a hex dump of exactly
`orig_nents * sizeof(struct scatterlist)` bytes — never the tail slack, which
would trip the KASAN redzone from inside the diagnostic.

A corrupted sync is **skipped**, not executed, so the machine survives and keeps
logging instead of dying in `dcache_clean_poc()`.

## Knobs

Both are `module_param`s on a built-in, so they take a `system_heap.` prefix:

```text
system_heap.sg_guard=0          # off (default on)
system_heap.sg_guard_panic=1    # panic at the first hit instead of skipping
```

They are also writable at runtime under `/sys/module/system_heap/parameters/`.

## Applying

```bash
cd ~/Code/kernel/<tree>
git am /home/yi/Code/rock-5b-ysp/kernel-drivers/patches/system-heap-sg-guard/0001-*.patch
```

Then build a debug kernel as usual. The guard is independent of KASAN and worth
running on **both** images — on the production kernel it is the only instrument
that can catch this class of write at all.

## Reading the result

- A hit at `post-map` or `attach` moves the window earlier than the finding
  assumed, and implicates the mapping path or the allocator.
- A hit at `end_cpu_access` with `attach`/`post-map` clean confirms the finding's
  window and, for the first time, names the device whose table was damaged.
- `DRIFTED` with `valid=1` means a wrong-but-plausible page was stored — the
  case no existing detector would have reported.
- Silence across a run that also fails to oops means the bug did not occur, not
  that it was absent; pair it with a production-kernel control.

Drop the commit once the writer is identified.
