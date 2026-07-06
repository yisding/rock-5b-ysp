# RGA3 memory import contract: fd, userptr, physical address, and mmap paths

> Scope: RGA userspace memory imports across the forward-port vendor driver,
> the compatibility rewrite, and local mainline RGA3 V4L2 support.
> Source: code inspection of BSP `../kernel/rockchip-kernel` @ `b4ef083dc0c3`,
> `../kernel/linux-6.18-rkvenc-av1-fwport`
> `rkvenc-fwport-6.18` @ `eb0f3e209007`,
> pre-RGA-userptr-IOMMU `../kernel/linux-6.18-rkvenc` `rk3588-rewrite-6.18` @
> `0e6fa86bd84c`, and pre-RGA-userptr-IOMMU `../kernel/linux`
> `rk3588-rewrite-mainline` @ `c092e016fd29`;
> related runtime evidence in
> `findings/2026-07-04-rga3-im2d-error-irq.md`.
> Date: 2026-07-05
> Trust: CODE-INSPECTED; MEASURED for the forward-port scattered-userptr reject
> behavior inherited from the related runtime finding.

> Update 2026-07-05: this finding captured the pre-RGA-userptr-IOMMU state. RGA userptr-IOMMU fallback patch
> artifacts now live under `kernel-drivers/patches/rga-userptr-iommu/` and
> are documented in `findings/2026-07-05-rga3-userptr-iommu-design.md`.
>
> Update 2026-07-06: the rewrite-side RGA userptr-IOMMU fallback slice is now committed and pushed
> to `yisding/linux-rock5b`: `rk3588-rewrite-6.18` @ `d1cfb432da7f` and
> `rk3588-rewrite-mainline` @ `c8a41bb830a6`. Both committed tips passed the
> clean-archive YSP rewrite build gate for `mpp_rewrite.o` and `rga_rewrite.o`.
> The rewrite now exposes `rk_rga_rewrite/route_b` counters and `force_remap`
> for direct fallback attribution; booted rewrite hardware validation is still
> pending.

## The fact

Physical-address imports and userptr/virtual-address imports are distinct ABI
paths.  The vendor ABI enum has separate `RGA_DMA_BUFFER`,
`RGA_VIRTUAL_ADDRESS`, and `RGA_PHYSICAL_ADDRESS` values
(`../kernel/linux-6.18-rkvenc-av1-fwport/drivers/video/rockchip/rga3/include/rga.h:83`).

`RGA_VIRTUAL_ADDRESS` is a userspace virtual pointer path.  The driver pins the
process pages, builds an sg-table, maps that table for DMA, and programs the
resulting device-visible address.  This is the path used by
`wrapbuffer_virtualaddr()` / `importbuffer_virtualaddr()` and by malloc-backed
sample code.

`RGA_PHYSICAL_ADDRESS` is not the same thing.  It means the userspace ABI field
is already a physical address.  In the forward-port vendor driver that path still
exists and assumes a physically contiguous span
(`../kernel/linux-6.18-rkvenc-av1-fwport/drivers/video/rockchip/rga3/rga_mm.c:682`,
`:718`, `:847`).  The rewrite intentionally rejects physical imports:
`rk_rga_import_one()` accepts only `RGA_DMA_BUFFER` and `RGA_VIRTUAL_ADDRESS`,
and returns `-EOPNOTSUPP` for the rest
(`../kernel/linux-6.18-rkvenc/drivers/video/rockchip/rga-rewrite/rga_rewrite.c:16791`).

RGA3 needs a single linear device-visible address span per programmed plane.  It
does not necessarily require physically contiguous DRAM if the IOMMU/DMA layer
gives the device one contiguous IOVA span.  But the hardware command format gets
only base addresses; it does not consume scatterlist descriptors.  Mainline RGA3
command emission writes base registers directly
(`../kernel/linux/drivers/media/platform/rockchip/rga/rga3-hw.c:110`, `:122`),
and the rewrite does the same with `lower_32_bits()`
(`../kernel/linux-6.18-rkvenc/drivers/video/rockchip/rga-rewrite/rga_rewrite.c:13802`,
`:13990`).  If a malloc-backed userptr maps as several DMA segments and the
driver programs only the first address, RGA3 walks off segment zero and faults.

The BSP RGA driver does not itself build a synthetic contiguous IOVA range from
scatterlist entries.  It calls the DMA API.  The BSP Rockchip IOMMU provider sets
`dma_set_max_seg_size(dev, DMA_BIT_MASK(32))` for attached devices
(`../kernel/rockchip-kernel/drivers/iommu/rockchip-iommu.c:1477`, `:1483`), and
the BSP `iommu-dma` path allocates one IOVA and calls `iommu_map_sg_atomic()`
(`../kernel/rockchip-kernel/drivers/iommu/dma-iommu.c:1280`, `:1290`).  That is
where the "scatterlist to one device-visible IOVA span" behavior can happen in
the BSP stack.

The BSP MPP codec stack should not be lumped together with RGA userptr support.
The MPP ioctl ABI copies userspace command/register payloads with
`copy_from_user()`, but the frame/stream buffers used for hardware DMA are
imported as dma-buf fds.  `MPP_CMD_TRANS_FD_TO_IOVA` copies an array of fds from
userspace, imports each fd with `mpp_dma_import_fd()`, and returns IOVAs
(`../kernel/rockchip-kernel/drivers/video/rockchip/mpp/mpp_common.c:1406`,
`:1420`, `:1430`, `:1437`).  Per-task register patching also imports fds through
`mpp_task_attach_fd()` rather than pinning arbitrary user pages
(`../kernel/rockchip-kernel/drivers/video/rockchip/mpp/mpp_common.c:1806`,
`:1838`).  The MPP file operations expose open/release/ioctl only, with no
`.mmap` entry (`../kernel/rockchip-kernel/drivers/video/rockchip/mpp/mpp_common.c:1797`).
Code search found no `get_user_pages`, `pin_user_pages`, or `VB2_USERPTR` path
under `../kernel/rockchip-kernel/drivers/video/rockchip/mpp`.  So BSP RGA/RGA3
has a virtual-address/userptr buffer import path; BSP VDEC/VENC/VPU through MPP
does not expose the same arbitrary malloc-backed buffer path.

The forward-port currently handles scattered malloc/userptr by rejecting it, not
by making it work.  `rga_dma_check_iova_contract()` requires exactly one nonzero
DMA segment and rejects 32-bit IOVA overflow
(`../kernel/linux-6.18-rkvenc-av1-fwport/drivers/video/rockchip/rga3/rga_dma_buf.c:16`,
`:27`, `:41`).  `rga_dma_map_sgt()` calls `dma_map_sg()`, records the returned
segment count, logs diagnostics when the DMA layer returns multiple segments,
and then applies that contract
(`../kernel/linux-6.18-rkvenc-av1-fwport/drivers/video/rockchip/rga3/rga_dma_buf.c:139`,
`:160`, `:169`).  That is fail-closed behavior.  It is not RGA userptr-IOMMU fallback.

The pre-RGA-userptr-IOMMU rewrite did not yet have the same fail-closed contract check.
Its userptr path pinned with `pin_user_pages_fast(FOLL_WRITE | FOLL_LONGTERM)`,
built an sg-table with `sg_alloc_table_from_pages()`, called
`dma_map_sgtable()`, and stored only `sg_dma_address(sgt->sgl)` as the IOVA
(`../kernel/linux-6.18-rkvenc/drivers/video/rockchip/rga-rewrite/rga_rewrite.c:16605`,
`:16624`, `:16629`, `:16745`).  Its dma-buf import similarly stores the first
sg DMA address after `dma_buf_map_attachment()`
(`../kernel/linux-6.18-rkvenc/drivers/video/rockchip/rga-rewrite/rga_rewrite.c:16640`,
`:16666`, `:16690`).  There is no rewrite-local equivalent of the forward-port
`nents == 1` and 32-bit-span validation as of `0e6fa86bd84c`.

As of `rk3588-rewrite-6.18` @ `d1cfb432da7f` and
`rk3588-rewrite-mainline` @ `c8a41bb830a6`, the rewrite now validates normal
DMA mappings and keeps dma-buf imports fail-closed unless they resolve to one
32-bit-safe segment. For driver-owned pinned userptr mappings only, it adds the
scoped RGA userptr-IOMMU fallback: allocate one byte-contiguous DMA IOVA from the device's
translated DMA domain, map a page-aligned sg copy with `iommu_map_sg()`, program
that synthetic IOVA, and unmap/free it explicitly when the import or temporary
job mapping is released. It also exposes development-only RGA userptr-IOMMU fallback counters and a
`force_remap` knob under `rk_rga_rewrite/route_b` so hardware validation can
distinguish "the workload passed" from "the fallback executed."

The mainline RGA3 V4L2 driver is a different ABI.  It has no vendor
`RGA_IOC_IMPORT_BUFFER`, no raw physical import, and no arbitrary userptr queue
mode.  The queues expose `VB2_MMAP | VB2_DMABUF`, not `VB2_USERPTR`
(`../kernel/linux/drivers/media/platform/rockchip/rga/rga.c:98`, `:117`).
For RGA3, `.has_internal_iommu = false`
(`../kernel/linux/drivers/media/platform/rockchip/rga/rga3-hw.c:488`), so queue
init chooses `vb2_dma_contig_memops` rather than the internal-RGA-MMU
scatter/gather path (`../kernel/linux/drivers/media/platform/rockchip/rga/rga.c:102`,
`:120`).  `VB2_MMAP` means kernel/videobuf2-allocated video buffers that
userspace can mmap; it does not allow an arbitrary `malloc()` pointer to be
queued.  Imported dmabufs must present a large enough contiguous chunk
(`../kernel/linux/drivers/media/common/videobuf2/videobuf2-dma-contig.c:714`).

The historical gap was that neither the forward-port nor the rewrite implemented
RGA userptr-IOMMU fallback: a driver-owned `iommu_map_sg()` / synthetic contiguous IOVA range for
scattered userptr. That is no longer true for the committed rewrite tips above.
The remaining evidence gap is runtime: the rewrite RGA userptr-IOMMU fallback path is build- and
style-verified on both target kernels, but still needs booted Rock 5B validation
against direct virtual-address `librga` workloads.

## Why it matters / follow-up

Use dma-buf / dma-heap / CMA-style buffers for dependable RGA3 operation.  If a
dma-buf is mmap'ed into userspace, pass the dma-buf fd to RGA rather than the
mmap pointer; the fd path preserves the exporter/importer contract.

That does not mean every dma-buf is physically contiguous.  A dma-buf is a
sharing handle, not a contiguity guarantee.  CMA / dma-contig style exporters can
provide physically contiguous backing memory; system-heap style exporters may be
backed by scattered pages.  What matters to RGA3 is that importing the dma-buf
produces one contiguous device-visible DMA segment for the plane.  The
forward-port checks that and rejects imported mappings with multiple DMA
segments.  The committed rewrite now applies the same fail-closed rule for
dma-buf imports.

Plain `malloc()` or anonymous `mmap()` memory was previously opportunistic on
RGA3.  It worked only when the pinned pages happened to map as one contiguous,
non-wrapping device-visible span.  The rewrite RGA userptr-IOMMU fallback slice is intended to make
that direct virtual-address path deterministic without weakening the dma-buf
contract, but hardware conformance still needs to prove it on the booted rewrite
driver.

## Implementation options if RGA3 userptr must work

Forward-porting the BSP IOMMU code wholesale is the highest-blast-radius option
and is probably not the right lever.  The BSP IOMMU files are not tiny:
`drivers/iommu/rockchip-iommu.c` is 1,883 lines and
`drivers/iommu/dma-iommu.c` is 1,710 lines in `../kernel/rockchip-kernel`.
The forward-port equivalents are already 1,683 and 2,214 lines, respectively.
The rough BSP-vs-forward diffstat is 445 insertions / 645 deletions for
`rockchip-iommu.c` and 890 insertions / 386 deletions for `dma-iommu.c`.

More importantly, the relevant BSP large-segment hook is already in the
forward-port: `rk_iommu_probe_device()` allocates `dev->dma_parms` and calls
`dma_set_max_seg_size(dev, DMA_BIT_MASK(32))`
(`../kernel/linux-6.18-rkvenc-av1-fwport/drivers/iommu/rockchip-iommu.c:1238`,
`:1252`).  The modern forward `iommu-dma` path also allocates one IOVA range and
calls `iommu_map_sg()` before finalising DMA segments
(`../kernel/linux-6.18-rkvenc-av1-fwport/drivers/iommu/dma-iommu.c:1483`,
`:1493`, `:1497`).  The BSP path is structurally similar, using
`iommu_map_sg_atomic()`
(`../kernel/rockchip-kernel/drivers/iommu/dma-iommu.c:1280`, `:1290`, `:1294`).
So a wholesale IOMMU import would be a large global change without clearly
adding the missing RGA3 userptr behavior.

The realistic options are:

1. Repair the normal DMA API path if the chosen RGA `map_dev` is bypassing
   `iommu-dma`.  This is a targeted RGA/IOMMU-device selection problem, not a
   wholesale BSP import.  It is worth checking before RGA userptr-IOMMU fallback, but the measured
   zero-merge signature (`nents == orig_nents`) already shows that simply
   re-applying `max_seg_size` is not enough.

2. Keep the fail-closed contract.  RGA3 accepts only mappings that import as one
   non-wrapping DMA segment; scattered userptr is rejected.  This is the current
   forward-port behavior and should be copied into the rewrite.

3. Add a staging-copy fallback for scattered userptr.  Allocate an RGA-owned
   contiguous/importable buffer, copy user memory in before the job and copy it
   out after the job when needed.  This supports arbitrary malloc memory without
   manual IOMMU ownership, but it is not zero-copy and can be expensive for
   large frames.

4. Implement RGA userptr-IOMMU fallback in a scoped way.  For a pinned userptr sg-table, allocate a
   contiguous IOVA span in an RGA-translated domain, map the scattered pages into
   that span with `iommu_map_sg()`, program that synthetic IOVA, perform explicit
   cache synchronization, and unmap/free the IOVA when the import is released.
   This is the closest semantic match to the BSP behavior, but it is medium-high
   risk: the driver must not collide with the DMA API's own IOVA allocator for
   the same domain.  Public building blocks exist (`iommu_map_sg()`,
   `iommu_unmap()`, and exported IOVA allocators), but the ownership model needs
   a deliberate design rather than ad hoc mapping into the DMA domain.

5. Add an RGA allocator / mmap-like path instead of arbitrary userptr.  This is
   closer to mainline `VB2_MMAP`: userspace maps kernel-allocated RGA-suitable
   buffers, then queues/imports those handles.  It avoids malloc fragmentation
   while still giving userspace CPU access, but it is a UAPI and userspace
   integration change.

Rewrite follow-up: run booted forward-port-vs-rewrite conformance for direct
virtual-address `librga` smoke cases and GStreamer/RKNN-shaped fd-backed paths.
The code-side follow-up is now smaller: preserve the fail-closed dma-buf rule,
keep RGA userptr-IOMMU fallback scoped to driver-owned userptr sg-tables, and add a runtime
breadcrumb or counter if direct fallback attribution is needed. The rewrite
counter surface now exists; the remaining work is to capture it on booted RK3588
hardware.
