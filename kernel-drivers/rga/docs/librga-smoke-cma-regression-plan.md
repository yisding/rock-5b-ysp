# librga handle-plane ABI compatibility regression

> Scope: RGA rewrite driver
> `drivers/video/rockchip/rga-rewrite/rga_rewrite.c`, specifically
> `rk_rga_resolve_img_handles_locked()`, and official librga sample result
> classification.
>
> Status: **ROOT-CAUSED** / **SOURCE-CONFIRMED** / **SOURCE-FIXED** /
> **FIX-COMPILE-VERIFIED** / **FIX-RUNTIME-VERIFIED** / **PARTIAL**.
>
> Observed on: `6.18.41-video-rewrite-kasan-rockchip64 #29`, boot source
> `rk3588-rewrite-6.18@8042f13c5459`, installed librga
> `2.2.0+git20260725.26a50ef-0ubuntu1~rk1`, conformance run
> `20260802-101933-librga-suite`.
>
> Date: 2026-08-02

> **Current-source update (2026-08-04):** the repair remains in maintained
> tips `19634f4eebba` / `b296374b7520`, whose current normal focused build
> passes. Boot `#29` is still the observed failing baseline and predates the
> fix; no current-tip librga rerun exists.

> **Runtime update (2026-08-05):** KASAN boot `#2 g19634f4eebba` passed the
> exact 92+152 KUnit manifest, and `20260805-084559-librga-suite` passed the
> initial imported-handle copy plus 11 following smoke operations. That closes
> runtime proof for this handle-plane repair. The full smoke later failed on an
> independent legacy fd-zero fence mismatch, and official userptr samples
> exposed oversized SWIOTLB segments. Those defects are source-fixed and
> compile-verified at 6.18 `df22eeef8757` / mainline `518f59c9f1f8`, but require
> a new boot; see the [follow-up finding](../../../findings/2026-08-05-rewrite-rga-librga-swiotlb-fence-status.md).

## Result

The 128x128 RGBA8888 handle copy was rejected before any imported handle was
looked up. This is not a CMA or scatter-gather mapping failure. It is an ABI
compatibility mismatch over how librga represents a single-buffer image.

In handle mode, librga's legacy request builder calls
`NormalRgaSetSrcVirtualInfo()` with values equivalent to:

```text
yrgb_addr = imported handle
uv_addr   = 0
v_addr    = virtual_width * virtual_height
```

For the failing 128x128 request, both source and destination therefore reached
the kernel as `(handle, 0, 0x4000)`. The nonzero `v_addr` is the value left by
`base + width * height` when the userspace base pointer is null. It is not an
independently imported plane handle.

Rockchip's driver uses `uv_addr > 0` as the sole separate-plane discriminator
in `rga_mm_get_channel_handle_info()`. If `uv_addr` is zero, it resolves only
`yrgb_addr` and derives the image's plane addresses from the single buffer.
The rewrite instead entered explicit-plane handling when either `uv_addr` or
`v_addr` was nonzero. It consequently interpreted `0x4000` as a third handle,
required a missing UV handle, and returned `EINVAL` before handle resolution,
mapping, scheduling, dispatch, or IRQ handling.

## Evidence

The attribution combines four independent observations:

1. `strace` showed successful handle imports followed by
   `RGA_BLIT_SYNC` (`0x5017`) returning `EINVAL`.
2. A debugger capture of the exact request decoded source and destination as
   `yrgb_addr=1/2`, `uv_addr=0`, `v_addr=0x4000`, RGBA8888, 128x128 raster.
3. A function-graph trace entered `rk_rga_img_layout()` inside
   `rk_rga_resolve_img_handles_locked()` and then unwound without calling the
   handle resolver. That places the return in the caller's plane-shape checks.
4. Source inspection agrees on both sides:
   `rockchip-userspace/librga-fork@26a50ef09c87` constructs the placeholder in
   `core/NormalRga.cpp`, while Rockchip's forward driver
   `linux-6.18-rkvenc-av1-fwport@5b87d46eefdc` branches only on `uv_addr` in
   `drivers/video/rockchip/rga3/rga_mm.c`.

The earlier CMA theory was caused by where the reproducer allocated its
buffers, not by where the request failed. The trace proves that no DMA-BUF
mapping path was reached. The separate multi-SG defect remains valid but does
not explain this rejection.

## Driver fix

The rewrite now matches the vendor ABI:

- `uv_addr` alone selects explicit-plane handle resolution;
- `v_addr` is treated as a handle only inside that explicit-plane mode;
- compressed single-buffer requests with `uv_addr == 0` accept librga's
  placeholder `v_addr`;
- genuine explicit UV/V requests retain their format-size checks, alias
  validation, reference acquisition, and compressed-mode rejection.

The same source change is applied to the 6.18 rewrite tree at
`8042f13c5459` and its mainline mirror at `94e9ad41a19a`. The existing explicit
plane KUnit fixture now also covers a semiplanar single-buffer placeholder and
an FBC RGBA single-buffer placeholder before exercising the genuine explicit
plane case.

Both affected `rga_rewrite.o` objects compile, and the source diffs pass the
kernel `checkpatch.pl --strict` gate. Hardware closure still requires building,
installing, and booting the patched kernel, then rerunning the KUnit manifest
and librga suite.

## Suite result classification

The same investigation exposed an independent userspace evidence defect.
Several official sample `main()` functions return a failed `IM_STATUS` value
whose numeric value is zero, so the shell reports success even after the sample
prints a fatal error. In `20260802-101933-librga-suite`, 33 official cases (32
required and one diagnostic) were recorded as passes despite fatal log
messages. Conversely, successful official samples commonly return
`IM_STATUS_SUCCESS`, numeric value one; the 2026-08-05 wrapper still recorded
those as shell failures.

`librga-suite.sh` now gives fatal diagnostics precedence over any process
status, and translates status one to success only when the same log contains
the official sample's explicit terminal `running success!` message. The
in-repo smoke is excluded from this scan because its negative compatibility
probes deliberately print rejected-operation diagnostics. A device-free parser
selftest is available as:

```sh
LIBRGA_SUITE_VALIDATE_LOG_PARSER=1 \
  bash kernel-drivers/tests/librga-suite.sh
```

This correction does not make the hard-coded official sample heap names
portable. The 13 cases that require absent
`/dev/dma_heap/system-uncached{,-dma32}` nodes are excluded from the default
suite and remain available through `LIBRGA_ENABLE_VENDOR_HEAP_CASES=1` for a
matching BSP environment; they must not be attributed to the handle-plane fix.

## Runtime closure

After booting a kernel containing the fix:

1. run the rewrite KUnit manifest and confirm the RGA fixture remains green;
2. run `kernel-drivers/tests/librga-smoke.sh` and require the full maintained
   smoke, including the legacy RGB resize, to pass;
3. run `kernel-drivers/tests/librga-suite.sh` and inspect `summary.tsv` for real
   `log-fail` classifications rather than accepting shell-zero sample exits;
4. require no SWIOTLB mapping failure and no successful RGA2 internal-MMU
   fallback logged as a rejected dma-buf remap; and
5. preserve the kernel identity, suite directory, debugfs deltas, and clean
   dmesg scan before marking the follow-up fixes runtime-verified.
