# RGA2 syncs page-table memory through an unmapped DMA address

> Scope: RK3588 RGA2 (`fdb80000.rga2`) on the forward-port
> `6.18.38-current-rockchip64 #1` KASAN/DMA-debug kernel; direct
> `librga-smoke.sh` dma-buf copy; Rockchip RGA3 driver
> `drivers/video/rockchip/rga3/rga_dma_buf.c` / `rga_iommu.c`.
>
> Source: bracketed system journal plus the exact booted-kernel source worktree
> under `/home/yi/Code/rock-5b/kernel/rock5b-kernel-build/`.
>
> Date: 2026-07-20
>
> Evidence: `/home/yi/Code/rock-5b/rockchip-conformance/logs/forward-port/`
> `20260720-213827-rga-dma-api-warning/`; PID 864994 at 2026-07-20 21:38:27.
>
> Trust: **MEASURED** (complete DMA-API warning and call trace) /
> **CODE-INSPECTED** (invalid mapping lifecycle) / **RESOLVED** by `0050`.

> **Resolved 2026-07-21 by `0050@473903525009a`.** The fix gives RGA2 real
> ownership of its page-table memory (coherent allocation, `virt_to_phys()`
> dropped) instead of syncing through an unmapped DMA address. Verified on
> booted `P9636-C4ad2`: the full librga smoke passes 28/0 and the
> `rga_dma_sync_flush_range` splat recorded below is gone. The verification
> gate at the end of this file is therefore met. Design, deviations, and the
> over-4G `0051` companion are in
> [`2026-07-21-rga2-dma-api-ownership-and-over-4g-scope.md`](2026-07-21-rga2-dma-api-ownership-and-over-4g-scope.md).

## Result

The direct smoke's virtual-buffer `imcopy` completed, but its dma-buf copy
triggered this warning while RGA2 was constructing the hardware MMU table:

```text
DMA-API: rga2 fdb80000.rga2: device driver tries to sync DMA memory it has not allocated
        [device address=0x0000000029472000] [size=16 bytes]
```

The symbolized path was:

```text
debug_dma_sync_single_for_device
__dma_sync_single_for_device
rga_dma_sync_flush_range
rga_set_mmu_base
rga2_init_cmd_reg
rga2_init_reg
rga_job_commit
rga_request_commit
rga_request_submit
rga_ioctl_blit
```

The same request subsequently reported `no core match` and failed submission.
That later scheduling failure and the DMA-API violation happened in one request,
but this evidence does not prove that one caused the other.

## Root cause

`rga_mmu_base_init()` allocates the shared RGA2 page-table ring with
`rga_get_free_pages(GFP_KERNEL | GFP_DMA32, ...)`. Handle-backed jobs can
similarly allocate an individual table from ordinary pages. The driver fills
those CPU pages, and `rga_set_mmu_base()` calls:

```c
rga_dma_sync_flush_range(page_table, page_table + page_count, scheduler);
```

The helper then treats the physical address as though it were a DMA mapping:

```c
dma_sync_single_for_device(scheduler->dev, virt_to_phys(pstart),
			   pend - pstart, DMA_TO_DEVICE);
```

No preceding `dma_map_single()` (or coherent DMA allocation) created that DMA
address for `scheduler->dev`. A CPU physical address from `virt_to_phys()` is
not a streaming-DMA mapping token, so passing it to
`dma_sync_single_for_device()` violates the DMA API. The 6.18 DMA debugger
correctly rejects the lifecycle even when the platform happens to use an
identity DMA translation.

## Fix direction

The page-table allocation and hardware base-address programming need one
coherent DMA ownership model:

1. Prefer DMA-coherent allocation for the shared RGA2 MMU ring and the
   per-job handle-backed tables, retain both CPU and DMA addresses, and program
   the retained DMA address plus the table offset.
2. If streaming mappings are retained instead, map each allocation for the
   correct RGA2 device, use the returned DMA address in the register, sync only
   while that mapping is live, and unmap it at the matching lifetime boundary.
3. Account for the shared ring being consumed by a specific scheduler/device;
   do not reuse a mapping created for an unrelated RGA core.

Replacing the call with another physical-address cache helper or suppressing
DMA debugging would only hide the ownership error.

## Verification gate

- Boot a kernel with `CONFIG_DMA_API_DEBUG=y` and the proposed fix.
- Run the direct `librga-smoke.sh` virtual and dma-buf cases, then the official
  librga matrix with valid fixture and heap configuration.
- Require no DMA-API warning, RGA/IOMMU fault, or new fatal-signature line.
- Prove both the RGA2 page-table path and the RGA3 system-IOMMU path complete;
  a scheduler fallback that merely avoids RGA2 is not a fix.
