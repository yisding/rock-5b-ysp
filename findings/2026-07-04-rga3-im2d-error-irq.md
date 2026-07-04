# RGA3 core0 throws an error IRQ on some direct im2d copy/resize samples

> Scope: forward-port kernel `../kernel/linux-6.18-rkvenc-av1-fwport` (av1-fwport build, `/proc/mpp_service/version` = `6.18-rkvenc-fwport`), RGA driver `drivers/video/rockchip/rga3/`
> Source: on-board run of the prebuilt `airockchip/librga` IM2D samples (`../rockchip-conformance/out/librga-samples/bin/`) on kernel `6.18.37-current-rockchip64 #8`
> Date: 2026-07-04
> Trust: MEASURED (symptom); HYPOTHESIS (root cause — not yet isolated)

## The fact

Running the official librga IM2D sample binaries directly (not through
ffmpeg `scale_rkrga`), on the av1-fwport kernel:

- `rga_transform_rotate_demo` → **`running success!`** — RGA hardware + the full
  submit/IRQ/readback path work.
- `rga_copy_demo`, `rga_resize_rect_demo` → `Failed to call RockChipRga
  interface`. `dmesg` shows the real cause on the RGA3 side:
  ```
  rga: ID[1]: irq handler err! INTR[0x2], HW_STATUS[0xaaaaa], CMD_STATUS[0x1]
  rga: RGA3_core0[0x1] soft reset complete.
  rga: ID[1]: rga intr error[0x2]!  ... request commit failed! ... submit failed!
  ```
  i.e. RGA3 core0 raises the **error interrupt (`INTR[0x2]`)**, the driver
  **soft-resets the core and recovers**, and the *next* job (the transform demo)
  succeeds. So the reset/recovery path is healthy; specific RGA3 im2d
  copy/resize submissions fault.
- `rga_fill_rectangle_demo`, `rga_cvtcolor_csc_demo` → fail earlier, at buffer
  allocation: `alloc dma32_heap buffer failed!` / `alloc src dma_heap buffer
  failed!`. This kernel exposes only `/dev/dma_heap/{system,default_cma_region,
  reserved}` — there is **no `dma32_heap`** node the samples ask for. That is an
  environmental/sample-expectation mismatch, not an RGA fault.

Contrast: RGA *is* validated through ffmpeg `scale_rkrga` in `transcode-test.sh`
(1080p→720p / 720p→480p) and through `librga-smoke.sh`'s maintained im2d paths.
Those pass. Only the direct upstream copy/resize sample shapes fault here.

## Why it matters / follow-up

RGA is part of the forward-port, so a real RGA3 copy/resize regression would
matter — but this is **not yet root-caused**, and the validated userspace paths
(ffmpeg scale, librga-smoke) are clean, so it is most likely the samples driving
RGA3 with a format/stride/heap the fallback-allocated buffer doesn't satisfy
rather than a driver defect. Do not treat it as a confirmed regression.

Follow-up to isolate:
1. Re-run `rga_copy_demo`/`rga_resize_rect_demo` with `RGA_DEBUG` / the driver
   debugger (`echo 1 > /sys/kernel/debug/rkrga/*` if present) to dump the failing
   request (src/dst format, stride, core-mask). `INTR[0x2]` + `HW_STATUS[0xaaaaa]`
   is an RGA3 config/format error, not an IOMMU fault.
2. Force the op to RGA2 (`imconfig`/core-mask) to confirm whether it is
   RGA3-core-specific.
3. Compare the same sample binaries on the vendor 6.1 BSP kernel (golden
   reference) — if BSP RGA3 also errors on these exact samples, it is a
   sample/heap issue, not a forward-port regression.
4. `librga-suite.sh`'s required `ysp_librga_smoke` artifact case already dumps
   deterministic destination buffers for the maintained paths; extend it to the
   copy/resize sample shapes if this needs a byte-level gate.

Related: the missing `dma32_heap` is worth noting for anyone running the raw
upstream librga samples — rebuild them with a heap this kernel provides
(`system`) via `LOCAL_FILE_PATH`/allocator flags, or they fail before touching
RGA.
