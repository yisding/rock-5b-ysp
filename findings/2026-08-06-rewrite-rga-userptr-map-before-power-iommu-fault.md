# Rewrite RGA USERPTR imports mapped before core power and left a stale IOTLB entry

> Scope: ROCK 5B rewrite RGA under the 2026-08-06 KASAN GStreamer conformance run
> Source: booted `rk3588-rewrite-6.18@c49308313ce7`; `rga_rewrite.c` `rk_rga_import_userptr()`, `rk_rga_backend_start()`, and `rk_rga_job_map_import()`; fixed 6.18 `5e5effdcfa099` / mainline `943f7573491a9`
> Date: 2026-08-06
> Trust: MEASURED, SOURCE-INSPECTED, INFERRED, ROOT-CAUSED, FIX-COMPILE-VERIFIED

## Result

The GStreamer `parallel_roundtrip_h264` case reached a genuine RGA3 IOMMU
read fault at `0xdb05d070`. The provider printed a valid DTE, a valid PTE, and
PTE flags `0x106`; the request geometry also places the fault inside the
320x240 NV12 USERPTR span. This was not an out-of-range plane calculation.

The rewrite's explicit USERPTR import path created a persistent mapping on an
arbitrarily chosen core before scheduling and before that core's power domain
was enabled. A later job selected the same core and reused the import mapping,
bypassing the already-correct job path that powers the core before installing
DMA/IOMMU mappings. Rockchip IOMMU invalidation can skip its TLB shootdown while
the IOMMU is runtime-suspended, leaving valid page-table entries behind a stale
IOTLB translation. The fault's valid PTE plus the source ordering identify that
power-domain hole as the cause.

## Evidence and reconstruction

- The bounded suite artifact is
  `../rock-5b/build/rockchip-conformance/logs/rewrite-kasan/20260806-142819-gstreamer-suite`.
  `dmesg-new.txt` contains the four-line fault, and
  `parallel_roundtrip_h264.log` identifies the virtual source as
  `0xffff6805cfb8`, 320x240, with librga MMU mode enabled.
- NV12 requires `0x1c200` bytes. The virtual address has page offset `0xfb8`,
  so the pinned/map span is `ALIGN(0xfb8 + 0x1c200) = 0x1e000`. Reconstructing
  the page-aligned IOVA as `0xdb040000` places the first image byte at
  `0xdb040fb8`; the fault is at image offset `0x1c0b8`, 328 bytes before the
  valid end. This address reconstruction is the INFERRED part of the finding.
- The BSP `drivers/video/rockchip/rga3/rga_job.c` explicitly says “Memory
  mapping needs to keep pd enabled” and calls `rga_power_enable()` before
  `rga_mm_map_job_info()`.
- The rewrite's job path already followed that order. Only the persistent
  import-level USERPTR mapping and its same-core reuse fast path bypassed it.

## Fix

`5e5effdcfa099` (mainline mirror `943f7573491a9`) makes an RGA import a logical
capability only: DMA-BUF identity or pinned USERPTR pages, size, and provenance.
Every USERPTR execution mapping is now created for the selected core after
`rk_rga_hw_power_on()` and released, including synchronization/copyback, before
the matching power-off. Core removal no longer has persistent USERPTR mappings
to detach. `67f323aebdf39` / `7a6d4cb075a67` updates the affected KUnit identity
fixture without changing the runtime path.

The warning-fatal clean-archive gate passed normal and KASAN/fault-injection
profiles on 6.18 `67f323aebdf39` and mainline `7a6d4cb075a67`, including both
IOMMU providers, both rewrite objects with KUnit, and the ROCK 5B DTB.

## Boundary

This is source-root-caused and compile-verified, not runtime-verified. The new
6.18 KASAN package must be booted and the same GStreamer parallel roundtrip
replayed with zero `rga:iommu_fault_count` and `rga:irq_error_count` deltas
before the fix can be called hardware-verified.
