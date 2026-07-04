# FFmpeg submission plan — what goes to nyanmisaka, what goes upstream

Per-area targeting analysis of **everything** in `ffmpeg-rockchip-81` since
nyanmisaka's last commit, produced 2026-07-02 by a six-agent sweep of the net
diff (each logical change verified against both nyanmisaka's tree and FFmpeg
master). This supersedes the coarse summary table in
[`fix-candidates.md`](fix-candidates.md) for *submission targeting*;
FIX-CANDIDATES remains the narrative for the 14 originally-audited fix groups.
The dated outcome ledger stays in [`rebase-notes.md`](rebase-notes.md) §6.

## Scope and pins

| Pin | Commit | Meaning |
|-----|--------|---------|
| NYAN | `53e76abdc7` | last replayed nyanmisaka commit (intra-refresh GDR) |
| upstream | `87bd15dc3c` | FFmpeg master rebase base — **also the merge-base**, i.e. nyanmisaka's series sits directly on it |
| tip | `6cf02ab253` | `ffmpeg-rockchip-81` `main`, 2026-07-02 |

The analyzed range `53e76abdc7..main` is 29 commits (the port commit
`def08a047f` + 28 review-fix commits), net **+3631/−725 across 30 files**.
The commits are iterative review sweeps that amend each other, so the
submission unit is the **~35 logical patches** below re-sliced from the net
diff, not the raw commits ([`../patches/`](../patches/README.md) archives the
raw commits).

Two structural facts drive all the verdicts:

- **Upstream FFmpeg can only take the generic-file work.** It has no
  rkmppenc/rkrga at all, and its rkmppdec is an unrelated implementation.
- **nyanmisaka's series never touches the `libavcodec/v4l2_*` m2m stack**
  (verified: empty diff vs merge-base), so everything we did there sits on
  vanilla upstream code — the cleanest upstream candidates in the branch.

## A. Worth submitting to FFmpeg upstream

All verified to fix bugs present in `87bd15dc3c` with no dependency on
fork-only pixel formats (`NV15`/`NV20_PACKED`):

| # | Patch | Files | The upstream bug it fixes |
|---|-------|-------|---------------------------|
| A1 | **v4l2_buffers copy-bounds rewrite** (~150 lines) | `libavcodec/v4l2_buffers.c` | Multiplanar `swframe_to_buf` NULL-derefs on typical `av_frame_get_buffer()` frames (single `buf[0]`, `frame->buf[1]` NULL); single-buffer path overreads the source when driver height > frame height and corrupts output when `frame->linesize != bytesperline`; no overflow checks. Strongest candidate — reachable NULL deref in any v4l2 m2m encode today. |
| A2 | **v4l2_context negotiation fixes** (~65 lines) | `libavcodec/v4l2_context.c` | `VIDIOC_TRY_FMT` result never verified (drivers silently substitute formats); `v4l2_get_raw_format()` can succeed without writing `*p`, after which the caller saves `av_fmt = {0}` = YUV420P, clobbering the real format; enum loop round-trips fourccs through the av-format table (aliased rows diverge) and can negotiate MJPEG as "raw". |
| A3 | **mplane-aware fourcc selection + table rows** (~70 lines) | `libavcodec/v4l2_fmt.c/h` | First-table-hit fourcc selection ignores whether the queue is mplane (contiguous vs `*M` variants); adds NV21/NV16/NV24/YUV422M/YUV444M rows — all upstream pixfmts. |
| A4 | **libavdevice/v4l2.c generics** (~60 lines total, separable) | `libavdevice/v4l2.c`, `v4l2-common.c` | `device_caps` used instead of `capabilities` when `V4L2_CAP_DEVICE_CAPS`; `planes[]` zero-init + single-planar `bytesused` bounds/`INT_MAX` guards; two-pass pixel-format fallback in `device_try_init` (first pass prefers the requested format); NV21 mapping. |
| A5 | *(sliver)* `av_read/write_image_line2` BE `x`-offset | `libavutil/pixdesc.c` | The step>8 big-endian branch ignores its `x` argument — latent XV30BE/V30XBE bug at x>0. |
| A6 | *(sliver)* `fate-pixdesc` hookup | `tests/fate/libavutil.mak` | Upstream builds `libavutil/tests/pixdesc` but never runs it in FATE. |

## B. Worth submitting to nyanmisaka's fork

~30 logical patches; every bug below was **verified to exist verbatim in
nyanmisaka's tree** (not introduced by our port). His fork sits on an older
FFmpeg base, so everything needs backport-by-behavior — mostly mechanical.

**Memory-safety / crash class (highest value):**

- `rkmpp_export_frame` double-free (error after `frame_create_buf` deinits the
  MppFrame twice) + descriptor/`tmp_frame` leaks
- buffer-group double-free in HALF_INTERNAL mode (group owned by the hwframes
  ctx is `put` on the decoder fail path)
- encoder submit-frame unwind (failed entries stay `queued=1` with a
  bufferless MppFrame that `clear_unused_frames` can never reclaim)
- encoder `get_packet` memcpy from `mpp_packet_get_data` instead of `get_pos`;
  `!mpp_pkt` → EAGAIN not ENOMEM; error paths still return the input frame's
  MppBuffer to the pool
- RGA error-path frame lifecycle (every failure leaked the clone; double-free
  after failed `ff_filter_frame`; fence fd 0 treated as an error)
- overlay preproc blends an **uninitialized pat buffer** into the background
  outside the overlay rect
- swscale `nv15_20ToYUV_c` one-byte source overread

**Hang / deadlock class:**

- decoder EOS-with-data never latches `eof` → next drain call blocks forever
- `rkmpp_send_eos` busy-loops `do {} while (ret != MPP_OK)` on failure
- receive-loop EAGAIN deadlock when the caller holds all pool frames
- encoder async queue silently **drops frames** when full and busy-waits on
  send-EAGAIN (`sent`/`order` queue rework)

**Wrong-output class:**

- drain converting EAGAIN→EOF drops tail frames behind a discard/errinfo frame
- errinfo latching `eof` kills live MJPEG capture; `AV_EF_EXPLODE` ignored
- MPEG1/2 SAR treated as DAR (`av_div_q` misuse)
- colorimetry only exported at info-change → mid-stream changes missed
- AFBC byte-vs-pixel stride wrong for 10-bit formats
- RGA float `bytes_pp` stride math truncates on non-divisible pitches
- transpose rotate-mode encoding: `clock_flip`/`cclock_flip` wrong orientation
  (**runtime-verify on RGA before sending** — this board can)
- SAR 0/1 → invalid 1/0 through transpose (common + per-frame paths)
- crop default centering uses scaled-output size instead of crop size
- RGA core-mask literal `== 0x4` comparisons bypass RGA2 constraints for
  `rga2_core1`/combined masks
- vpp keeps 10-bit output when RGA2 gets forced later (scale ratio, size
  limits, RGA2-only input) → runtime failure
- colorspace silently left unprogrammed for unspecified in-colorspace;
  `global_alpha=0` treated as opaque
- unscaled NV15 wrapper drops tail pixels (width%4) and the last chroma row
  (odd heights)

**Broken-in-his-tree-only:**

- restore the endian-neutral `AV_PIX_FMT_NV20` alias his series deleted (API
  break + `"nv20"` descriptor-name collision with nv20le/be)
- his `fate-imgutils` ref is broken as committed (nv15/nv20 lines in the wrong
  section/format)

**Small fixes (bundle 2–3 per patch):** `AVERROR(EOF)`→`AVERROR_EOF` sign bug;
`(r->info_change = …)` precedence; MJPEG RC uninitialized `qp_max_i/qp_min_i`;
YUVJ420P missing from the MJPEG format map; extradata size counting padding;
DV-timings inverted time-per-frame fraction; `mmap_free` leak; v4l2 mplane
payload/`data_offset` validation; padded raw-layout validation;
`ignore_input_error` semantics tightening; NV15/NV20 v4l2 format rows +
`raw_pix_fmt_tags` entries; MJPEG output-buffer sizing from SOF dimensions +
in-flight drain counter; encoder flush support; per-frame prep-config
revalidation; decoder flush resets (`last_pts` etc.); `rkmpp_map_from` should
accept `AV_PIX_FMT_NONE`; DMA_BUF cache-sync flags (device-level `CACHABLE`
ignored); allocator NV24/NV42 pitch + size-overflow fixes; out-of-band
extradata injection (needs adaptation — uses newer-FFmpeg BSF APIs).

**Propose as design, not bugfix (needs his buy-in):**

- the DRM descriptor/layout **validation frameworks** (~750 lines rkrga, ~350
  lines rkmppenc, ~90 lines hwcontext) — real hardening (his code trusts any
  foreign descriptor), but large, and it rejects layouts it can't represent
- `afbc_offset_y` as a real `AVRKMPPDRMFrameDescriptor` field replacing the
  `frame->crop_top` smuggling hack — the misuse is worth reporting either way,
  but the fix changes his public struct
- odd-YUV-dimension rejection instead of silent `ALIGN_DOWN` (behavior change)

## C. Not worth submitting anywhere

- FFmpeg-8.x port glue (FilterLink, `ffhwframesctx()`, `CODEC_PIXFMTS_ARRAY`,
  version/APIchanges bumps) — only relevant if/when he rebases
- RFBC modifier **removal** (`drop unsafe rfbc modifiers`) — he added RFBC
  deliberately for his vendor-kernel stack; our validation framework simply
  can't cover it. A feature removal he won't take.
- the "fix … regressions/followups" content that only repairs code we
  ourselves introduced mid-range (folds into the logical patches above)

## Suggested first wave

1. **Upstream:** A1 (v4l2_buffers copy-bounds) as its own series, then A2+A3.
2. **nyanmisaka:** the crash/hang class as small obviously-correct patches —
   export-frame double-free, buffer-group double-free, EOS/drain trio, encoder
   queue frame-drop, get_packet pos fix, overlay uninitialized-pat blend.
3. Hold the validation frameworks for a design conversation, not a patch dump.

Nothing has been sent anywhere as of 2026-07-02 — update
[`rebase-notes.md`](rebase-notes.md) §6 (and the `status.md` rollup) when that
changes.
