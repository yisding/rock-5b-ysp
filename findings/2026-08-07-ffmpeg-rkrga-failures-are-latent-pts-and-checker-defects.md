# FFmpeg rkrga conformance failures are latent PTS and checker defects exposed by suite strictness; kernel #8 exonerated

> Scope: `kernel-drivers/tests/ffmpeg-suite.sh` rkrga transcode/filter gates; ffmpeg-rockchip-81 `rkmppdec.c` PTS fabrication; `run_case` verdict plumbing
> Source: suite commits `3aa7471` (pre) vs `3b00231` (post, adds `suite_run_strict`); ffmpeg-rockchip-81 `git-2026-07-11-844d95e047` `libavcodec/rkmppdec.c` (~:1334 PTS fabrication, ~:813 frame PTS); evidence in `~/Code/tmp/ffmpeg-rkrga-regression`
> Date: 2026-08-07
> Trust: MEASURED, ROOT-CAUSED, CONFIRMED

## Result

All eight 20260807-204828 ffmpeg-suite failures (five required `*_rkrga`
cases, three AV1/AFBC diagnostics) are pre-existing userspace and test-design
defects that became visible when commit `3b00231` started running case
payloads inside `suite_run_strict` (a `set -e` subshell). Before that,
`run_case` ran payloads after `set +e`, so a failed mid-function assertion —
`encoded_psnr_against_input` returning 1, or a failed `run_ffmpeg` — was
swallowed and the case's verdict was the exit status of its *last* command
(usually `record_artifact`, which succeeds). The hardware, driver, and kernel
#8 commits are exonerated; the #8 dispatch-order fix demonstrably works (the
promoted repeat-exact gates pass 30/30 under load on both rkvdec cores).

Proof the "regression" narrative was false: yesterday's 20260806-203117 run
on kernel #6 recorded **pass** for `transcode_h264_to_hevc_rkrga` while its
own log contains `average:26.082528` (threshold 35), `scale` logged 26.23,
`vpp` logged 8.56, and the overlay case logged the identical
`Unsupported 'input' pad 1 format: 'nv12'` error that "failed" today.

The real defects, by case family:

1. **Transcode/scale PSNR ~26 dB — CFR vsync churn on fabricated PTS, not
   pixel error.** The generated inputs are raw elementary streams *with
   B-frames* (`I P P P P P P B B B …`). With no container timestamps,
   PTS reaching the decoder is decode-order; frames emit in display order, so
   emitted PTS is non-monotonic (the long-standing "non-monotonic DTS"
   warnings). ffmpeg's default CFR output then duplicates/drops frames in
   the encode leg. Decoded content is perfect: with `-fps_mode passthrough`,
   framemd5 of a drm-prime H.264 decode is 60/60 bit-exact **in order**, and
   the full hw transcode (decode → `scale_rkrga` → `hevc_rkmpp`) scores
   **39.67 dB** (min 39.4) against the reference once vsync padding is
   disabled, versus 26.8 with defaults. The earlier "duplicate frame"
   observation was vsync padding: 11 dup/drop pairs at default vsync,
   `dup=0 drop=23` under a different sink timebase, 0 defects under
   passthrough.
2. **`vpp_rkrga` crop/transpose 8.5 dB — checker geometry is wrong.**
   `encoded_psnr_against_input` bicubic-scales the full landscape reference
   to the output size, but the output is cropped and transposed to portrait;
   the comparison is structurally incomparable and can never reach 35 dB.
3. **`overlay_rkrga` — real filter negotiation failure.**
   `Unsupported 'input' pad 1 format: 'nv12'` at filter (re)init, error -38,
   present in yesterday's "passing" log too. A genuine ffmpeg-rockchip
   `vf_overlay_rkrga` defect (or wrong case format), never a kernel one.
4. **AV1→RGA diagnostics (exit 69, empty output)** — same always-failing,
   previously-swallowed class; not yet separately root-caused.

## Evidence and reproduction

- `~/Code/tmp/ffmpeg-rkrga-regression/`: `pt.md5` vs `ref.md5` (60/60
  in-order bit-exact passthrough decode), `pt-enc.hevc` (39.67 dB passthrough
  transcode), `corrupt.md5` dup/drop maps, differential PSNRs (sync RGA,
  no-encoder, hwupload-fed RGA, CPU readback of drm-prime frames).
- Verdict flip: `git diff 3aa7471 3b00231 -- kernel-drivers/tests/ffmpeg-suite.sh`
  — `run_case_payload > log` under `set +e` became
  `suite_run_strict "$log" run_case_payload`.
- Yesterday's fake passes: `20260806-203117-ffmpeg-suite/system_ffmpeg_transcode_h264_to_hevc_rkrga.log`
  (`average:26.082528`, scored pass) and the overlay log with today's exact error.

## Consequence

Every threshold- or assertion-gated ffmpeg verdict recorded before `3b00231`
(2026-08-07 10:57) is untrustworthy: only the last command's status counted.
The 20260807-204828 run is the first honest baseline. Green cases in that run
are genuinely green; the red set above is the true backlog.

## Boundary

The AV1/AFBC diagnostic failures and the overlay pad-1 format rejection are
confirmed pre-existing but not yet root-caused. HEVC-input legs were not
frame-hashed (same PTS mechanism assumed from identical failure shape). This
finding does not evaluate whether decode-order PTS fabrication should be
fixed in `rkmppdec.c` (a PTS reorder queue) or in the suite (containerized
inputs / `-fps_mode passthrough` legs / index-aligned PSNR); both close the
gap. The GStreamer and librga suites were already strict and are unaffected.
