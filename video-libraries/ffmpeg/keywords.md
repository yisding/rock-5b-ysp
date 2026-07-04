# video-libraries/ffmpeg — keywords

FFmpeg-on-RK3588 terms. Cross-cutting vocabulary is in
[`../../glossary.md`](../../glossary.md).

- **ffmpeg-rockchip** — nyanmisaka's upstream rockchip FFmpeg fork (the 6.1-era
  base this work started from).
- **ffmpeg-rockchip-81** — the owner's port of that work to FFmpeg 8.1.2
  (`github.com/yisding/ffmpeg-rockchip-81`, branch `main`); the current tree.
- **h264_rkmpp / hevc_rkmpp** — the MPP-backed hardware encoder/decoder codecs.
  Same names exist in upstream FFmpeg 8.1.2 with a different control surface — see
  [`docs/implementation-comparison.md`](docs/implementation-comparison.md).
- **scale_rkrga / vpp_rkrga** — the RGA-backed scale / video-postproc filters.
- **AVHWFramesContext / DRM PRIME** — FFmpeg's hardware-frame model; frames move as
  dma-buf via DRM PRIME descriptors.
- **AFBC modifiers** — Arm FrameBuffer Compression format modifiers on hardware
  frames; several fix patches concern AFBC capability/validation.
- **submission plan** — the mapping of every logical change to upstream-FFmpeg vs
  nyanmisaka-fork candidates: [`docs/submission-plan.md`](docs/submission-plan.md).
