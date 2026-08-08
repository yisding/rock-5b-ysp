# Why stock Kodi 22 selects the rkmpp decoders (no patch)

The one question that decides whether a Kodi fork is needed: does upstream Kodi
route an H.264 stream to `h264_rkmpp` (hardware) or to the software `h264`? On
Kodi 22 with `ffmpeg-rockchip-81`, it routes to hardware **with no source
change**. This doc records why, so a future Kodi release that changes the
selection code can be checked against it.

> Anchors (drift with the trees): Kodi
> `xbmc/cores/VideoPlayer/DVDCodecs/Video/DVDVideoCodecDRMPRIME.cpp`
> @ `22.0b1-Piers-96-g5bc2478806`; fork `libavcodec/rkmppdec.h`
> @ `75638e7f0b`.

## Kodi side — `FindDecoder` → `FindHWConfig`

`FindDecoder()` prefers a decoder that advertises a hardware config:

```c
while ((codec = av_codec_iterate(&i))) {
    if (!av_codec_is_decoder(codec)) continue;
    if (codec->id != hints.codec)    continue;
    const AVCodecHWConfig* config = FindHWConfig(codec);   // <-- key
    if (config) return codec;
}
codec = avcodec_find_decoder(hints.codec);                 // else: software
```

`FindHWConfig()` accepts a config when the "prime for hw" setting is on, the
`pix_fmt` is one Kodi treats as hardware (`AV_PIX_FMT_DRM_PRIME`), and the
method is `INTERNAL` or `HW_DEVICE_CTX`:

```c
if (!settings->GetBool(SETTING_VIDEOPLAYER_USEPRIMEDECODERFORHW))
    return nullptr;
for (int n = 0; (config = avcodec_get_hw_config(codec, n)); n++) {
    if (!IsSupportedHwFormat(config->pix_fmt)) continue;      // DRM_PRIME ok
    if ((config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) ||
        (config->methods & AV_CODEC_HW_CONFIG_METHOD_INTERNAL))
        return config;
}
```

So the software `h264` (no hw_config) is skipped; a decoder with a matching
hw_config wins. Kodi never looks up `"*_rkmpp"` by name — it doesn't need to.

## Fork side — the rkmpp decoders advertise exactly that

`rkmpp_dec_hw_configs` (attached to every `*_rkmpp` decoder via
`DEFINE_RKMPP_DECODER`):

```c
.pix_fmt     = AV_PIX_FMT_DRM_PRIME,
.methods     = AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX | AV_CODEC_HW_CONFIG_METHOD_INTERNAL,
.device_type = AV_HWDEVICE_TYPE_RKMPP,
```

`pix_fmt == DRM_PRIME` and `methods & INTERNAL` → `FindHWConfig()` returns it →
`FindDecoder()` returns `h264_rkmpp`.

## Open path — the RKMPP hwdevice

Because the config's methods include `HW_DEVICE_CTX`, `Open()` calls
`av_hwdevice_ctx_create(..., pConfig->device_type, ...)` with
`device_type = AV_HWDEVICE_TYPE_RKMPP`. The fork implements that hwdevice
(`libavutil/hwcontext_rkmpp.c`, registered in `hwcontext.c`), so creation
succeeds; the `INTERNAL` method means the decoder also self-initialises its MPP
context. `device_type` is *not* `AV_HWDEVICE_TYPE_DRM`, so Kodi skips the
DRM-render-node path — correct for rkmpp.

## The one caveat that isn't a patch

The static `pix_fmts` array the fork's decoders used to also declare
(`NV12/NV16/NV15/NV20/NV24/DRM_PRIME`) is unrelated to selection — it is
metadata that broke the `libavcodec-avcodec` FATE self-test, and it is dropped
by the [frozen package correction](../../../packaging/ppa/docs/building.md#ffmpeg81-package-lessons).
The hw_config above is untouched by that patch, so selection is unaffected.

## Re-check triggers

Revisit this if, in a newer Kodi, `FindHWConfig` stops accepting
`AV_CODEC_HW_CONFIG_METHOD_INTERNAL`, `IsSupportedHwFormat` stops accepting
`DRM_PRIME`, or `FindDecoder` changes its two-pass order — or if the fork drops
the `hw_configs` from the rkmpp decoders.
