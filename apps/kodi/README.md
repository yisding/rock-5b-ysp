# apps/kodi/ — hardware video decode in Kodi on RK3588

This project explains how Kodi's DRM PRIME path can consume RKMPP hardware
decoders from an external Rockchip FFmpeg build without a Kodi source patch.

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Build Kodi for GBM/DRM and play supported streams with RK3588 decode frames carried as DRM PRIME objects. |
| Developer focus | Kodi decoder discovery, FFmpeg `AVCodecHWConfig`, DRM PRIME rendering, external-FFmpeg linkage, and a recoverable console test. |
| Owns | Decoder-selection analysis and the Kodi build/run validation procedure. |
| Depends on | A compatible RKMPP kernel/libmpp stack, the selected Rockchip FFmpeg ABI, GBM/KMS, EGL/GLES, libdrm, and input support. |
| Evidence boundary | [`../../status.md`](../../status.md) track 11 owns the public build/playback verdict and next proof; the build guide owns the operation, not a copied package matrix here. |

## Technical model

Kodi enumerates FFmpeg decoders and their hardware configurations. A Rockchip
decoder that advertises `AV_PIX_FMT_DRM_PRIME` can be selected by Kodi's normal
`CDVDVideoCodecDRMPRIME` path, and its dma-buf-backed frame can reach the GBM/DRM
renderer without a CPU pixel copy. Generic “hardware acceleration” labels do
not prove that this decoder was selected; logs and the exercised codec name do.

The external FFmpeg ABI, MPP runtime, and Kodi binary form one compatibility
tuple. Publication or decoder registration alone does not prove that Kodi was
built, launched on the intended console path, or played a representative file.

## Files

| Path | One-liner |
|------|-----------|
| [`docs/decoder-selection.md`](docs/decoder-selection.md) | Why unpatched Kodi selects the `*_rkmpp` decoders and renders DRM PRIME frames. |
| [`docs/build-hwaccel.md`](docs/build-hwaccel.md) | Prerequisites, external-FFmpeg configure/build, GBM console launch, settings, pass/fail signals, and cleanup. |

## Validate

Follow [`docs/build-hwaccel.md`](docs/build-hwaccel.md) with the exact package
and source identities selected for the run. Retain the CMake summary, linked
FFmpeg libraries, Kodi log decoder choice, media identity, display/session
state, playback result, and kernel log. Report the result through the findings
intake until it is promoted to the maintained evidence owner and status track.

## See also

- [`../../video-libraries/ffmpeg/`](../../video-libraries/ffmpeg/README.md) —
  Rockchip codec mechanism, package-input route, and validation scorecard.
- [`../../packaging/ppa/`](../../packaging/ppa/README.md) — archive topology,
  ABI separation, and artifact reconstruction.
- [`../../status.md`](../../status.md) — current Kodi verdict and next proof.
