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
> SOURCE-INSPECTED (suspect commit's touched functions) + **NOT BISECTED**
> (never tested on `#21` or the production kernel) + HYPOTHESIS (the specific
> mechanism inside the RGA driver)

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
- Size dependence is measured but unexplained. Both a fragmentation story
  (small buffers land in multi-segment scatter-gather) and a timing story
  (small frames submit jobs ~9x more often, opening a race) fit the data.
  Nothing here distinguishes them.
- Only RGA3 AFBC→P010 was exercised. RGB→NV12 encode input and the 8-bit NV12
  export repack use the same `improcess` entry point and were not tested for
  dropped writes.

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
