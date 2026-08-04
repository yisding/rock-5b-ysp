# rockchip-vaapi's remaining non-AV1 gaps split three ways: two are MPP walls, the size caps fail open below as well as closed above, and the sweep harness overwrites its own evidence

> Scope: C15 hardware codecs and status track 14; the `rockchip-vaapi` capability
> boundaries other than AV1 — the encode surface contract (P010, B-frames, packed
> headers, tiled imports), the decode/encode picture-size caps, the narrow AFBC
> 10-bit refusal, and the currency of the HEVC conformance sweeps.
> Source: `yisding/rockchip-vaapi` `main@a39c6290cc67cd13690a17c68f4d95c7196fd200`
> (clean worktree, installed as `1.0.11+ysp10-0ubuntu1~rk1`) —
> `src/driver_internal.h` (~:21-22), `src/rockchip_drv_video.c`
> `rk_GetConfigAttributes()` (~:229-244) and `rk_CreateConfig()` (~:335),
> `src/surface.c` `import_surface_descriptor()` (~:93,103) and (~:236),
> `src/context.c` (~:71-73), `src/convert.h` (~:10), `src/convert.c` (~:30);
> vendor MPP working tree `~/Code/rock-5b/rockchip-userspace/mpp-rockchip@483f8a47`
> — `mpp/hal/rkenc/common/vepu5xx_common.c` `vepu5xx_yuv_cfg[]` (~:208-245) and
> `vepu5xx_set_fmt()` (~:569), `mpp/codec/enc/h264/h264e_slice.c` (~:63),
> `mpp/codec/enc/h265/h265e_slice.c` (~:239-246), `mpp/common/h265_syntax.h`
> (~:195-197); librga fork
> `~/Code/rock-5b/rockchip-userspace/librga-fork@58064e3`; sweep reports
> `.test-work.hevc-sweep/report.tsv` and `.test-work.hevc-sweep-ppa/report.tsv`
> as found on disk.
> Date: 2026-08-04
> Trust: **SOURCE-INSPECTED** (MPP encoder format table and slice-type
> assignments) + **CODE-INSPECTED** (driver caps, import validation, size
> enforcement) + **MEASURED** (both sweep reports are prior recorded runs read
> off disk, **not** re-run for this finding) + **PARTIAL** (the missing-minimum
> defect and the overwrite hazard are code/artifact reasoning; neither was
> exercised on hardware)

> **Acted on the same day, 2026-08-04.** Two of the six items below were closed
> by decision rather than by further measurement:
>
> - **Picture-size caps raised to 8192x8192** (`src/driver_internal.h`), the
>   only range RK3588 publishes. The 2026-07-28 finding's gate 5 — md5-compare
>   `PICSIZE_A` and a synthetic 8192-wide clip before relaxing — was **not**
>   run, and the change proceeded anyway on a narrower argument: both PICSIZE
>   vectors carry an 8440 dimension, so neither changes class at an 8192 bound
>   and the sweep result is unchanged. What the change does newly admit is
>   untested geometry between 7680 and 8192 (measured clean at 7688, 8064 and
>   8192 wide, but never byte-compared). Gate 5 remains the right proof before
>   trusting that band. The driver rebuilt clean under `-Werror` and `make test`
>   passes; no hardware run was made.
> - **Narrow AFBC 10-bit below 68 pixels declined** — see the
>   [decision and rationale](../video-libraries/vaapi/README.md#declined-narrow-afbc-10-bit-below-68-pixels).
>   The section below stands as the record of what was open at inspection time.
>
> One premise correction feeding that second decision: **RGA2 does support
> 10-bit raster in both directions** (`rga2e_input_raster_format[]` and
> `rga2e_output_raster_format[]` both list `RGA_FORMAT_YCbCr_420_SP_10B`), and
> its width floor is 2. RGA2's gap is AFBC, not 10 bits. The no-core-match
> condition is the combination, not a shared missing capability.

## Result

The six non-AV1 items the record carries as "remaining" are not one class of
work. They split three ways, and the split changes what should be done about
each:

| Gap | Class | What it actually is |
|---|---|---|
| P010 encode | **MPP/silicon wall** | No `vepu5xx` register encoding exists for any 10-bit input format |
| B-frames | **MPP/silicon wall** | Both MPP encoders assign only I and P slice types |
| Narrow AFBC 10-bit (width < 68) | **Ours, planned, unstarted** | Two-workstream closure plan written 2026-07-29; neither workstream has landed |
| Tiled imports | **Ours, open** | Fails closed correctly; closing it is bounded RGA work with a real consumer |
| Packed headers | **Ours, open, no consumer** | Implementable, but MPP owns header generation and nothing in the app matrix needs it |
| Picture-size caps | **Ours, wrong in a third way** | Known too strict above; also enforces **no minimum at all** |

Two of the six are not driver work. Recording them as "remaining" invites
re-investigation of walls that have already been hit.

## The two MPP walls

**P010 encode.** `vepu5xx_yuv_cfg[]` maps `MPP_FMT_YUV420SP_10BIT` to
`VEPU5xx_FMT_BUTT` — the sentinel, not a format code
(`vepu5xx_common.c` ~:218-219). Every 10-bit entry in the table is `BUTT`:
`YUV420SP_10BIT`, `YUV422SP_10BIT`, and the 10-bit variants further down.
`vepu5xx_set_fmt()` turns that sentinel into a hard error:

```c
if (fmt && fmt->format != VEPU5xx_FMT_BUTT)
    memcpy(cfg, fmt, sizeof(*cfg));
else {
    mpp_err_f("unsupport frame format %x\n", format);
    cfg->format = VEPU5xx_FMT_BUTT;
    ret = MPP_NOK;
}
```

There is no 10-bit encoder input path to enable. The only way to feed a P010
surface to this encoder is to down-convert it to NV12 first, which discards the
precision that motivated the request. This is why the driver refuses to expose
`VA_RT_FORMAT_YUV420_10` to any encode config
(`rk_GetConfigAttributes()` ~:229-231, and the comment at `rockchip_drv_video.c`
~:519 — "do not expose P010 to 8-bit encoders"). The refusal is correct and
final. `make probe-mpp-main10-encode` already exists to re-demonstrate it.

**B-frames.** Both MPP encoders assign exactly two slice types. H.264
(`h264e_slice.c` ~:63):

```c
slice->slice_type = (is_idr != 0) ? (H264_I_SLICE) : (H264_P_SLICE);
```

HEVC has the same shape (`h265e_slice.c` ~:239-246): `curr.is_idr` selects
`I_SLICE`, the `else` branch selects `P_SLICE`, and those are the only two
assignments to `m_sliceType` in the encoder.

The HEVC encoder is the one that could mislead a future reader: it carries
several live-looking `B_SLICE` comparison branches (`h265e_dpb.c` ~:878-922,
`h265e_slice.c` ~:150,176,251), inherited from its x265-derived ancestry. They
are dead relative to the assignment sites — nothing in the encoder ever sets
`m_sliceType = B_SLICE`, so `B_SLICE` (value 0 in `h265_syntax.h` ~:195) is
unreachable. `H264_B_SLICE` appears only on MPP's *decoder* side.

The driver's `VAConfigAttribEncMaxRefFrames = 1` (~:237) is therefore an honest
advertisement of the backend, not a conservative placeholder.

## The size caps fail open below, not just closed above

The [2026-07-28 rkvdec2 finding](2026-07-28-rkvdec2-err23-picsize-oversize-width.md)
established that `RK_MAX_WIDTH 7680` / `RK_MAX_HEIGHT 4320`
(`driver_internal.h` ~:21-22) began as an upstream Firefox-compatibility
*advertisement*, were promoted to an enforced rejection in an unrelated
refactor, then reused for encode, and are measurably too strict — 7688, 8064 and
8192 decode clean, and 8440 tall decodes clean. Two things this inspection adds:

**There is no minimum.** Every use of those constants is an upper bound:

| Site | What it gates |
|---|---|
| `surface.c` ~:236 | decode/encode surface creation |
| `context.c` ~:71-73 | context creation, both entrypoints |
| `rockchip_drv_video.c` ~:257,260 | advertised `VAConfigAttribMaxPictureWidth/Height` (encode only) |
| `rockchip_drv_video.c` ~:558,563 | published `VASurfaceAttribMaxWidth/MaxHeight` (what FFmpeg reads) |
| `rockchip_drv_video.c` ~:243-244 | `VAConfigAttribEncMaxSlices`, **derived from `RK_MAX_HEIGHT`** |

No lower bound is checked anywhere in surface or context creation. The RK3588S
datasheet is explicit where it is silent about the decoder: *"Encoder size is
from 96x96 to 8192x8192"* (quoted in the 2026-07-28 finding). So the one place
the vendor documents a hard range is the place the driver does not enforce, and
a sub-96 encode context is accepted and handed down. Whether MPP or the kernel
rejects it is untested — see the gate below.

**The slice cap inherits the error.** `VAConfigAttribEncMaxSlices` is computed
from `RK_MAX_HEIGHT`, so a wrong height cap silently produces a wrong slice
cap. Any correction has to move both, and the encode reuse is separately wrong
in the other direction: the datasheet's encoder maximum is 8192x8192, larger
than the 7680x4320 decode-flavored guess currently advertised for encode.

## Narrow AFBC 10-bit: written, sequenced, unstarted

`WPP_D_ericsson_MAIN10_2.bit` at 64x240 remains the only failing row of the
Main10 sweep — class `driver`, "VA-API decode errored", against 10 bit-exact
and 5 profile skips in `.test-work.hevc-sweep/report.tsv`. The mechanism is
settled ([no-core-match finding](2026-07-29-rga-no-core-match-narrow-afbc-10bit.md))
and the remediation is fully specced in
[`narrow-10bit-closure-plan.md`](../video-libraries/vaapi/docs/narrow-10bit-closure-plan.md):
workstream A makes librga's `imcheck()` honest per-core, workstream B replaces
the up-front refusal with a linear-NV15 + CPU-repack fallback ladder.

Neither has started. `RK_RGA3_MIN_ACTIVE_WIDTH 68` is still the up-front refusal
(`convert.h` ~:10, applied at `convert.c` ~:30), and the librga fork's last
`im2d` commit is still `26a50ef` (2026-07-24); its only newer commit, `58064e3`,
is a samples-level dma_heap fallback. The plan's own sequencing says both should
land *before* the next Main10 sweep so the sweep exercises honest-imcheck and
narrow-linear together. Its phase-0 spike (S1 — does MPP grant linear NV15 at
width 64?) is a log-only change and decides whether workstream B is viable at
all; the plan states the contingency plainly, that if MPP forces AFBC the
shipped refusal is already correct behavior.

## The two gaps that are genuinely open

**Tiled imports.** `import_surface_descriptor()` rejects any
`drm_format_modifier != DRM_FORMAT_MOD_LINEAR`, on the first object (~:93) and
on the second when multi-plane (~:103), returning
`VA_STATUS_ERROR_INVALID_PARAMETER`. Failing closed rather than reinterpreting
an unknown layout is right. The cost is that a compositor-supplied
AFBC/tiled buffer cannot be encoded zero-copy, which is exactly the
screen-capture path. The conversion machinery for imported formats already
exists — RGB imports are gated on `rk_rga_available()` and converted through RGA
— so this is bounded work, but it needs a check of which modifiers RGA will
actually accept before it can be scoped.

**Packed headers.** The driver advertises `VA_ENC_PACKED_HEADER_NONE` (~:230)
and `rk_CreateConfig()` hard-rejects any other value (~:335). This one is
implementable and genuinely ours, but MPP generates its own SPS/PPS, so
honouring app-supplied header bytes means reconciling or splicing them against
what the hardware was actually configured to emit — a mismatched-stream risk for
no current consumer. FFmpeg and GStreamer encode both pass today without it.

## The sweep harness overwrites its own evidence

`tests/sweep-hevc-conformance.sh` defaults its report directory to
`$REPO_ROOT/.test-work.hevc-sweep` (~:73) **for both profiles** — `PROFILE`
selects Main or Main10 (~:47-61) but does not vary the output path. On disk:

| Report | mtime | Rows | Tally |
|---|---|---:|---|
| `.test-work.hevc-sweep-ppa/report.tsv` | 2026-07-29 05:32 | 163 | 144 exact / 17 skip / 2 unsup — the Main sweep, written to an explicit second-argument directory |
| `.test-work.hevc-sweep/report.tsv` | 2026-08-01 17:56 | 16 | 10 exact / 5 skip / 1 driver — the **Main10** sweep, in the shared default |

Two consequences. First, no Main-profile sweep result newer than 2026-07-29
exists on disk — that run was against the ysp6-era Published package root, and
ysp8, ysp9 and ysp10 have shipped since. Second, because the default directory
is shared, a Main-profile run *could* have happened after 07-29 and been
overwritten by the 08-01 Main10 run without leaving a trace. The artifact record
cannot distinguish those cases, which is itself the defect: profile should be in
the default path.

## Boundary

- **Nothing here was re-run.** Both sweep tallies are prior recorded output read
  off disk; their dates are file mtimes, not observed run times. This finding
  re-reads artifacts and source, and measures nothing new.
- **The missing minimum is a code fact, not an observed failure.** No sub-96
  encode context was created, and MPP's or the kernel's own reaction to one is
  unknown. It may fail safely one layer down.
- **The MPP walls are bounded to the pinned tree** `483f8a47` and to the
  `vepu5xx` HAL family that RK3588 selects (`hal_h264e_vepu580.c` names
  `ROCKCHIP_SOC_RK3588`). They are statements about this encoder generation, not
  about the RK3588 TRM, which was not consulted for either.
- **The tiled-import scoping is unverified.** No check was made of which DRM
  format modifiers RGA can consume, so "bounded work" is a judgement about the
  code shape, not a measured capability.
- **The overwrite hazard is inferred from the script's default and two mtimes**,
  not from an observed clobber.

## Verification gate

Cheapest first; the first two are single commands.

1. **Re-run the Main sweep** — `make check-hevc-conformance-sweep`, to an
   explicit report directory so it does not land in the shared default. This is
   the largest coverage currently unclaimed on the shipping driver, and it
   re-tests the two `unsup` size refusals for free.
2. **Fix the default report path** to include `$PROFILE`, so the two sweeps
   stop sharing a directory.
3. **Run narrow-10bit phase-0 (S1)** — log-only; skip the AFBC output-format
   request on the 64x240 vector and record `fmt` / `hor_stride` /
   `hor_stride_pixel`. Either answer is decisive for workstream B.
4. **Probe the missing minimum** — create a 64x64 encode context and record
   where it is refused, if it is. That decides whether the driver needs a
   96x96 lower bound or merely a documented one.
5. **Size caps** — unchanged from the 2026-07-28 finding's gate 5: raise the
   caps in a scratch build and md5-compare `PICSIZE_A` plus a synthetic
   8192-wide clip against the software reference before moving anything.

## Why it matters / follow-up

The record currently phrases P010 encode as "P010 backend support remains" and
lists B-frames alongside it, which reads as a queue of driver work. Both are
walls in MPP with no driver-side move available. Restating them as capability
statements — in the [`rockchip-vaapi` README](../video-libraries/vaapi/README.md)
encode-contract section and in the fork's `docs/ROADMAP.md` Phase 4 — removes
two items from an open list that can never close, and stops the next reader from
re-deriving the same two source facts.

The size-cap work has a real ordering dependency: `VAConfigAttribEncMaxSlices`
is computed from `RK_MAX_HEIGHT`, so the multi-slice encode gates would move
with any correction. That argues for doing the size work as one change after
gate 5, not opportunistically.
