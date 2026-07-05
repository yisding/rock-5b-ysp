# RGA3 MMU interrupt on direct im2d samples: RGA DMA/IOMMU IOVA contract gaps

> Scope: forward-port kernel `../kernel/linux-6.18-rkvenc-av1-fwport` branch
> `rkvenc-fwport-6.18`, RGA driver `drivers/video/rockchip/rga3/`,
> Rockchip IOMMU provider `drivers/iommu/rockchip-iommu.c`
> Source: on-board debugfs run of prebuilt `airockchip/librga` IM2D samples from
> `../rockchip-conformance/out/librga-samples/bin/`, plus BSP-vs-forward source
> comparison against `../kernel/rockchip-kernel`
> Date: 2026-07-04
> Trust: MEASURED (symptom and fault addresses); ROOT-CAUSED (source deltas);
> FIX IN TREE (runtime validation pending after next rebuild)

## Summary

The direct upstream librga samples initially looked like either bad/outdated
tests or a vague RGA3 + IOMMU forward-port gap. They are real forward-port
bugs in the DMA/IOMMU contract that the vendor RGA driver assumes:

- The failing samples import malloc-backed userspace buffers with
  `importbuffer_virtualaddr()`, not dma-heaps.
- RGA pins those pages, builds an sg-table, calls `dma_map_sg()`, then programs
  only `sg_dma_address(sgt->sgl)` into RGA registers while treating the sum of
  all sg lengths as one contiguous IOVA span.
- The BSP Rockchip IOMMU driver explicitly allows a single huge DMA segment for
  each attached device with `dma_set_max_seg_size(dev, DMA_BIT_MASK(32))`.
- The forward kernel lost that device DMA contract in
  `rk_iommu_probe_device()`.
- Without it, `dma_map_sg()` can leave the mapped buffer as multiple DMA
  segments. RGA then walks past the first segment into unmapped IOVA pages and
  raises `INTR[0x2]`, the RGA MMU interrupt.
- After rebuilding with the segment-size fix, validation still failed because
  the generic IOVA allocator could place an RGA mapping at the very top of the
  32-bit aperture, for example `iova = 0xfffff010` for a 3.5 MiB RGBA buffer.
  RGA register generation then added plane/stride offsets in 32-bit registers
  and wrapped into low IOVA addresses such as `0x00000410`, which were not part
  of the mapping.

Forward-kernel fixes:

```text
../kernel/linux-6.18-rkvenc-av1-fwport
13afe70c8271 iommu: rockchip: restore large DMA segment support
6b9dba7abcd0 video: rockchip: rga: keep IOVAs below 32-bit wrap guard
uncommitted     video: rockchip: rga: reject unsafe DMA/IOMMU mappings cleanly
```

The first commit restores the BSP `dma_parms` allocation and
`dma_set_max_seg_size(dev, DMA_BIT_MASK(32))` in the mainline Rockchip IOMMU
provider. The second commit caps RGA IOMMU mappings with a 512 MiB guard band
below the 32-bit IOVA ceiling by lowering the RGA mapping device's
`bus_dma_limit`. That keeps the hardware-visible base plus typical plane offsets
away from 32-bit wrap.

The current defensive fix also makes the implicit driver/hardware contract
explicit at import time: RGA rejects and logs any mapping where the DMA API does
not return exactly one nonzero segment whose complete IOVA span fits inside
32 bits. MPP dma-buf imports now apply the same contract because those drivers
also pass one IOVA/size pair to hardware. This is intentionally fail-closed for
now; if hardware validation shows frequent rejections from legitimate users, the
next design step is a driver-owned contiguous staging/allocation fallback.

The touched objects build and the diffs pass `checkpatch`; runtime validation is
pending after rebuilding, installing, rebooting, and rerunning the diagnostic
script below.

## Reproducer / Diagnostic Script

The support repo now carries a focused runner:

```bash
sudo bash kernel-drivers/tests/rga-mmu-debug.sh
```

The script:

- checks `/dev/rga` and `/sys/kernel/debug/rkrga`;
- idempotently enables RGA `reg msg int mm time` debug flags and restores their
  original state on exit;
- runs `rga_copy_demo`, `rga_resize_rect_demo`, and
  `rga_transform_rotate_demo`;
- writes `/dev/kmsg` markers around each case;
- captures per-case stdout/stderr, full dmesg before/after, filtered
  RGA/IOMMU/MMU dmesg, dmesg tail, and debugfs snapshots;
- treats the upstream samples' "printed fatal error but exit 0" behavior as
  `fail-output` instead of pass.

The run that found the bug was:

```text
../rockchip-conformance/logs/rga-mmu-debug/20260704-102533
kernel: Linux rock-5b 6.18.37-current-rockchip64 #8
librga: rga_api version 1.10.6_[3]
```

The board had `/sys/kernel/debug/rkrga/{debug,driver_version,hardware,load,
mm_session,request_manager,reset,scheduler_status}`. The `hardware` debugfs
file reported:

```text
rga3 core 1: mmu: RK_IOMMU
rga3 core 2: mmu: RK_IOMMU
rga2 core 4: mmu: RGA_MMU
```

So these failures are specifically on the RGA3 + Rockchip IOMMU path, not the
legacy RGA2 internal MMU path.

## Measured Fault Evidence

All three samples selected `RGA3_core0`, whose IOMMU is `fdb60f00.iommu`.
The sample programs returned process status `0`, but their stdout/stderr printed
fatal librga errors and the kernel logs showed RGA request failure.

| Case | Mapped buffer evidence | Fault evidence | Interpretation |
|------|------------------------|----------------|----------------|
| `rga_copy_demo` | src handle `7`: `iova = 0xfff7e010`, `size = 3686400`, `map_core = 0x1`; dst handle `8`: `iova = 0xff000010`, same size | `Page fault at 0x00000000fff85810 of type read`; `pte ... valid: 0`; `INTR[0x2]`, `HW_STATUS[0xaaaaa]`; `RGA3_core0[0x1] soft reset complete` | Fault is inside the logical src range, only about `0x7800` bytes after the programmed base. That points at a fragmented DMA mapping, not bad dimensions. |
| `rga_resize_rect_demo` | src handle `9`: `iova = 0xff400010`, `size = 3686400`; dst handle `10`: `iova = 0xffe79010`, `size = 8294400`; RGA programmed `wr: y = ffe79010 ... vw = 1920 vh = 1080` | `Page fault at 0x00000000fff78010 of type write`; invalid PTE; `INTR[0x2]`, `HW_STATUS[0x5aaaa]` | Fault is inside the logical dst range. Again, RGA walked into an unmapped page inside what the driver believed was one buffer. |
| `rga_transform_rotate_demo` | src handle `11`: `iova = 0xffcef010`, `size = 3686400`; dst handle `12`: `iova = 0xfff26010`, `size = 3686400` | `Page fault at 0x0000000000071c10 of type read`; invalid DTE/PTE; `INTR[0x2]`, `HW_STATUS[0xaaaaa]` | This one also shows 32-bit wrap because the logical src range crosses 4 GiB. The copy/resize faults already occurred before wrap, so wrap is a symptom amplifier, not the root cause. |

The important common pattern is not "address above 4 GiB"; it is "RGA programs
a single base address and then faults inside the buffer range because the IOMMU
page table does not contain a contiguous mapping for that whole range."

## Follow-up Validation: Segment Fix Was Necessary But Insufficient

After rebuilding and installing `P60c0-Cb831`
(`6.18.38-current-rockchip64 #9`), the generated Armbian userpatch set did
contain:

```text
rk3588-av1-fwport-0013-iommu-rockchip-restore-large-DMA-segment-support.patch
```

Rerunning the diagnostic still failed:

```text
../rockchip-conformance/logs/rga-mmu-debug/20260704-192122
kernel: Linux rock-5b 6.18.38-current-rockchip64 #9

case                         result
rga_copy_demo                fail-exit
rga_resize_rect_demo         fail-output
rga_transform_rotate_demo    fail-output
```

The new run exposed the remaining IOVA-wrap part of the bug:

- `rga_resize_rect_demo` imported a 3.5 MiB source at `iova = 0xfffff010`.
  RGA programmed `0x0110 : fffff010 000e0010 00118410 ...`, i.e. source plane
  offsets wrapped below 4 GiB, and the Rockchip IOMMU faulted at
  `0x0000000000000410`.
- `rga_transform_rotate_demo` imported a 3.5 MiB source at
  `iova = 0xffb60010`, then faulted inside the advertised source range at
  `0x00000000ffed7810`; the same job ended with `INTR[0x2]`,
  `request commit failed!`, and `submit failed!`.

This changed the conclusion: restoring the BSP segment-size contract is
necessary, but the forward RGA/IOMMU integration must also prevent top-of-32-bit
IOVA placement for RGA3 because the vendor register path uses 32-bit base-plus-
offset arithmetic.

## How The Source Comparison Found The Cause

The RGA3 driver source did not contain a material BSP-vs-forward delta in the
paths involved here. The relevant RGA behavior is the same:

- `rga_dma_map_sgt()` calls `dma_map_sg(map_dev, sgt->sgl, sgt->orig_nents, dir)`;
- it stores only `sg_dma_address(sgt->sgl)` as `buffer->dma_addr`;
- it sums every sg entry's `sg_dma_len()` into `buffer->size`;
- register generation then programs `win0` / `wr` image base registers from that
  one base address.

That RGA design depends on the DMA layer returning one contiguous IOVA segment
for the whole buffer.

The BSP IOMMU driver has the missing contract in `rk_iommu_probe_device()`:

```c
/* set max segment size for dev, needed for single chunk map */
if (!dev->dma_parms)
	dev->dma_parms = kzalloc(sizeof(*dev->dma_parms), GFP_KERNEL);
if (!dev->dma_parms)
	return ERR_PTR(-ENOMEM);

dma_set_max_seg_size(dev, DMA_BIT_MASK(32));
```

The forward-port IOMMU provider lacked that block. Restoring it makes the
forward IOMMU provider match the vendor expectation that RGA and similar media
clients may map a whole 32-bit IOVA aperture as one DMA segment.

The follow-up failure was not from an RGA source delta either; BSP and forward
RGA both set a 40-bit streaming DMA mask for RGA3 and both program 32-bit RGA
register addresses. The practical difference is the forward port's modern
generic DMA/IOMMU path, which can allocate RGA IOVAs at the very end of the
32-bit aperture. The first forward fix is therefore local to the RGA probe path:
preserve the 40-bit DMA mask but set a lower `bus_dma_limit` for RGA IOMMU
mappings so the DMA API allocator has a 512 MiB guard band below `0xffffffff`.
The final defensive fix is in the common RGA DMA mapping helpers: after
`dma_map_sg()` or `dma_buf_map_attachment_unlocked()`, validate that the returned
DMA mapping is one contiguous, nonzero, non-wrapping 32-bit IOVA span before
programming it into RGA registers.

## What This Is Not

This is separate from the missing `dma32_heap` sample failures.

`rga_fill_rectangle_demo` and `rga_cvtcolor_csc_demo` fail earlier because they
ask userspace for `/dev/dma_heap/dma32_heap`, which this standard 6.18 kernel
does not expose. Rockchip DMA32 heaps mean "allocate memory suitable for devices
with a 32-bit DMA address window"; they are not for 32-bit ARM userspace
applications. That is a BSP ABI/sample-compatibility gap, not the cause of the
RGA3 MMU interrupt above.

This is also not explained by the forward-port guard around
`iommu_set_fault_handler()` on DMA-cookie domains. That affects diagnostic fault
callback registration/recovery plumbing. The fault here is caused before that:
RGA is given a single base address for a mapping that is not actually contiguous
for the full logical buffer size.

## Validation State

Done:

- Captured RGA debugfs logs and IOMMU fault lines on hardware.
- Matched the faulting IOVA to RGA's imported handle IOVA and programmed
  register bases.
- Compared BSP and forward RGA3 source and found no material RGA-side delta.
- Compared BSP and forward Rockchip IOMMU source and found the missing
  `dma_set_max_seg_size()` contract.
- Rebuilt/booted `P60c0-Cb831` with `13afe70c8271`; confirmed the direct RGA
  samples still failed, now clearly showing high-end 32-bit IOVA wrap.
- Patched, built, checkpatched, committed, and pushed the initial segment-size
  and RGA guard-band fixes.
- Added explicit RGA and MPP DMA/IOMMU contract checks that reject unsafe
  non-single-segment or 32-bit-wrapping mappings with kernel logs instead of
  allowing hardware to fault later.
- Ran adversarial subagent review of the provider/RGA/MPP IOMMU delta. The final
  review found no remaining forward-port correctness bugs in scope after the
  slice-mode wait fix documented in `kernel-drivers/iommu/docs/mpp-ccu-iommu-plan.md`.

Still pending:

1. Rebuild/install/reboot the forward kernel containing the current
   RGA/MPP contract-check delta.
2. Rerun:
   ```bash
   sudo env RGA_FAIL_ON_CASE_FAILURE=1 bash kernel-drivers/tests/rga-mmu-debug.sh
   ```
3. Expected result: the three samples no longer print fatal librga errors, no
   `rk_iommu fdb60f00.iommu: Page fault ...` appears between the per-case kmsg
   markers, and no `RGA3_core0 INTR[0x2]` / `rga intr error[0x2]` occurs.
4. If it still faults, add temporary RGA mapping logs for `dma_map_sg()` return
   count, first sg length, all mapped segment DMA ranges, `dma_get_mask()`,
   `dev->bus_dma_limit`, and `dma_get_max_seg_size()` for the actual `map_dev`.
