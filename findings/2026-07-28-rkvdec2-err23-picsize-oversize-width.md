# rkvdec2 `err 0x23`: an 8192-sample width inflection, BSP watchdog constants whose names are wrong, and VA-API caps that are wrong in both directions

> Scope: vendor MPP `rkvdec2` kernel driver on RK3588 (Rock 5B), and the
> `rockchip-vaapi` HEVC Main conformance sweep that provoked it; PICSIZE
> conformance rows, decode picture-size limits, and the CCU watchdog thresholds.
> Source: running kernel `6.18.40-ysp-rockchip64` built from
> `~/Code/kernel/rock5b-kernel-build/armbian-build/cache/sources/linux-kernel-worktree/6.18__rockchip64__arm64@221fc2f4d0ed`
> — `drivers/video/rockchip/mpp/mpp_rkvdec2.h` (status bits ~:59-69),
> `mpp_rkvdec2_link.c` `rkvdec2_soft_ccu_reset()` (~:1983),
> `rkvdec2_soft_ccu_irq()` (~:2179), `rkvdec2_ccu_get_timeout_threshold()`
> (~:1588), `.err_mask = 0xf0` (~:82), `mpp_rkvdec2.c` `cycle_clk`/`aclk_info`
> (~:1237-1242); vendor BSP of record
> `rockchip-linux/kernel.git@b4ef083dc0c3` (`release-20171213-680848`);
> forward-port import `rk3588-fwport-0001-…-vendor-MPP-…patch`;
> `rockchip-vaapi@a685db2` `src/driver_internal.h` (~:21-22);
> `librockchip-mpp1 1.5.0+git20260727.d8c6b88a+ds-0ubuntu1~rk1`;
> `ffmpeg 7:8.0.3+rockchip+git20260719.da5befc806-0ubuntu1~rk1`;
> Rockchip RK3588S Datasheet V1.3 § Video Decoder / Video Encoder.
> Date: 2026-07-28
> Trust: **MEASURED** / **CODE-INSPECTED** / **SOURCE-INSPECTED** /
> **SOURCE-CONFIRMED** (BSP provenance) / **BOARD-REPRODUCED** /
> **PARTIAL** / **HYPOTHESIS** (mechanism above 8192)

> **Self-corrected 2026-07-28, twice.** The first version of this finding
> claimed a hardware bound of 7680 and recommended MPP reject above it; the
> second claimed a *hard* 8192-wide wall and stated the failure was structural
> rather than a time budget. Both over-claimed. 8192 is a real inflection point
> **measured at height 1056**, but it is not an absolute wall: 8200x128 decodes
> clean, and above 8192 the failures are *partial and periodic*, not wholesale.
> The mechanism is unresolved. The measured data is below; the interpretation is
> deliberately weaker than it was.

## Result

`mpp_rkvdec2 ...video-codec: resetting for err 0x23` is the rkvdec2 core
interrupt/status register (`RKVDEC_REG_INT_EN`, offset 0x380) reporting a
**hardware watchdog timeout**, not a bitstream error and not a bus fault:

| bit | flag | set |
|---|---|---|
| 0 | `RKVDEC_IRQ` | yes — interrupt asserted |
| 1 | `RKVDEC_IRQ_RAW` | yes — raw interrupt |
| 2 | `RKVDEC_READY_STA` | **no — decode never completed** |
| 3 | `RKVDEC_BUS_STA` | no — no bus error |
| 4 | `RKVDEC_ERROR_STA` | no — no bitstream error |
| 5 | `RKVDEC_TIMEOUT_STA` | **yes — watchdog expired** |

The driver's error mask is `0xf0` (bits 4-7), so of the three bits set only
`RKVDEC_TIMEOUT_STA` counts as an error; that is what increments
`reset_request` in `rkvdec2_soft_ccu_irq()` and schedules the reset.

`PICSIZE_B_Bossen_1.bit` (HEVC Main, level 5.1, **8440x1056**) is the
conformance vector that surfaced this, and it is the only one of 163 that
produces any reset. The stream is legal: HEVC level 5.1 allows
`pic_width_in_luma_samples` up to `Sqrt(MaxLumaPs * 8)` ≈ 16888, and the PICSIZE
vectors exist to sit at the level's geometric corner.

Two structural details explain the shape of the log:

- **Both cores always appear.** `rkvdec2_soft_ccu_reset()` walks *every* enabled
  core in the CCU queue whenever any one core errors, so `fdc40100` +
  `fdc38100` reset as a pair. A pair of lines is not evidence that both cores
  failed independently.
- **The inter-reset spacing is the watchdog budget plus recovery**, measured
  below.

## The watchdog constants are BSP, and their names are wrong

```c
#define RKVDEC2_CCU_TIMEOUT_20MS	(0xefffff)
#define RKVDEC2_CCU_TIMEOUT_50MS	(0x2cfffff)
#define RKVDEC2_CCU_TIMEOUT_100MS	(0x4ffffff)
```

**Provenance: verbatim Rockchip BSP.** They appear unchanged in
`rockchip-linux/kernel.git@b4ef083dc0c3` (the vendor tree of record), arrive in
this repo as `+` lines of the 6.1-BSP forward-port import
(`rk3588-fwport-0001-…-vendor-MPP-rkvenc2-rkvdec2-RGA.patch`), and are identical
in all nine local kernel trees. Nothing here tuned or invented them.

**They are cycle counts, not times**, and they are round in binary, not in
milliseconds:

| macro | value | = | cycles |
|---|---|---|---|
| `…_20MS` | `0xefffff` | `0xf00000 - 1` | **15 Mi** |
| `…_50MS` | `0x2cfffff` | `0x2d00000 - 1` | **45 Mi** |
| `…_100MS` | `0x4ffffff` | `0x5000000 - 1` | **80 Mi** |

The names cannot all be right, and this is provable without knowing the clock:
15 : 45 : 80 = 1 : 3 : 5.33, whereas 20 : 50 : 100 = 1 : 2.5 : 5. **No single
clock frequency maps one set onto the other.** For each label to be exact
individually you would need 786.4, 943.7 and 838.9 MHz respectively.

`dec->cycle_clk = &dec->aclk_info` (`mpp_rkvdec2.c:1242`), so the reference
domain is the decoder aclk.

**Measured on the board.** Holding width at 8200 (which reliably provokes
timeouts) and varying only height to land in each bucket, then reading
inter-reset spacing from the journal:

| geometry | pixels | bucket | measured spacing |
|---|---|---|---|
| 8200x128 | 1,049,600 | 15 Mi (`_20MS`) | *no resets — decoded clean* |
| 8200x1056 | 8,659,200 | 45 Mi (`_50MS`) | 68.2 / 67.8 / 68.0 / 64.2 / 67.9 / 67.9 ms |
| 8200x1160 | 9,512,000 | 80 Mi (`_100MS`) | 116.0 / 112.0 / 116.0 / 115.9 / 112.1 / 116.7 ms |

The DT declares the decoder aclk at **800 MHz** for both cores
(`rockchip,normal-rates = <800000000>, …` in `rk3588-rock-5b.dtsi`, matching the
vendor). At 800 MHz the constants are:

| macro | claims | actually (800 MHz) | measured spacing | implied recovery |
|---|---|---|---|---|
| `…_20MS` | 20 ms | **19.7 ms** ✅ | — (no resets in this bucket) | — |
| `…_50MS` | 50 ms | **59.0 ms** ❌ (18 % high) | 67.3 ms | ~8.3 ms |
| `…_100MS` | 100 ms | **104.9 ms** ❌ (5 % high) | 114.8 ms | ~9.9 ms |

The consistent ~9 ms residual is the reset-plus-requeue cost, and its
consistency across two buckets is itself evidence that the register really is an
aclk cycle counter. A free two-point fit on the same data gives C ≈ 773 MHz,
i.e. the DT rate within the noise of two samples.

Only the `_20MS` name is honest. The practical consequence is mild — budgets are
*more* generous than advertised, not less — but any reasoning that trusts the
names (including the bucket-cliff analysis below) is off by up to a fifth.

## The 8192 inflection — and why it is not a simple wall

Synthetic solid-gray streams, `crf=28`, decoded through `tests/hevc_mpp_repro`
(direct MPP, no VA-API), reset counter sampled around each run. **All rows below
are at height 1056** unless stated; boundary cases run twice.

| geometry | resets | result |
|---|---|---|
| 4216x1056 | 0 | clean |
| 6144x1056 | 0 | clean |
| 7168x1056 | 0 | clean |
| **7680x1056** | 0 | clean — the value we advertise |
| **7688x1056** | 0 | clean — *past* the value we advertise |
| 8064x1056 | 0 | clean |
| **8192x1056** | 0 (2 runs) | clean — last good at this height |
| **8200x1056** | 2 (2 runs) | stream-error — first bad at this height |
| 8256 / 8320 / 8384 / 8440 x1056 | 6 / 4 / 2 / 2 | stream-error |
| 1056x8440 | 0 | clean — 8440 *tall* is fine |
| **8200x128** | **0** | **clean — 8200 wide is fine at low height** |

The cliff at height 1056 sits exactly on 8192 = 2^13, which is also the
documented encoder maximum (`96x96 to 8192x8192`) and RGA source maximum. That
is suggestive of a 13-bit width field or a width-indexed row buffer.

**But it is not an absolute width wall.** 8200x128 decodes 30/30 frames clean
with zero resets. And above 8192 the failures are *partial and strikingly
periodic* — in both 30-frame runs, exactly frames 4, 8, 12, 16, 20, 24, 28
failed and the other 23 decoded:

```text
1ok 2ok 3ok 4BAD 5ok 6ok 7ok 8BAD 9ok 10ok 11ok 12BAD  …  28BAD 29ok 30ok
```

**The period-4 pattern is core assignment, not a frame property.** Splitting the
reset log by device and error code settles it — over both 30-frame runs:

| core | device | code | count |
|---|---|---|---|
| core 0 | `fdc38100` | **`0x23`** (timed out) | 14 |
| core 1 | `fdc40100` | **`0x107`** (completed fine) | 14 |

14 core-0 timeouts, 14 bad frames. **Core 1 never timed out once.** The identical
geometry that kills core 0 decodes cleanly on core 1, so the failing frames are
simply the ones the CCU scheduled onto core 0; the period-4 rhythm is the
scheduling phase, not anything about frames 4/8/12.

And the two cores have *different thresholds*, not merely different luck:

| stream width | core 0 | core 1 |
|---|---|---|
| 8200 | `0x23` — times out | `0x107` — clean |
| 8440 (PICSIZE_B) | `0x23` — times out | `0x23` — times out |

So core 0 gives out somewhere at/below 8200 while core 1 survives to somewhere
between 8200 and 8440. That is why the original sweep burst showed `0x23` on
*both* devices while the 8200 experiments show it on only one.

Earlier reasoning in this finding leaned on a workload sweep at 8440x1056 —
6.6 KB to 55.9 MB of bitstream produced 1/4/5/4 resets, i.e. no scaling with
work — to conclude the failure was structural rather than a time budget. That
observation stands, but it does **not** license the "hard wall" conclusion,
because 8200x128 then decodes fine. Both simple stories are dead; the mechanism
is open.

### What differs between the two cores

Both are configured **identically** in `rk3588-rock-5b.dtsi` — same
`rockchip,rcb-info`, same `rockchip,rcb-min-width = <512>`, same
`rockchip,normal-rates` (800 MHz aclk), same `task-capacity`, same taskqueue.
Only two things differ, and **both match the vendor BSP
(`rockchip-linux/kernel.git` `rk3588s.dtsi`) verbatim** — this asymmetry is
Rockchip's, not an artifact of our forward-port:

| | core 0 (`fdc38100`) | core 1 (`fdc40100`) |
|---|---|---|
| SRAM pool | `0x0 + 0x78000` = **480 KiB** | `0x78000 + 0x77000` = **476 KiB** |
| RCB DDR fallback | `rcb-iova = 0xFFF00000` | `rcb-iova = 0xFFE00000` |

SRAM size does **not** explain it: core 0 has 4 KiB *more* and fails *earlier*.

The suspicious asymmetry is the fallback address. Core 0's 1 MiB RCB window is
`0xFFF00000 … 0x100000000` — it **ends exactly on the 4 GiB boundary**, with no
headroom, while core 1's sits an aperture below it. Any prefetch, alignment
round-up, or guard requirement past the end of core 0's window has nowhere to go
in a 32-bit IOVA space. That would make core 0 fail at a smaller width than
core 1, which is exactly what is observed.

The window is **fully backed and correctly reserved** — this is not a mapping
bug. `rkvdec2_alloc_rcbbuf()` maps SRAM for the first `sram_size` bytes and
`alloc_pages()` + `iommu_map()`s DDR for the remaining `rcb_size - sram_size`,
and the whole span is taken out of the session allocator via
`mpp_iommu_reserve_iova()` plus `mpp_iommu_shared_domain_reserve_window()`. RCB
entries are packed from `rcb_iova` upward as width grows, so wide pictures are
precisely the case that pushes allocations toward the top of the window — and on
core 0 the top of the window *is* the top of the address space.

**Bit depth does not scale this limit.** `mpp_rkvdec2.c:413` scales
`task->width` by bit depth, but that feeds only the timeout-bucket choice, not
the RCB geometry. A 10-bit ladder at heights 1056 decodes clean at every real
width up to 8192 (4096, 6144, 6560, 7680, 8192 — zero resets), including
real-width 7680 whose *effective* width is 9600. So 8K Main10 content is not in
scope, and the limit is on real luma width regardless of bit depth.

Candidate mechanisms, none confirmed:

- **RCB spill to DDR crossing the 4 GiB edge on core 0.** Row-cache buffers are
  width-sized by userspace and packed into SRAM by `mpp_set_rcbbuf()`; entries
  that do not fit fall back to the `rcb-iova` window
  (`"rcb: reg %d use original buffer"`). Wider pictures spill more. Testable
  with `DEBUG_SRAM_INFO` (`mpp_dev_debug` bit `0x200000`, root), and decisively
  by swapping the two cores' `rcb-iova` values — if the failure follows the
  address rather than the device, this is it.
- **Silicon or clock difference between the two cores**, which the DT swap test
  would also distinguish (failure stays on core 0 → not the address).

## Evidence and reproduction

- **Identity:** Rock 5B, kernel `6.18.40-ysp-rockchip64` (boot 0,
  2026-07-28 18:46 PDT), vendor MPP drivers, `librockchip-mpp1
  1.5.0+git20260727.d8c6b88a`, `rockchip-vaapi@a685db2` built in-tree.
- **Detection:** dual rkvdec2 cores `fdc38100`/`fdc40100` attached to the CCU as
  cores 0/1, `core_mask=00020002`, soft-CCU scheduling path.
- **Exercise:**
  ```sh
  # conformance vector
  tests/hevc_mpp_repro ~/Code/tmp/hevc-sweep/vectors/PICSIZE_B_Bossen_1.bit 10
  # synthetic, any geometry
  ffmpeg -f lavfi -i "color=c=gray:s=8200x1056:r=30:d=1" -frames:v 30 \
      -pix_fmt yuv420p -c:v libx265 -preset ultrafast \
      -x265-params crf=28 -f hevc g.h265
  tests/hevc_mpp_repro g.h265 30
  ```
  run from `~/Code/rockchip-vaapi`, with
  `journalctl -k -o short-monotonic | grep -c "resetting for err"` sampled
  before and after.
- **Attribution method:** all 20 non-`exact` vectors from the sweep were replayed
  individually against the reset counter (`~/Code/tmp/rkvdec-err23/`).
  `PICSIZE_B_Bossen_1.bit` was the **only** one that produced any reset.
- **No secondary fault signature.** Across every reset this boot the journal
  contains *only* `resetting for err` / `reset done`. No `soft reset fail`, no
  `bus busy`, no `rk_iommu` page fault. Recovery is clean every time.

Original burst (during the sweep) and the isolated reproduction are structurally
identical — same device order, same error code, 4 pairs, same cadence:

```text
sweep       [1396.376083 → 1396.500188 → 1396.564088 → 1396.628107]  Δ 124.1 / 63.9 / 64.0 ms
reproduced  [2079.128222 → 2079.252359 → 2079.320025 → 2079.384074]  Δ 124.1 / 67.7 / 64.0 ms
```

Sweep totals: `candidates=163 skipped=17 backend-failed=11 driver-failed=9
bit-exact=126`.

## A second, misleading error code: `0x107`

63 `0x23` and **15 `0x107`** resets were logged this boot. `0x107` decodes to
`IRQ | IRQ_RAW | READY_STA | CABAC_END_STA`, and `0x107 & err_mask(0xf0) ==
0x00`: **no error bit is set, and `READY_STA` means that core's decode completed
successfully.**

`rkvdec2_soft_ccu_reset()` logs `"resetting for err %#x"` with each core's last
latched `mpp->irq_status` for *every* core it walks, regardless of which core or
which path requested the reset. When a reset comes from queue level — software
timeout (`MPP_WORK_TIMEOUT_DELAY`, 500 ms), IOMMU fault handler, or session
abort — the message still says "err" and prints an unrelated status. So `0x107`
is a **logging defect, not a hardware error**: a successful task reported as a
failure.

## Our VA-API caps are wrong in both directions

| | value | measured |
|---|---|---|
| `RK_MAX_WIDTH` | 7680 | **too strict** — 7688, 8064, 8192 decode clean |
| `RK_MAX_HEIGHT` | 4320 | **too strict** — 8440 tall decodes clean |
| real limit | — | geometry-dependent, unenforced by any layer |

**Provenance: an advertisement that became a limit.** Neither number was ever
derived from hardware. The chain, from `git log -S`:

| commit | date / author | what happened |
|---|---|---|
| `3998a66` *Initial release … v1.0.4* | 2026-04-26, Eduardo García-Mádico Portabella (upstream, pre-fork) | `7680` appears as a bare literal in `rk_QuerySurfaceAttributes` — **advertised only**, as `VASurfaceAttribMaxWidth`. `4320` exists solely in `docs/DEVELOPMENT.md`, never in code. |
| `9119a50` *refactor: add zero-copy external decode buffers* | 2026-07-21, Yi Ding | first `if (width > 7680 \|\| height > 4320)` — the advertised figure becomes an **enforced rejection**, and `4320` graduates from doc example to code. |
| `c0edc91` *refactor: split surface lifecycle module* | — | carried along into the new module. |
| `760ef3c` *encode: add experimental H.264 VA path* | — | literals promoted to `RK_MAX_WIDTH`/`RK_MAX_HEIGHT` and **reused for encode**. |

The upstream context is decisive about intent. `docs/DEVELOPMENT.md` presents
the block as a **Firefox-compatibility recipe** — "…omits
`VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2`, Firefox silently falls back to
software decode. The driver must return:" followed by the attribute list
containing 7680/4320. The numbers are the "8K" marketing figure filled into a
capability query so a client would not disable hardware decode. They were never
a measurement, and nothing downstream ever tested them.

They are reported through `VAConfigAttribMaxPictureWidth/Height` **only for
encode**
(`rockchip_drv_video.c:251-256` returns `VA_ATTRIB_NOT_SUPPORTED` for decode),
but applied unconditionally to surface and context creation (`surface.c:172`,
`context.c:70`) and published as `VASurfaceAttribMaxWidth/MaxHeight`
(`rockchip_drv_video.c:553,558`) — which is what ffmpeg reads. An encode-derived
constant is what actually gates decode.

Neither `librockchip_mpp` nor the kernel enforces anything: MPP submitted the
8440-wide stream to hardware, and `mpp_rkvdec2.c:410-415` reads width only for
`task->pixels` and the `rcb_min_width` *minimum*. `RKVDEC2_8K_PIXELS
(7680*4320)` is defined at `mpp_rkvdec2_link.c:1583` and **never referenced**.

Datasheet context (RK3588S V1.3): the decoder rows are throughput figures —
`H.265 HEVC/MVC Main10 L6.1 : 8K@60fps (7680x4320)` — not a declared geometric
maximum. The datasheet states real size ranges when it means them
(`Encoder size is from 96x96 to 8192x8192`, RGA `Max resolution: 8192x8192
source`). **There is no published min/max picture-size range for the decoder.**

## Boundary

- **No output was ever verified.** `hevc_mpp_repro` reports frame count and MPP
  `errinfo`, has no dump path, and this ffmpeg has no `hevc_rkmpp` decoder.
  Every "clean" above means *the hardware raised no error*, not *the pixels are
  right*.
- **The 8192 boundary is height-specific.** It was bisected to (8192, 8200] **at
  height 1056 only**. 8200x128 is clean, so the boundary is a surface in at
  least two dimensions, not a single number. Nothing here maps that surface.
- **The period-4 failure pattern is unexplained** and was observed on synthetic
  x265 output only; it has not been checked against `PICSIZE_B` itself or any
  real-world stream.
- **The clock figure is a two-point fit** from inter-reset spacing, assuming the
  threshold register counts aclk cycles and that spacing = budget + constant
  overhead. Neither assumption is confirmed against the TRM.
- **HEVC Main 8-bit 4:2:0 only.** For 10-bit the driver scales `task->width` by
  bit depth before bucketing (`mpp_rkvdec2.c:413`), so effective limits differ.
- **Log cross-check was journald-only.** `/var/log/kern.log` is `syslog:adm` and
  this account is not in `adm`.
- **Timestamp discrepancy, unresolved.** The lines that opened this
  investigation were quoted as `1396.400520 / 1396.524060 / 1396.589246 /
  1396.654558`. That exact string appears in **no** boot in the journal; the only
  burst at that uptime is boot 0's `1396.376083 / .500188 / .564088 / .628107`,
  with slightly different deltas. Same device pair, error code and structure, so
  the analysis is unaffected, but the quoted lines are not verbatim from this
  machine and their provenance is unknown.

## A latent defect this investigation did *not* trigger

The buckets are selected by **pixel count**, with a cliff at
`RKVDEC2_4K_PIXELS`:

```text
8440x1112 = 9,385,280 px  -> 45 Mi (~61 ms)
8440x1120 = 9,452,800 px  -> 80 Mi (~109 ms)
```

Eight extra lines — 0.7 % more decode work — give **1.78× the time budget**. A
genuinely slow-but-decodable frame just under the boundary is killed where a
slightly larger one survives. Nothing observed here was caused by this, but it
is one `<` away in the same function and it is exactly the "let decodable frames
finish" failure mode.

## Verification gate

1. **Bisect each core's width threshold in isolation.** Disable one core at a
   time (`echo 1 > /proc/mpp_service/video-codecN/disable_work`, root) and rerun
   the synthetic width ladder. This turns "core 0 is worse" into two numbers and
   is the precondition for everything below. ~~Explain the period-4 pattern~~ —
   **CLOSED: it is core assignment**, see above.
2. **Swap the two cores' `rcb-iova`** in `rk3588-rock-5b.dtsi` and rebuild. If
   the lower threshold follows the `0xFFF00000` address to core 1, the 4 GiB-
   abutting fallback window is the mechanism; if it stays on core 0, it is
   silicon or clock. This is the decisive experiment.
3. **Settle RCB spill** with `DEBUG_SRAM_INFO` (`mpp_dev_debug` bit `0x200000`,
   root): do RCB entries fall back to DDR above 8192, and at what width?
4. **Map the failure surface, not a line.** Sweep width × height above 8192
   (widths 8200-8440 × heights 128, 256, 512, 1056), per core. The current
   single-height bisection cannot justify any guard value.
5. **Verify output correctness** before relaxing any cap: raise `RK_MAX_WIDTH`
   and `RK_MAX_HEIGHT` in a scratch `rockchip-vaapi` build and md5-compare
   against the software reference for PICSIZE_A and a synthetic 8192-wide clip.
6. Re-run the full sweep once the in-flight `pending[]` fix is built.

## Why it matters / follow-up

- **The kernel behaved correctly and nothing wedged.** Each core reset in ~30 µs,
  the IOMMU was refreshed, both cores rejoined the shared domain. The log lines
  are the recovery path working.
- **Do not add a hard width guard yet.** The obvious remediation — have MPP
  reject width > N — would wrongly reject 8200x128, which decodes fine. Gate 1
  has to come first. This is the concrete case for *not* rejecting frames the
  hardware can actually decode.
- **`RK_MAX_WIDTH 7680` and `RK_MAX_HEIGHT 4320` should still move.** They began
  life upstream as an *advertisement* — an "8K" figure written into a
  Firefox-compatibility attribute recipe — and were promoted to an enforced
  rejection during an unrelated refactor (`9119a50`), then reused for encode
  (`760ef3c`). No step in that chain measured anything. Both are demonstrably
  too strict, and the encode reuse is separately wrong: the datasheet documents
  the *encoder* at 96x96–8192x8192. Gate 5 is the precondition for changing
  them.
- **`"resetting for err %#x"` should not print a status the reset did not come
  from.** Reporting `0x107` — a completed decode — as an "err" sends anyone
  reading the log chasing a hardware fault that never happened.
- **The `_50MS`/`_100MS` macro names should be corrected to their cycle counts**
  or to measured values. They are BSP-inherited and misleading; any future
  timeout tuning that trusts them starts 22 % off.
- Relates to [`2026-07-27-rockchip-mpp-hevc-tiles-same-id-pps-update.md`](2026-07-27-rockchip-mpp-hevc-tiles-same-id-pps-update.md)
  and [`2026-07-28-vaapi-decode-readiness-and-remaining-work.md`](2026-07-28-vaapi-decode-readiness-and-remaining-work.md).

## Historical incidence

Across the 19 boots retained in the journal, resets appear in three:

| boot | started | reset pairs |
|---|---|---|
| -16 | 2026-07-25 19:22 | **227** (spanning 9624 s → 17483 s) |
| -4 | 2026-07-27 17:14 | 1 |
| 0 | 2026-07-28 18:46 | 39 (4 from the sweep, the rest from this investigation) |

The 227-pair storm on boot -16 is **not** attributed and is not explained here —
that boot predates this sweep, and a burst spanning two hours of uptime does not
match the single-stream signature. Open question.
