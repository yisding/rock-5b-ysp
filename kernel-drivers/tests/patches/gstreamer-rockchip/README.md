# JeffyCN GStreamer Rockchip conformance patches

These patches apply to the pinned `JeffyCN/mirrors` `gstreamer-rockchip`
source used by the driver conformance suite.  They fix userspace integration
gaps exposed by the suite; they are not kernel-driver patches.

`build-gstreamer-rockchip.sh` archives the pinned source commit into a
content-keyed directory next to its disposable build directory and applies all
patches here in lexical order.  It never changes the source checkout.  Set
`GST_ROCKCHIP_PATCH_DIR=` only for an intentional unpatched-upstream
comparison.

| Patch | Purpose | Runtime gate |
|-------|---------|--------------|
| `0001-rockchipmpp-advertise-dmabuf-input-for-h26x-encoders.patch` | Add the H.264/H.265 encoder `memory:DMABuf` sink caps already supported by the shared MPP import path. | `generated_transcode_h264_dmabuf_to_h265`, `generated_transcode_h265_dmabuf_to_h264` |
