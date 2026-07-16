# video-libraries/ffmpeg — keywords

FFmpeg-on-RK3588 terms. Cross-cutting vocabulary is in
[`../../glossary.md`](../../glossary.md).

- **ffmpeg-rockchip** — nyanmisaka's upstream rockchip FFmpeg fork (the 6.1-era
  base this work started from).
- **ffmpeg-rockchip-81** — the owner's replay and hardening of that work on
  FFmpeg master (`github.com/yisding/ffmpeg-rockchip-81`, branch `main` at
  `be367abfe6`, described as `n8.2-dev-2123-gbe367abfe6`). The repository name
  does not mean that `main` is based on FFmpeg 8.1.
- **rockchip-8.1.2** — the separate real FFmpeg 8.1.2 replay, local branch
  `rockchip-8.1.2@53b3551b9176` in `~/Code/ffmpeg/ffmpeg-rockchip-812`; see
  [`docs/rockchip-812-jellyfin-comparison.md`](docs/rockchip-812-jellyfin-comparison.md).
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
