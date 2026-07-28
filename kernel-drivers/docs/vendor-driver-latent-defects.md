# Latent defects in the forward-ported vendor MPP/RGA drivers

Five defects found by source inspection on 2026-07-27 while hunting the writer
behind the GRD/RKMPP system-heap scatterlist corruption. **None of them is
confirmed to be that writer** — the hunt is still open — but each is a real
correctness or security problem in its own right, and they are recorded here so
they get fixed on their own schedule rather than living only inside an
investigation narrative.

> Source of every anchor below: the exact production kernel source at
> `packaging/ppa/out/work/linux-rockchip64-ysp-6.18.40+rk3588av1fwport20260725`,
> identical to the git worktree `~/Code/tmp/fwport-sgguard` (`v6.18..HEAD`).
> Every line number and code quotation was read directly, not inferred.
>
> Investigation context:
> [`findings/2026-07-27-grd-sg-writer-source-sweep-vendor-drivers-cleared.md`](../../findings/2026-07-27-grd-sg-writer-source-sweep-vendor-drivers-cleared.md).
> Trust: **SOURCE-INSPECTED**. No defect here has a runtime reproducer yet.

| # | Defect | Severity | Reachable by |
|---|---|---|---|
| [D01](#d01-unbounded-user-controlled-kernel-heap-read-modify-write) | Unbounded user-controlled kernel heap read-modify-write | **High (security)** | any process opening `/dev/mpp_service` |
| [D02](#d02-u32-wrap-size-underflow-unbounded-copyfromuser) | `u32` wrap → size underflow → unbounded `copy_from_user` | **High (security)** | same, via `MPP_CMD_SET_REG_WRITE` |
| [D03](#d03-iovacookie-union-type-confusion) | `iova_cookie` union type-confusion | Medium (latent) | not currently reachable |
| [D04](#d04-stale-buffer-sgt-read-after-free-window) | Stale `buffer->sgt` read-after-free window | Medium | encoder teardown race |
| [D05](#d05-pfntopage-on-a-pfnmap-vma-without-validation) | `pfn_to_page()` on a PFNMAP VMA without validation | Medium | RGA userptr import |

Fixes belong on the audit/cleanup series
([`patches/cleanup-split/`](../patches/cleanup-split/README.md)), not on the
forward-port series proper, which is meant to stay a faithful carry of the BSP
plus the fixes already catalogued in
[`patch-catalog.md`](patch-catalog.md). D01 and D02 are the two that justify
being pulled forward independently of the scatterlist investigation.

---

## D01 — Unbounded user-controlled kernel heap read-modify-write

**Where:** `drivers/video/rockchip/mpp/mpp_common.c:2210-2228`,
`mpp_translate_reg_offset_info()`.

```c
    if (off_inf) {
        int i;

        for (i = 0; i < off_inf->cnt; i++) {
            mpp_debug(DEBUG_IOMMU, "reg[%d] + offset %d\n",
                  off_inf->elem[i].index,
                  off_inf->elem[i].offset);
            reg[off_inf->elem[i].index] += off_inf->elem[i].offset;
        }
    }
```

**Mechanism.** Both halves of `elem[]` come straight from userspace. The
producer is `mpp_extract_reg_offset_info()` (`mpp_common.c:2160-2191`), which
`copy_from_user()`s into `off_inf->elem[]`, and the element type is

```c
struct reg_offset_elem {
    u32 index;
    u32 offset;
};                              /* mpp_common.h:215-218 */
```

The existing hardening on this function bounds the element **count**
(`(cnt + off_inf->cnt) > max_size` → `-EINVAL`) and rejects a `req->size` that
is not a whole number of elements — that check was added after a previous bug
where a non-multiple size copied up to seven bytes past the array. Neither check
constrains `index`. Nothing downstream constrains it either:
`mpp_query_reg_offset_info()` only compares `index` for equality, and the sole
caller passes a raw array pointer.

So `reg[index] += offset` writes at `reg + 4 × (u32)index`, i.e. anywhere in a
16 GiB window above the register array, adding a fully chosen 32-bit value.
That is an arbitrary-add primitive: repeatable, aimable, and with the addend
under caller control it can synthesise an arbitrary target value in two passes.

**Blast radius.** The only caller is `rkvdec2_task_init()`
(`mpp_rkvdec2.c:400`), where the target is `task->reg[]`, declared
`u32 reg[RKVDEC_REG_NUM]` with `RKVDEC_REG_NUM 360` (`mpp_rkvdec2.h:123`, `:42`)
inside a `kzalloc`'d task. rkvenc2 and av1dec use the read-only
`mpp_query_reg_offset_info()` and are unaffected. Trigger requires only
`MPP_CMD_SET_REG_ADDR_OFFSET` on a decoder session — available to any process
that can open `/dev/mpp_service`, which on this board is the `video` group, and
which the gdm greeter had.

**Proposed fix.** Pass the destination length and validate. The `task` parameter
is currently unused, so the signature change costs nothing:

```c
 int mpp_translate_reg_offset_info(struct mpp_task *task,
-                  struct reg_offset_info *off_inf, u32 *reg)
+                  struct reg_offset_info *off_inf,
+                  u32 *reg, u32 reg_cnt)
 {
     ...
         for (i = 0; i < off_inf->cnt; i++) {
+            u32 index = off_inf->elem[i].index;
+
+            if (index >= reg_cnt) {
+                mpp_err("reg offset index %u >= %u\n",
+                    index, reg_cnt);
+                return -EINVAL;
+            }
             mpp_debug(DEBUG_IOMMU, "reg[%d] + offset %d\n", ...);
-            reg[off_inf->elem[i].index] += off_inf->elem[i].offset;
+            reg[index] += off_inf->elem[i].offset;
         }
```

and at the call site, `mpp_rkvdec2.c:400`:

```c
-        mpp_translate_reg_offset_info(mpp_task, &task->off_inf, task->reg);
+        ret = mpp_translate_reg_offset_info(mpp_task, &task->off_inf,
+                            task->reg,
+                            ARRAY_SIZE(task->reg));
+        if (ret)
+            goto fail;
```

Note the function already returns `int` and the current call site discards it —
so returning `-EINVAL` is only useful if the caller starts checking, which the
hunk above does. Rejecting the whole task is the right behaviour: a
back-of-array index is never a legitimate request, so there is no compatibility
argument for clamping-and-continuing.

**Verification.** A KUnit case or a userspace probe that submits
`MPP_CMD_SET_REG_ADDR_OFFSET` with `index = 0xFFFFFFFF` must get `-EINVAL` and
leave `/proc/sys/kernel/tainted` at 0. On the pre-fix kernel the same request
faults or silently corrupts, so run it only on a disposable boot.

**Relation to the SG oops.** A plausible-shaped candidate — an in-bounds-looking
write onto a foreign live object is exactly the class KASAN cannot report — but
the measured trace shows no `SET_REG_ADDR_OFFSET` and no decoder task in the
failing process, and reaching `sgl[1].page_link` three times across boots would
require the victim-to-`reg` distance to be constant across boots, which is
implausible. Kept on the list only because a *concurrent* decoder session in
another process was never excluded.

---

## D02 — `u32` wrap → size underflow → unbounded `copy_from_user`

**Where:** `drivers/video/rockchip/mpp/mpp_rkvenc2.c:802-816` (`req_over_class`),
`:855-869` (`rkvenc_update_req`), consumed at `:974-984`.

```c
    req_e = req->offset + req->size - sizeof(u32);          /* :813, u32 */
    ret = (req->offset <= base_e && req_e >= base_s) ? true : false;
```
```c
    req_e = req_in->offset + req_in->size - sizeof(u32);    /* :861, u32 */
    s = max(req_in->offset, base_s);
    e = min(req_e, base_e);

    req_out->offset = s;
    req_out->size = e - s + sizeof(u32);                    /* :867 */
    req_out->data = (u8 *)req_in->data + (s - req_in->offset);
```
```c
    data = rkvenc_get_class_reg(task, wreq->offset);
    if (!data) { ... }
    if (copy_from_user(data, wreq->data, wreq->size)) {     /* :982 */
```

**Mechanism.** `req->offset` and `req->size` are both user-controlled `u32`.
`offset + size - 4` is computed in `u32` and wraps. A wrapped `req_e` can still
satisfy `req_over_class()`, so the class loop proceeds. Inside
`rkvenc_update_req()` the same wrapped value becomes `e`, and when `e < s` the
expression `e - s + sizeof(u32)` underflows to a value near 4 GiB. That value is
handed directly to `copy_from_user()` as the length, with the destination being
`task->reg[class].data + (addr - base_s)` from `rkvenc_get_class_reg()`
(`mpp_rkvenc2.c:900-915`) — a `kzalloc`'d buffer of `base_e - base_s + 4` bytes
(`rkvenc_alloc_class_msg()`, `:832-850`). The copy therefore runs off the end of
a small heap object for as far as the user pages allow.

Neither `req_over_class()` nor `rkvenc_update_req()` validates that
`e >= s`, and there is no global cap on `req->size` on this path (the caps at
`mpp_common.c:1549` and `:1599` are on different sub-commands).

**Proposed fix.** Compute the end with overflow checking and reject an inverted
window in both places:

```c
 static bool req_over_class(struct mpp_request *req,
                struct rkvenc_task *task, int class)
 {
-    u32 base_s, base_e, req_e;
+    u32 base_s, base_e, req_e;
     ...
-    req_e = req->offset + req->size - sizeof(u32);
+    if (req->size < sizeof(u32))
+        return false;
+    if (check_add_overflow(req->offset, req->size - (u32)sizeof(u32),
+                   &req_e))
+        return false;
```
```c
 static int rkvenc_update_req(...)
 {
     ...
-    req_e = req_in->offset + req_in->size - sizeof(u32);
+    if (req_in->size < sizeof(u32))
+        return -EINVAL;
+    if (check_add_overflow(req_in->offset,
+                   req_in->size - (u32)sizeof(u32), &req_e))
+        return -EINVAL;
     s = max(req_in->offset, base_s);
     e = min(req_e, base_e);
+    if (e < s)
+        return -EINVAL;
     req_out->offset = s;
     req_out->size = e - s + sizeof(u32);
```

`rkvenc_update_req()` already returns `int` but its call site at
`mpp_rkvenc2.c:975` discards it; that call must start checking and `goto fail`.
The same pattern appears in the `MPP_CMD_SET_REG_READ` arm a few lines below and
needs the identical treatment.

Belt-and-braces worth adding at the same time: have the copy assert against the
allocation, `if (wreq->size > task->reg[j].size - (wreq->offset - base_s))
return -EINVAL;`, so a future arithmetic slip cannot reach `copy_from_user()`
at all.

**Verification.** Submit `MPP_CMD_SET_REG_WRITE` with
`offset = base_s + 0x40, size = 0xFFFFFFC0` and require `-EINVAL` with taint 0.

**Relation to the SG oops.** Ruled out as the writer: a ~4 GiB `copy_from_user`
smashes kilobytes, whereas the observed damage is a single 8-byte field with
`sgl[0]` and `sgl[1].offset`/`.length` intact — and a multi-kilobyte overrun
would trip a KASAN redzone, which never fired in 1600 sessions.

---

## D03 — `iova_cookie` union type-confusion

**Where:** `drivers/video/rockchip/mpp/mpp_iommu.c:1079-1114`
(`mpp_iommu_reserve_iova()`) and `:1118-1136` (`mpp_iommu_unreserve_iova()`).

```c
    domain = info->domain;
    if (!domain || !domain->iova_cookie)
        return -EINVAL;

    /* 6.18: iovad must be the first member of iommu_dma_cookie */
    BUILD_BUG_ON(offsetof(struct mpp_iommu_dma_cookie, iovad) != 0);
    cookie = (struct mpp_iommu_dma_cookie *)domain->iova_cookie;
    iovad = &cookie->iovad;
```

**Mechanism.** In 6.18 `iova_cookie` is one arm of a union in
`struct iommu_domain`, discriminated by `domain->cookie_type`
(`include/linux/iommu.h:171-177`, `:224-238`):

```c
enum iommu_domain_cookie_type {
    IOMMU_COOKIE_NONE,
    IOMMU_COOKIE_DMA_IOVA,
    IOMMU_COOKIE_DMA_MSI,
    IOMMU_COOKIE_FAULT_HANDLER,
    IOMMU_COOKIE_SVA,
    IOMMU_COOKIE_IOMMUFD,
};
```

A non-NULL test on `iova_cookie` no longer proves the member is an
`iommu_dma_cookie`. If the domain carried an MSI cookie, a fault handler, or an
iommufd hardware page table, this code would reinterpret it as an
`iova_domain` and then hand it to `reserve_iova()`/`free_iova()`, which walk and
mutate an rb-tree through those bytes.

The *shadow-struct* half of this code is correct and should not be
"fixed": `struct mpp_iommu_dma_cookie` mirrors only the leading `iovad` member,
the real `struct iommu_dma_cookie` (`drivers/iommu/dma-iommu.c:57-77`) does
begin with `struct iova_domain iovad`, and the driver asserts it with
`BUILD_BUG_ON`. The gap is purely the missing discriminator check.

The same series already contains the correct pattern, used by RGA: the new
accessor `iommu_dma_get_iova_domain()` (`drivers/iommu/dma-iommu.c:385-395`,
added by the forward-port) checks `cookie_type` before returning the domain, and
`rga_dma_iommu_iovad()` (`rga3/rga_dma_buf.c:96-99`) calls it. MPP was never
migrated to it.

**Proposed fix.** Delete the shadow struct and both casts; route MPP through the
same accessor RGA uses:

```c
-    BUILD_BUG_ON(offsetof(struct mpp_iommu_dma_cookie, iovad) != 0);
-    cookie = (struct mpp_iommu_dma_cookie *)domain->iova_cookie;
-    iovad = &cookie->iovad;
+    iovad = iommu_dma_get_iova_domain(domain);
+    if (!iovad)
+        return -EINVAL;
```

This removes an ABI-fragile assumption from the driver entirely and leaves one
place in the tree that knows the cookie layout. `struct mpp_iommu_dma_cookie`
(`mpp_iommu.h:27-30`) and both `BUILD_BUG_ON`s then go away.

**Verification.** Compile-only plus a boot: the reserve path runs at rkvdec2
probe (`rkvdec2_alloc_rcbbuf()`), so a clean boot with the RCB IOVA windows
still reserved (`/sys/kernel/debug/iommu` or an RCB allocation success message)
is sufficient.

**Relation to the SG oops.** Not the writer. Probe-time only, and a normal DMA
domain genuinely is `IOMMU_COOKIE_DMA_IOVA`, so the confusion is latent today.

---

## D04 — Stale `buffer->sgt` read-after-free window

**Where:** `drivers/video/rockchip/mpp/mpp_iommu.c:123-145`
(`mpp_dma_release_buffer()`) versus `:471-508` (`mpp_dma_buf_sync()`).

```c
    /* 6.18: locked variant now asserts dma_resv held; use _unlocked */
    dma_buf_unmap_attachment_unlocked(buffer->attach, buffer->sgt, buffer->dir);
    dma_buf_detach(buffer->dmabuf, buffer->attach);
    dma_buf_put(buffer->dmabuf);
    buffer->dma = NULL;
    buffer->dmabuf = NULL;
    buffer->attach = NULL;
    buffer->sgt = NULL;                     /* only cleared here, after the free */
```
```c
void mpp_dma_buf_sync(struct mpp_dma_buffer *buffer, u32 offset, u32 length,
              enum dma_data_direction dir, bool for_cpu)
{
    struct device *dev = buffer->dma->dev;
    struct sg_table *sgt = buffer->sgt;
    struct scatterlist *sg = sgt->sgl;      /* no NULL check, no lock */
```

**Mechanism.** `dma_buf_detach()` runs `system_heap_detach()`, which
`sg_free_table()`s the attachment's scatterlist and frees the attachment — so
between that call and the `buffer->sgt = NULL` three lines later, `buffer->sgt`
is a dangling pointer. `mpp_dma_buf_sync()` reads it with no `dma->list_mutex`
and no revalidation, and dereferences both `sgt->sgl` and `buffer->dma->dev`
unconditionally. Its callers are `rkvenc_run()` (`mpp_rkvenc2.c:1241`) and
`rkvenc_finish()` (`:1980`), which run from the task worker and the IRQ-completion
path respectively — genuinely concurrent with a session teardown that drops the
last kref.

The window also extends past the NULL store: a caller that already loaded
`buffer->sgt` into a register before the release is unaffected by the NULLing at
all.

**Proposed fix.** Two changes, both cheap:

1. Clear the pointers *before* the operations that free what they point at, so
   the dangling window closes:

```c
+    struct sg_table *sgt = buffer->sgt;
+    struct dma_buf_attachment *attach = buffer->attach;
+    struct dma_buf *dmabuf = buffer->dmabuf;
+
+    buffer->sgt = NULL;
+    buffer->attach = NULL;
+    buffer->dmabuf = NULL;
+
-    dma_buf_unmap_attachment_unlocked(buffer->attach, buffer->sgt, buffer->dir);
-    dma_buf_detach(buffer->dmabuf, buffer->attach);
-    dma_buf_put(buffer->dmabuf);
+    dma_buf_unmap_attachment_unlocked(attach, sgt, buffer->dir);
+    dma_buf_detach(dmabuf, attach);
+    dma_buf_put(dmabuf);
```

2. Make the reader defensive and correctly serialised:

```c
 void mpp_dma_buf_sync(...)
 {
-    struct device *dev = buffer->dma->dev;
-    struct sg_table *sgt = buffer->sgt;
-    struct scatterlist *sg = sgt->sgl;
+    struct sg_table *sgt;
+    struct device *dev;
+    struct scatterlist *sg;
+
+    if (!buffer || !buffer->dma)
+        return;
+    sgt = buffer->sgt;
+    if (!sgt || !sgt->sgl)
+        return;
+    dev = buffer->dma->dev;
+    sg = sgt->sgl;
```

The NULL checks alone do not close the race — they narrow it. The real fix is
that a buffer being synced must hold a reference for the duration; the ordering
change above is what makes the reference-drop safe, and the checks catch the
already-released case.

**Verification.** Reproduce by racing an encode session against an
`MPP_CMD_RESET_SESSION` (`mpp_common.c:1519-1538`, which destroys `session->dma`
wholesale) under lockdep + KASAN on the `video-port-kasan` slot; a use-after-free
report on `sg_free_table`'d memory is the pre-fix signal.

**Relation to the SG oops.** Not the writer — this path only *reads* the
scatterlist, so it can fault but cannot corrupt. Worth noting that it produces a
superficially similar oops (a bad walk of an sg table from an MPP path), so a
future report that looks like the GRD oops should be checked against this
mechanism before being merged into that investigation.

---

## D05 — `pfn_to_page()` on a PFNMAP VMA without validation

**Where:** `drivers/video/rockchip/rga3/rga_mm.c:250-260` (and the legacy
pre-6.12 branch below it).

```c
        args.vma = vma;
        args.address = (Memory + i) << PAGE_SHIFT;
        if (follow_pfnmap_start(&args)) {
            rga_err("page[%d] failed to get pfnmap\n", i);
            ret = RGA_OUT_OF_RESOURCES;
            break;
        }

        pages[i] = pfn_to_page(args.pfn);
        follow_pfnmap_end(&args);
```

**Mechanism.** `follow_pfnmap_start()` is reached precisely for `VM_PFNMAP` /
`VM_IO` VMAs — device MMIO, reserved and no-map ranges. A PFN from such a VMA
frequently has no `struct page` behind it, and `pfn_to_page()` on it yields a
pointer into a vmemmap hole. The resulting array is handed to
`rga_alloc_sgt()` → `sg_alloc_table_from_pages()` (`rga_mm.c:414`), which writes
those pointers into a scatterlist that is then DMA-mapped and cache-synced —
i.e. the same class of operation that oopses in the GRD trace.

The series already knows this: the sibling physical-import path at
`rga_mm.c:370-386` was hardened with exactly the right check and even documents
why `pfn_valid()` alone is insufficient —

```c
        /*
         * pfn_valid() only proves that a struct page exists.  It can be
         * true for sparse-memory holes and no-map ranges which cannot be
         * passed to dma_map_sg().
         */
        if (!virt_addr_valid(phys_to_virt(addr)))
            return -EINVAL;
```

The userptr/PFNMAP path was left unhardened.

**Proposed fix.** Apply the same guard the hardened sibling uses, which is
stricter than `pfn_valid()` for exactly the reason its own comment gives:

```c
+        if (!pfn_valid(args.pfn) ||
+            !virt_addr_valid(pfn_to_virt(args.pfn))) {
+            rga_err("page[%d] pfn %#lx is not mappable memory\n",
+                i, (unsigned long)args.pfn);
+            follow_pfnmap_end(&args);
+            ret = RGA_OUT_OF_RESOURCES;
+            break;
+        }
         pages[i] = pfn_to_page(args.pfn);
         follow_pfnmap_end(&args);
```

Note the `follow_pfnmap_end()` on the error path — the existing `break` arms
above it already return without it in one place, which is a second, smaller bug
in the same loop worth fixing in the same patch.

**Verification.** `mmap()` a `/dev/mem` or GPU BAR range and pass it to RGA as a
userptr; require a clean `RGA_OUT_OF_RESOURCES` and taint 0. Pre-fix this either
oopses in the DMA sync or silently maps nonsense.

**Relation to the SG oops.** The only vendor code that can manufacture a wild
`struct page *` of the observed shape (`vmemmap + 64 × arbitrary_pfn`, page
aligned, no flag bits). It writes only into RGA's own private table, so it
cannot reach the victim directly — but it is the closest structural match to the
corrupt value in the whole tree, and if the guard ever reports a damaged table
owned by the RGA device this is the first place to look.

---

## Checked and found correct

Recorded so the next pass does not re-derive them.

| Construct | Verdict |
|---|---|
| `struct mpp_iommu_dma_cookie` shadow struct (`mpp_iommu.h:27-30`) | **Correct.** The real `iommu_dma_cookie` does start with `struct iova_domain iovad`, and the driver asserts it with `BUILD_BUG_ON`. Only the missing `cookie_type` check (D03) is wrong. |
| `mpp_dma_buf_sync()` advancing `sg_dma_addr` by `sg->length` (`mpp_iommu.c:471-508`) | **Correct under the driver's own contract.** It looks wrong — CPU length used to walk DMA addresses — but `mpp_dma_check_iova_contract()` (`mpp_iommu.c:83-120`) requires `nents == 1`, so the mapping is one contiguous IOVA span and the cumulative CPU offset equals the IOVA offset. |
| `rga_dma_alloc_aligned_sgt()` (`rga3/rga_dma_buf.c:159-213`) | **Bounded and safe.** Private table allocated at `:174` with exactly `orig_nents` entries, walked by `sg_next()` inside a `for_each_sg(..., orig_nents, i)` bound, `sg_free_table()`d on the success path (`:277`) and on every error path. `aligned_sgt.sgl` never escapes the function; `buffer->sgt` retains the *original* table. |
| `mpp_extract_reg_offset_info()` count/size checks (`mpp_common.c:2160-2191`) | **Correct as far as they go** — `cnt` is bounded and a non-element-multiple `req->size` is rejected. The gap is `index` (D01), not these. |
| `buffer->copy_sgt` (`mpp_iommu.h:42`) | **Dead field.** Only ever assigned `NULL` (`mpp_iommu.c:139`); the `CONFIG_DMABUF_CACHE` path it belonged to compiles out. Candidate for deletion during cleanup. |
| rkvenc2 slice-FIFO records (`mpp_rkvenc2.c:220-227`, `:1717`) | **CPU-filled from MMIO, not DMA.** 4-byte records read from register `0x4038` in IRQ context; no DMA address for the FIFO is ever programmed. |
| All MPP device-visible memory | **Never in a slab.** Every hardware-writable region is `dma_alloc_coherent` or `alloc_pages` at a DT-fixed reserved IOVA, all probe-to-remove scoped. Both `dma_map_single()` sites in the tree are `DMA_TO_DEVICE`. |

## Suggested sequencing

1. **D01 and D02 first**, together, as a two-patch security pair on
   [`patches/cleanup-split/`](../patches/cleanup-split/README.md). They are
   small, independently testable, and both are unprivileged-reachable memory
   corruption. Neither depends on the scatterlist investigation concluding.
2. **D05** next — one hunk plus an error-path fix, and it removes the tree's
   only manufacturer of wild page pointers, which also simplifies reasoning
   about the open investigation.
3. **D03** as a cleanup that *deletes* code (shadow struct and both casts) by
   adopting the accessor RGA already uses.
4. **D04** last of the five: the correct fix is an ordering change plus a
   reference-lifetime argument, so it deserves its own review rather than being
   bundled.

Each should carry a `Fixes:`-style note naming the forward-port patch that
introduced or carried the code, per
[`patch-catalog.md`](patch-catalog.md) conventions, and the two security fixes
are candidates for the upstream/BSP submission list tracked in
[`findings/2026-07-22-bsp-bug-upstream-submission-priority.md`](../../findings/2026-07-22-bsp-bug-upstream-submission-priority.md)
— D01 and D02 are BSP-inherited, not forward-port regressions.
