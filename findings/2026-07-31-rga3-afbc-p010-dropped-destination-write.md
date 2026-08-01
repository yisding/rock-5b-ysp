# RGA3 AFBC NV15→P010 returns success without writing the destination at small picture sizes

> Scope: RGA rewrite driver (`drivers/video/rockchip/rga-rewrite/rga_rewrite.c`)
> on the RGA3 AFBC-source path, as exercised by `rockchip-vaapi`'s 10-bit
> decode conversion (`src/convert.c` `rk_convert_nv15_to_p010()`, a blocking
> `improcess(..., IM_SYNC)`), and therefore by every HEVC Main10 and VP9
> Profile 2 hardware decode.
> Source: booted `6.18.41-video-rewrite-kasan-rockchip64 #23`, kernel identity
> `~/Code/rock-5b/kernel/linux @ 75a34815b132a`; suspect commit `995a0aa710fb2`
> ("rga-rewrite: add RGA2 multi-SG MMU", 887 insertions) in the same window.
> Userspace `librga2 2.2.0+git20260725.26a50ef-0ubuntu1~rk1`,
> `librockchip-mpp1 1.5.0+git20260729.3381fd2c+ds-0ubuntu1~rk1`.
> Date: 2026-07-31
> Trust: MEASURED (1,248 hash-compared frames across three geometries) +
> LAYER-ISOLATED (destination-buffer identity correlation, below) +
> SOURCE-INSPECTED (rewrite and vendor job paths, rockchip-iommu) +
> **PARTIAL-ROOT-CAUSE** (a vendor-divergent power/IOMMU ordering found and
> several competing mechanisms eliminated; the mechanism is not closed) +
> **NOT BISECTED** (never tested on `#21` or the production kernel)

## Result

On this kernel, an RGA3 AFBC-NV15 → linear-P010 blit **intermittently returns
`IM_STATUS_SUCCESS` from a synchronous `improcess()` without writing the
destination buffer at all**. The failure is silent at every layer: MPP reports
no `errinfo`/discard, librga reports no error, and the driver's own audit
counts the expected number of conversions (48/48 in every run below).

The destination is simply left holding whatever it held before:

- **Recycled destination buffer** → the output frame is *bit-exact* the
  content of the previous frame that used the same destination fd.
- **Freshly allocated destination buffer** → the output frame is **entirely
  zero** (299,520 of 299,520 bytes at 416x240).

Measured with `testsrc2` Main10, 48 frames, no B-frames (so decode order equals
display order), each hardware run compared byte-for-byte against the software
P010 reference:

| Geometry | P010 frame bytes | Runs affected | Frames wrong | Zeroed | Stale-previous |
|---|---:|---:|---:|---:|---:|
| 416x240 | 299,520 | 6/10 | 24/480 (5.00%) | 8 | 16 |
| 320x240 | 230,400 | 3/8 | 5/384 (1.30%) | 1 | 4 |
| 1280x720 | 2,764,800 | **0/8** | 0/384 | 0 | 0 |

1280x720 is additionally clean across roughly 1,500 further hash-verified
frames decoded the same day by the Main10 reducer.

### Why this is the destination write, not decode and not the source

Every wrong frame was matched against the whole software reference set and
against the driver's `assign_mpp_frame` log, which records both the **source**
external-pool index and the **destination** (converted) buffer fd per frame.
**All 24 wrong frames at 416x240 attribute to a dropped destination write with
no exceptions and none unattributed** — including two chained cases where the
same destination buffer was skipped twice in a row and still held a frame from
two skips earlier. Without exception:

```
same_convfd = True      # matches the previous frame that used this destination fd
same_pool   = False     # the source pool buffer differs
```

Example (run 8): `out28 == sw23` with destination `conv_fd=64` previously used
by output 23, while the source pool indices were 4 and 23 respectively. If the
*source* AFBC buffer were being read before MPP finished writing it, the stale
content would follow the source pool index; it never does. The AFBC decode
output is therefore fine and the conversion's destination write is what goes
missing. The all-zero fresh-buffer case rules out a CPU cache-coherency
explanation for the readback — a never-written dma-heap page is what zeros
look like, and the driver already brackets CPU access with dma-buf sync.

An 8-bit NV12 control at the same 416x240 geometry — same decoder, same
external pool, same readback, but **no RGA in the path** — is clean 8/8 runs
(384/384 frames), which is the other half of the isolation.

### A second, loud symptom of the same path

One `make check-hevc-main10-experimental` run instead produced repeated
*kernel-level* RGA submit rejections on the same conversion, userspace
reporting EIO:

```
E im2d_rga_impl: Failed to call RockChipRga interface
E librga: src | afbc16x16( 0x2) | 0, 4, 416, 240 | 416, 240, 448, 256 | nv12_10(0x2000)
E librga: dst |    raster( 0x1) | 0, 0, 416, 240 | 416, 240, 448, 256 | nv12_10(0x2000)
```

Same geometry, same job shape. Whether the loud refusal and the silent
no-write share a cause is not established, but they appeared in the same
session on the same path and should be triaged together.

## Boundary

- **Not bisected.** Every measurement here is on `#23`. It is *not* established
  that this is a regression, nor that `995a0aa710fb2` introduced it. The
  failure could predate the rewrite kernel entirely — prior `rockchip-vaapi`
  10-bit qualification used 320x240 and 416x240 vectors that pass most runs, and
  a 1-in-20-to-1-in-75 frame failure rate is exactly the density a single-run
  gate misses. Several previously recorded "bit-exact" Main10 results were
  single runs and should be treated as unconfirmed at these sizes.
- The mechanism *inside* the RGA driver is unidentified. `995a0aa710fb2` is a
  suspect because it landed in this window, it rewrote the shared DMA-BUF
  import and mapping helpers (`rk_rga_check_dma_sgt()`,
  `rk_rga_import_dmabuf_object()`, `rk_rga_job_map_import()`,
  `rk_rga_job_prepare_hw_mappings()`, `rk_rga_job_rebase_img_to_hw()`) and
  `rk_rga3_emit_simple_bitblt()` — i.e. it is not RGA2-only despite its subject
  line — and its own finding records it as
  [RUNTIME-UNVERIFIED for fragmented DMA-BUFs](2026-07-31-rga-rewrite-multisg-dmabuf-cma-einval.md).
  That is motive and opportunity, not evidence.
- Size dependence is measured but not explained by anything observed. The
  candidate explanations are discussed under Root-cause investigation; none is
  confirmed.
- Only RGA3 AFBC→P010 was exercised. RGB→NV12 encode input and the 8-bit NV12
  export repack use the same `improcess` entry point and were not tested for
  dropped writes.

## Root-cause investigation (2026-07-31, second pass)

Not closed. The layer is certain; the mechanism is narrowed to one named
divergence from the vendor driver, with several competing explanations
eliminated by source inspection.

### The write never reaches DRAM — it is not a readback artifact

All 24 wrong frames were *wholly* stale or *wholly* zero. CPU cache staleness
operates at 64-byte line granularity and would produce frames mixing fresh and
stale lines; not one such frame occurred. The `vaGetImage` path also brackets
its read with `DMA_BUF_IOCTL_SYNC(START|READ)`
(`src/surface.c` `rk_GetImage()`), and the conversion destination is a
`MPP_BUFFER_TYPE_DRM` buffer whose CPU mapping is write-combine. The data
genuinely never lands.

### Eliminated by source inspection

Recording these so they are not re-derived:

- **Incomplete TLB invalidation on unmap.** `rk_iommu_unmap()`
  (`drivers/iommu/rockchip-iommu.c`) zaps the *full* unmapped range
  (`rk_iommu_zap_iova(rk_domain, iova, unmap_size)`), not just first/last.
- **Missing `iotlb_sync`.** The rockchip domain ops genuinely omit
  `.iotlb_sync`, so the IOMMU core's post-unmap sync is a no-op — but this is
  by design, because the zap happens inside `rk_iommu_unmap()` itself.
- **Command-buffer publication race.** The CMD buffer is `dma_alloc_coherent`
  and every register write goes through `writel()`, which carries an implicit
  barrier on arm64. Ordering before the doorbell is sound.
- **Treating `CMD_LINE_FINISH` as completion.** The rewrite's
  `RK_RGA3_INT_DONE_MASK` is `FRM_DONE | CMD_LINE_FINISH`, which looked like
  early completion — but the vendor does exactly the same
  (`rga3_reg_info.c` `rga3_irq()`, `m_RGA3_INT_FRM_DONE |
  m_RGA3_INT_CMD_LINE_FINISH`). Not a divergence.
- **Per-core IOMMU confusion.** RK3588 has two RGA3 cores with separate
  IOMMUs, but both mapping-reuse checks in `rk_rga_job_map_import()` are
  correctly keyed on `hw`.
- **A faulting write.** `RK_RGA3_INT_RGA_MI_WR_BUS_ERR` is in the enabled error
  mask and no error interrupt was ever reported, so the write was not
  rejected — the engine either wrote elsewhere or never wrote.

### The divergence that remains: IOMMU work while the power domain is gated

The vendor driver powers the domain **before** mapping and documents why
(`rga_job.c` `rga_job_commit()`):

```c
	/* Memory mapping needs to keep pd enabled. */
	ret = rga_power_enable(scheduler);
	...
	ret = rga_mm_map_job_info(job);
```

The rewrite inverts this at **both** ends of the job:

```c
/* rk_rga_backend_start(), rga_rewrite.c:23036-23043 */
	ret = rk_rga_job_prepare_hw_mappings(hw, job);   /* iommu_map_sg() */
	...
	ret = rk_rga_hw_power_on(hw);                    /* power AFTER the map */

/* completion path, rga_rewrite.c:23138-23148 */
	rk_rga_hw_power_off(hw);                         /* pm_runtime_put_sync() */
	...
	rk_rga_job_clear_mappings(job);                  /* iommu_unmap() AFTER */
```

This matters because the rockchip IOMMU's shootdown is silently conditional on
the IOMMU being powered — it shares the RGA core's power domain:

```c
/* rk_iommu_zap_iova(), drivers/iommu/rockchip-iommu.c */
		/* Only zap TLBs of IOMMUs that are powered on. */
		ret = pm_runtime_get_if_in_use(iommu->dev);
		if (WARN_ON_ONCE(ret < 0))
			continue;
		if (!ret)
			continue;
```

The rewrite also uses `pm_runtime_put_sync()` with **no autosuspend anywhere in
the driver**, so the domain is gated after every single job. Both the map-time
first/last zap and the unmap-time full-range zap are therefore skipped on every
job, and the IOVA allocator (`alloc_iova_fast`/`free_iova_fast`) hands the same
addresses straight back.

**Why this is a lead and not a conclusion:** `rk_iommu_resume()` →
`rk_iommu_enable()` issues `rk_iommu_force_reset()` and
`RK_MMU_CMD_ZAP_CACHE` on every runtime resume, which should clear any stale
TLB before the job runs. For the skipped zaps to actually bite, that resume
must not be happening as assumed — e.g. the IOMMU not truly suspending
between jobs, or the device link not ordering its resume ahead of the RGA's
DMA. Settling that needs the counters below, which need root.

Size dependence is consistent with a stale-translation story (a 675-page 720p
mapping floods a small TLB and self-evicts stale entries; a 57-84-page mapping
does not), but that is a hypothesis, not a measurement.

### Fix applied (2026-07-31, not yet boot-validated)

The ordering is corrected on both rewrite tips — `0fa40902df66b`
(`rk3588-rewrite-6.18`) and byte-identical `d530e4ba31ee8`
(`rk3588-rewrite-mainline`). The forward-port tree carries only the vendor
`rga3` driver, which already has the correct ordering, so it needs no change.

- `rk_rga_backend_start()` powers the core **before**
  `rk_rga_job_prepare_hw_mappings()`, and powers back off if mapping fails.
- The IRQ thread, the timeout path, and both abort paths release the job's
  mappings **before** `rk_rga_hw_power_off()`, through a new
  `rk_rga_job_release_mappings_powered()` helper that also completes the
  userptr sync-for-CPU first. All four sites already ran their recovery reset
  beforehand, so nothing is unmapped from under live hardware.

`rewrite-build-gate.sh` passes both trees in the `normal` and `test-disabled`
profiles, with the byte-identity and KUnit-manifest checks green.

**This is the ordering fix, not a proven cure.** It restores an invariant the
vendor documents and that this driver violated, but the measurement in
§Root-cause investigation showed `rk_iommu_resume()` issues `ZAP_CACHE`, which
in theory already covered the skipped zaps. If the 416x240 harness still fails
on the rebuilt kernel, the ordering was a real bug but not this bug, and step 1
below becomes the next move.

### Next steps, in order of decisiveness

1. **Read the driver's own counters during a failing run** (needs root, debugfs
   is `0700`):
   ```sh
   sudo grep . /sys/kernel/debug/rk_rga_rewrite/{irq_error_count,irq_spurious_count,timeout_count,power_cycle_count,iommu_refresh_count}
   ```
   Sample before and after the 416x240 harness. A nonzero `timeout_count` or
   `irq_spurious_count` would redirect this to completion detection and away
   from the IOMMU entirely.
2. **Test the ordering hypothesis without a kernel rebuild:** pin the RGA
   devices runtime-active so the domain never gates, then re-run the harness.
   ```sh
   for d in /sys/bus/platform/devices/*rga*/power/control; do echo on | sudo tee $d; done
   ```
   Failures vanishing implicates the power/IOMMU ordering directly.
3. **Fix and rebuild:** move `rk_rga_hw_power_on()` above
   `rk_rga_job_prepare_hw_mappings()` and `rk_rga_job_clear_mappings()` above
   `rk_rga_hw_power_off()`, matching the vendor. This is worth doing regardless
   of whether it cures this bug — it restores an invariant the vendor
   documents.

## Verification gate

The smallest discriminating run, and the one that would settle the regression
question: boot `#21 g06ab78b69615` (or the production `6.18.40-ysp` kernel) and
re-run the 416x240 harness below. Ten runs, byte-compared. Clean there and
dirty on `#23` bisects it to this three-commit window; dirty on both means the
defect predates the rewrite kernel and every small-geometry 10-bit result on
record needs re-qualifying.

## Evidence and reproduction

- **Exercise:**
  ```sh
  ffmpeg -f lavfi -i "testsrc2=size=416x240:rate=24" -frames:v 48 \
    -vf format=yuv420p10le -c:v libx265 -profile:v main10 \
    -x265-params bframes=0 -f hevc nob416.h265
  /usr/bin/ffmpeg -c:v hevc -i nob416.h265 -vf format=p010le \
    -fps_mode passthrough -f rawvideo nob.sw.p010

  for i in $(seq 1 10); do
    RK_VAAPI_EXPERIMENTAL_PROFILES=hevc-main10 LIBVA_DRIVER_NAME=rockchip \
    LIBVA_DRIVERS_PATH=<driver-dir> RK_VAAPI_LOG=nob-$i.driver.log \
      /usr/bin/ffmpeg -hwaccel vaapi -hwaccel_output_format vaapi \
      -vaapi_device /dev/dri/renderD128 -i nob416.h265 \
      -vf 'hwdownload,format=p010le' -fps_mode passthrough \
      -f rawvideo nob-$i.p010
    cmp -s nob.sw.p010 nob-$i.p010 || echo "run$i: STALE"
  done
  ```
- **Pass/fail signal:** byte-identical raw P010. Do **not** use `-f hash` over
  the whole stream alone — it detects the failure but hides that the wrong
  frames are whole recycled frames. `framemd5` plus the destination-fd
  correlation is what identifies the layer.
- **Analysis:** `hevc-reducer/attrib-20260731/analyze-dropped-writes.py` in the
  driver work tree reproduces the correlation table from a run's `.p010` output
  and `.driver.log`.
- **Artifacts:** `hevc-reducer/attrib-20260731/` (raw P010 captures, driver
  logs, the failing `check-hevc-main10-experimental` output with the librga
  EIO dump).

## Why it matters

This is a silent-wrong-output defect on a shipping-candidate path, which is
strictly worse than the loud one it was found while requalifying. It blocks
Main10/VP9-Profile-2 promotion on this kernel, and because a stale frame is a
*plausible-looking* previous frame rather than visible garbage, it would reach
a browser as an intermittent stutter rather than an obvious fault. It also
means `rockchip-vaapi`'s 10-bit gates need repeat-run structure at small
geometries before any of them can be called green again.
