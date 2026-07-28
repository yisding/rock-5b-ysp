# Source sweep clears the vendor MPP driver of the GRD scatterlist write, and corrects three readings of the corrupt value

> Scope: ROCK 5B kernel forward-port; attribution of the writer behind the
> GRD/RKMPP system-heap oops traced in
> [`2026-07-27-grd-sg-oops-third-repro-ioctl-window-measured.md`](2026-07-27-grd-sg-oops-third-repro-ioctl-window-measured.md).
>
> Source: `packaging/ppa/out/work/linux-rockchip64-ysp-6.18.40+rk3588av1fwport20260725`
> and the identical git worktree `~/Code/tmp/fwport-sgguard` (`v6.18..HEAD` = the
> 76-patch series). Read: all of `drivers/video/rockchip/mpp/`, all of
> `drivers/video/rockchip/rga3/`, `drivers/dma-buf/heaps/system_heap.c`, the
> series' `drivers/iommu/` delta (`dma-iommu.c`, `rockchip-iommu.c`, new
> `vsi-iommu.c`), and `arch/arm64/boot/dts/rockchip/rk3588-rock-5b.dtsi`.
> Three parallel read-only sweeps plus direct verification of every load-bearing
> claim.
>
> Date: 2026-07-27
>
> Trust: **SOURCE-INSPECTED** / **INFERRED**. No new runtime measurement.

## Result

The writer is **not attributed**. What this pass buys is a strong, code-anchored
negative — the vendor MPP driver cannot be the writer — the elimination of the
most attractive RGA candidate, three corrections to how the corrupt value was
being read, and five latent defects found along the way, one of them an
unbounded user-controlled kernel write that is worth fixing on its own merits.

### The vendor MPP driver never writes a scatterlist

Exhaustive grep of `drivers/video/rockchip/mpp/` for `scatterlist`, `sg_set_page`,
`sg_assign_page`, `page_link`, `sg_next`, `for_each_sg`, `sg_alloc_table`,
`sg_free_table` yields **four** references, all reads:

| Site | Access |
|---|---|
| `mpp_iommu.h:41-42` | `struct sg_table *sgt; *copy_sgt;` — fields |
| `mpp_iommu.c:139` | `buffer->copy_sgt = NULL` (dead field; never set non-NULL) |
| `mpp_iommu.c:102-103`, `:319-320` | `sg_dma_address()`/`sg_dma_len()` reads |
| `mpp_iommu.c:476-481` | `mpp_dma_buf_sync()` reads `sg->length`, `sg_dma_address()` |

There is no `sg_set_page`, no `sg_assign_page`, no `memcpy`/`memset` onto an sg
array anywhere in `mpp/`. MPP is a pure scatterlist reader.

Allocation sizes rule out the slab-collision route independently. Every object
MPP allocates or frees across the measured timeline misses **kmalloc-1024**,
the victim's bucket: `mpp_session` 376 B and `mpp_task_msgs` 488 B (kmalloc-512),
`rkvenc2_session_priv` 256 B, `rkvdec2_session_priv` ≤256 B,
`mpp_dma_session` ≈6.8 KiB, `mpp_task` >4 KiB (it embeds `mem_regions[80]`).
The only MPP tenants of kmalloc-1024 in the entire driver are the rkvenc2
class-register buffers — `ST` 720 B and `DEBUG` 856 B
(`mpp_rkvenc2.c:832-850`, freed at `:818-830`) — and both require an allocated
task, which requires `MPP_CMD_SET_REG_WRITE`, which the measured trace shows
never happened. They remain the one MPP-side collision partner to watch if this
signature ever reappears alongside an active encode.

Deferred teardown does exist and does run after the fd closes
(`mpp_session_detach_workqueue()` `mpp_common.c:496-520` → the taskqueue kthread
→ `mpp_session_cleanup_detach()` → `mpp_session_deinit()`), which is what the
three probe sessions (client types 4 = AV1DEC, 9 = RKVDEC, 16 = RKVENC) exercise
two seconds before the oops. It frees only kmalloc-256/512/8k objects. Nothing
in the 513–1024 band.

### The RGA aligned-table candidate is excluded

`rga_dma_alloc_aligned_sgt()` (`rga3/rga_dma_buf.c:159-213`) is the only code in
the whole 76-patch series that computes a `struct page *` from an address and
stores it into a scatterlist — `sg_set_page(dst, phys_to_page(start), len, 0)`
at `:199` — and `sg_alloc_table(aligned_sgt, 24)` produces a byte-identical
768 B → kmalloc-1024 allocation shape to the victim. It is nevertheless
excluded, verified by reading the whole caller
(`rga_dma_map_sgt_iommu()`, `rga_dma_buf.c:215-299`):

- the destination table is **private and freshly allocated** at `:174`, with
  exactly `sgt->orig_nents` entries, walked by `sg_next()` inside a
  `for_each_sg(..., sgt->orig_nents, i)` bound — it cannot run off its end;
- `aligned_sgt.sgl` **never escapes**: it is passed synchronously to
  `iommu_map_sg()` at `:263`, and `sg_free_table(&aligned_sgt)` runs at `:277`
  on the success path and at `err_free_aligned_sgt` on every failure path. The
  retained `buffer->sgt = sgt` is the *original* table, not the aligned copy.

### Three corrections to how the corrupt value was read

1. **`0xfffffe00` is not evidence of `-ERESTARTSYS`.** It is arithmetically
   forced. Every legitimate `page_link` here is
   `0xfffffdffc0000000 + 64 × pfn` with `pfn < 0x500000`, so the high word is
   always `0xfffffdff` and the low word confined to `[0xc0000000, 0xd4000000]`.
   Any `struct page *` for `pfn ∈ [0x1000000, 0x5000000)` — which is what all
   three corrupt values are — has high word exactly `0xfffffe00`. The
   two-32-bit-word reading (`{address, −512}`) recorded in the third-repro
   finding is an **artifact**, and the search for a `{u32 addr, s32 errno}`
   writeback record was accordingly fruitless. Confirming this independently:
   an exhaustive sweep found **no** site in `mpp/` or `rga3/` that stores
   `-ERESTARTSYS` into a struct field at all; all six interruptible-wait sites
   only `return ret`.

2. **The corruption window is pinned only if the damaged table is the
   encoder's.** `system_heap_dma_buf_end_cpu_access()`
   (`system_heap.c:163-182`) iterates `buffer->attachments` and syncs
   `&a->table` for **every mapped attachment**. All attachments of one buffer are
   `dup_sg_table()` copies with identical geometry, so `orig_nents = 24` and a
   1 MiB entry 1 do not identify *which* attachment faulted. The third-repro
   finding's statement that the window is pinned between the clean map-time sync
   and the fatal sync therefore carries an unstated precondition; it is corrected
   there.

3. **`sg_set_page`-shaped writers are not excluded in general.** The reasoning
   "offset and length survived, so the writer wrote only `page_link`" holds only
   when the writer's geometry differs from the victim's. A same-geometry copier
   writes byte-identical `offset` (0) and `length` (0x100000), leaving
   `page_link` as the only visible change. `dup_sg_table()`
   (`system_heap.c:55-71`) is exactly such a copier —
   `sg_set_page(new_sg, sg_page(sg), sg->length, sg->offset)` — so it, and any
   code copying a table of this buffer's shape, stays in scope.

### The sharpened fingerprint

Entry 1 is an order-8 (1 MiB) system-heap chunk, so its true pfn `P ≡ 0 (mod
256)` and its true `page_link ≡ 0 (mod 0x4000)`. All three corrupt values have
low 14 bits `0x3f00`. Stated in the cleanest form:

```text
V = pfn_to_page(A − 4),   A ≡ 0 (mod 256),   A ≈ 0x1de0300 (≈119.5 GiB phys)
```

The stored value is the vmemmap slot of a 1 MiB-aligned page **minus exactly
four `struct page`s (256 bytes)**, where the aligned base is itself far outside
RAM. Both 32-bit halves differ from the correct value, and the high half differs
by exactly `+1`. So the event was a single 8-byte store, a 64-bit add, or two
adjacent 32-bit stores — not a 4-byte device write, which would have left
`0xfffffdff` in place at `+0x24`. This is the shape of **CPU pointer
arithmetic** (`page − 4`, `pfn − 4`, or `pfn_to_page()` of an off-by-16 KiB
input), not of a hardware descriptor writeback.

### The device-DMA hypothesis has no instance in the vendor drivers

The profile floated after the third repro — "a driver kmallocs a ≤1 KiB buffer,
hands its address to hardware for writeback, and frees it before the device
writes" — was searched for exhaustively and **does not exist** in `mpp/` or
`rga3/`. Every device-writable region is either `dma_alloc_coherent` or
`alloc_pages` at a DT-fixed reserved IOVA, all probe-to-remove scoped, never in
a slab: rkvdec2 link table (16 KiB, `mpp_iommu.c:225` via
`mpp_rkvdec2_link.c:757`), rkvdec2/rkvenc2 RCB spill pages
(`mpp_rkvdec2.c:1911`, `mpp_rkvenc2.c:3352`), RGA cmd_buf/pool
(`rga_dma_buf.c:692`). Both `dma_map_single()` sites in the tree are
`DMA_TO_DEVICE` (RGA2 page tables, device-read). There is no
`DMA_FROM_DEVICE`/`DMA_BIDIRECTIONAL` streaming map anywhere in either driver,
and the encoder (client 16) allocates no device-visible memory of its own beyond
imported dma-bufs.

The rkvenc2 slice-FIFO terminal-record patch was checked specifically: records
are **4 bytes** (`union rkvenc2_slice_len_info`, `mpp_rkvenc2.c:220-227`), the
FIFO lives inside `struct rkvenc_task`, and it is filled by the CPU from MMIO
register `0x4038` in IRQ context (`rkvenc2_read_slice_len()`, `:1717`) — no DMA
address for it is ever programmed.

This does not retire the device-DMA theory globally, since KASAN's blindness to
device writes remains the cleanest explanation of "no repro and no report". It
relocates it: any such writer is outside the vendor codec drivers.

## Latent defects found (independent of this bug)

These are real and worth fixing regardless of whether any of them is the writer.

1. **Unbounded user-controlled kernel heap read-modify-write.**
   `mpp_translate_reg_offset_info()` (`mpp_common.c:2210-2228`):
   ```c
   reg[off_inf->elem[i].index] += off_inf->elem[i].offset;
   ```
   `elem[]` is filled verbatim from userspace (`mpp_extract_reg_offset_info()`,
   `mpp_common.c:2183`) and `struct reg_offset_elem { u32 index; u32 offset; }`
   (`mpp_common.h:215-218`). The existing hardening bounds `cnt` and rejects a
   non-element-multiple `req->size` — it does **not** bound `index`. No caller
   validates it. `reg + 4 × (u32)index` reaches up to 16 GiB past the register
   array, so any process with `/dev/mpp_service` access (the `video` group; the
   gdm greeter had it) can add a chosen 32-bit value at a chosen 4-byte-aligned
   offset anywhere in that range. Only caller is `rkvdec2_task_init()`
   (`mpp_rkvdec2.c:400`); rkvenc2 and av1dec use the read-only
   `mpp_query_reg_offset_info()`. Fix: clamp `index` against the caller's
   register-array length.
2. **`u32` wrap → size underflow → unbounded `copy_from_user`.**
   `rkvenc_get_class_reg()`/`req_over_class()` (`mpp_rkvenc2.c:852-869`, `:801`)
   compute `req_e = req_in->offset + req_in->size - sizeof(u32)` in `u32`; a
   wrapped `req_e` passes the class check and yields `req_out->size = e - s + 4`
   underflowed to ~4 GiB, consumed by `copy_from_user()` at `:974-984`. Fix:
   `check_add_overflow()` and reject `e < s`.
3. **`iova_cookie` union type-confusion.** `mpp_iommu_reserve_iova()` /
   `mpp_iommu_unreserve_iova()` (`mpp_iommu.c:1098-1105`, `:1126-1134`) test
   only `!domain->iova_cookie` and cast to `struct iova_domain *`. In 6.18 that
   member is a union discriminated by `domain->cookie_type`
   (`include/linux/iommu.h:224-238`), so a `msi_cookie`/`iommufd_hwpt` would be
   misread. RGA already does this correctly through the series' own new
   `iommu_dma_get_iova_domain()` accessor (`rga_dma_buf.c:97-100`). Latent
   today because a normal DMA domain really is `IOMMU_COOKIE_DMA_IOVA`.
   (The separate `mpp_iommu_dma_cookie` shadow-struct hack was checked and is
   **correct**: `iovad` is at offset 0 of the real `iommu_dma_cookie`, and the
   driver asserts it with `BUILD_BUG_ON`.)
4. **Stale `buffer->sgt` read-after-free window.** `mpp_dma_release_buffer()`
   (`mpp_iommu.c:132-138`) unmaps and detaches — freeing the attachment's sgl —
   and only then NULLs `buffer->sgt`, while `mpp_dma_buf_sync()`
   (`mpp_iommu.c:471-508`, called from `mpp_rkvenc2.c:1241`, `:1980`) walks that
   cached pointer without `dma->list_mutex` and without revalidation. Read-only,
   so it cannot produce this corruption, but it can fault.
5. **Unvalidated `pfn_to_page()` on a PFNMAP VMA.** `rga_mm.c:258` (and `:305`)
   take `follow_pfnmap_start()` output straight into `pfn_to_page()` with no
   `pfn_valid()` guard, feeding `sg_alloc_table_from_pages()` at `:414`. The
   sibling site at `:381` *was* hardened by the series
   (`virt_addr_valid(phys_to_virt(addr))`); this one was left. It is the only
   vendor code that can manufacture wild page pointers of the observed form,
   though only into RGA's own private table.

## Boundary

- **No attribution.** This is elimination plus corrections, not a root cause.
- The sweep covered the vendor codec/RGA drivers, the series' IOMMU delta, and
  `system_heap.c`. It did **not** cover the concurrently live module drivers —
  `panthor`, `rockchipdrm`, `hantro_vpu`, `rocket`, `dw_hdmi_qp` — all loaded
  during the failing second, nor generic `mm/`, nor the dma-buf core beyond the
  system heap. If the writer is a CPU path, it is now most likely in one of
  those.
- The "no device-writable slab memory" result is scoped to `mpp/` and `rga3/`.
- Defect 1's exploitability is argued from the code path, not demonstrated; no
  proof-of-concept was attempted.
- Whether the damaged table belongs to the encoder's attachment is still
  unestablished, and the number of attachments on the victim buffer has never
  been measured.

## Verification gate

The guard build must capture three things the register block cannot give, and
all three are already implemented in
[`system-heap-sg-guard`](../kernel-drivers/patches/system-heap-sg-guard/README.md):

1. **The prior value.** The guard's snapshot gives the *correct* `page_link` `T`,
   hence the delta `D = V − T`. That single number discriminates a 64-bit add
   from an 8-byte store and is the most informative missing datum.
2. **The owning device** (`dev_name(a->dev)`) and the attachment count — which
   settles correction 2 and tells us whether the encoder's own table was the
   damaged one.
3. **The checkpoint** (`attach` / `post-map` / `begin` / `end`) that first sees
   drift, which brackets the window without relying on inference.

Then the hardware watchpoint, whose prediction is now sharper: the caught store
must write a value equal to `pfn_to_page(A − 4)` for a 1 MiB-aligned `A` outside
RAM. A watchpoint stack in `rkvdec2_task_init` would implicate defect 1.

## Why it matters / follow-up

Two tracks that looked promising are closed: the vendor MPP driver is cleared as
the writer, and the device-DMA story has no mechanism inside the vendor drivers.
The `-ERESTARTSYS` reading that shaped part of the previous search is retired as
an arithmetic artifact. Effort should go to the guard build now in progress
rather than further reading of `mpp/`, and the five defects above should be
fixed on their own schedule — defect 1 in particular, which is an unprivileged
unbounded kernel write reachable from any process in the `video` group.
