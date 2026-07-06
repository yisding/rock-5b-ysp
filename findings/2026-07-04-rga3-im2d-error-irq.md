# RGA3 MMU interrupt on direct im2d samples: RGA DMA/IOMMU IOVA contract gaps

> Scope: forward-port kernel `../kernel/linux-6.18-rkvenc-av1-fwport` branch
> `rkvenc-fwport-6.18`, RGA driver `drivers/video/rockchip/rga3/`,
> Rockchip IOMMU provider `drivers/iommu/rockchip-iommu.c`
> Source: on-board debugfs run of prebuilt `airockchip/librga` IM2D samples from
> `../rockchip-conformance/out/librga-samples/bin/`, plus BSP-vs-forward source
> comparison against `../kernel/rockchip-kernel`
> Date: 2026-07-04 (updated 2026-07-05)
> Trust: MEASURED (symptom and fault addresses); ROOT-CAUSED (source deltas);
> RUNTIME-VALIDATED 2026-07-05 — the MMU IRQ is gone and the contiguous-buffer
> path runs clean; scattered `virt_addr` imports are now cleanly fail-closed
> **by design** (see the 2026-07-05 section). Related: [[2026-07-04-librga-consumer-survey]]

> Update 2026-07-05: candidate RGA userptr-IOMMU fallback patches now exist under
> `kernel-drivers/patches/rga-userptr-iommu/`; see
> `findings/2026-07-05-rga3-userptr-iommu-design.md`. They are static/build verified,
> but the RK3588 runtime gate described there is still pending.

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
590c9ef297ce media: rockchip: harden IOMMU forward port   (the fail-closed reject; was "uncommitted" above)
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

## 2026-07-05 Runtime Validation: Fix Confirmed; Scattered virt_addr Is Fail-Closed By Design

Runtime validation (the pending item from 2026-07-04) is done, on
`6.18.38-current-rockchip64 #10` (runs
`../rockchip-conformance/logs/rga-mmu-debug/20260704-233927` and
`20260705-000005`). Note the sample harness now redirects the librga demos' raw
`.bin` fixtures off the hardcoded Android `/data` path to a user-writable dir via
`$RGA_SAMPLE_DATA_DIR` (patched into the vendored librga at
`kernel-drivers/tests/conformance/patches/airockchip-librga/0001-sample-data-dir-env-override.patch`,
re-applied by `bootstrap-workspaces.sh`), and stages the 1280x720 RGBA fixture
the copy/resize/rotate cases consume.

**The IOMMU/DMA fix works.** The `INTR[0x2]` MMU interrupt / page fault / soft
reset is gone. Programmed IOVAs land well below the 32-bit wrap guard (e.g.
`0xde800010`, `0xdec00010`), confirming `6b9dba7abcd0`. `rga_resize_rect_demo`
ran four real hardware jobs to completion (`finished 1 failed 0` five times,
output written) — the contiguous-buffer path is clean.

**But the fail-closed check now rejects scattered malloc buffers, and that is
by design.** For `importbuffer_virtualaddr()` imports, success depends on the
*physical contiguity* of the specific malloc'd buffer:

- copy/rotate first buffer: `orig_nents = 341` (ordinary fragmentation of a
  3.6 MB / 900-page buffer) → `reject sg_table DMA mapping: expected one DMA
  segment, got 341` (`-EOPNOTSUPP`) → userspace prints `importbuffer failed!`.
- resize, and copy's second buffer: happened to be physically contiguous
  (`orig_nents = 1`) → passed.

So the pass/fail split across cases is **allocation luck, not a regression**.
The check is doing exactly its job: turning a would-be MMU fault into a clean
reject. 341 is not "a lot" — it is normal fragmentation; the relevant fact is
that it is not 1.

### Step 0 (raise `max_seg_size` so `dma_map_sg` coalesces) is already in-tree and PROVEN INSUFFICIENT

The obvious cheap fix — make `dma_map_sg()` fold the scattered runs into one
IOVA by lifting the segment-size cap — is exactly what `13afe70c8271` already
does (`dma_set_max_seg_size(dev, DMA_BIT_MASK(32))` in `rk_iommu_probe_device()`).
Proof it was **active** during the 341-segment run, despite an unreliable build
timestamp:

- the `reject sg_table DMA mapping` string was introduced in `590c9ef297ce`;
- `git merge-base --is-ancestor 13afe70c8271 590c9ef297ce` → true;
- the booted kernel emitted that string ⟹ it contains `590c9ef` ⟹ it contains
  `13afe70` ⟹ `max_seg_size = 4 GB` was in effect.

Yet `dma_map_sg()` returned `nents == orig_nents == 341`. That is the decisive
signal: **zero merging occurred.** A segment-size cap can only *floor* merging
(a 64 KB cap would give ~57 output segments for this buffer; a 4 GB cap would
give 1) — `nents == orig_nents` means no merge was attempted at all, i.e.
`dma_map_sg()` is **not being serviced by the coalescing `iommu_dma_map_sg()`
path**. So `max_seg_size` is not the lever; re-applying it on the RGA device side
(tried, then reverted) cannot change the outcome.

> **Correction (2026-07-05 map-site DIAG):** an earlier version of this section
> called that the "direct/identity" path. The map-site diagnostic below refutes
> the *identity* part: the RGA map device is on a **translated** DMA-API IOMMU
> domain (`domain_type = 0x3 = IOMMU_DOMAIN_DMA`), not an identity/passthrough
> one. The buffer is being translated; it is just not being coalesced. See
> "### 2026-07-05 map-site diagnostic" below.

This fits the surrounding upstream history:
`9176a303d971 iommu/rockchip: Use IOMMU device for dma mapping operations` and
`4f0aba676735 iommu/rockchip: Use DMA API to manage coherency` shape the RGA's
`map_dev = scheduler->iommu_info->default_dev` path. On this platform, client
`dma_map_sg()` does not coalesce, so RGA3 is effectively physically-addressed and
requires physically-contiguous input.

### 2026-07-05 map-site diagnostic: domain is translated, not identity — Option 1 reopened (later eliminated by the use_dma_iommu probe)

The de-risking diagnostic recommended below was built (temporary forward-port
commit `eb0f3e209007`, "DIAG: log dma_map_sg non-coalescing for RGA3 imports")
and run on `6.18.38-current-rockchip64 #11`
(`../rockchip-conformance/logs/rga-mmu-debug/20260705-125811`). It logs, whenever
`dma_map_sg()` returns more than one segment, the effective `max_seg_size`, the
`orig_nents`/`nents` pair, and the device's IOMMU domain type. The one line it
emitted (on `rga_resize_rect_demo`'s scattered buffer) was:

```text
DIAG rga_dma_map_sgt: dev=fdb60000.rga max_seg_size=4294967295 orig_nents=254 nents=254 domain_type=0x3
```

Decoded against `include/linux/iommu.h`:

- `max_seg_size = 0xffffffff` — the 4 GB cap from `13afe70c8271` is active **on the
  actual map device** (`fdb60000.rga`), now measured directly rather than inferred
  from git ancestry. Not the lever.
- `orig_nents == nents == 254` — zero coalescing, same signature as the 341-segment
  run, just a different allocation draw.
- `domain_type = 0x3` = `__IOMMU_DOMAIN_PAGING | __IOMMU_DOMAIN_DMA_API` =
  `IOMMU_DOMAIN_DMA` — a **translated, paging, DMA-API-managed** domain. **Not**
  identity (`0x4`). This is the correction to the Step 0 wording above.

The key inference: the userptr sgt is built by `sg_alloc_table_from_pages()`
(`rga3/rga_mm.c:226`), which coalesces the 900 pages into 254 physically-contiguous
runs whose starts (after the first) are page-aligned. That shape is exactly what
`iommu_dma_map_sg()`'s merge pass (`__finalise_sg`, gated on `!s_iova_off`) is
built to fuse. A genuine `iommu_dma_map_sg()` on a translated domain with a 4 GB
seg cap would have collapsed all 254 runs into **one** IOVA segment. It returned
254. So the map is **not being serviced by the coalescing iommu-dma routine** even
though a DMA-type default domain is attached to the device.

Those are two separate facts: "a `IOMMU_DOMAIN_DMA` default domain exists" (what
`iommu_get_domain_for_dev()` reports) is *not* the same as "the DMA API routes this
device's scatter-maps through `iommu_dma_map_sg()`" (which is gated by
`dev->dma_iommu` / `use_dma_iommu()`, set from `iommu_is_dma_domain(domain)` during
dma-ops setup — `drivers/iommu/dma-iommu.c:2107`). The DIAG only measured the first.

**This reopened Option 1** as a candidate: if `fdb60000.rga` were simply not on the
generic coalescing iommu-dma path despite having a translated domain, routing it
there (a dma-ops-wiring fix) would make scattered userptr collapse for free. The
discriminator is one field: `use_dma_iommu(map_dev)`, added to the same DIAG:

- `false` → device is off iommu-dma despite the DMA domain ⟹ **Option 1**.
- `true` → `iommu_dma_map_sg()` runs yet still returns non-coalesced segments ⟹ a
  deeper issue — see the next section, which resolves this.

### 2026-07-05 use_dma_iommu probe: on iommu-dma AND the multi-segment return may be contiguous

Built `use_dma_iommu` into the DIAG (fixup `30102c8f769e`) and ran on
`6.18.38-current-rockchip64 #12` (`../rockchip-conformance/logs/rga-mmu-debug/20260705-142730`,
the `P4256-Cb831` build). The line:

```text
DIAG rga_dma_map_sgt: dev=fdb60000.rga max_seg_size=4294967295 orig_nents=332 nents=332 domain_type=0x3 use_dma_iommu=1
```

`use_dma_iommu=1` **eliminates Option 1** — the device *is* on the generic
iommu-dma path; `dma_map_sg()` dispatches to `iommu_dma_map_sg()`. There is nothing
to "route onto iommu-dma"; it is already there.

But reading `iommu_dma_map_sg()` (`../kernel/linux-6.18-rkvenc-av1-fwport/drivers/iommu/dma-iommu.c`)
reframes what the 332-segment return *means*. For a platform device like RGA the
swiotlb bounce sub-path is not taken (`dev_use_sg_swiotlb()` is untrusted-PCI /
unaligned-kmalloc only, `:603`), so the **normal path** runs:

- `iommu_dma_alloc_iova(domain, iova_len, …)` allocates **one** IOVA range for the
  whole buffer (`:1483`);
- `iommu_map_sg(domain, iova, sg, nents, …)` maps every page into it (`:1493`);
- `__finalise_sg()` then returns segment addresses that march monotonically from
  `iova` (`:1312`, `:1316`).

So the multi-segment return is **non-coalesced *reporting*, not a non-contiguous
*mapping*** — the underlying IOVA is one contiguous block `[iova, iova+iova_len)`.
If the returned segments abut (`addr[i]+len[i] == addr[i+1]`), then RGA's
`base = sg_dma_address(sgl)` + `size = Σ len` programming is **already safe**, and
the fail-closed `sgt->nents != 1` reject in `rga_dma_check_iova_contract()`
(`rga3/rga_dma_buf.c:28`) is rejecting buffers that would actually work.

**If that held, the fix would be "relax the check"** rather than RGA userptr-IOMMU fallback: generalise
the contract check from "exactly one segment" to "segments form one contiguous,
non-wrapping 32-bit IOVA span." That hypothesis was **inferred from generic code and
had to be measured** before relaxing a safety check — the original MMU fault proves
non-contiguity was real at some point. So a contiguity walk was staged in the DIAG
(fixup `171de4153e97`): in the `nents != 1` branch it logs
`contiguous=<0|1> gaps=<n> span=… end=…`.

### 2026-07-05 contiguity result: contiguous=0 — the reject is correct, "relax the check" is dead

Ran the contiguity build on `#13` (two runs, `20260705-151717` all-contiguous by
luck → passed, and `20260705-151723` fragmented → the interesting one). **Every
multi-segment mapping came back `contiguous=0`:**

```text
orig_nents=386 contiguous=0 gaps=9   first=0xdfd04010 span=0x17c000            end=0xdfe8000f
orig_nents=492 contiguous=0 gaps=68  first=0xdfebd010 span=0x89000             end=0xdff4600f
orig_nents=367 contiguous=0 gaps=306 first=0xdfe27010 span=0x96000            end=0xdfebd00f
orig_nents=895 contiguous=0 gaps=894 first=0xdffff010 span=0xffffffffffc7a000  end=0xdfc7900f
orig_nents=390 contiguous=0 gaps=367 first=0xdfd0d010 span=0xffffffffffc5f000  end=0xdf96c00f
```

Two things kill the "one contiguous span, just non-coalesced reporting" hypothesis:

1. **`gaps` is nonzero and large** (up to 894 of 895 — essentially every segment
   starts somewhere unexpected).
2. **`span=0xffffffff…` means `end < first`**: the last segment ends *below* where
   the first begins — the IOVAs run **backwards**. The generic normal path
   (`iommu_dma_alloc_iova` + `iommu_map_sg` + `__finalise_sg`) can only ever hand
   back *monotonically ascending* addresses tiling one allocation, so it is **not**
   what ran. The device is mapping scattered pages to scattered per-segment IOVAs
   (a per-segment / swiotlb-style path, not coalescing) — which refutes my
   generic-code reading from the previous section. This is exactly why we measured.

So RGA's `base + size` programming really would walk into unmapped/out-of-order
IOVA and fault. **The fail-closed `nents != 1` reject is correct**, and relaxing it
would reintroduce the original MMU interrupt. `contiguous=0` closes the cheap-fix
door.

### Consequence and recommendation

Every cheap lever is now eliminated **by measurement, not argument**: not
`max_seg_size` (maxed), not Option 1 (`use_dma_iommu=1`, already on iommu-dma), not
check-relaxation (`contiguous=0`, the mapping genuinely is not one span). The only
technical path that makes scattered `virt_addr` work on RGA3 is **RGA userptr-IOMMU fallback**:
allocate an IOVA range in a translated RGA domain, `iommu_map_sg()` the scatter into
it, program that one base, do explicit `dma_sync_sg_*`, and tear it down on release
— a few hundred lines, medium-high risk (it re-enters the manual-IOMMU territory the
fail-closed check was added to escape).

**Recommendation: accept the limitation.** RGA3 requires dma-buf /
physically-contiguous input; userptr imports otherwise route to the rga2 core
(`RGA_MMU`, its own page-table MMU, which handles scatter via
`rga_mm_set_mmu_base()`). Nothing in [[2026-07-04-librga-consumer-survey]] feeds
RGA3 raw userptr — real pipelines (GStreamer/MPP) normally hand RGA dma-buf fds from
suitable exporters, and the forward-port already validates those imports before
programming RGA3.

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

Done (2026-07-05, see the 2026-07-05 section above):

- Rebuilt/installed/rebooted the forward kernel with the full RGA/MPP
  contract-check delta (`6.18.38-current-rockchip64 #10`, contains
  `13afe70c8271` + `6b9dba7abcd0` + `590c9ef297ce`).
- Reran `kernel-drivers/tests/rga-mmu-debug.sh`: **no** `Page fault`, **no**
  `INTR[0x2]`, **no** soft reset. The MMU IRQ is fixed; the contiguous-buffer
  path runs clean (`rga_resize_rect_demo`: 4 jobs, `finished 1 failed 0`).
- Confirmed the remaining `importbuffer failed!` cases are the fail-closed
  reject of physically-*discontiguous* `virt_addr` buffers (`got 341 == orig_nents`),
  which is by-design, not a fault.
- Proved Step 0 (`max_seg_size`) is already in-tree and insufficient (ancestry
  proof + `nents == orig_nents` zero-merge signature).
- Built and ran the map-site diagnostic (`eb0f3e209007`) on
  `6.18.38-current-rockchip64 #11` (`20260705-125811`). Result:
  `dev=fdb60000.rga max_seg_size=0xffffffff orig_nents=254 nents=254
  domain_type=0x3`. Directly measured that the cap is maxed on the real map
  device and the domain is **translated** (`IOMMU_DOMAIN_DMA`), not identity —
  correcting the earlier "direct/identity path" wording and reopening Option 1.
- Built the `use_dma_iommu` field (fixup `30102c8f769e`) and ran on `#12`
  (`P4256-Cb831`, `20260705-142730`). Result adds `use_dma_iommu=1` (orig_nents =
  nents = 332). **Eliminates Option 1** — the device is already on the iommu-dma
  path. (Inferred from `iommu_dma_map_sg()` that the mapping was probably one
  contiguous IOVA span; the next probe refuted that.)
- Built the contiguity walk (fixup `171de4153e97`) and ran on `#13`
  (`20260705-151717` all-contiguous by luck → passed; `20260705-151723` fragmented).
  Result: **`contiguous=0` in every case** (gaps 9–894; two cases with `end < first`,
  i.e. IOVAs running backwards). The mapping is genuinely not one span — the
  generic normal-path inference was wrong; it is a per-segment/scattered mapping.
  **The `nents != 1` reject is therefore correct**, and check-relaxation is dead.

Investigation closed (not a bug):

1. Every cheap lever is eliminated by measurement: not `max_seg_size` (maxed), not
   Option 1 (`use_dma_iommu=1`), not check-relaxation (`contiguous=0`). Making
   scattered `virt_addr` work on RGA3 requires **RGA userptr-IOMMU fallback** (driver-owned
   `iommu_map_sg()` into a translated RGA domain) — pursue only if a concrete
   userptr-on-RGA3 consumer appears. Standing recommendation: **accept the
   dma-buf/contiguous-only limitation**; the fail-closed reject stays as-is.
2. The DIAG has served its purpose. Drop `eb0f3e209007` + its two fixups
   (`30102c8f769e`, `171de4153e97`) from `rkvenc-fwport-6.18` and rebuild a clean
   kernel (the fail-closed reject in `590c9ef297ce` is unaffected and remains).
