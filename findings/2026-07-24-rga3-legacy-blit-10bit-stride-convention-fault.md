# RGA3 legacy-blit 10-bit stride convention fault — `0048` regressed legacy byte-stride callers

> Scope: forward-port RGA driver (`drivers/video/rockchip/rga3/`), patch
> `4b2beb91521f1` ("rga3: program byte-literal strides for 10-bit rasters",
> the `0048` compact-raster leg) as shipped in the production PPA kernel
> `…20260723~rk1`; JeffyCN GStreamer + librga legacy `RGA_BLIT` path.
> Source: booted board (production kernel), kernel + librga-fork sources,
> minimal reproducer under scratchpad `nv10b-repro/`.
> Date: 2026-07-24
> Trust: MEASURED / SOURCE-CONFIRMED

## Result

The GStreamer NV12_10 RGA failures from the
[production conformance run](./2026-07-24-production-ppa-kernel-full-conformance-run.md)
are **a kernel regression introduced by our own `0048` RGA3 stride fix**, not
a plugin bug. The legacy `RGA_BLIT` ABI convention for 10-bit formats puts a
**byte** stride in `rga_req.img.vir_w` (448 = `ALIGN(320×10/8, 64)` for a
320-wide compact NV12_10 surface — the historical BSP contract, which our own
RGA2 leg preserves with the comment "10bit format width_stride equals
byte_stride", `rga2_reg_info.c:749`). Since `0048`, the **RGA3** register
writer interprets `vir_w` as a **pixel** stride
(`rga3_reg_info.c:362`: `stride = ALIGN(vir_w*10/8, 16)`), programming
560-byte rows. The hardware then reads 560×240×1.5 = 201600 B from a
161280–193536 B surface → RGA3 IOMMU read fault past the mapping, job abort,
`EACCES` ("Permission denied") to userspace. The scheduler prefers RGA3 for
eligible NV12_10 jobs, so **every** legacy 10-bit blit faults.

Pre-`0048` BSP behavior programmed 1 byte/px on RGA3 — accidentally correct
for legacy byte-stride callers, corrupt for the im2d pixel-stride convention
our fork's P010/NV15 support uses. `0048` fixed the latter and inverted who
wins: the two conventions share one ABI field (`vir_w`) and even one ioctl
(im2d single ops also submit via `RGA_BLIT_SYNC`), so the kernel currently
cannot distinguish them.

## Proof (discriminating experiment, this boot)

Minimal reproducer — now tracked as
[`kernel-drivers/tests/rga-10bit-legacy-stride-test.c`](../kernel-drivers/tests/rga-10bit-legacy-stride-test.c)
(fd/CMA variant; the userptr variant lived only in the session scratchpad):
legacy `RGA_BLIT_SYNC`, src compact NV12_10
320×240 `vir_w=448` (byte stride, `compact_mode=0` = compact default as
GStreamer sends), dst NV12, forced per core via `req.core`:

| Buffers | RGA3 (`core=1`) | RGA2 (`core=4`) |
|---|---|---|
| below-4G CMA dma-buf (161280 B src) | **`EACCES` + `rk_iommu fdb60f00` read fault** (RGA3 core0's IOMMU; `INTR[0x2]`, clean soft reset) | **success (`ret=0`)** |
| malloc userptr (above-4G phys) | same fault | `EFAULT` + RGA2 **bus error** `INTR[0x701]` (see secondary note) |
| unforced (`core=0`) | scheduler picks RGA3 → same fault | — |

Identical request, identical buffers, only the core differs: RGA2's
byte-stride leg succeeds, RGA3's pixel-stride leg over-reads by 25 % and
faults. Arithmetic matches the suite failures exactly (GStreamer buffer
193536 B < 201600 B read). Fault contained cleanly by the driver in all runs
(soft reset, no WARN/oops/leak — consistent with the clean whole-battery
sweeps).

## Blame chain

- `rga3_reg_info.c:349–368` `if (yuv10)` block: introduced by
  `4b2beb91521f1` (our `0048` series; not BSP-inherited — parent commit is
  the original driver import).
- `0048` was validated against the ysp librga fork's im2d P010/NV15 gates
  (`rga-p010-test`, `rga-nv15-test`), which pass **pixel** wstride through
  `vir_w` untranslated (fork commits `1dbf1b2`/`a632217` are validation
  hardening, no unit conversion).
- Legacy consumers (JeffyCN GStreamer via prebuilt librga `1.10.6_[3]`
  `c_RkRgaBlit`) pass **byte** strides, per the BSP contract. Prebuilt librga
  rejects P010 in userspace, so the pixel-convention traffic is exclusively
  our fork's 10-bit additions.

## Fix — IMPLEMENTED 2026-07-24 (compile-verified; booted gates pending)

Restores the BSP ABI convention — **`vir_w` is a byte stride for 10-bit
formats, on every core**:

1. **Kernel `0072` (`138f0de2c972`)** "rga3: honor the legacy byte-stride
   ABI for 10-bit rasters": all three RGA3 raster windows (win0/win1/wr)
   program `vir_w` byte-literally (`stride = ALIGN(vir_w, 16) >> 2`,
   compact and incompact alike; the compact flag still drives the
   YUV10B_COMPACT bit), and `rga_check_align()` treats a 10-bit stride
   unit as 8 bits — otherwise legitimate byte strides (e.g. 464) were
   rejected. `Fixes: 4b2beb91521f`.
2. **ysp librga fork `c80eea7`** "im2d: submit 10-bit vir_w as a byte
   stride to match the kernel ABI": `generate_blit_req()` /
   `generate_fill_req()` convert the im2d pixel `wstride` → byte `vir_w`
   (compact ×10/8, incompact ×2; `is_10b_compact` carries the kernel
   `compact_mode` value where 1 = incompact) after the pixel-space clip
   window and before the virtual-address plane-offset arithmetic — which
   also fixes the 10-bit UV plane offset on that path. The legacy
   `NormalRga` path is untouched (its callers already pass bytes).
3. **Kernel `0073` (`79fc616390e5`)** covers the secondary observation:
   the RGA2 MMU page-table builder fails closed with `-EOPNOTSUPP` when
   any 32-bit entry would truncate (>4G page), instead of programming a
   wrong page and bus-erroring.

Both kernel patches compile clean (`drivers/video/rockchip/rga3/` on the
tree config) and are checkpatch-clean; exported as series `0072`/`0073`
under `kernel-drivers/patches/forward-port-rk3588/`. The fork builds clean
via meson. The alternative fix (a new uapi "vir_w in pixels" flag) was
rejected: unmodified legacy consumers must keep working by default, which
forces byte-stride as the default semantics anyway.

**Deliberate compatibility note:** kernel `0072` and fork `c80eea7` must
land together — the fork's converted (byte) strides are wrong on a
`0048`..`0071` kernel, and pixel-convention im2d 10-bit is wrong on a
`0072` kernel. Neither combination can corrupt silently (both over- or
under-stride visibly / fault contained), and no published package ships
the pixel-convention pair.

**Verification gate (pending next debug-kernel build + boot):** on a
`0072` kernel, `rga-10bit-legacy-stride-test` passes on forced cores 1, 4,
and 0 with zero new RGA/IOMMU journal lines; `rga-p010-test`/`rga-nv15-test`
pass against the rebuilt fork; the two GStreamer NV12_10 cases go green with
unmodified JeffyCN + prebuilt librga (modulo the separate pool-geometry note
below); and a >4G userptr legacy blit on RGA2 returns `-EOPNOTSUPP` with no
bus-error journal line (`0073`).

## Rewrite drivers — same ABI aligned (2026-07-24, compile-verified)

The clean-room rewrite needed the same fix, in a different shape. Its RGA2
**and** RGA3 register writers already programmed `vir_w` byte-literally
(`pixel_width` 1 — the pre-`0048` BSP style), but its common image layout
and RGA3 raster-stride validation used pixel math, and the RGA3 write path
scaled the offset row stride ×2 for incompact images. Net effect: legacy
byte-stride callers got correct registers but over-sized layouts that
rejected tightly sized imports (`-EINVAL`, fail-closed), while
pixel-convention callers passed validation but were programmed with
under-sized row strides — internally inconsistent and never caught because
no booted rewrite 10-bit hardware evidence exists. Fixed by
`185d4dcec110` on `rk3588-rewrite-6.18` (cherry-picked as `d5165caeddb7`
on `rk3588-rewrite-mainline`): byte-stride semantics end-to-end for raster
10-bit (layout, validators incl. a new active-window byte-fit check, RGA3
write-offset path), TILE/FBC retain the pixel convention, KUnit
expectations moved to byte strides with a new TILE pixel-convention guard
case, and `ABI.rst` documents the contract. Checkpatch-clean,
compile-verified on both trees; the booted-KUnit re-run rides the existing
pending rewrite hardware gates. The rewrite has no `0073` analog — it uses
the system IOMMU with a 32-bit RGA2 DMA mask, so no truncatable page-table
exists.

## Secondary observations (recorded, not triaged)

- **RGA2 + above-4G userptr 10-bit → hardware bus error** (`INTR[0x701]`,
  "RGA current status: bus error", surfaced as `EFAULT`, clean soft reset)
  instead of a graceful reject. The `0047`/`0051` over-4G work covered the
  dma-buf legs; the legacy userptr leg on a >4G page apparently reaches the
  hardware. Contained, but a fail-closed reject would be better.
- **JeffyCN pool geometry vs MPP**: the failing case also logs
  `mpp_buf_slot: mismatch h_stride_by_byte 768 - 448` /
  `size_total 331776 - 193536` — the plugin's external buffer pool is
  smaller than what the vdpu381 decoder wants for this Main10 stream. Even
  with the kernel stride fix, these cases may need this plugin-side geometry
  mismatch resolved (or proven benign) before they pass end-to-end.

## Why it matters / follow-up

- Any appliance/display userspace using the shipped stack (JeffyCN
  GStreamer, prebuilt librga) has **no working 10-bit RGA path** on the
  current production kernel; 8-bit paths are unaffected. The failure mode is
  contained (no memory-safety impact — consistent with KASAN-clean history).
- Follow-up: implement kernel + fork legs of the fix above as the next patch
  in the series, then re-run the verification gate and the GStreamer suite.
