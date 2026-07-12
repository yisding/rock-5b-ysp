# apps/kodi/ — hardware video decode in Kodi on RK3588

Kodi 22 ("Piers") playing video decoded on the RK3588 **VDEC/RKVDEC/AV1** blocks
instead of the CPU, by building Kodi against **our** `ffmpeg-rockchip-81`
forward-port and letting Kodi's DRM PRIME path render the hardware frames
zero-copy.

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Play H.264/HEVC/AV1 in Kodi with the RK3588 decoding in hardware — smooth 4K at a few percent CPU. The AV1 container fix is implemented but awaits its board re-test. |
| Developer focus | How Kodi's `CDVDVideoCodecDRMPRIME` auto-selects the `*_rkmpp` decoders, how it renders `AV_PIX_FMT_DRM_PRIME` frames, and how to build Kodi against an external Rockchip FFmpeg. |
| Owns | The build recipe, the decoder-selection analysis, the runtime settings, and the tty1 test procedure. |
| Depends on | The PPA MPP `1375813c` runtime, `librga`, and the fork FFmpeg `libavcodec63` (PPA `ffmpeg`); a GBM/DRM console (KMS), GLES/EGL, libdrm/libgbm/libinput. See [`../../video-libraries/ffmpeg/README.md`](../../video-libraries/ffmpeg/README.md) and [`../../packaging/ppa/README.md`](../../packaging/ppa/README.md). |
| Current state | Design + prerequisites validated; **the Kodi build and on-board playback have not been run yet.** See [`status.md`](../../status.md). |

| Piece | What | Status |
|-------|------|--------|
| **Decoder selection** | Stock Kodi 22 auto-picks `h264_rkmpp`/`hevc_rkmpp`/`av1_rkmpp` via the fork's `AVCodecHWConfig` — **no Kodi patch** | ✅ analyzed, [`docs/decoder-selection.md`](docs/decoder-selection.md) |
| **FFmpeg** | External `ffmpeg-rockchip-81` (`libavcodec63`), `-DENABLE_INTERNAL_FFMPEG=OFF` | 🛠 `main@be367abfe6` source accepted by Launchpad; previous `~rk5` built |
| **MPP runtime** | PPA `1375813c` (h264/hevc `rkmpp` decode verified); board stock `750e76e` is broken | ✅ [finding](../../findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md) |
| **Build** | GBM windowing + GLES render, native cmake | ⏳ not built yet — [`docs/build-hwaccel.md`](docs/build-hwaccel.md) |
| **Playback** | `kodi-gbm` on tty1, Prime-decoder settings on | ⏳ pending (needs `gdm` stopped) |
| **AV1 from mp4/mkv** | mark the fork's existing extradata packet with MPP's extra-data flag so it parses `av1C` | 🛠 fixed and rebuilt; RK3588 re-test pending |
| **PPA package** | plain `kodi` depending on the fork `libavcodec63` | ⏳ not packaged yet |

## Files

| Path | One-liner |
|------|-----------|
| [`docs/build-hwaccel.md`](docs/build-hwaccel.md) | Exact build recipe: deps, cmake flags, external FFmpeg wiring, the linuxbrew/tmpfs gotchas, settings to enable, and the tty1 test. |
| [`docs/decoder-selection.md`](docs/decoder-selection.md) | Why stock Kodi 22 selects the `*_rkmpp` decoders with no source patch, quoting `FindDecoder`/`FindHWConfig` and the fork's `hw_configs`. |

## See also

- Origin finding: [`../../findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md`](../../findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md)
- FFmpeg fork + PPA packaging: [`../../packaging/ppa/ffmpeg/README.md`](../../packaging/ppa/ffmpeg/README.md)
- State rollup: [`../../status.md`](../../status.md)
