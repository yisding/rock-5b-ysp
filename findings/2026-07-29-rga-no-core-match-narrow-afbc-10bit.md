# A narrow AFBC 10-bit frame has no RGA core: RGA3 needs width ≥ 68 and RGA2 cannot read AFBC

> Scope: kernel-drivers RGA core scheduling, and the `rockchip-vaapi` AFBC
> NV15→P010 repack that every 10-bit surface depends on. Explains the single
> remaining failure in the [Main10 conformance sweep](2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md).
>
> Source: forward port `~/Code/kernel/linux-6.18-rkvenc-av1-fwport`
> `drivers/video/rockchip/rga3/` — `rga_hw_config.c` `rga3_data`/`rga2e_data`
> `.input_range` and `rga3_win_data`/`rga2e_win_data` `.rd_mode`;
> `rga_policy.c` `rga_check_channel()` and `rga_check_resolution()`. Runtime
> from `journalctl -k` on `6.18.40-ysp-rockchip64` with
> `librga2 2.2.0+git20260725.26a50ef` and
> `librockchip-mpp1 1.5.0+git20260727.d8c6b88a`.
>
> Date: 2026-07-29
>
> Trust: **MEASURED** (the runtime failure and its kernel log) /
> **SOURCE-CONFIRMED** (the two constraints that produce it) /
> **UNVERIFIED** (both proposed remedies).

## Result

`WPP_D_ericsson_MAIN10_2.bit` is 64×240. Converting its decoded frame fails,
and the failure is **not** a librga parameter rejection — librga accepted the
job and the *kernel scheduler* could not place it.

The driver logs `status=0`, which is `IM_STATUS_FAILED` (`IM_ERROR_FAILED = 0`,
`im2d_type.h`). A size or format rejection from librga's own `imcheck` would
have been `IM_STATUS_INVALID_PARAM` (−3) or `IM_STATUS_NOT_SUPPORTED` (−1). The
kernel says what happened:

```text
rga: ID[5277]: no core match
rga: ID[5277]: failed to assign task 0
rga: ID[5277]: job assign failed
rga: ID[5277]: request commit failed!
rga: ID[5277]: submit failed!
```

`no core match` means no RGA core could take the job. RK3588 has two RGA3 cores
and one RGA2, and this job eliminates both:

| Core | Disqualifier |
|---|---|
| RGA3 | `rga3_data.input_range = {{68, 2}, {8176, 8176}}` (`rga_hw_config.c`) — **minimum input width 68**. The frame is 64. |
| RGA2 | `rga2e_win_data` declares `.rd_mode = RGA_RASTER_MODE` only; `RGA_FBC_MODE` appears solely in `rga3_win_data`. RGA2 **cannot read AFBC at all**. Its own `input_range` minimum is 2, so width is not RGA2's problem. |

That is a pincer rather than a single limit: only RGA3 can consume
AFBC-compressed 10-bit, and RGA3 is the core carrying the 68-pixel floor. Any
AFBC 10-bit frame narrower than 68 luma pixels is unconvertible by this
hardware.

### The rectangle, not the stride, is what is checked

`rga_check_channel()` range-checks `img->act_w`/`act_h` — the **active
rectangle** — via `rga_check_resolution()`, which is a plain
`width < range->min.width`. RGA3 is additionally checked at
`act_w + x_offset` / `act_h + y_offset`.

So padding the *stride* does not help; only a wider active rectangle would. For
this stream that is unavailable anyway: the driver's own conversion log records
`64x240 (pixel_stride=64 vstride=256 afbc=1)`, so MPP handed over an AFBC
surface whose header stride is exactly the visible width. There are no extra
source columns to widen the rectangle into.

## Boundary

- **Only the 64-pixel case is measured.** 68 is read from the source table, not
  bisected on hardware. Every other 10-bit vector that passes is ≥ 68 wide
  (416×240, 320×240, 160×90), which is consistent with the table but does not
  by itself locate the threshold.
- **Height is not implicated.** RGA3's minimum height is 2 and the frame is 240.
- **This says nothing about the linear NV15 path**, which is a different core
  match, or about whether MPP can be asked for a different AFBC geometry.
- The two remedies below are **design proposals, untested**.

## Why it matters

This is the sole remaining failure in the HEVC Main10 conformance sweep (10 of
11 real Main10 vectors are byte-exact), and it is one of the three reasons
`VAProfileHEVCMain10` is still hidden. It is a hardware capability boundary, not
a driver defect — but the driver currently discovers it **mid-decode**, after
accepting the stream, which is the part worth fixing regardless of whether the
stream can ever be made to work.

## Follow-up

1. **Refuse up front.** Reject a 10-bit decode context narrower than 68 at
   context creation so the application falls back cleanly instead of taking a
   mid-stream `VA_STATUS_ERROR_DECODING_ERROR`. Certain to work; does not make
   the stream decode.
2. **Widen the AFBC geometry.** If MPP honours a horizontal-alignment request
   for AFBC output, `act_w` could reach 68 and RGA3 would accept the job.
   Unverified that MPP exposes this for AFBC.
3. **Fall back to linear NV15 and repack on the CPU.** AFBC is mandatory for
   10-bit only because VDPU383's *linear* NV15 stride is frequently not
   RGA-representable; at 64 wide it may be. Linear NV15 is CPU-unpackable,
   unlike AFBC. Unverified.
