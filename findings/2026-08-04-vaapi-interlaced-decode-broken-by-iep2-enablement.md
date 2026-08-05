# Enabling IEP2 broke interlaced VA-API decode by un-masking a driver defect: MPP's decoder deinterlacer is 1:N, VA-API decode is 1:1

> Scope: C15 hardware codecs and status track 14; `rockchip-vaapi` interlaced
> H.264 decode on the production forward-port kernel, MPP's decoder-internal
> vproc/IEP2 path, and the first standalone IEP2 evidence on a non-KASAN kernel.
> Source: booted `6.18.42-ysp-rockchip64`
> (`6.18.42+rk3588av1fwport20260803-0ubuntu1~rk1`, installed 2026-08-04 07:26);
> `librockchip-mpp1 1.5.0+git20260730.ad325345+ds-0ubuntu1~rk1`;
> `librga2 2.2.0+git20260725.26a50ef-0ubuntu1~rk1`;
> `ffmpeg 7:8.0.3+rockchip+git20260729.33a651a55b-0ubuntu1~rk1`;
> `yisding/rockchip-vaapi` `main@73dea57` plus the fix below, and installed
> `1.0.11+ysp10-0ubuntu1~rk1`; libmpp fork
> `~/Code/rock-5b/rockchip-userspace/mpp-rockchip@483f8a47` —
> `mpp/vproc/mpp_dec_vproc.c` `dec_vproc_set_dei_v1()` (~:300-305),
> `dec_vproc_dei_v2_deinterlace()` (~:627-690), `dec_vproc_put_frame()`
> (~:104-149), `mpp/codec/mpp_dec.c` (~:65-69, ~:1014),
> `mpp/vproc/mpp_vproc_dev.c` `get_iep_ctx()` (~:33-51),
> `/usr/include/rockchip/rk_mpi_cmd.h` (~:99); driver `src/context.c`,
> `src/mpp_dec.c` `assign_mpp_frame()` (~:425-500).
> Date: 2026-08-04
> Trust: **MEASURED** + **ROOT-CAUSED** + **BOARD-REPRODUCED** (deterministic,
> a pinned conformance vector) + **SOURCE-INSPECTED** +
> **FIX-RUNTIME-VERIFIED** (17/17 pinned vectors, `check`, `check-sanitize`) +
> **PARTIAL** (only the tier-1 gate set was run; sweeps, encode/experimental,
> display, and the two 7,200 s soaks were not)

## Result

> **Subsequent qualification update, 2026-08-04:** the exact `0092` kernel and
> installed ysp12 driver later completed the broad VA-API campaign, including
> all 163 HEVC Main vectors, Main10/10-bit and encode gates, plus both 7,200 s
> soaks. The encode soak is green; the decode workload and kernel scan are green
> while its strict fd-span oracle remains red. That later result supersedes only
> this finding's skipped-campaign boundary, not its one-vector interlaced
> limitation. See the
> [production finding](2026-08-04-forward-port-6-18-42-0092-production-validation.md).

Kernel `6.18.42` enabled IEP2. The next conformance run failed one vector:
`h264/CABREF3_Sand_D.264` (352x288, `field_order=tt`), the only **interlaced**
stream in the pinned set, with
`Failed to sync surface: 23 (internal decoding error)`. Sixteen of seventeen
vectors stayed bit-exact and the kernel journal was silent — no fault, IOMMU
error, reset, or timeout.

**The kernel did not break the driver. It removed an accident that had been
masking a driver defect since the beginning.**

MPP's decoder enables its internal vproc deinterlacer *by default* — the public
header says so outright (`rk_mpi_cmd.h:99`): *"MPP enable deinterlace by
default. Vpuapi can disable it."* Consumers are expected to opt out.
`rockchip-vaapi` never did; it contains no reference to deinterlace or vproc
anywhere in `src/`.

That was harmless only because every RK3588 kernel this driver had ever run on
shipped **no IEP2 client**. `get_iep_ctx()` selects on
`access("/dev/mpp_service", F_OK)` — the node always exists — so vproc was
always selected, but IEP2 init then failed with the long-known harmless
`rk_vcodec cmd 100 ret -22`, MPP fell back to a plain decode, and the interlaced
vector came out bit-exact **by luck rather than by design**. Once IEP2 was
present, init succeeded and a code path that had never once executed on this
stack started running.

The disappearance of the `-22` warning looked like an improvement. It was the
regression signature.

## Root cause: a frame-cardinality and timestamp mismatch

MPP's deinterlacer changes how many frames exist and invents timestamps for the
ones it adds. In the I5O2/I4O2 path (`dec_vproc_set_dei_v1()` ~:300-305, and the
v2 equivalent) two frames are emitted per input field pair, and the interpolated
one is given a synthesized PTS:

```c
RK_S64 first_pts = (prev_pts + curr_pts) / 2;
dec_vproc_put_frame(mpp, frm, dst0, first_pts, frame_err);   /* invented */
dec_vproc_put_frame(mpp, frm, dst1, curr_pts,  frame_err);   /* real     */
```

`rockchip-vaapi` routes H.264/HEVC output by a **unique PTS token**: one
submitted picture maps to exactly one surface fence (`assign_mpp_frame()` →
`h264_route_take()`). The interpolated frames carry a PTS matching no submitted
token, so every one of them is dropped as unroutable, and surfaces whose frames
were consumed by the mismatch never complete. `vaSyncSurface` then returns
`VA_STATUS_ERROR_DECODING_ERROR`.

Measured on the failing vector:

| Quantity | Value |
|---|---:|
| Coded pictures in the clip | 50 |
| Frames MPP's vproc emitted | 98 |
| Frames the driver dropped as unroutable | 48 |
| Parity of every dropped PTS | 100 % even (2, 4, 6, …) |

Roughly 2x output, and precisely the surplus half is unroutable.

### Why no amount of routing repair would fix it

VA-API decode is **1:1 by construction**. The client allocates one surface per
coded picture and brackets each with `vaBeginPicture`/`vaEndPicture`. There is
nowhere to deliver a second decoded frame: the client never allocated a surface
for it and would not recognise its synthesized timestamp. Deinterlacing in
VA-API belongs to `VAEntrypointVideoProc`, where the client allocates the output
surfaces and drives one pipeline call per output frame.

So a VA-API **decode** backend must never deinterlace internally, and this is a
property of the API contract rather than a tuning choice.

## Fix

Disable MPP's decoder-internal vproc at decode-context creation
(`src/context.c`, in the non-encoder branch after `mpp_init`):

```c
RK_U32 enable_deinterlace = 0;
if (c->mpi->control(c->mpp, MPP_DEC_SET_ENABLE_DEINTERLACE,
                    &enable_deinterlace) != MPP_OK)
    LOG_WARNING("CreateContext: could not disable MPP deinterlacing; "
                "interlaced streams may decode through vproc");
```

Verified on the booted kernel: **17/17 pinned vectors bit-exact** including
`CABREF3_Sand_D.264` via VA-API, `make check` PASS, `make check-sanitize` PASS
with zero ASan/UBSan reports, and no `select in vproc` line at all.

A control failure logs a warning rather than failing context creation. If it
ever fails, interlaced streams regress to this same hard decode error — not to
silent corruption — so the softer handling is proportionate.

Regression coverage already exists: `CABREF3_Sand_D.264` is a pinned
conformance vector, so re-enabling vproc trips the gate immediately.

## This is not an IEP2 defect, and IEP2 now has production-kernel evidence

The IEP2 forward port works. Standalone `iep2_test` on the running
`6.18.42-ysp-rockchip64`:

| `-m` | Mode | Exit | Output | Nonzero |
|---|---|---|---|---|
| 1 | `IEP2_DIL_MODE_I5O2` | 0 | 921,600 B (the expected `(6-2)*2*115200`) | 100 % |
| 5 | `IEP2_DIL_MODE_I1O1T` | 0 | 921,600 B | 50 % |

Outputs differ between modes, so mode selection reaches hardware, and the kernel
journal logged nothing across both runs. This matters independently of the
regression: the
[2026-08-03 IEP2 finding](2026-08-03-rk3588-iep2-nondeterministic-output.md)
validated the port on `6.18.41-video-port-kasan-rockchip64`, a different and
KASAN-instrumented kernel. Until now "IEP2 works" had never been shown on the
kernel that actually ships it.

The incompatibility is between MPP's *decoder integration* of IEP2 and VA-API
decode semantics — not in the kernel driver.

## Two hypotheses that looked right and were not

Recorded because both are the sort of thing a reader would re-derive:

- **"The buffer-less info-change frame is the failure."** The vproc trace shows
  `mpp_buffer_get_ptr invalid NULL input` and `buf ptr (nil)` for the first
  frame. That is normal: `dec_vproc_put_frame()` also carries the info-change
  and EOS *signal* frames, which are deliberately put with a NULL buffer, and
  the driver already handles info-change at `assign_mpp_frame()` ~:427. The
  error line is emitted **by the debug statement itself** dereferencing a
  pointer it knows may be NULL. Fixed in the libmpp fork; see below.
- **"The decoder drives untested IEP1-style modes."** `dec_vproc_set_dei_v1()`
  does set `IEP_DEI_MODE_I4O2`/`I2O1`, but the **v2** path is what runs on
  RK3588, and it selects `IEP2_DIL_MODE_I5O2`/`I1O1T` — exactly the two modes
  proven working above. Likewise `dec_vproc_start_dei_v2()` ignoring its `mode`
  argument is correct, not an asymmetry: v2 configures through
  `IEP2_PARAM_TYPE_MODE` in `dec_vproc_config_dei_v2()`, including `dil_order`
  arbitration between stream syntax and IEP's own detection confidence.

## The one real libmpp defect found

`dec_vproc_put_frame()` dereferenced `impl->buffer` in its debug trace, but that
function also carries the NULL-buffer signal frames, so
`mpp_buffer_get_ptr "invalid NULL input"` was logged at **error level during
entirely normal operation**. Severity is low and bounded — it is debug-only
(zero occurrences without `vproc_debug`, one with) — but it is a false error
that actively misdirected this investigation. Guarded in the fork.

## Attribution, and what was ruled out

The last green 17/17 run was 2026-08-03 with installed ysp10. Only one thing
changed between that run and this failure:

| Component | Installed | Verdict |
|---|---|---|
| `librga2` | 2026-07-25 | unchanged — not the variable |
| `librockchip-mpp1` `ad325345` | 2026-08-01 | already in place on 08-03 — **not** the variable |
| `rockchip-vaapi` ysp10 | 2026-08-03 | ran 17/17 green that day |
| **kernel `6.18.42`** | **2026-08-04** | **the only change** |

Also ruled out: the same-session picture-size cap change (7680x4320 →
8192x8192) is **not** implicated — the installed ysp10 payload, carrying the old
constants, fails identically on this kernel. And it is not a memory-safety
issue: the sanitizer run produced zero ASan/UBSan reports.

## Boundary

- **At this checkpoint only the tier-1 gate set had run.** Build/lint/unit, sanitizer/TSan/Valgrind
  unit, driver-objects, synthetic, zero-copy, concurrent-decode, HEVC, tiles
  backend, conformance, `check`, `check-sanitize`. The 163-vector HEVC Main
  sweep, the Main10 sweep, all encode and 10-bit experimental gates, the four
  display-app gates, and both 7,200 s soaks had **not** run on this predecessor;
  the subsequent qualification update above owns their current result.
- **One interlaced vector is thin coverage.** `CABREF3_Sand_D.264` is 352x288
  TFF. No BFF, PAFF/MBAFF variety, or 1080i content was exercised, and the
  pinned set contains no other interlaced stream.
- **The fix is verified by absence.** Its proof is that vproc never initializes
  and decode matches the software reference. No test asserts the control call
  itself succeeded.
- **IEP2 output was checked structurally, not for correctness.** Sizes, nonzero
  ratio, and mode-to-mode difference — not deinterlacing quality against any
  reference. The I1O1T run returning the same byte count as I5O2 with 50 %
  nonzero is unexplained and probably a harness framing artifact; it was not
  investigated.
- **`IEP2_DIL_MODE_I1O1B` is never selected** anywhere in `mpp_dec_vproc.c`;
  both bootstrap sites hardcode `I1O1T`. Whether that is wrong for BFF content
  depends on register semantics not settled here, and the IEP2 audit already
  lists TFF/BFF plus I1O1 mode correctness as an unmet gate.

## Verification gate

1. **Closed later 2026-08-04:** the broad exact-`0092` campaign ran the skipped
   HEVC, Main10, encode/10-bit, and soak gates; read the production finding for
   the per-gate verdict and decode-oracle boundary.
2. Add broader BFF and 1080i interlaced vectors to the pinned set. One 352x288 TFF clip
   is the entire current guard against this class of defect.
3. **Hardware parity closed; integration follow-up remains:** the dedicated
   TFF/BFF run settled `I1O1T` versus `I1O1B` and exposed a separate libmpp BFF
   bootstrap defect. Runtime-verify that fix and keep the untriggered software
   timeout as a fault-injection gap; see the
   [field-parity finding](2026-08-04-iep2-field-parity-closed-and-i1o1-bff-bug.md).

## Why it matters / follow-up

The Phase 5 rule — *re-run the conformance and app matrix on each libva/MPP/
kernel bump* — is what caught this, on the first kernel bump after it was
written. It found a defect that had been latent in the driver since its
renovation and would have shipped to users the moment an IEP2-capable kernel
reached them.

It also generalises: **a capability appearing in the kernel can break userspace
that silently depended on its absence.** The forward-port programme turns
vendor blocks on one at a time, so this failure mode will recur. Enabling a new
mpp_service client is a userspace-visible event and deserves a conformance run,
not just its own driver gate.

There is no hardware deinterlacing on this pipeline today and there never has
been: the driver advertises only `VAEntrypointVLD` and `VAEntrypointEncSlice`,
so a client cannot request it. The hardware is capable and now proven working;
the gap is purely the missing VPP entrypoint. That plan is now **Phase 6** of
the fork's `docs/ROADMAP.md`, designed around driving IEP2 through libmpp's
standalone `get_iep_ctx()` API — whose symbols are already exported from the
shipped `librockchip_mpp.so` — rather than through the decoder-coupled
`mpp_dec_vproc`.
