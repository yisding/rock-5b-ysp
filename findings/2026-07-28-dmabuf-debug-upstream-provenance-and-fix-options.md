# The DMABUF_DEBUG scatterlist defect is 100% upstream code, reported since 2022, and blocked on an unresolved dma-buf design argument

> Scope: ROCK 5B kernel forward-port. Establishes provenance for the defect
> root-caused in
> [`2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md`](2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md)
> — is it ours, Rockchip's, Armbian's, or upstream's — and evaluates what an
> upstream fix would have to look like.
>
> Source: our published production source
> `linux-rockchip64-ysp_6.18.40+rk3588av1fwport20260725.orig.tar.gz`
> (sha256 `5d0a584d…`, the exact bytes that built the running kernel) diffed
> against the vanilla `Linux 6.18.40` tag (`221fc2f4d0ed`) held as `HEAD` in the
> Armbian worktree; `include/linux/dma-buf.h`, `drivers/dma-buf/Kconfig`,
> `kernel/dma/direct.c`, `drivers/iommu/dma-iommu.c`,
> `drivers/dma-buf/heaps/{system,cma}_heap.c`. Upstream record:
> [Yunfei Wang's 2022-08-31 bug report](https://lkml.iu.edu/hypermail/linux/kernel/2208.3/09369.html)
> and [Zack Rusin's 2024-05-10 "dma-buf sg mangling" thread](https://www.mail-archive.com/dri-devel@lists.freedesktop.org/msg492965.html);
> [LWN on the phys_addr_t DMA API migration](https://lwn.net/Articles/1036434/).
> Christian König's two replies are transcribed from those threads by the repo
> owner, not fetched verbatim by the agent.
>
> Date: 2026-07-28
>
> Trust: **SOURCE-INSPECTED** / **CONFIG-INSPECTED** / **CONFIRMED** (provenance)
> / **DESIGN** (fix options) / **UNVERIFIED** (the König quotes, as transcribed).

## Result

Neither we, nor Rockchip's BSP, nor Armbian introduced any part of this defect.
Both halves of the collision are unmodified upstream code, and the only thing
this project contributed was a config symbol that enabled itself.

Upstream has known about it since **2022-08-31**. It is unfixed in 6.18.40 not
because nobody noticed, but because the maintainer and the reporters disagree
about whose bug it is, and the disagreement has no resolution that anyone has
built.

## Provenance: the code is upstream, byte for byte

Our shipped source versus the vanilla `Linux 6.18.40` tag:

| file | role in the failure | vs. upstream |
|---|---|---|
| `drivers/dma-buf/dma-buf.c` | `mangle_sg_table()`, the writer | **identical** |
| `drivers/dma-buf/heaps/system_heap.c` | the `end_cpu_access` sync loop | **identical** |
| `drivers/iommu/dma-iommu.c` | `sg_phys()` deref that faults | +14 lines, an added `iommu_dma_get_iova_domain()` export; **sync path untouched** |

Neither our 76-patch series nor Armbian's `rockchip64-6.18` archive touches
`drivers/dma-buf` at all. Verified by grepping both patch sets for the path.

The one thing that is ours is `CONFIG_DMABUF_DEBUG=y` in the production config —
and even that was not a decision. `drivers/dma-buf/Kconfig:58` reads:

```
default y if DMA_API_DEBUG
```

so it switched itself on when `DMA_API_DEBUG` was enabled to support
`dma_debug_entries=2097152` on the kernel command line. Yunfei Wang flagged the
same coupling in 2022.

## Why the same heap code is legal on one platform and fatal on another

This is the sharpest technical fact in the whole investigation, and it did not
appear in the root-cause finding.

```c
/* kernel/dma/direct.c — dma_direct_sync_sg_for_cpu(): NEVER touches page_link */
phys_addr_t paddr = dma_to_phys(dev, sg_dma_address(sg));
arch_sync_dma_for_cpu(paddr, sg->length, dir);

/* drivers/iommu/dma-iommu.c — iommu_dma_sync_sg_for_cpu(): MUST touch page_link */
arch_sync_dma_for_cpu(sg_phys(sg), sg->length, dir);
```

The IOMMU path cannot use the DMA address because it is a translated IOVA, and
inverting it means a page-table walk per entry. So it goes back to the page.

The consequence: **identical dma-heap code is correct on a direct-DMA system and
oopses on an IOMMU system.** The heap does not call `sg_page()` anywhere. It
calls the public `dma_sync_sgtable_for_*()`, and whether that dereferences
`page_link` is an internal choice of the DMA layer that varies by platform.

## The upstream record

### 2022-08-31 — Yunfei Wang reports it

Same defect, same option, the mirror-image half of ours — `begin_cpu_access` /
`for_cpu`, where ours died on `end_cpu_access` / `for_device`:

```
dma_buf_begin_cpu_access()
→ system_heap_dma_buf_begin_cpu_access()
→ iommu_dma_sync_sg_for_cpu()
→ arch_sync_dma_for_cpu(sg_phys(sg)...)   [PA error]
```

### Christian König's reply — "the dma_heap is doing something it shouldn't"

> Hi Yunfei, well it looks like `system_heap_dma_buf_begin_cpu_access()` is
> exactly doing what this patch tries to prevent. In other words the dma_heap
> implementation is doing something which it shouldn't be doing. The patch from
> Daniel is just surfacing this.

### 2024-05-10 — Zack Rusin hits the same mangling from another angle

`CONFIG_DMABUF_DEBUG` also breaks `drm_prime_sg_to_page_array`, which vmwgfx and
xen depend on. He judged it low-priority: "afaik currently it only affects IGT
testing with vgem."

### König again — the pages are leaving the interface

> Well the whole point is that you should never touch the pages in the sg_table
> in the first place. The long term plan is actually to completely remove the
> pages from that interface. XEN and KVM were actually adjusted to not touch the
> struct pages any more. […] Well there is no solution for that. Accessing the
> underlying struct page through the sg_table is illegal in the first place. So
> the question is not how to access the struct page, but rather why do you want
> to do this?

## The design disagreement, stated fairly

**König's position.** A dma-buf's backing memory is opaque. Once
`dma_buf_map_attachment()` returns, the sgtable is a DMA-address carrier and
nothing else; its `page_link` is not readable by any layer and is scheduled for
removal. On that reading the debug option did not create a bug, it surfaced one,
and the heaps' `begin/end_cpu_access` — which walks *every attached device's*
mapping and re-syncs it from an ioctl unrelated to those devices — is reaching
into state the exporter already handed away.

**The counter.** The trap's own help text says it "validates that **importers**
do not peek." The heap is the exporter, caught by a trap aimed at someone else,
because the core scrambles the exporter's own live object rather than a copy
given to the importer. And the heap is not inspecting foreign memory — it is
performing cache maintenance on pages it allocated itself.

**Why it is unresolved.** The kerneldoc for `begin_cpu_access` mandates an
*outcome* —

> allows the exporter to ensure that the memory is actually coherent for cpu
> access

— and is completely silent on *mechanism*. There is no portable kernel API for
"make these pages coherent for whatever device might read them": every
cache-maintenance entry point needs a `struct device` to decide coherency and
swiotlb behaviour, and the only devices in reach are the attached importers'.
`arch_sync_dma_for_cpu()` is not exported to drivers; `flush_dcache_page()`
addresses page-cache aliasing, not device coherency.

So the maintainer says "don't do it that way" and no other way exists. Neither
party is obliged to build the replacement, and neither has.

**Why nobody has urgency.** Without `DMABUF_DEBUG`, the violation is harmless in
practice — reading `page_link` for pages you allocated yourself works fine.
Every ARM SoC shipping dma-heaps behind a non-coherent VPU carries the same
latent violation and none of them crash, because no distro enables the option.
A contract violation with no victim, and a crash only under a debug option
nobody ships.

## What the "long term plan" actually is, as of today

Real in direction, incomplete in execution.
[Leon Romanovsky's migration of the DMA API to physical addresses](https://lwn.net/Articles/1036434/)
reworks the internals to `phys_addr_t` and adds `DMA_ATTR_MMIO` so P2P MMIO can
be mapped without ever creating a `struct page`. As of the v5 review it is **not
merged**, explicitly does **not** touch scatterlist ("this series does the core
code and modern flows"), and does not mention dma-buf. König himself hedges on
his own precedent — "I'm not sure if that work is already upstream or not."

Note the implication if it does land: `iommu_dma_sync_sg_for_*()` needs
`sg_phys()`, so removing pages from the interface makes it unusable on dma-buf
sgtables **by anyone**, not just the heaps. The dma-heap CPU-access design needs
replacing either way, and no replacement has been proposed.

## Fix options, with the blockers actually verified

`cma_heap.c`'s `end_cpu_access` is byte-identical in shape to `system_heap.c`'s,
so any fix covers both. Only these two of the 25 in-tree `.map_dma_buf`
exporters are affected.

| approach | verdict |
|---|---|
| **Drop `default y if DMA_API_DEBUG`** | One line, zero risk, backportable. Does not fix the incompatibility — stops it ambushing people who never asked for it. **Caveat:** König holds that the crash is a *correct detection*, so he may defend the default as working as intended. Frame it as "two unrelated debug features should not auto-couple," never as "it causes crashes," which hands him his own argument. |
| **Core tracks the sgt and brackets the CPU-access hooks** | **Blocked harder than first thought.** `struct dma_buf_attachment` has *no* `sgt` field — the core mangles a table, hands it to the importer, and keeps no reference; the table lives in exporter-private `attach->priv`. Needs an ABI addition (cheap, `#ifdef`-able) *plus* a locking answer: `dma_buf_begin_cpu_access()` only does `might_lock()` on resv, and the exporter's own hook may take it, so the core cannot simply grab resv around an attachment walk. |
| **Heaps sync from the pristine `buffer->sg_table`** | **Subtly wrong.** The dups have identical geometry, so it looks safe, but `dma_sync_sgtable_for_*()` first tests `sg_dma_is_swiotlb(sgl)`; the origin table carries no DMA flags, so this silently skips the bounce sync wherever swiotlb is in play. |
| **A dma-buf-aware sync helper** | Core exports e.g. `dma_buf_sync_sgtable_for_device(dev, sgt, dir)` doing unmangle → sync → remangle. `mangle_sg_table()` is its own inverse (an XOR), so bracketing is exact. Right layering, no ABI addition, no attachment walk, no new locking. Four call sites in tree. **But** it entrenches exactly the pattern König rejects, so it fixes the crash while losing the argument. |
| **`dma_buf_ops` flag for "exporter retains the table"** | Weakest. Exporters self-declare, easy to get wrong, core cannot verify. |

## Boundary

- No patch has been written, compiled, or submitted. Every row above is
  **DESIGN**.
- The König quotes are transcribed by the repo owner from the two threads; the
  agent fetched the thread pages and confirmed the substance and the reporters,
  but did not independently verify the quotes word for word.
- Whether the 2022 thread continued past the quoted reply, or whether any later
  series addressed it, was not traced. Only that 6.18.40 still carries the
  defect, which the byte-identical diff proves directly.
- "Only two in-tree exporters affected" counts dma-heaps that sync attachments
  in `begin/end_cpu_access`. Other exporters may dereference dma-buf sgtable
  pages by other routes — `drm_prime_sg_to_page_array` is one, per Rusin — and
  those were not surveyed.
- No claim that the heaps' design is *correct*; only that no sanctioned
  alternative currently exists.

## Why it matters

Two practical consequences.

**Our fix is durable, not a workaround.** Disabling an option that was never
deliberately enabled, on a kernel where it buys nothing and costs all login
video, is right independent of how upstream resolves the design question.
Shipped as `~rk2`.

**The KASAN kernels were never the controls we believed.** They have
`DMABUF_DEBUG=n`, so their 9/9 clean logins and 1600 clean encoder sessions were
exercising a different program than production. That is the same blind spot
that produced the toolchain-confound detour, appearing a second time.

## Suggested next action

If engaging upstream, send **the question, not a patch**: *how should a dma-heap
make its buffer coherent for CPU access on a non-coherent IOMMU system, if the
attachment sgtable's pages are off-limits?* That question is unanswered in both
threads and is the blocker for everyone, and this is — as far as this
investigation found — the first instance where the latent violation produced a
user-visible failure on shipping hardware rather than an IGT artifact. That is
new information for a stalled argument.
