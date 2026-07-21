# Root causes for the FFmpeg 10-bit/AV1 diagnostics and librga smoke failures

> Scope: RK3588 forward-port kernel `Pb999-C4ad2` (patch tip `0045`), the
> `ffmpeg-rockchip-81` RKRGA filters, prebuilt librga `1.10.6`, the patched
> `yisding/librga@a632217` source build, and
> `kernel-drivers/tests/{ffmpeg-suite.sh,librga-smoke.*}`.
>
> Source: live experiments on the booted `Pb999-C4ad2` KASAN kernel plus
> inspection of `rga_policy.c`/`rga_job.c`/`rga3_reg_info.c` (forward port and
> `rockchip-kernel@develop-6.1` reference) and `rkrga_common.c`.
>
> Date: 2026-07-21
>
> Trust: **MEASURED** / **CODE-INSPECTED** (root causes 1–3, including the
> 10-bit stride misprogramming, measured via a direct im2d P010 probe);
> **COMPILE-PENDING** (fixes `0046`–`0048` committed, booted gates open).

## 1. librga smoke `no core match` — scheduler geometry, not a driver fault

The recurring `imcopy` failure (`rga: no core match`) is the intersection of
two hardware limits with an allocation lottery:

- RGA3's raster input/output ranges start at **68 pixels wide**
  (`rga_hw_config.c: input_range {{68, 2}, ...}`), so every sub-68 test
  surface is RGA2-only.
- RGA2 only accepts **below-4G memory** (`rga_policy.c: "RGA2 only support
  under 4G memory!"`, driven by `RGA_MEM_UNDER_4G` in `rga_job.c`).
- This kernel exposes no dma32 heaps, so `system`-heap dmabufs and malloc
  pages on the 16 GB board land above 4G by luck — which also explains why
  the July 20 run instead reached RGA2 and tripped the separate
  [RGA2 page-table DMA warning](./2026-07-20-rga2-unmapped-page-table-dma-sync.md).

Verified live: 64×64 imcopy fails from the `system` heap, passes from
`default_cma_region` (CMA at `0xd6000000`, RGA2), and passes at 128×128 from
the `system` heap (RGA3). The smoke harness was fixed accordingly: it now
prefers `/dev/dma_heap/default_cma_region` before the system heaps and sizes
every case at or above the RGA3 minimum (with matching buffer sizes). Thirteen
cases including every dmabuf path now pass deterministically.

**Legacy `RGA_BLIT` `EFAULT` — root-caused and source-fixed.** A minimal
`RGA_BLIT_SYNC` probe with the legacy virtual convention (`yrgb_addr = 0`,
address in `uv_addr`) reproduces the failure and the kernel logs
`invalid task list`: patch `0045`'s staged-task validation demanded
`yrgb_addr` on every channel, rejecting every legacy virtual blit — a `0045`
regression (the `0043` kernel ran this path to hardware on July 20), not a
DMA-placement issue. Patch `0046@e1d6d47d9565d` treats a channel as populated
when either address slot is set; empty channels still reject, preserving the
ABI-probe contract. Patch `0047@0388a3efc829a` additionally makes the
memory-placement failure explicit: when the only skipped core was excluded by
the RGA2 under-4G rule, the driver now logs the reason and returns
`EOPNOTSUPP` instead of a bare `EINVAL`.

**DMA32 heap decision:** full BSP userspace compatibility (official librga
samples, heap-name-hardcoding apps) requires exposing the BSP's
`system-dma32`/`system-uncached-dma32` heaps (vendor dma-heap driver — not
upstream). Functionally it only matters for RGA2-reachable allocations;
MPP/FFmpeg need nothing. Tracked as a candidate forward-port addition, not a
blocker.

## 2. FFmpeg AV1 PSNR diagnostic — missing software reference decoder

`ffmpeg-rockchip-81` has no software AV1 decoder (its native `av1` decoder is
a hwaccel-only wrapper; no libdav1d/libaom), so `decode_psnr_inf`'s software
reference leg produced zero frames and the PSNR was `missing`. The suite now
uses the generator FFmpeg (system build with libdav1d) for the AV1 reference
leg — and the case then **passes bit-exact**: RK3588 hardware AV1 decode is
`PSNR inf` against dav1d, consistent with the 2026-07-04 `mpi_dec_test`
bit-exact result.

## 3. FFmpeg HEVC Main10 → P010 via RGA — two stacked causes

1. **Linear NV15 decoder output is not RGA-expressible at 1920 wide.** MPP
   allocates `hor_stride` 2816 bytes for 1920×1080 Main10; at 10 packed
   bits/pixel that is 2252.8 pixels — not an integral pixel stride, and RGA
   requires 10-bit wstrides in whole (64-aligned) pixels. The `-81` fork's
   hardened stride derivation rejects it cleanly ("Failed to get frame
   strides"); upstream would fail alignment checks slightly later. The RGA
   input for 10-bit must therefore come from the AFBC decoder path
   (`-afbc rga`), which works — the suite case now does that.
2. **RGA3 corrupts incompact (padded P010) writes.** With AFBC input the
   same-size NV15→P010 conversion runs 60/60 frames but produces garbage
   (PSNR ≈ 7 dB against the software P010 decode), identically with the
   prebuilt librga 1.10.6 and the patched `yisding/librga@a632217` build
   (`ldd`-verified). The 8-bit control on the identical path is bit-exact
   (`inf`), and Main10→NV12 is clean (~60 dB, dither-limited), so the 10-bit
   AFBC read is fine — the corruption is isolated to the incompact P010
   write. The flag chain (ffmpeg `uncompact_10b_msb` → librga
   `compact_mode=RGA_10BIT_INCOMPACT` → kernel `wr.is_10b_compact=0`) is
   verified correct in source, and the reference BSP 6.1 tree is
   byte-identical in this logic — this is stock vendor behavior, matching
   the Jellyfin community's known P010 corruption and their NV15-first-pass
   workaround.

   **Root cause measured and source-fixed.** A direct im2d probe (P010→NV12
   on CMA dmabufs with a known ramp pattern) shows the read side fetching
   row N at byte offset `N * vir_w` instead of `N * vir_w * 2` — the
   hardware stride registers are byte-literal and `rga3_reg_info.c` leaves
   `pixel_width = 1` for every 10-bit semi-planar raster in WIN0/WIN1/WR.
   A P010→P010 copy corrupts likewise. Patch `0048@8e641bcd48a38` programs
   byte-literal strides for both layouts (incompact 2 bytes/pixel, compact
   10 bits/pixel, UV rows equal to Y rows in both); the incompact leg is
   measured, the compact raster leg matches the layout math but needs
   hardware validation. Booted verification runs the bit-exact P010 suite
   gate.

## Suite changes landed with this finding

- `ffmpeg-suite.sh`: AV1 software reference via the generator FFmpeg; the
  Main10 P010 case switched to AFBC input, same-size conversion, and a
  bit-exact PSNR assertion (stays diagnostic-red for the true reason until
  the kernel-side write path is fixed).
- `librga-smoke.cpp`: `default_cma_region` heap fallback; all case surfaces
  scaled to RGA3-minimum-compatible sizes with matching buffer sizes.

## Verification gate

- AV1: `ffmpeg_psnr_av1_decode_inf` passes (run `20260721-054239`).
- P010: `ffmpeg_hevc_main10_p010_rga` diagnostic-fails with
  `expected PSNR average:inf, got '6.957150'` on the `0045`-tip kernel —
  flips to pass when a kernel carrying `0048` boots and re-verifies
  bit-exact.
- Smoke: 13 cases green through `rkmppenc fd chain` on the `0045` tip; a
  kernel carrying `0046` must turn the legacy-blit case green and unblock
  the 10-bit im2d cases behind it.
- `0047`: a 64×64 dmabuf imcopy from the system heap (above 4G) must return
  `EOPNOTSUPP` with the explanatory log line instead of `EINVAL`.
