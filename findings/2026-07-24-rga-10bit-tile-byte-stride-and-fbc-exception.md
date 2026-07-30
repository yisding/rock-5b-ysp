# 10-bit `vir_w` is a byte stride in TILE too — the `* 8` is a line factor, not a depth scale

> Scope: kernel-drivers RGA — the rewrite (`rga-rewrite`), the forward port
> (`rga3/`), and the `librga` fork, reconciled against the BSP.
> Source: BSP `~/Code/rock-5b/kernel/rockchip-kernel` `origin/develop-6.1` (`b4ef083dc0c3`)
> and `origin/develop-5.10` — `rga3_reg_info.c` win0/win1 `rd_mode` switch,
> `rga_common.c` `rga_convert_addr()`. Fixes: rewrite `40cf22629cf63`
> (6.18) / `7481ab327d7ea` (mainline); librga fork `4c26ddf`.
> Date: 2026-07-24
> Trust: SOURCE-CONFIRMED / COMPILE-VERIFIED / PREDICTION-HARDWARE-CONFIRMED
> (the fix itself is still unrun on hardware)

## Result

**The BSP treats 10-bit `vir_w` as a BYTE stride in every uncompressed mode —
RASTER and TILE alike. There is no pixel convention for 10-bit outside the
compressed modes.** Both BSP branches are identical on this:

```c
/* rga3_reg_info.c — win0/win1 rd_mode switch */
case 0: /* raster */   stride = ((vir_w * pixel_width     + 15) & ~15) >> 2;
case 2: /* tile 8*8 */ stride = ((vir_w * pixel_width * 8 + 15) & ~15) >> 2;
```

and `pixel_width` stays at its default `1` for all four `*_SP_10B` formats (they
set only `yuv10 = 1`, which drives endianness). So both modes yield **`vir_w`
bytes per line**. `rga_convert_addr()` has no 10-bit branch and no `rd_mode`
distinction whatsoever: `uv_addr = yrgb_addr + vir_w * vir_h`, universally.

### The root cause: one misread expression

The `* 8` in the TILE expression is the **eight-lines-per-tile-block factor**.
The BSP says so directly, immediately above it:

> `/* tile 8*8 mode 8 lines of data are read/written at one time, so stride
> needs * 8. YUV420 only has 4 lines of UV data, so it needs to >>1. */`

It was read as a pixel-depth scale, and the conclusion *"the kernel's tile stride
math scales vir_w itself"* propagated into two places, which then agreed with each
other and diverged from the BSP:

- **librga fork `b8def3e`** ("limit the 10-bit byte-stride conversion to raster
  mode") — states the premise verbatim in its commit message, and gated the
  pixel→byte conversion on raster, so the fork sent TILE 10-bit `vir_w` as pixels.
- **`rk_rga_yuv10_plane_layout()` in the rewrite**, its comment, and a
  `KUNIT_EXPECT_NE(layout.yrgb_size, pixels)` *regression guard* actively pinning
  the pixel convention.

The rewrite's own register writer never followed that convention —
`rk_rga3_tile_stride()` is `vir_w * pixel_width * 8` with `pixel_width = 1`, i.e.
byte-literal — so **the rewrite was internally self-contradictory**: layout and
register disagreed by 25% for compact 10-bit.

Concretely, compact NV15 TILE at `vir_w = 80`, `vir_h = 64`:

| | Y plane bytes | UV plane at |
|---|---|---|
| rewrite layout (pixel convention) | `80 * 64 * 10/8` = 6400 | `+6400` |
| rewrite register (what HW is told) | `80 * 64` = 5120 | `+5120` |
| BSP / forward port post-`0074` | `80 * 64` = 5120 | `+5120` |

An over-sized import silently read chroma 1280 B past the true plane; a tightly
sized one was rejected `-EINVAL` because the inflated `layout.total_size` failed
the import size check. Same defect class as
[`2026-07-24-rga-10bit-uv-plane-offset-still-pixel-scaled.md`](2026-07-24-rga-10bit-uv-plane-offset-still-pixel-scaled.md),
one storage mode over.

### FBC *is* a genuine exception — but not for the stated reason

`b8def3e` was right to exclude FBC and wrong about why. FBC really does carry a
pixel-count `vir_w`, provable from the payload-stride table (values in 4-byte
words, so `bytes/px = stride * 4 / aligned_w`):

| format | payload stride | implied bytes/px |
|---|---|---|
| RGBA8888 | `aligned_w` | 4 |
| RGB888 | `(aligned_w >> 2) * 3` | 3 |
| YUV420SP | `(aligned_w >> 3) * 3` | 1.5 |
| YCbCr_422_SP_10B | `(aligned_w >> 3) * 5` | 2.5 (20 bit/px) |

The format's own bytes-per-pixel is applied *to* `vir_w`, so `vir_w` must be
pixels. And the FBC *register* stride is the format-independent **header** stride
(`ALIGN(vir_w,16) >> 2` for every format), not a row stride. The TILE argument
does not transfer to FBC, and FBC stays on the pixel convention.

### Correction to an earlier reading

An earlier pass through this suspected forward-port `0074` of over-reaching into
TILE and wanting an `rd_mode` guard. **That was wrong.** `0074` restored BSP
behaviour exactly, TILE included — the `×10/8` block it deleted was never BSP
code, it came from this repo's own `0049`. `0072` + `0074` put the forward port
back on the BSP contract; the rewrite and librga were the two that had drifted.

### The alignment constant was also a pixel count

`rk_rga3_validate_tile_image()` required `vir_w & 0x3f` ("64-pixel width stride")
for 10-bit TILE. Under byte semantics the correct rule is **16 bytes**, matching
`rga3_data.byte_stride_align` and the rule the rewrite's RASTER 10-bit validator
already enforces (`ALIGN(vir_w,16) == vir_w`). This *relaxes* the check and
rejects nothing current userspace can emit: librga's `rga_check_align()` requires
`bit_stride % 128 == 0`, so 10-bit pixel strides are 64-aligned and their byte
form is always a multiple of 80.

## Evidence and reproduction

- **Identity:** code-only, four trees. BSP `rockchip-kernel` `origin/develop-6.1`
  + `origin/develop-5.10`; forward port at `710e6ad12af6` on `rk3588-video-6.18`
  in `~/Code/rock-5b/kernel/linux`; rewrite on `rk3588-rewrite-6.18` /
  `rk3588-rewrite-mainline`; `~/Code/rock-5b/rockchip-userspace/librga-fork` `main`.
- **Exercise:** `git show origin/develop-{5.10,6.1}:drivers/video/rockchip/rga3/{rga3_reg_info.c,rga_common.c}`
  and a diff of the two branches over `rga3_reg_info.c` filtered to
  `stride|pixel_width|10B|yuv10`.
- **Pass/fail signal:** the 5.10↔6.1 filtered diff is **empty** — the two branches
  are identical on every site involved. `pixel_width` is assigned only for RGB and
  packed formats; the four `*_SP_10B` cases set `yuv10 = 1` and nothing else.
- **Fix verification:** all three clean-source profiles (`normal`, `memory`/KASAN,
  `race`/KCSAN+lockdep) build warning-free at the rewrite tip; mainline compiles
  clean. The changed librga translation unit compiles with 0 errors / 0 warnings
  (extracted via `compile_commands.json`).
- **Artifacts:** none retained; the commits are the record.

Note: `librga-fork` has a **pre-existing** host-build failure in
`core/RgaUtils.cpp` (4 × `inputFilePath`/`outputFilePath` not declared), confirmed
identical at `HEAD` before the change. It is unrelated and does not affect the
packaged arm64 build.

## Boundary

- **The corrected offsets have not been observed on silicon.** The reconciliation
  and the fix are source plus compile gate; the fixed path is still unrun.
- **The prediction was confirmed, on the pre-`0074` kernel.** TILE 10-bit had
  zero test coverage anywhere in this project — not in the rewrite's KUnit suite
  (which covered only the layout, and pinned it wrong), not in `librga-smoke`
  (its tile round-trip is 8-bit NV12), and `0074`'s measurement was a raster
  blit. `rga-10bit-uv-offset-test` gained TILE8x8 coverage the same day and ran
  the discriminating case: tile-mode chroma tracks the pixel-scaled offset and a
  tightly sized tile blit IOMMU-faults, exactly as this reconciliation said.
- **The deeper hardware question is still open**: whether `pixel_width = 1` is
  itself right for 10-bit TILE. Every driver here programs it that way, so they
  must at least agree with each other and the plane offset must follow the
  programmed stride — which is what this fix establishes. If silicon turns out to
  want 10 bits/pixel rows in TILE, then the BSP, the forward port and the rewrite
  are all consistently wrong together and the *register* side needs the change.
- FBC's convention is established from the stride tables, not from a run.

## Why it matters / follow-up

**Kernel and librga must now ship together for TILE 10-bit.** A new kernel with a
pre-`4c26ddf` librga (or the reverse) is wrong by 20% on that path — the same
coupling as the `0072` / `c80eea7` raster pair. Worth stating in the PPA release
notes.

1. Build a debug kernel at the rewrite tip and run the TILE8x8 NV15 round-trip
   above; add it to `librga-smoke.cpp` so the gap closes permanently.
2. Re-check `rga-10bit-uv-offset-test.c` (added for the `0074` work) — extend it
   to TILE, since it currently only discriminates raster.
3. The forward port needs no change; confirm that by running the same TILE case
   against it as an oracle once the rewrite case exists.
4. When a validated build lands, refresh the §6 pins in
   [`rewrite-drivers.md`](../kernel-drivers/docs/rewrite-drivers.md) — the rewrite
   tips are now `40cf22629cf63` (6.18) and `7481ab327d7ea` (mainline).
