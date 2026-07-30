# video-libraries/ffmpeg — keywords

FFmpeg-on-RK3588 terms. Cross-cutting vocabulary is in
[`../../glossary.md`](../../glossary.md).

- **ffmpeg-rockchip** — nyanmisaka's upstream rockchip FFmpeg fork (the 6.1-era
  base this work started from).
- **ffmpeg-rockchip-81** — the owner's canonical replay and hardening of the
  nyanmisaka stack (`github.com/yisding/ffmpeg-rockchip-81`). Its three public
  branches carry the complete patchset over different FFmpeg upstream lines.
- **main** — rolling canonical branch `8b57e531d1fc` over
  `FFmpeg/master@ceabc9b306f5`, described as `n8.2-dev-2444-g8b57e531d1`.
  The repository name does not mean this branch is based on FFmpeg 8.1.
- **ffmpeg-80** — canonical FFmpeg 8.0 branch `be753f3bbb2c` over
  `release/8.0@435ae0581deb`, described as `n8.0.3-100-gbe753f3bbb`.
- **ffmpeg-81** — canonical FFmpeg 8.1 branch `8d3ca020b6a2` over
  `release/8.1@94138f6973dd`, described as `n8.1.2-93-g8d3ca020b6`; it
  supersedes local comparison branch `rockchip-8.1.2@53b3551b9176`. See
  [`docs/rockchip-812-jellyfin-comparison.md`](docs/rockchip-812-jellyfin-comparison.md).
- **h264_rkmpp / hevc_rkmpp** — the MPP-backed hardware encoder/decoder codecs.
  Same names exist in upstream FFmpeg 8.1.2 with a different control surface — see
  [`docs/implementation-comparison.md`](docs/implementation-comparison.md).
- **scale_rkrga / vpp_rkrga** — the RGA-backed scale / video-postproc filters.
- **AVHWFramesContext / DRM PRIME** — FFmpeg's hardware-frame model; frames move as
  dma-buf via DRM PRIME descriptors.
- **AFBC modifiers** — Arm FrameBuffer Compression format modifiers on hardware
  frames; several fix patches concern AFBC capability/validation.
