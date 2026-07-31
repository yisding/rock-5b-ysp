# RGA multi-segment memory contract: the BSP relies on 5.10/6.1 IOMMU coalescing; newer drivers validate or remap

> Scope: [`kernel-drivers`](../kernel-drivers/README.md), specifically RGA2/RGA3
> USERPTR and DMA-BUF mapping in the Rockchip 5.10/6.1 BSP, the RK3588 6.18
> forward port, and both compatibility-rewrite trees.
> Source: `rockchip-kernel` `origin/develop-5.10@bfa51d2ab081` and
> `develop-6.1@b4ef083dc0c3`; forward port
> `rk3588-video-6.18@c10074f4474e`; rewrite
> `rk3588-rewrite-6.18@a12e4116c758` and
> `rk3588-rewrite-mainline@8ffc6ac4a8da`. Primary anchors are
> `rga_dma_map_sgt()`, `rga_dma_map_buf()`, `rga_mm_sgt_to_page_table()`,
> `iommu_dma_map_sg()`, `rk_iommu_probe_device()`,
> `rga_dma_set_buffer_mapping()`, `rk_rga_check_dma_sgt()`,
> `rk_rga_map_userptr_sgt()`, and `rk_rga_job_map_import()`.
> Date: 2026-07-31
> Trust: **CODE-INSPECTED** / **SOURCE-CONFIRMED** / **ROOT-CAUSED** for the
> cross-version mapping contract; existing board evidence is linked rather
> than reclassified here.

## Result

RGA3 never consumes a scatterlist. Its command stream contains one base address
per image plane, so the bytes behind that base must form one linear,
device-visible span. Physical scatter is harmless only when the DMA/IOMMU layer
presents it as a contiguous IOVA. RGA2 is different: the vendor driver can
build an internal RGA-MMU page table containing one address per page.

The BSP's RGA3 code is not generally correct according to the DMA API: it keeps
only the first mapped SG address, sums all mapped lengths, and never proves that
the mapped entries are adjacent. It is nevertheless safe for the intended
pinned-userptr path on the studied Rockchip 5.10/6.1 stack because of a private,
cross-layer implementation contract:

1. generic `iommu_dma_map_sg()` allocates one IOVA range for the entire SG list
   and maps every physical run consecutively into it;
2. Rockchip commit `3fc0486fdf76` sets each IOMMU client's maximum DMA segment
   size to `DMA_BIT_MASK(32)`, specifically to obtain a single-chunk map; and
3. the per-entry SWIOTLB path cannot intercept a platform RGA mapping in those
   versions: 5.10 has no such SG branch, while 6.1 restricts it to untrusted PCI
   devices.

That contract stopped being reliable after 6.1. Upstream commit
`861370f49ce48` (`iommu/dma: force bouncing if the size is not
cacheline-aligned`, 2023-06-19) added `dev_use_sg_swiotlb()` for non-coherent
devices. When selected, `iommu_dma_map_sg_swiotlb()` maps each SG entry through
an independent IOVA allocation rather than the whole-list allocation. The
result can contain real gaps or descending IOVAs, and the Rockchip 4 GiB
`max_seg_size` setting cannot coalesce it. This is the version-dependent hole
that the 6.18 forward-port validation and driver-owned userptr-IOMMU fallback
close.

DMA-BUF adds a separate ownership rule. A physically discontinuous allocation
is valid; the exporter creates a device-specific attachment mapping. RGA3 may
use it when that mapping is one byte-contiguous IOVA span. The forward port and
rewrite deliberately do not replace a discontinuous exporter-owned attachment
with the userptr fallback: they reject it. The BSP retains its unchecked
first-address-plus-total-length assumption.

## Do not conflate the two SG counts

| Field | Meaning | RGA consequence |
|---|---|---|
| `orig_nents` | Physical runs in the original SG table. | May be greater than one without being a problem. |
| `nents` after `dma_map_sg*()` | DMA segments presented to this attachment/device. | For RGA3, one segment is the current safe admission rule. |
| Multiple adjacent DMA entries | More than one reported entry, but `next_addr == prev_addr + prev_len`. | Byte-contiguous in principle; current forward/rewrite RGA3 checks reject it conservatively. |
| Gapped or descending DMA entries | The next address does not follow the previous segment. | Cannot be consumed by RGA3's base-address command ABI. |

A typical successful IOMMU mapping is therefore:

```text
userspace or DMA-BUF backing
  -> physical SG: orig_nents = N
  -> one whole-list IOVA allocation
  -> DMA SG: nents = 1
  -> RGA3 programs the one IOVA base
```

`orig_nents > 1` does not imply that the hardware sees scatter. Conversely,
`nents > 1` is not by itself proof of a gap; proving adjacency requires walking
the mapped entries.

## Why the BSP RGA3 assumption holds on 5.10/6.1

### Generic IOMMU-DMA supplies the contiguous address space

Both inspected BSP generations route RGA3 through a translated Rockchip IOMMU
DMA domain. Their normal `iommu_dma_map_sg()` path:

1. aligns every input SG entry to the IOMMU granule;
2. computes the total `iova_len`;
3. calls `iommu_dma_alloc_iova()` once for that total;
4. calls `iommu_map_sg_atomic(domain, iova, ...)`; and
5. finalizes the caller-visible DMA SG entries starting from that one base.

The generic `__iommu_map_sg()` core passes each physical run to the provider at
`iova + mapped`, so Rockchip's provider fills consecutive IOVA page-table
slots. The provider is not secretly allocating one IOVA per physical segment;
the generic DMA layer owns the single allocation and the provider materializes
it.

The BSP's Rockchip domain also advertises a forced 32-bit aperture. That bounds
the domain itself, although it is not a substitute for the later forward-port
guard against RGA plane/stride arithmetic wrapping near the top of the
aperture.

### Rockchip makes the returned DMA segment large enough

Rockchip commit `3fc0486fdf762698abd24b8ce4f596b8b87b7707` adds this to
`rk_iommu_probe_device()`:

```c
/* set max segment size for dev, needed for single chunk map */
if (!dev->dma_parms)
	dev->dma_parms = kzalloc(sizeof(*dev->dma_parms), GFP_KERNEL);
...
dma_set_max_seg_size(dev, DMA_BIT_MASK(32));
```

The commit message says the default 64 KiB maximum split larger mappings and
sets the limit to 4 GiB to preserve one chunk. In the whole-list IOMMU path,
`__finalise_sg()` can therefore concatenate ordinary page-aligned userptr runs
into one reported DMA segment for any RGA-sized buffer.

This is the custom Rockchip half of the contract. The generic 5.10/6.1 IOMMU-DMA
algorithm supplies the contiguous allocation; Rockchip's client parameter lets
that allocation be reported as one large segment.

### The old SWIOTLB exception does not apply to RGA

Rockchip 5.10's `iommu_dma_map_sg()` has no whole-list bypass for unaligned
non-coherent platform mappings. Rockchip 6.1 has
`iommu_dma_map_sg_swiotlb()`, but its `dev_use_swiotlb()` predicate is:

```c
return IS_ENABLED(CONFIG_SWIOTLB) && dev_is_untrusted(dev);
```

`dev_is_untrusted()` requires an untrusted PCI device. RK3588 RGA is a platform
device, so its userptr mapping stays on the single-allocation path even when
the SG table contains an unaligned first or last fragment.

Thus the BSP behavior is best classified as **conditionally safe by an
intentional, pinned-stack contract**, not as a portable use of the DMA API. A
backport that changes IOMMU-DMA bounce selection can invalidate it without any
RGA source change.

## What changed after 6.1

Commit `861370f49ce484cd6ef2e9b3ad06d137f3cb0ca3` broadened IOMMU-DMA bounce
selection for non-coherent devices. The newer predicate scans an SG list when
`dma_kmalloc_safe()` is false and selects the SWIOTLB path if an entry length is
not suitably aligned. The selected mapping path then performs roughly:

```text
SG entry 0 -> iommu_dma_map_phys() -> independent IOVA allocation A
SG entry 1 -> iommu_dma_map_phys() -> independent IOVA allocation B
SG entry 2 -> iommu_dma_map_phys() -> independent IOVA allocation C
```

This behavior is correct according to the DMA API: the caller receives a
mapped scatterlist and must consume all returned entries. It is incompatible
with the BSP RGA3 shortcut, which consumes only entry zero as a linear base.

The forward-port investigation measured mappings with real gaps and, in some
cases, a final segment below the first. Those observations prove that the
whole-list coalescer was bypassed, so the fail-closed check and fallback are
required. They do not by themselves identify the exact bounce predicate that
fired for each import; that attribution remains bounded in the maintained
[RGA userptr/IOMMU investigation](../kernel-drivers/rga/docs/userptr-iommu.md#3-why-scattered-userptr-imports-get-non-contiguous-iovas).

## USERPTR behavior by driver

### BSP

`rga_mm_map_virt_addr()` pins pages and uses `sg_alloc_table_from_pages()`.
For RGA3, `rga_dma_map_sgt()` calls `dma_map_sg()`, records
`sg_dma_address(sgt->sgl)`, and sums every mapped length without checking
`sgt->nents` or adjacency. It is safe only while the pinned BSP DMA contract
above holds.

For RGA2, physical scatter is represented explicitly. Non-contiguous imports
enable the internal RGA MMU, and `rga_mm_sgt_to_page_table()` walks the original
SG entries to emit one 32-bit page address per page. Pages above the RGA2
address range are rejected; the BSP does not consume a transient SWIOTLB
mapping for them.

### Forward port

The forward port splits the contracts deliberately:

- RGA3 first tries the DMA API and accepts exactly one nonzero, non-wrapping,
  32-bit-safe mapped segment.
- If a **driver-owned** userptr SG table maps as multiple segments or outside
  that contract, it unmaps the DMA result, clears stale DMA/SWIOTLB state,
  allocates one IOVA from the existing translated DMA domain, and maps a
  page-aligned SG copy into it with `iommu_map_sg()`.
- Teardown records which API owns the mapping, while cache maintenance and
  page lifetime remain attached to the original pinned-page SG table.
- RGA2 uses page-granular DMA mappings and internal page tables. The current
  forward port can create a transient per-job RGA2 mapping and use SWIOTLB DMA
  addresses to serve some above-4-GiB userptr pages, with bidirectional
  copyback for writable buffers. The maintained implementation detail is in
  [patch 0050](../kernel-drivers/patches/forward-port-rk3588/rk3588-fwport-0050-video-rockchip-rga3-serve-over-4G-memory-on-RGA2-via.patch).

### Rewrite

The rewrite pins user pages into an import object and creates a mapping-local
SG table plus cache-line boundary shadows. `rk_rga_map_userptr_sgt()` first
tries `dma_map_sgtable()`. If `rk_rga_check_dma_sgt()` does not see one
sufficient, 32-bit-safe segment, it abandons that DMA mapping and uses the same
driver-owned contiguous-IOMMU strategy as the forward port.

The rewrite applies this at both lifetimes:

- the persistent import mapping, on a preferred RGA3 device; and
- a per-job mapping when the selected hardware uses another DMA device.

On RK3588, the rewrite's RGA2 node has no external system-IOMMU domain, and the
rewrite does not implement the BSP internal RGA-MMU page-table path. A genuinely
multi-segment userptr remap to rewrite RGA2 therefore cannot use the contiguous
IOMMU fallback and fails unless the ordinary DMA mapping happens to produce one
segment. The two rewrite source files inspected for this finding are
byte-identical at their named 6.18 and mainline pins.

## DMA-BUF behavior by driver

A DMA-BUF is a logical sharing and synchronization object, not a physical-
contiguity promise. The exporter owns the backing allocation and supplies a
device-specific attachment SG table through `dma_buf_map_attachment*()`.

For the in-tree system heap, each attachment gets a duplicate of the exporter's
physical SG geometry and `system_heap_map_dma_buf()` calls
`dma_map_sgtable(attachment->dev, ...)`. The allocation's SG offsets are zero
and its lengths are whole pages or higher-order page multiples. On an RGA3
IOMMU device this normally stays on the whole-list coalescing path, including
on 6.18; unlike a sub-page-offset userptr, physical fragmentation alone does
not satisfy the newer unaligned-element bounce predicate. A CMA-heap DMA-BUF
normally starts physically contiguous as well.

That common behavior is not a DMA-BUF guarantee. An exporter may return
multiple mapped entries because of its own staging, bus-address, boundary,
bounce, or device constraints. The importing RGA driver must validate the
attachment it actually receives.

### BSP DMA-BUF

`rga_dma_map_buf()` / `rga_dma_map_fd()` attach and map the DMA-BUF, record the
first DMA address, and sum all returned DMA lengths. As with userptr, they do
not check mapped adjacency. A system-heap DMA-BUF mapped through the pinned BSP
RGA3 IOMMU stack normally satisfies the hidden contract, but an arbitrary
exporter returning true gaps would be misprogrammed.

BSP RGA2 can build its internal page table from physically scattered DMA-BUF
pages when they fit the 32-bit page entries. It does not have the forward
port's above-4-GiB transient DMA/SWIOTLB service path.

### Forward-port DMA-BUF

The forward port validates exporter-owned attachments but never sends them
through the userptr fallback:

- RGA3 requires `nents == 1` plus a safe 32-bit span;
- RGA2's page-granular path accepts multiple individually addressable DMA
  segments and can use a transient per-job mapping where required; and
- a failed RGA3 attachment validation is unmapped, detached, and returned to
  userspace as an error.

This means the current RGA3 check also rejects a mapped SG table containing
several entries that are provably adjacent. Such a table is hardware-usable in
principle, but accepting it requires an explicit byte-adjacency and overflow
walk rather than the BSP assumption.

The userptr fallback is intentionally not reused for DMA-BUF. The exporter owns
attachment lifetime, cache synchronization, possible bounce/staging memory,
and backing-store movement rules. Directly remapping `sg_page()` behind an
active exporter attachment would cross that ownership boundary. Any future
DMA-BUF contiguous-IOVA design needs a separate exporter/DMA/IOMMU ownership
audit; the maintained constraint is recorded in
[the fallback architecture](../kernel-drivers/patches/rga-userptr-iommu/architecture.md#invariants).

### Rewrite DMA-BUF

The rewrite checks the same single-span rule twice:

1. `rk_rga_import_dmabuf_object()` creates a persistent, read-only attachment
   on a preferred RGA3 device and requires one mapped segment covering the
   entire DMA-BUF; and
2. `rk_rga_job_map_import()` creates a role-specific attachment on the selected
   core (`DMA_TO_DEVICE` for source-only, `DMA_BIDIRECTIONAL` for destination)
   and repeats the one-segment check.

There is no rewrite DMA-BUF Route B. A physically scattered buffer works when
each required attachment coalesces into one IOVA; a genuinely multi-segment
attachment is rejected. Because the rewrite also lacks the vendor RGA2 page-
table path, a buffer that imports through RGA3 may still fail if a later job
remaps it to the non-IOMMU RGA2 device and that mapping exposes physical
scatter.

## Compact comparison

| Memory and mapping result | BSP | Forward port | Rewrite |
|---|---|---|---|
| USERPTR: physical scatter, RGA3 DMA map is one span | Accepted through the pinned DMA contract. | Accepted as normal DMA route. | Accepted at import/per-job mapping. |
| USERPTR: RGA3 DMA map has true gaps | Unsafely treated as linear. | Driver-owned contiguous-IOMMU fallback or clean failure. | Driver-owned contiguous-IOMMU fallback or clean failure. |
| USERPTR: RGA2 physical scatter | Internal page table, below 4 GiB. | Internal page table; transient DMA/SWIOTLB service for some above-4-GiB mappings. | No internal page-table implementation; requires one DMA segment or fails. |
| DMA-BUF: physical scatter, attachment is one IOVA | Accepted. | Accepted. | Accepted on each required device mapping. |
| DMA-BUF: several adjacent mapped entries | Used as if linear, without proof. | Rejected conservatively on RGA3. | Rejected conservatively. |
| DMA-BUF: gapped/descending RGA3 attachment | Unsafely treated as linear. | Rejected; no userptr fallback. | Rejected; no userptr fallback. |
| DMA-BUF: RGA2 physical scatter | Internal page table within address limit. | Page-granular mapping/page table, including bounded transient bounce support. | No internal page-table implementation; multi-segment remap fails. |

## Evidence and inspection

The source comparison used these identities and checks:

```text
rockchip-kernel origin/develop-5.10  bfa51d2ab08140d1309afc9a9fe0fc2878cee35a
rockchip-kernel develop-6.1         b4ef083dc0c3608e744deabb43dc6b781aadbe6e
forward rk3588-video-6.18           c10074f4474e088341ba7adbac9b93705c124439
rewrite rk3588-rewrite-6.18         a12e4116c758e47565256c587f888f66f3b235ad
rewrite rk3588-rewrite-mainline     8ffc6ac4a8da84d02496b0a736335b5dad21e24d
```

Inspection included:

```sh
git show origin/develop-5.10:drivers/iommu/dma-iommu.c
git show origin/develop-5.10:drivers/iommu/rockchip-iommu.c
git show -s --format=fuller 3fc0486fdf762
git show -s --format=fuller 861370f49ce484
rg -n 'iommu_dma_map_sg|dev_use_sg_swiotlb|dma_set_max_seg_size' \
  drivers/iommu drivers/video/rockchip/rga3
sha256sum \
  ../linux-6.18-rkvenc/drivers/video/rockchip/rga-rewrite/rga_rewrite.c \
  ../linux/drivers/video/rockchip/rga-rewrite/rga_rewrite.c
```

The rewrite files had the same SHA-256,
`48b695f1755381a63da1086e58b94c03d81cc6e0ff833d45eef5f577d99400b7`.
No new kernel was built or booted for this finding.

## Boundary

- This finding proves the source mechanism and the version boundary. It does
  not add new hardware measurements.
- The post-6.1 `dev_use_sg_swiotlb()` change makes the per-entry route available
  to non-coherent RGA mappings, but the existing forward-port artifacts did not
  log the exact branch predicate for each failing userptr. That direct
  attribution remains pending.
- Physical scatter does not guarantee a multi-entry DMA result, and a
  multi-entry result does not guarantee gaps. Preserve `orig_nents`, `nents`,
  every DMA address/length, selected core/device, direction, and adjacency in a
  discriminating runtime capture.
- No generic claim is made that system-heap DMA-BUFs always coalesce on RGA3.
  The in-tree allocation geometry makes the normal path likely; the exporter,
  selected core, DMA domain, and current kernel still decide the attachment
  result.
- This finding does not choose a DMA-BUF multi-segment fix. An adjacency
  validator and a synthetic contiguous-IOVA remap have different ownership and
  cache/copyback consequences; the latter requires an exporter-aware design.
- The rewrite RGA2 limitation is source-confirmed but was not isolated with a
  selected-core hardware capture here.
