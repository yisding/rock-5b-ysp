# CONFIG_DMABUF_DEBUG's mangle_sg_table() is the system-heap page_link writer, and the dma-heap CPU-access sync dereferences it

> Scope: ROCK 5B kernel forward-port; the GRD/RKMPP system-heap scatterlist oops
> tracked since
> [`2026-07-27-grd-rkmpp-system-heap-sg-corruption-oops.md`](2026-07-27-grd-rkmpp-system-heap-sg-corruption-oops.md).
> Closes the "unattributed writer" boundary carried by that finding and its three
> successors.
>
> Source: booted `6.18.40-video-port-rockchip64` (local guarded build, gcc 13.3.0)
> versus the recorded production journal of `6.18.40-ysp-rockchip64`; kernel
> source `~/Code/tmp/fwport-sgguard` — `drivers/dma-buf/dma-buf.c`
> `mangle_sg_table()` (~:831), its call sites in `dma_buf_map_attachment()`
> (~:1142) and `dma_buf_unmap_attachment()` (~:1224);
> `drivers/dma-buf/heaps/system_heap.c` `system_heap_map_dma_buf()` (~:327) and
> `system_heap_dma_buf_end_cpu_access()` (~:391);
> `drivers/iommu/dma-iommu.c` `iommu_dma_sync_sg_for_device()` (~:1148);
> the four installed `/boot/config-*` files.
>
> Date: 2026-07-28
>
> Trust: **MEASURED** (boot outcomes, journal fault addresses, config inventory) /
> **SOURCE-INSPECTED** / **CONFIG-INSPECTED** / **ROOT-CAUSED** /
> **CONFIRMED** (arithmetic inversion, 8/8) — the *fix* is
> **DESIGN** only, not yet built or booted.

> **Extended and partly corrected 2026-07-28 by**
> [`2026-07-28-dmabuf-debug-upstream-provenance-and-fix-options.md`](2026-07-28-dmabuf-debug-upstream-provenance-and-fix-options.md).
> Three changes. (1) **Provenance is now proven, not assumed:** `dma-buf.c` and
> `system_heap.c` are byte-identical to the vanilla `Linux 6.18.40` tag, and
> neither our series nor Armbian's touches `drivers/dma-buf` — so no part of
> this is ours, Rockchip's, or Armbian's. (2) The Boundary below says the fix
> options are "not implemented or discussed with upstream"; the second clause is
> **wrong**. Yunfei Wang reported this on **2022-08-31** with the mirror-image
> call chain (`begin_cpu_access` / `for_cpu`), and Christian König replied that
> the dma-heap is at fault rather than the debug option. It has been known and
> unfixed for nearly four years. (3) The four fix options in *The upstream bug
> worth reporting* are optimistic. Option 1 is blocked harder than stated —
> `struct dma_buf_attachment` has no `sgt` field at all, so the core keeps no
> reference to the tables it mangles — and option 2 silently skips the swiotlb
> bounce sync. See the successor for the verified blockers and the design
> argument that keeps this unfixed.

## Result

There was never any memory corruption. The "corrupt" `page_link` is written
deliberately, by the kernel, as designed, by a debug feature that the production
config has enabled and no other kernel on this board does.

`CONFIG_DMABUF_DEBUG` makes the dma-buf core scramble the exporter's
`page_link` for exactly the interval an attachment is mapped:

```c
/* drivers/dma-buf/dma-buf.c ~:831 */
static void mangle_sg_table(struct sg_table *sg_table)
{
#ifdef CONFIG_DMABUF_DEBUG
	int i;
	struct scatterlist *sg;

	/* To catch abuse of the underlying struct page by importers mix
	 * up the bits, but take care to preserve the low SG_ bits to
	 * not corrupt the sgt. The mixing is undone on unmap
	 * before passing the sgt back to the exporter.
	 */
	for_each_sgtable_sg(sg_table, sg, i)
		sg->page_link ^= ~0xffUL;
#endif
}
```

The system heap hands out its *own* per-attachment table and then keeps using
it, so the core mangles the very object the heap will later walk:

```c
/* system_heap.c ~:327 — the exporter's map callback */
struct sg_table *table = &a->table;
ret = dma_map_sgtable(attachment->dev, table, direction, 0);  /* syncs; page_link pristine */
a->mapped = true;
return table;                       /* ...returns &a->table to the core */

/* dma-buf.c ~:1142 — dma_buf_map_attachment(), immediately after the callback */
mangle_sg_table(sg_table);          /* ...which scrambles &a->table in place */
```

```c
/* system_heap.c ~:391 — reached straight from DMA_BUF_IOCTL_SYNC, no unmangle */
list_for_each_entry(a, &buffer->attachments, list) {
        if (!a->mapped)                                   /* selects the mangled ones */
                continue;
        dma_sync_sgtable_for_device(a->dev, &a->table, direction);
}
```

```c
/* dma-iommu.c ~:1159 — RKVENC2 is non-coherent behind an IOMMU */
else if (!dev_is_dma_coherent(dev))
        for_each_sg(sgl, sg, nelems, i)
                arch_sync_dma_for_device(sg_phys(sg), sg->length, dir);
```

`sg_phys()` is `page_to_phys(sg_page(sg)) + sg->offset`, so it dereferences
`page_link`. The heap syncs precisely the tables the core has scrambled, the
resulting physical address is nonsense, and `__phys_to_virt()` of it faults in
`dcache_clean_poc()` — the recorded stack, frame for frame.

The mangle is *not* undone for CPU access. It is undone only in
`dma_buf_unmap_attachment()` (~:1224), before the exporter's `unmap_dma_buf`
callback. Every checkpoint reached *through* an exporter callback therefore sees
a pristine table; only `begin_cpu_access` and `end_cpu_access`, which
`dma_buf_ioctl()` invokes directly while attachments are mapped, see the mangled
one.

## Why the measured window matches exactly

The prior findings established the window empirically: the table was valid
through the map-time noncoherent sync, and invalid at the later
`end_cpu_access` sync, with no kernel-side MPP activity in between. That window
has a single instruction in it. The map-time sync happens *inside*
`dma_map_sgtable()` at `system_heap.c:334`; the mangle happens at
`dma-buf.c:1142`, after `system_heap_map_dma_buf()` has returned. The left edge
the investigation kept proving was the exporter's own sync, and the writer is
the first thing the core does after it.

This also explains the third repro's most confusing measurement — that the
window contained *zero* kernel-side MPP activity. Correct: nothing in the MPP
driver was ever going to be in it.

## Evidence

### 1. Arithmetic inversion, 8/8

If the transform is `page_link ^= ~0xffUL`, then a fault address is a real page
frame pushed through that XOR. Inverting every recorded fault address over the
board's real PFN space (0 … `0x400000`, 16 GiB) recovers a valid in-RAM page for
**every one**:

| recorded fault vaddr | recovered real PFN | physical | |
|---|---|---|---|
| `0xffff001fc4aec000` | `0x003b510` | `0x00003b510000` | 0.927 GiB |
| `0xffff001e2320c000` | `0x01dcdf0` | `0x0001dcdf0000` | 7.451 GiB |
| `0xffff001e0c1fc000` † | `0x01f3e00` | `0x0001f3e00000` | 7.811 GiB |
| `0xffff001de02fc000` | `0x021fd00` | `0x00021fd00000` | 8.497 GiB |
| `0xffff001d9071c000` | `0x026f8e0` | `0x00026f8e0000` | 9.743 GiB |
| `0xffff001d6b1fc000` | `0x0294e00` | `0x000294e00000` | 10.326 GiB |
| `0xffff001d6b0cc000` | `0x0294f30` | `0x000294f30000` | 10.327 GiB |
| `0xffff001d6807c000` | `0x0297f80` | `0x000297f80000` | 10.375 GiB |

† the original finding's oops; the other seven are the boot -1 cluster.

Eight independent values cannot all invert into valid RAM by chance. The
forward direction is equally tight: mangling *any* real RAM page yields a fault
address in `0xffff001c00003000` … `0xffff001fffffff00`, and all eight observed
faults fall inside that window.

This also retires the "well-formed `struct page` pointer" puzzle that motivated
the whole guard exercise. The value looked well-formed because it *is* a real
page pointer — bit-flipped in its high 56 bits and left otherwise intact, which
is exactly what `^ ~0xffUL` does and exactly what the comment says it does.

### 2. Config correlation, 4/4

`mangle_sg_table()` is compiled out unless `CONFIG_DMABUF_DEBUG` is set. Across
every 6.18.40 kernel installed on this board:

| kernel | `DMABUF_DEBUG` | `DMA_API_DEBUG` | KASAN | oopses on RDP login? |
|---|---|---|---|---|
| `6.18.40-ysp-rockchip64` (production) | **y** | y | n | **yes — 3/3 boots, 7× in boot -1 alone** |
| `6.18.40-video-port-rockchip64` (guarded, local) | n | n | n | no — 2/2 logins clean |
| `6.18.40-video-port-kasan-rockchip-rk3588` | n | y | y | no — 0/9 logins, 0/1600 sessions |
| `6.18.40-video-rewrite-kasan-rockchip64` | n | y | y | no |

The one kernel with the option is the only kernel that reproduces. Note that
`DMA_API_DEBUG` — which the earlier config sweep *did* check and found equal —
is a different symbol and does not gate the mangle.

### 3. Boot outcomes measured this session

Booted `6.18.40-video-port-rockchip64` with the guard armed
(`sg_guard=Y`, `sg_guard_panic=N`), took two RDP logins from macOS at the
reproduction geometry. Both clean: zero `SGGUARD:` lines, zero oopses. The
encoder path ran — GRD logged `Created h264_rkmpp encode session for surface
with size 2056x1290 (encoder dimensions 2064x1296)` for both the greeter and the
post-handover user session. Production, by contrast, oopsed seven times across
boot -1.

## Fix

One line in the tracked production config,
`packaging/ppa/kernel-forward-port/debian/config/arm64-rockchip64.config:8203`:

```diff
-CONFIG_DMABUF_DEBUG=y
+# CONFIG_DMABUF_DEBUG is not set
```

`CONFIG_DMABUF_DEBUG` is a developer option for catching importers that
dereference `sg_page()` on a mapped table. It has no place in a production
kernel, and it almost certainly rode in alongside `CONFIG_DMA_API_DEBUG` when
`dma_debug_entries=2097152` was added to the kernel command line. Disabling it
removes the writer outright.

`CONFIG_DMA_API_DEBUG=y` can stay: it does not gate the mangle, and nothing in
this failure is attributable to it.

### The upstream bug worth reporting

The config change fixes *this board*. The underlying defect is upstream and
general: **any dma-heap exporter that implements `begin_cpu_access` /
`end_cpu_access` by syncing its mapped attachments' tables is an unconditional
oops under `CONFIG_DMABUF_DEBUG` on a non-coherent device.** The core mangles
the exporter's own table and unmangles it only around the unmap callback, so the
CPU-access hooks — which are not exporter-callback-bracketed — always observe
scrambled `page_link`s.

`system_heap.c` and `cma_heap.c` both have this shape. Candidate fixes, in
rough order of how well they respect the feature's intent:

1. **Unmangle around the CPU-access hooks**, symmetric with the unmap path —
   `dma_buf_begin_cpu_access()` / `dma_buf_end_cpu_access()` bracket the
   `->begin_cpu_access` / `->end_cpu_access` calls with `mangle_sg_table()` over
   every mapped attachment. Correct but invasive: the core does not currently
   walk attachments there, and would need the resv lock.
2. **Have the heaps sync from `buffer->sg_table`** (the pristine origin) rather
   than the per-attachment duplicates. Cheap, but changes which device's sync
   semantics apply, so it is not obviously equivalent.
3. **Mangle only for dynamic importers**, or exclude tables the exporter retains
   a reference to. Narrow, and arguably what the "abuse by importers" comment
   intended in the first place — the heap is the *exporter* here, not an
   importer, and the feature is scrambling a structure its owner still uses.
4. **Make `CONFIG_DMABUF_DEBUG` depend on `!DMABUF_HEAPS`**, or document the
   incompatibility. The blunt option, but honest about the current state.

## Boundary

- **The fix is not yet built or booted.** Everything above is source, config,
  and arithmetic. The decisive confirmation is a production rebuild with
  `CONFIG_DMABUF_DEBUG` off, verified to survive an RDP login; until that runs,
  the fix carries **DESIGN** only.
- The clean logins were on a **gcc 13.3.0 local build**, so they do not by
  themselves separate "no `DMABUF_DEBUG`" from "different compiler". The
  arithmetic inversion and the 4/4 config correlation are what carry the
  attribution; the boot outcomes corroborate rather than establish it.
- No claim is made that `CONFIG_DMABUF_DEBUG` is the *only* thing wrong. The
  five vendor-driver latent defects in
  the vendor-driver latent-defect catalogue (private `rock-5b-security`
  repository)
  remain real and remain unfixed; none of them is this oops.
- The upstream fix options are sketched, not implemented. No patch has been
  written or submitted. **Corrected:** they *have* been discussed upstream —
  reported 2022-08-31, still unfixed, blocked on a design argument. See
  [`2026-07-28-dmabuf-debug-upstream-provenance-and-fix-options.md`](2026-07-28-dmabuf-debug-upstream-provenance-and-fix-options.md).
- Whether other dma-heap consumers on this board (CMA heap, DRM importers) hit
  the same path was not surveyed.

## Verification gate

Rebuild the production source package with `CONFIG_DMABUF_DEBUG` disabled,
install it, and take one RDP login at `2064x1296` on a fresh boot. Production
oopses 3/3 boots and repeated seven times within a single boot, so a single
clean login on the rebuilt kernel — with `Created h264_rkmpp encode session`
present in the GRD journal to prove the encoder path ran — closes this.

Keep one production kernel with the option still enabled installed and bootable
until that passes, so the comparison can be re-run.

## Why it matters

This closes an investigation that ran through four findings on a false premise.
It also explains, in one stroke, three separate results that had each been given
their own speculative explanation:

- **the KASAN non-reproduction** — the KASAN kernels have
  `CONFIG_DMABUF_DEBUG=n`. Not KASAN's layout changes, not its quarantine, and
  not the toolchain. See the correction on
  [`2026-07-27-kasan-vs-production-build-provenance-confound.md`](2026-07-27-kasan-vs-production-build-provenance-confound.md).
- **the vendor-driver sweep coming back empty** — correctly. The writer is in
  `drivers/dma-buf/`, which that sweep did not cover.
- **the measured ioctl window containing no MPP activity** — correctly. The
  writer is the core's first action after the exporter's map callback returns.

The `linux-rockchip64-ysp-sgguard` PPA package built for this hunt is now
unnecessary and should not be uploaded; see
[`kernel-sgguard/README.md`](../packaging/ppa/kernel-sgguard/README.md).
