# A narrow AFBC 10-bit frame has no RGA core: RGA3 needs width ≥ 68 and RGA2 cannot read AFBC

> Scope: kernel-drivers RGA core scheduling, and the `rockchip-vaapi` AFBC
> NV15→P010 repack that every 10-bit surface depends on. Explains the single
> remaining failure in the [Main10 conformance sweep](2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md).
>
> Source: forward port `~/Code/rock-5b/kernel/linux-6.18-rkvenc-av1-fwport`
> `drivers/video/rockchip/rga3/` — `rga_hw_config.c` `rga3_data`/`rga2e_data`
> `.input_range`/`.output_range` and `rga3_win_data`/`rga2e_win_data`
> `.rd_mode`;
> `rga_policy.c` `rga_check_channel()` and `rga_check_resolution()`. Runtime
> from `journalctl -k` on `6.18.40-ysp-rockchip64` with
> `librga2 2.2.0+git20260725.26a50ef` and
> `librockchip-mpp1 1.5.0+git20260727.d8c6b88a`. Provenance comparison against
> Rockchip BSP `develop-6.1@b4ef083dc0c3` and the first forward-port import
> `924f4232546d`.
>
> Date: 2026-07-29
>
> Trust: **MEASURED** (the runtime failure and its kernel log) /
> **SOURCE-CONFIRMED** (the constraints and BSP provenance) /
> **FIX-VERIFIED** (the VA-API refusal, runtime guard, and software fallback) /
> **UNVERIFIED** (the physical-hardware floor and conversion workarounds).

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
| RGA3 | `rga3_data.input_range = {{68, 2}, {8176, 8176}}` and `.output_range = {{68, 2}, {8128, 8128}}` (`rga_hw_config.c`) — **minimum input and output width 68**. Both active rectangles are 64. |
| RGA2 | `rga2e_win_data` declares `.rd_mode = RGA_RASTER_MODE` only; `RGA_FBC_MODE` appears solely in `rga3_win_data`. RGA2 **cannot read AFBC at all**. Its own `input_range` minimum is 2, so width is not RGA2's problem. |

That is a pincer rather than a single limit: only RGA3 can consume
AFBC-compressed 10-bit, and RGA3 is the core carrying the 68-pixel floor. Any
AFBC 10-bit conversion narrower than 68 luma pixels is rejected by the vendor
driver policy.

### This policy came from the BSP, not the forward port

The first forward-port import `924f4232546d` contains Git blobs
`581693e82cb961d5814fc2030238bcf7706d1259` (`rga_hw_config.c`) and
`2554f4bf6389bbbbda5a0fa844ec0a873fc2b3fb` (`rga_policy.c`). They are
byte-identical to the same two files in Rockchip
`develop-6.1@b4ef083dc0c3`.

Rockchip history predates the 2026 forward port by years:

- `8ca0b5936e9f1` (2021-11-18) introduced the RGA3 AFBC and RGA2 raster-only
  mode tables;
- `fc308534be4a` (2022-06-21) introduced the 68-pixel RGA3 range and the
  active-rectangle range check.

Later forward-port changes did not alter those ranges or mode assignments.
The refusal is therefore inherited BSP behavior. What the 2026 VA-API work
initially added was a Main10/VP9 Profile 2 path that reached that existing
boundary mid-decode.

### The rectangle, not the stride, is what is checked

`rga_check_channel()` range-checks `img->act_w`/`act_h` — the **active
rectangle** — via `rga_check_resolution()`, which is a plain
`width < range->min.width`. RGA3 is additionally checked at
`act_w + x_offset` / `act_h + y_offset`.

So padding the *stride* does not help. A hardware workaround would need wider
active rectangles on **both** sides of the operation: RGA3 also applies its
68-pixel `output_range` minimum to the P010 destination. The driver would then
have to retain a 64-pixel visible crop over the padded result.

For this stream even the source half is unavailable with the measured layout:
the conversion log records
`64x240 (pixel_stride=64 vstride=256 afbc=1)`, so MPP handed over an AFBC
surface whose header stride is exactly the visible width. There are no extra
source columns to widen the active rectangle into.

## Resolution

Local `rockchip-vaapi` source commit `491533e` closes the integration defect at
the layer that knows the decode profile and fallback contract:

1. `vaCreateContext()` now returns
   `VA_STATUS_ERROR_RESOLUTION_NOT_SUPPORTED` for an experimental HEVC Main10
   or VP9 Profile 2 context narrower than 68 pixels.
2. The AFBC NV15→P010 converter keeps a matching geometry check immediately
   before allocation/submission, so changed or cropped geometry cannot bypass
   the context check and reach librga.
3. `tests/check-main10-narrow-fallback.sh` exercises the pinned 64×240 stream
   through FFmpeg without forcing a hardware output format. The application
   receives the context refusal and software-decodes all 48 frames.

The focused hardware run recorded exactly one context rejection, zero
`NV15->P010 via RGA` conversion markers, and zero new kernel `no core match`
messages. The object gate also proves the boundary for both experimental
profiles: 64×240 is refused and 68×240 creates and destroys a context. The same
gate passes under ASan/UBSan.

The existing supported-width regression stayed green: the generated 320×240
Main10 stream produced 48 byte-exact frames and the pinned 416×240 Toshiba
vector produced 256 byte-exact frames. This is therefore an up-front refusal
for the one unsupported geometry, not a global minimum that removes narrow
raster work from RGA2.

## Boundary

- **Only the 64-pixel case is measured.** 68 is read from the source table, not
  bisected on hardware. Every other 10-bit vector that passes is ≥ 68 wide
  (416×240, 320×240, 160×90), which is consistent with the table but does not
  by itself locate the threshold.
- **The evidence proves an inherited vendor-driver policy, not a physical
  hardware limit.** No run has bypassed the 68-pixel check and submitted the
  register program.
- **Height is not implicated.** RGA3's minimum height is 2 and the frame is 240.
- **This says nothing about the linear NV15 path**, which is a different core
  match, or about whether MPP can be asked for a different AFBC geometry.
- The conversion workarounds below are **design proposals, untested**.

## Why it matters

This is the sole remaining failure in the HEVC Main10 conformance sweep (10 of
11 real Main10 vectors are byte-exact), and it is one of the three reasons
`VAProfileHEVCMain10` is still hidden. The kernel refusal itself is inherited
from the BSP. The local driver source now fixes the VA-API integration defect:
it refuses the unsupported context early enough for application software
fallback and retains a pre-submit safety check. The installed driver package
was subsequently advanced to `1.0.11+ysp5`, payload-matched, and passed the
focused fallback plus pinned installed-driver gates. The later roadmap changes
remain source-tree evidence until their final package is installed.

## Remaining follow-up

1. **Harden librga separately.** `imcheck()` currently merges the capabilities
   of all installed cores, so it cannot express “AFBC requires RGA3, whose
   minimum is 68.” A correct librga rejection requires per-core,
   per-storage-mode matching; a global 68-pixel minimum would incorrectly
   reject narrow raster jobs that RGA2 can run.
2. **Widen both operation geometries.** If MPP can produce a wider AFBC source,
   allocate a correspondingly wider P010 destination, run both active
   rectangles at ≥68, and preserve the 64-pixel visible crop. Unverified that
   MPP exposes the necessary AFBC geometry control.
3. **Fall back to linear NV15 and repack on the CPU.** AFBC is mandatory for
   10-bit only because VDPU383's *linear* NV15 stride is frequently not
   RGA-representable; at 64 wide it may be. Linear NV15 is CPU-unpackable,
   unlike AFBC. Unverified.
