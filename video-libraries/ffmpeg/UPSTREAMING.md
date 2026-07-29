# Upstreaming decisions — FFmpeg Rockchip

This package holds the ffmpeg-rockchip build recipe plus the exported patch
series and findings that back it, and this file is its upstream submission
disposition decided 2026-07-29. Cross-package ordering and coupling
constraints live in the central upstreaming ledger
([`../../docs/upstreaming-ledger.md`](../../docs/upstreaming-ledger.md));
dated claims below must be re-verified against current upstream state before
acting.

## Decision list

| ID | Item | Artifact | Upstream target | Decision | Priority | Gates / prerequisites |
|----|------|----------|------------------|----------|----------|------------------------|
| FF-1 | v4l2_buffers copy-bounds rewrite (multiplanar NULL deref, source overread, linesize corruption) | patches/0028, 0020 (libavcodec/v4l2_buffers.c, ~150 lines); plan A1 | FFmpeg upstream — confirm channel: code.ffmpeg.org/FFmpeg/FFmpeg PR track vs ffmpeg-devel | SUBMIT-NOW | P1 | — |
| FF-2 | v4l2_context negotiation fixes + mplane-aware fourcc selection and format-table rows | libavcodec/v4l2_context.c (~65 lines), v4l2_fmt.c/h (~70 lines); plan A2+A3 | FFmpeg upstream — inherit FF-1's channel | SUBMIT-AFTER-GATE | P2 | FF-1 posted and its first review round returned |
| FF-3 | libavdevice/v4l2.c generics: device_caps, planes[] init/bytesused bounds, two-pass format fallback, NV21 | libavdevice/v4l2.c + v4l2-common.c (~60 lines); plan A4 | FFmpeg upstream — inherit FF-1's channel | SUBMIT-AFTER-GATE | P3 | FF-1 first review response received |
| FF-4 | pixdesc big-endian x-offset fix plus fate-pixdesc test hookup | libavutil/pixdesc.c + tests/fate/libavutil.mak; plan A5+A6 | FFmpeg upstream — confirm with FF-1, send in parallel | SUBMIT-NOW | P3 | — |
| FF-5 | rkmppenc constant-QP rate control for upstream's own RKMPP H.264/HEVC encoder | upstream-patches/0001-avcodec-rkmppenc-add-constant-QP-rate-control.patch (rkmpp-cqp @ eaadedce43db) | FFmpeg upstream — code.ffmpeg.org PR (confirm first) | SUBMIT-AFTER-GATE | P1 | Board hardware gate per patch README (H.264/HEVC, several QP values, qp_init=22 -> FIXQP, VBR/CBR/AVBR unchanged); rebase onto current master, re-run fate-source |
| FF-6 | Memory-safety class: export-frame double-free, buffer-group double-free, submit unwind, get_packet position, RGA error-path lifecycle, overlay uninitialised blend, swscale overread | ~10 logical patches re-sliced from patches/0001-0017; plan §B | nyanmisaka/ffmpeg-rockchip (GitHub PR) | SUBMIT-NOW | P1 | — |
| FF-7 | Hang/deadlock class: EOS-with-data never latches eof, send_eos busy-loop, receive-loop EAGAIN deadlock, encoder async queue frame-drop | ~4 logical patches incl. 0003, 0009; plan §B | nyanmisaka/ffmpeg-rockchip (GitHub PR) | SUBMIT-NOW | P1 | — |
| FF-8 | rkmppenc bounded synchronous output wait plus transient MPP input-backpressure absorption | fix/rkmpp-output-timeout @ 540657970e, da5befc806 | nyanmisaka/ffmpeg-rockchip (GitHub PR) | SUBMIT-AFTER-GATE | P1 | Forward-port da5befc806 from the 8.0 packaging branch onto canonical main/ffmpeg-81; close the open GRD combined-workload runtime stress gate on the board |
| FF-9 | rkmppdec out-of-band extradata: send BSF-filtered extradata before the first packet, mark it MPP extra-data (fixes AV1 from MP4/MKV) | be367abfe6 plus the extradata-send hunk of 3fecea975b | nyanmisaka/ffmpeg-rockchip (GitHub PR) | SUBMIT-AFTER-GATE | P2 | W08: re-test AV1 decode from MP4 and MKV through av1_rkmpp on RK3588 |
| FF-10 | Wrong-output class: SAR/transpose orientation, AFBC 10-bit strides, RGA core-mask literals, colorspace defaults, crop centring, vpp 10-bit forced-RGA2, unscaled NV15 tails | ~14 logical patches incl. 0010, 0011, 0019, 0023, 0025; plan §B | nyanmisaka/ffmpeg-rockchip (GitHub PR) | SUBMIT-AFTER-GATE | P2 | Runtime-verify transpose rotate-mode orientation on RGA hardware; first-wave reception (FF-6/FF-7 acknowledged) |
| FF-11 | Restore the endian-neutral AV_PIX_FMT_NV20 alias and repair the broken fate-imgutils reference | plan §B "Broken-in-his-tree-only" pair | nyanmisaka/ffmpeg-rockchip (GitHub PR) | SUBMIT-NOW | P2 | — |
| FF-12 | Small-fixes bundle: AVERROR_EOF sign bug, assignment precedence, MJPEG RC/format gaps, extradata size padding, DV-timings fraction, mmap_free leak, v4l2 mplane validation, decoder/encoder flush, DMA-BUF cache-sync flags, allocator pitch/overflow | ~20 items across patches/; plan §B | nyanmisaka/ffmpeg-rockchip (GitHub PR) | SUBMIT-AFTER-GATE | P3 | FF-6 and FF-7 reviewed, establishing a working rhythm first |
| FF-13 | DRM descriptor/layout validation frameworks, afbc_offset_y as a real descriptor field, odd-YUV-dimension rejection | ~750 lines rkrga + ~350 lines rkmppenc + ~90 lines hwcontext validation; plan §B | nyanmisaka/ffmpeg-rockchip (GitHub design issue, then PR) | HOLD | P3 | Maintainer responds to a design issue on the hardening rationale and public-struct change; FF-6/FF-7 landed first |
| FF-14 | NV15 / NV20_PACKED compact 10-bit pixel formats as a full upstream feature series | pixdesc/imgutils/swscale support plus FATE refs across canonical branches | FFmpeg upstream (ffmpeg-devel ML) | HOLD | P3 | A concrete second consumer or upstream appetite; settle the nv20_packed naming question first |
| FF-15 | libavformat/id3v2 sliver: reject unknown text encodings instead of falling through to an empty tag | libavformat/id3v2.c decode_str() hunk in 8b57e531d1 / be753f3bbb2c | FFmpeg upstream (ffmpeg-devel ML) | HOLD | P3 | Confirm against vanilla master that the fall-through produces a bogus tag rather than benign empty output; build a FATE-able sample |
| FF-16 | FFmpeg-8.x port glue and self-inflicted regression fixes, including "drop static decoder pixel formats" | 371202839d plus FilterLink / ffhwframesctx() / CODEC_PIXFMTS_ARRAY / version-and-APIchanges commits; plan §C | none (would be nyanmisaka/ffmpeg-rockchip) | NEVER | P3 | — |
| FF-17 | Removal of unsafe RFBC DRM modifiers | patches/0018-drop-unsafe-rfbc-modifiers.patch | none (would be nyanmisaka/ffmpeg-rockchip) | NEVER | P3 | — |

## Rationale and evidence

### FF-1 — v4l2_buffers copy-bounds rewrite
The strongest item in this track and the plan's designated channel-establishing series: it fixes a reachable NULL deref in vanilla upstream m2m encode (multiplanar frames with only buf[0]), a source overread when driver height exceeds frame height, and output corruption when linesize differs from bytesperline. The fix sits on pure vanilla v4l2_buffers.c untouched by nyanmisaka's fork, so it carries no fork-only dependency. Not yet reproduced on a real v4l2 m2m device, which the cover letter should say plainly; FF-2/FF-3 are gated on how this one is received.
- Evidence: [docs/submission-plan.md](docs/submission-plan.md), [docs/rebase-notes.md](docs/rebase-notes.md), [patches/README.md](patches/README.md), [docs/fix-candidates.md](docs/fix-candidates.md), [../../status.md](../../status.md)
- Coupled with: FF-2, FF-3

### FF-2 — v4l2_context negotiation fixes and mplane-aware fourcc selection
VIDIOC_TRY_FMT's result is never checked, v4l2_get_raw_format() can return success without writing its output pointer and corrupt the negotiated format, and the enum loop can alias fourccs so MJPEG negotiates as raw. Held behind FF-1 only for review-bandwidth sequencing, since it is the same source-analysis and compile/fate-source evidence class; if FF-1 draws a maintainer wanting the whole negotiation story at once, fold this into that thread.
- Evidence: [docs/submission-plan.md](docs/submission-plan.md), [docs/rebase-notes.md](docs/rebase-notes.md), [patches/README.md](patches/README.md), [docs/fix-candidates.md](docs/fix-candidates.md)
- Coupled with: FF-1

### FF-3 — libavdevice/v4l2.c generics
Independent of FF-1/FF-2 in code but gated on the same channel-establishment signal since it is the lowest-severity of the three v4l2 series. Covers device_caps use, planes[] zero-init plus bytesused/INT_MAX bounds, a two-pass pixel-format fallback, and an NV21 mapping; fold in the same scrutiny fix-candidates.md flags for the related VIDIOC_G_DV_TIMINGS fallback rather than shipping the fork's placement unexamined.
- Evidence: [docs/submission-plan.md](docs/submission-plan.md), [docs/rebase-notes.md](docs/rebase-notes.md), [docs/fix-candidates.md](docs/fix-candidates.md)
- Coupled with: FF-1

### FF-4 — pixdesc big-endian x-offset fix plus fate-pixdesc hookup
Two self-contained hunks with no Rockchip content and nothing for a reviewer to argue about: a latent step>8 big-endian offset bug in av_read/write_image_line2, and wiring the already-built libavutil/tests/pixdesc into FATE where it exercises the corrected path. Send in parallel with FF-1 rather than behind it; the goodwill carries into the v4l2 series.
- Evidence: [docs/submission-plan.md](docs/submission-plan.md), [docs/rebase-notes.md](docs/rebase-notes.md)

### FF-5 — rkmppenc constant-QP rate control
The one item where a finished, standalone patch against vanilla FFmpeg already exists, targeting the real upstream rkmppenc.c added 2025-10-07 (61b034a47c) that the 2026-07-02 plan predates. It exposes rc=auto|vbr|cbr|cqp|avbr with qp and a qp_init compatibility alias, pinning inter/intra QP bounds for the whole stream. Held only on the hardware gate its own README names as pending, which this board can close cheaply; while closing it, look at whether rkmpp_send_frame's blanket AVERROR_EXTERNAL mapping is reachable (that would be the FF-8 defect class living upstream), but reachability has not been demonstrated.
- Evidence: [upstream-patches/README.md](upstream-patches/README.md), [upstream-patches/0001-avcodec-rkmppenc-add-constant-QP-rate-control.patch](upstream-patches/0001-avcodec-rkmppenc-add-constant-QP-rate-control.patch), [../../packaging/userspace-patches.md](../../packaging/userspace-patches.md), [docs/submission-plan.md](docs/submission-plan.md)

### FF-6 — Memory-safety class (fork)
The plan's explicit first wave and the highest-severity fork work, with every bug verified present verbatim in nyanmisaka's tree rather than introduced by this port: export-frame and buffer-group double-frees, an encoder submit unwind that leaves unreclaimable queued entries, a get_packet position bug, RGA error-path lifecycle leaks/double-frees, an uninitialised overlay blend, and a swscale one-byte overread. Fork aliveness is real but not fatal — master is 388741a3544b (2026-07-18) — though only 1 of 14 PRs there has ever merged, so jellyfin/jellyfin-ffmpeg (470/529 merged) is the validated fallback route, not a contingency.
- Evidence: [docs/submission-plan.md](docs/submission-plan.md), [docs/rebase-notes.md](docs/rebase-notes.md), [patches/README.md](patches/README.md), [docs/fix-candidates.md](docs/fix-candidates.md), [docs/jellyfin-ffmpeg-patch-survey.md](docs/jellyfin-ffmpeg-patch-survey.md)
- Coupled with: FF-7, FF-10, FF-12, FF-13

### FF-7 — Hang/deadlock class (fork)
Split from FF-6 because deadlocks are a different review conversation, and because this class carries booted A/B evidence: status.md W21 (2026-07-23) shows a build lacking this flow-control work deadlocking two transcode chains on identical kernel/RGA/MPP while the shipping build carrying the fix passes cleanly, ruling out the kernel. Covers EOS-with-data never latching eof, a busy-looping send_eos, a receive-loop EAGAIN deadlock, and encoder async-queue frame drops under backpressure.
- Evidence: [../../status.md](../../status.md), [docs/submission-plan.md](docs/submission-plan.md), [docs/rebase-notes.md](docs/rebase-notes.md), [../../findings/2026-07-23-forward-port-current-tip-full-validation-run.md](../../findings/2026-07-23-forward-port-current-tip-full-validation-run.md), [patches/README.md](patches/README.md)
- Coupled with: FF-6, FF-8, FF-10, FF-12

### FF-8 — rkmppenc bounded output wait and backpressure absorption
Root cause is measured, not inferred: an mpi/mpp_enc trace across live wedge events shows mpi_encode_put_frame transiently returning MPP_NOK on a momentarily exhausted input task pool, after which the wrapper waits the full sync timeout for a frame that was never submitted. The retry-with-shared-deadline fix cannot live in the GRD caller, which is strictly one-in-one-out, so it belongs in this wrapper. Already shipped in the normal PPA but never offered upstream and not yet forward-ported off the divergent 8.0 packaging branch; per the ledger's cross-package constraint, GRD-8 should not be offered until this and FF-5 are upstream, or its own bitrate-triplet workarounds become the review.
- Evidence: [../../findings/2026-07-19-grd-rkmpp-encoder-wedge-mpp-input-backpressure.md](../../findings/2026-07-19-grd-rkmpp-encoder-wedge-mpp-input-backpressure.md), [../../findings/2026-07-19-grd-rkmpp-encoder-wedge-userspace-not-driver.md](../../findings/2026-07-19-grd-rkmpp-encoder-wedge-userspace-not-driver.md), [../../status.md](../../status.md), [README.md](README.md), [../../packaging/userspace-patches.md](../../packaging/userspace-patches.md), [../../docs/status-ledger.md](../../docs/status-ledger.md)
- Coupled with: FF-7, MPP-7, GRD-8

### FF-9 — rkmppdec out-of-band extradata
Concrete user-visible bug: av1_rkmpp decodes raw IVF AV1 but fails on the same stream muxed to MP4/MKV, because MP4 av1C / Matroska CodecPrivate configuration-record bytes need MPP_PACKET_FLAG_EXTRA_DATA to be parsed correctly. Checking nyanmisaka's tree directly shows his rkmppdec.c never forwards extradata at all despite registering an AV1 decoder, so the fork submission must carry the extradata-send path as well as the flag; does not apply to FFmpeg upstream, whose rkmppdec has no AV1. Gated on a board re-test because only compile/package proof of the fix exists so far.
- Evidence: [../../findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md](../../findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md), [../../status.md](../../status.md), [README.md](README.md), [../../docs/status-ledger.md](../../docs/status-ledger.md)

### FF-10 — Wrong-output class (fork)
Correctness rather than safety, hence P2 behind the crash/hang waves, but it retires the largest single block of fork-delta carried here: drain/EAGAIN/EOF handling, SAR-as-DAR confusion, AFBC 10-bit stride errors, RGA core-mask literal bypasses, crop centring, colorspace/alpha defaults, and unscaled NV15 tails. The transpose rotate-mode orientation fix needs runtime verification on this board's RGA hardware before sending, per the plan's own instruction; consider splitting the RGA half from the rkmppdec half if 14 patches is too large a single review.
- Evidence: [docs/submission-plan.md](docs/submission-plan.md), [docs/rebase-notes.md](docs/rebase-notes.md), [patches/README.md](patches/README.md), [../../findings/2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md](../../findings/2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md), [docs/fix-candidates.md](docs/fix-candidates.md)
- Coupled with: FF-6, FF-7, FF-12

### FF-11 — NV20 alias restoration and fate-imgutils repair
Two defects that exist only in nyanmisaka's tree: his series deleted the endian-neutral AV_PIX_FMT_NV20 alias, creating a descriptor-name collision, and his fate-imgutils reference is broken as committed. Both are self-contained with no dependency on any other patch here, making them a low-friction first interaction alongside the FF-6 wave. The naming discipline here (keeping plain nv20 free) is why FF-14's compact format must be called nv20_packed.
- Evidence: [docs/submission-plan.md](docs/submission-plan.md), [docs/rebase-notes.md](docs/rebase-notes.md)
- Coupled with: FF-14

### FF-12 — Small-fixes bundle (fork)
The long tail: individually minor items (AVERROR_EOF sign bug, precedence error, MJPEG RC/format gaps, extradata padding, DV-timings fraction, mmap_free leak, v4l2 validation, flush support, DMA-BUF cache-sync flags, allocator overflow fixes) that collectively form the bulk of remaining fork-delta. Gated behind FF-6/FF-7 so it does not read as a patch dump before the maintainer has agreed the higher-severity work is welcome; bundle two or three per patch as the plan directs, and consider dropping the out-of-band extradata item since it needs real adaptation to his older FFmpeg base.
- Evidence: [docs/submission-plan.md](docs/submission-plan.md), [patches/README.md](patches/README.md), [docs/fix-candidates.md](docs/fix-candidates.md)
- Coupled with: FF-6, FF-7, FF-10

### FF-13 — DRM descriptor/layout validation frameworks
Real hardening — the fork trusts any foreign descriptor and smuggles the AFBC Y offset through frame->crop_top — but at ~1200 lines of new framework, a behavior change that can reject layouts it can't represent, and a public-struct change, this is a design conversation, not a patch dump. Open an issue describing the trust problem and the crop_top misuse and let the maintainer choose the shape; his master is active (388741a3544b, 2026-07-18) but merges roughly 1 in 14 PRs, so expect re-authoring rather than dead silence.
- Evidence: [docs/submission-plan.md](docs/submission-plan.md), [docs/rebase-notes.md](docs/rebase-notes.md), [docs/review-learnings.md](docs/review-learnings.md)
- Coupled with: FF-6, FF-17

### FF-14 — NV15 / NV20_PACKED compact 10-bit pixel formats
Not a NEVER: both fix-candidates.md and the submission plan agree these could become upstream material, but only as a complete public-API feature series (formats, imgutils/pixdesc, swscale, tests), never as the fix-shaped patches held here. The realistic trigger is external — another in-tree consumer or a maintainer asking — so until then the formats stay fork-local and their correctness work (FF-6's swscale overread, FF-10's compact-tail fixes) goes to nyanmisaka where the formats actually exist.
- Evidence: [docs/submission-plan.md](docs/submission-plan.md), [docs/rebase-notes.md](docs/rebase-notes.md), [docs/fix-candidates.md](docs/fix-candidates.md)
- Coupled with: FF-11

### FF-15 — libavformat/id3v2 unknown-encoding sliver
The only genuinely new generic fix in the post-plan refactor work that is neither Rockchip-specific nor a revert: our hunk rejects an unknown ID3v2 text encoding where upstream logs a warning and falls through to an empty tag. The fall-through is confirmed to exist verbatim in vanilla FFmpeg, but whether it is a defect (versus deliberate tolerant parsing) is unresolved on source-review alone, so this holds pending a FATE-able reproduction. The sibling hlsenc.c/segment.c hunks in the same commit are Jellyfin-patch reverts and local policy, not fixes, and must not be submitted alongside this.
- Evidence: [docs/jellyfin-ffmpeg-patch-survey.md](docs/jellyfin-ffmpeg-patch-survey.md), [docs/rockchip-812-jellyfin-comparison.md](docs/rockchip-812-jellyfin-comparison.md), [docs/rebase-notes.md](docs/rebase-notes.md)

### FF-16 — FFmpeg-8.x port glue and self-inflicted regressions
Deliberately never submitted: verifying nyanmisaka's tree directly shows his rkmppdec.c has no static pix_fmts array and no CODEC_PIXFMTS_ARRAY at all, so the array this group removes was introduced by this project's own FFmpeg-8.x port glue, not by his fork. Submitting it would ask a maintainer to fix a defect he does not have; the same applies to the FilterLink/ffhwframesctx()/version-bump glue, which is only relevant if and when he rebases onto a modern FFmpeg.
- Evidence: [docs/submission-plan.md](docs/submission-plan.md), [../../findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md](../../findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md), [patches/README.md](patches/README.md), [../../packaging/userspace-patches.md](../../packaging/userspace-patches.md)

### FF-17 — Removal of unsafe RFBC DRM modifiers
Kept separate from FF-16's NEVER because the reason differs: this is a deliberate feature the upstream maintainer added intentionally for his vendor-kernel stack, and it works there. It was removed locally because this project's own descriptor/layout validation framework (FF-13) cannot express or verify those modifiers — a limitation of the local hardening approach, not a defect in his code — so offering the removal as a fix would invert the burden and poison the FF-13 design conversation. Keep the removal fork-local and revisit RFBC coverage only as part of that design thread if it ever proceeds.
- Evidence: [docs/submission-plan.md](docs/submission-plan.md), [patches/README.md](patches/README.md), [patches/0018-drop-unsafe-rfbc-modifiers.patch](patches/0018-drop-unsafe-rfbc-modifiers.patch)
- Coupled with: FF-13
