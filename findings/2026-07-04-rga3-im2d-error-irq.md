# RGA3 core0 throws an error IRQ on some direct im2d copy/resize samples

> Scope: forward-port kernel `../kernel/linux-6.18-rkvenc-av1-fwport` (av1-fwport build, `/proc/mpp_service/version` = `6.18-rkvenc-fwport`), RGA driver `drivers/video/rockchip/rga3/`
> Source: on-board run of the prebuilt `airockchip/librga` IM2D samples (`../rockchip-conformance/out/librga-samples/bin/`) on kernel `6.18.37-current-rockchip64 #8`
> Date: 2026-07-04
> Trust: MEASURED (symptom); ANALYZED (BSP/forward-port source comparison);
> HYPOTHESIS (runtime root cause — not yet isolated on hardware)

## The fact

Running the official librga IM2D sample binaries directly (not through
ffmpeg `scale_rkrga`), on the av1-fwport kernel:

- `rga_transform_rotate_demo` → **`running success!`** — at least one librga/RGA
  submit/IRQ/readback path works after recovery. This does not, by itself, prove
  the RGA3+IOMMU path is clean unless the selected core is captured in logs.
- `rga_copy_demo`, `rga_resize_rect_demo` → `Failed to call RockChipRga
  interface`. `dmesg` shows the real cause on the RGA3 side:
  ```
  rga: ID[1]: irq handler err! INTR[0x2], HW_STATUS[0xaaaaa], CMD_STATUS[0x1]
  rga: RGA3_core0[0x1] soft reset complete.
  rga: ID[1]: rga intr error[0x2]!  ... request commit failed! ... submit failed!
  ```
  i.e. RGA3 core0 raises the **RGA MMU interrupt** (`INTR[0x2]` is
  `m_RGA3_INT_RGA_MMU_INTR`), the driver **soft-resets the core and recovers**,
  and the *next* job (the transform demo) succeeds. So the reset/recovery path
  is healthy; specific RGA3 im2d copy/resize submissions fault.
- `rga_fill_rectangle_demo`, `rga_cvtcolor_csc_demo` → fail earlier, at buffer
  allocation: `alloc dma32_heap buffer failed!` / `alloc src dma_heap buffer
  failed!`. This kernel exposes only `/dev/dma_heap/{system,default_cma_region,
  reserved}` — there is **no `dma32_heap`** node the samples ask for. That is an
  environmental/sample-expectation mismatch, not an RGA fault.

Contrast: RGA *is* validated through ffmpeg `scale_rkrga` in `transcode-test.sh`
(1080p→720p / 720p→480p) and through `librga-smoke.sh`'s maintained im2d paths.
Those pass. Only the direct upstream copy/resize sample shapes fault here.

The failing copy/resize samples are not the heap-name failures: they allocate
ordinary userspace memory with `malloc()`, register it through
`importbuffer_virtualaddr()`, and then wrap the imported handles as RGBA buffers.
That keeps the RGA MMU interrupt separate from the `dma32_heap` allocation
failures.

## BSP vs forward-port comparison

Compared `../kernel/rockchip-kernel` against
`../kernel/linux-6.18-rkvenc-av1-fwport`:

- `drivers/video/rockchip/rga3/` is effectively BSP-equivalent. The diffs are
  forward-port/build adaptations: Kconfig dependency/defaults, Makefile include
  syntax, hrtimer API, module namespace quoting, safer version-string
  `snprintf()`, a 6.12+ VMA/PFN fallback, and an IOMMU fault-handler guard for
  DMA-managed domains. There is no material diff in RGA3 register programming,
  IRQ handling, policy/core selection, format/stride checks, job submission, or
  virtual-buffer IOVA mapping.
- The RK3588 RGA DT nodes are also effectively BSP nodes transplanted into the
  6.18 base: same register ranges, IRQ numbers, clocks, power domains, and
  IOMMU attachments, with mainline binding-compatible spelling/default
  enablement. The important exception is the IOMMU provider binding: BSP RGA
  MMUs use `compatible = "rockchip,iommu-v2"`, while the forward port binds
  them through the mainline Rockchip IOMMU provider as
  `compatible = "rockchip,rk3588-iommu", "rockchip,rk3568-iommu"`.
- The heap behavior is a real BSP/forward-port delta, but it explains only the
  allocation-only failures. The BSP enables Rockchip dma-buf heaps and creates
  `system-dma32` / `system-uncached-dma32`; the forward kernel uses standard
  6.18 heaps (`system`, `default_cma_region`, `reserved`) and does not expose a
  Rockchip DMA32 heap.

DMA32 here means **memory suitable for devices with a 32-bit DMA address
window**, usually pages below 4 GiB. It is not about whether the userspace
process is a 32-bit ARM program: userspace gets a dma-buf fd, and the kernel
maps that buffer for the hardware device. On RK3588, the maintained RGA3/MPP
paths use IOMMU/dma-buf mappings and do not require a Rockchip DMA32 heap for
correctness. Missing DMA32 heaps are therefore a BSP ABI/sample-compatibility
gap, not a confirmed functional gap for the validated forward-port workloads.

So there is no identified forward-port RGA3 *driver* change that directly
explains only these copy/resize MMU interrupts. The plausible forward-port gap
is narrower: the vendor RGA3 driver is now running against the mainline
Rockchip IOMMU path instead of Rockchip's BSP `iommu-v2` path. The RGA driver
maps malloc-backed virtual buffers by pinning pages, building an sg-table,
calling `dma_map_sg()` against the selected scheduler/default IOMMU device, and
programming the resulting IOVA into the RGA3 image base registers. If the
mainline IOMMU domain, TLB maintenance, device/domain selection, or fault
recovery differs from BSP in a way this vendor RGA driver did not expect, the
first visible symptom would be exactly this: `m_RGA3_INT_RGA_MMU_INTR`.

One tempting theory is high-address truncation: RGA3 image base registers are
programmed as 32-bit values while the RGA IOMMU devices request a 40-bit DMA
mask. That must still be checked in the fault logs, but it is not the leading
theory from source alone because the Rockchip IOMMU domain advertises a forced
32-bit IOVA aperture in both trees. If the failing IOVA or programmed `win0` /
`wr` addresses show high bits, address-width truncation becomes actionable. If
the fault IOVA is below 4 GiB, focus instead on map range, domain sharing, TLB
sync, or RGA/core selection.

The forward-port guard around `iommu_set_fault_handler()` for cookie-backed DMA
domains is probably diagnostic/recovery related rather than the cause of the
bad access. Restoring the generic call blindly is not the right fix on 6.18
because the IOMMU core warns on cookie-backed domains. If we need the vendor RGA
fault callback again, use the Rockchip-specific fault-handler shim exported by
the forward IOMMU driver (`rockchip_iommu_set_fault_handler()`) or add explicit
RGA-side fault dumps, instead of bypassing the 6.18 cookie rules.

## Why it matters / follow-up

RGA is part of the forward-port, so a real RGA3 copy/resize regression would
matter — but this is **not yet root-caused**, and the validated userspace paths
(ffmpeg scale, librga-smoke) are clean. Treat the raw upstream sample binaries as
diagnostic on the forward-port until the exact same binaries and shapes are
measured on the vendor 6.1 BSP image. In particular, `librga-suite.sh` currently
lists many upstream sample binaries as required; that requirement is too broad
for the forward-port gate unless BSP parity for those exact cases is known.

Debug plan:
1. Re-run `rga_copy_demo`/`rga_resize_rect_demo` with RGA MM/REG/INT logging
   enabled under `/sys/kernel/debug/rkrga/` if present. Capture the failing
   request, selected core, src/dst format, active/virtual dimensions, stride,
   `win0`/`wr` addresses, and `rga_mm_dump_buffer()` IOVA/dma_addr/offset values.
2. Capture the Rockchip IOMMU page-fault line from `dmesg`
   (`Page fault at ... of type read/write`) for the same run. Compare the fault
   IOVA with the mapped src/dst IOVA ranges and the RGA3 register dump:
   in-range faults point to IOMMU/TLB/domain handling; just-past-end faults point
   to size/stride/overread; unrelated faults point to wrong device/domain or
   stale mapping.
3. Force core selection: RGA3 core0, RGA3 core1, then RGA2. If both RGA3 cores
   fault and RGA2 succeeds, the RGA3/mainline-IOMMU path is suspect. If only one
   RGA3 core faults, check that core's DT/IOMMU/power/clock path. If all cores
   fail, focus on the sample request or virtual-buffer import path.
4. Run the same copy/resize shapes with dma-buf fd-backed buffers from heaps the
   forward kernel actually exposes (`system`, `default_cma_region`, or
   `reserved`). If fd-backed buffers pass while `importbuffer_virtualaddr()`
   fails, the GUP/sg/dma_map virtual-import path is the target. If both fail,
   focus on RGA3 register programming or IOMMU translation.
5. Vary size around the failing shapes. Small maintained smoke cases pass today;
   finding the smallest failing width/height helps distinguish IOVA allocator
   pressure, page-boundary/sg issues, and algorithm-specific copy/resize
   behavior.
6. Run the exact same prebuilt sample binaries and image shapes on the vendor
   6.1 BSP kernel. If BSP RGA3 passes and the forward kernel fails, this is a
   real forward-port bug in the RGA3 + IOMMU integration. If BSP also faults,
   demote the raw upstream copy/resize samples to outdated/bad diagnostic tests
   and keep the maintained smoke/ffmpeg paths as the gate.

Candidate fix directions, depending on the evidence:
1. If the fault IOVA is outside the mapped buffer: fix the sample/test request
   or the driver size/stride validation; do not paper over it in IOMMU code.
2. If the fault IOVA is inside a mapped buffer: audit the forward IOMMU glue for
   the selected map device, shared domain setup between RGA3 cores, DMA API
   attachment lifetime, and Rockchip IOMMU TLB/page-table sync.
3. If the RGA driver needs its vendor fault callback for correct recovery, wire
   it through `rockchip_iommu_set_fault_handler()` or add explicit RGA-side fault
   dumps; do not re-enable generic `iommu_set_fault_handler()` on DMA-cookie
   domains.
4. If only malloc-backed imports fail: prefer dma-buf-backed buffers in
   production tests while fixing the virtual import path separately. The public
   librga ABI still supports virtual imports, so this should remain tracked.
5. If forcing RGA2 avoids the fault: RGA2 routing is a workaround only. It should
   not close the finding unless BSP also fails the RGA3 case.

Related: the missing DMA32 heap is worth noting for anyone running the raw
upstream librga samples — rebuild heap-allocating samples with a heap this kernel
provides (`system`, `default_cma_region`, or `reserved`) or treat those failures
as environment/sample-expectation mismatches before they touch RGA.
