# Why AV1 is hard for the VA-API↔MPP bridge (and H.264/HEVC/VP9 are not): the bitstream-reconstruction spectrum

> Scope: the reconstruction strategy the `rockchip-vaapi` VA-API-over-MPP
> bridge uses, and why it makes AV1 decode far harder than H.264/HEVC/VP9 —
> the rationale behind scoping AV1 out of the driver's v1 (VP9 fallback)
> Source: `yisding/rockchip-vaapi` (`rockchip_drv_video.c`
> `rk_QueryConfigProfiles` AV1 comment, `do_generic_decode`, `h264.c`;
> `docs/DEVELOPMENT.md` AV1 note); codec bitstream formats (H.264/HEVC NAL,
> VP9 frame, AV1 OBU); the av1-fwport `av1_rkmpp` decode validation
> Date: 2026-07-21
> Trust: SOURCE-INSPECTED (the driver's per-codec handling) / INFERRED
> (the spec-level reasoning about what each VA-API entrypoint passes) /
> MEASURED (the cross-referenced `av1_rkmpp` hardware decode)

## Result

The bridge's difficulty per codec is **not** about decode-hardware capability —
`mpp_rkvdec2` decodes AV1 fine. It is entirely about the bridge's strategy:
**reconstruct the compressed bitstream that MPP re-parses**, from what VA-API
hands over. AV1 is the one codec where VA-API discards exactly the part you
would have to rebuild (a large, per-frame header), so reconstruction becomes a
large and fragile job. The root cause is the impedance mismatch between a
*stateless* API (VA-API) and a *stateful* decoder (MPP).

## Why the bridge reconstructs bitstream at all

VA-API is stateless: the application (libavcodec) parses the bitstream, hands
the driver **parsed headers as C structs** plus the **raw entropy-coded
payload**, and expects the driver to program hardware from the structs. MPP is
the opposite — a stateful decoder that does its **own** parsing and manages its
own DPB; it wants the **original compressed bytes**. So the bridge ignores most
parsed structs, **regenerates the original bitstream**, and feeds it to MPP,
which re-parses it. The per-codec question is: *how much of the original
bitstream must you regenerate versus pass through verbatim?*

## The spectrum

| Codec | What VA-API hands the driver | What the driver must reconstruct | Effort |
|-------|------------------------------|----------------------------------|--------|
| **VP9** | The **whole coded frame**, header included, as slice-data payload | **Almost nothing** — pass it through. Only sequencing wrinkles: superframes, `show_existing_frame`/altref routing. | ~0 (`do_generic_decode`) |
| **H.264 / HEVC** | Slice payloads **verbatim** + parameter sets as structs | Parameter sets (SPS/PPS, +VPS for HEVC): small, mostly *static across the stream*, emitted once/per-IDR; the heavy slice data passes through untouched | Bounded (`h264.c` ≈170 lines; HEVC 2–3×) |
| **AV1** | **Only the tile data** + sequence & frame headers as structs | A **sequence-header OBU and a full frame-header OBU, every frame**, with correct OBU framing — VA-API consumed the headers and does *not* pass them through | Large & fragile |

VP9 is trivial because the frame's header travels with the payload.
H.264/HEVC are tractable because the regenerated part is small, standardized,
and largely constant. AV1 breaks the pattern: feeding MPP only the tile data
(the VP9 shortcut) makes MPP hit entropy-coded tiles with no preceding
frame-header OBU — it **never acknowledges `info_change` and decodes zero
frames** (the recorded symptom; `rk_QueryConfigProfiles` AV1 comment and
`docs/DEVELOPMENT.md`).

## Why AV1's frame header specifically is the wall

Regenerating an AV1 frame header is a different order of problem than an
H.264 SPS/PPS, for five compounding reasons:

1. **Per-frame, not per-sequence.** H.264/HEVC parameter sets describe the
   *stream* and rarely change; AV1's frame header changes *every frame*, so you
   re-encode a large syntax structure on the hot path for every picture.
2. **Huge and densely conditional.** The AV1 uncompressed frame header carries
   reference selection, frame-level quantization, segmentation, loop filter,
   CDEF, loop restoration, global motion, tile info, superres, and film grain,
   with heavy nested conditionality (fields present only under specific
   combinations of earlier flags). Bit-exact write-back is a large, error-prone
   body of code versus a short flat SPS.
3. **Entropy-coder state must line up.** AV1 carries probability-model (CDF)
   context *across frames* (`primary_ref_frame`, `refresh_frame_context`,
   `disable_frame_end_update_cdf`). A slightly wrong reconstructed header
   desyncs MPP's arithmetic decoder → total garbage, with **no graceful
   degradation and almost no diagnostic**.
4. **Reference bookkeeping.** The header names which of AV1's 8 reference slots
   the frame uses, plus order hints; you must reproduce the encoder's exact
   bookkeeping from parsed values.
5. **OBU framing.** You also emit correct OBU headers, `leb128` size fields,
   temporal delimiters, and tile-group framing — more assembly than H.264's
   start codes.

## The clarifying proof

This is a plumbing problem, not a hardware one: **our own stack already decodes
AV1 in hardware.** Through ffmpeg's `av1_rkmpp` path, MPP gets a real OBU
bitstream straight from the MP4/MKV container and `rkvdec2` decodes it —
hardware-validated bit-exact on the av1-fwport build (2026-07-04,
`decode-differential.sh`; needs that variant's `mpp_av1dec.c`; see the
[Kodi/FFmpeg operation boundary](../apps/kodi/docs/build-hwaccel.md#6-known-limits)).
Same hardware, same MPP. The VA-API bridge fails on AV1 *only because VA-API
already tore the OBUs apart* and the bridge would have to rebuild them.

## Consequence for the driver

AV1 reconstruction is possible (the spec is fully specified; dav1d/libaom show
every field), but it is the highest-effort, highest-fragility, lowest-marginal-
benefit codec: browsers fall back to hardware VP9 for AV1 content, which the
bridge decodes today. Hence AV1 is scoped **out of v1** in the
[production roadmap](https://github.com/yisding/rockchip-vaapi/blob/ysp/cleanup/docs/ROADMAP.md)
and the [app-enablement map](../docs/app-enablement.md).

The general lesson for the whole bridge: difficulty tracks the
stateless-API/stateful-decoder impedance mismatch. Where it is small (VP9:
header rides with payload) the bridge is trivial; where it is large (AV1:
fine-grained parse + big per-frame header) it is brutal. If MPP ever exposed a
parsed/stateless input path, AV1 would stop being special.
