# RGA3 userptr-IOMMU runtime smoke: behavior passes, fallback attribution still indirect

> Scope: RK3588 Rock 5B forward-port RGA userptr-IOMMU fallback kernel, RGA3 `virt_addr` librga
> demos, and `kernel-drivers/tests/rga-mmu-debug.sh`.
> Source: `/boot/vmlinuz-6.18.38-current-rockchip64` string inspection and
> `../rockchip-conformance/logs/rga-mmu-debug/20260705-182754` through
> `../rockchip-conformance/logs/rga-mmu-debug/20260705-182808`.
> Date: 2026-07-05
> Trust: MEASURED for kernel string evidence and smoke-test behavior; INFERRED
> for RGA userptr-IOMMU fallback attribution because the clean image had no positive
> fallback breadcrumb.

## The fact

The installed test kernel was:

```text
Linux rock-5b 6.18.38-current-rockchip64 #14 SMP PREEMPT Sat Jul  4 11:44:22 UTC 2026 aarch64 GNU/Linux
```

`strings /boot/vmlinuz-6.18.38-current-rockchip64` found the RGA userptr-IOMMU fallback identifiers
`driver-owned IOMMU` and `iommu_dma_get_iova_domain`, but did not find
`DIAG rga_dma_map_sgt`. This means the booted image contained clean RGA userptr-IOMMU fallback
without the temporary debug-tip fallback diagnostics.

Six consecutive `rga-mmu-debug.sh` artifact directories reported `pass` for all
selected cases:

```text
20260705-182754
20260705-182758
20260705-182801
20260705-182803
20260705-182806
20260705-182808
```

Selected cases:

```text
rga_copy_demo
rga_resize_rect_demo
rga_transform_rotate_demo
```

The filtered dmesg for those runs had no `DIAG rga_dma_map_sgt`, no
`reject sg_table DMA mapping`, no `INTR[0x2]`, no IOMMU page fault, and no RGA
`finished N failed M` fault with `M > 0`.

The latest run's debugfs hardware dump confirmed the expected RK3588 split:

```text
rga3, core 1 ... mmu: RK_IOMMU
rga3, core 2 ... mmu: RK_IOMMU
rga2, core 4 ... mmu: RGA_MMU
```

RGA3 command dumps can still show:

```text
mmu: win0 = 00 win1 = 00 wr = 00
```

That is the internal RGA3 command MMU bitfield. It is expected to be zero when
RGA3 uses the external RK_IOMMU, and is not evidence that the command used
physical addresses. The same logs showed device-visible IOVA handles, for
example `iova = 0xdd800000, dma_addr = 0xdd800000, offset = 0x10`, with jobs
finishing as `finished 1 failed 0`.

## Why it matters / follow-up

This is strong indirect RGA userptr-IOMMU fallback evidence because the earlier debug run at
`../rockchip-conformance/logs/rga-mmu-debug/20260705-151723` showed this same
demo family failing closed with non-contiguous userptr imports such as:

```text
orig_nents=895 nents=895 contiguous=0 gaps=894 ... reject sg_table DMA mapping
orig_nents=386 nents=386 contiguous=0 gaps=9   ... reject sg_table DMA mapping
orig_nents=367 nents=367 contiguous=0 gaps=306 ... reject sg_table DMA mapping
orig_nents=492 nents=492 contiguous=0 gaps=68  ... reject sg_table DMA mapping
orig_nents=390 nents=390 contiguous=0 gaps=367 ... reject sg_table DMA mapping
orig_nents=389 nents=389 contiguous=0 gaps=36  ... reject sg_table DMA mapping
```

Do not overclaim this as direct fallback proof. The clean image had no success
log/counter in `rga_dma_map_sgt_iommu()`, so the artifact set cannot identify
which individual import entered RGA userptr-IOMMU fallback. To close that gap, boot the debug-tip
profile or add a temporary positive breadcrumb/counter in `rga_dma_map_sgt_iommu()`
and capture one passing selected case that entered the fallback.
