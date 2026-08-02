# IEP2 keywords

- **IEP** — Image Enhancement Processor. Rockchip also has a legacy,
  standalone IEP driver; do not infer that `/dev/iep` is the RK3588 IEP2 ABI.
- **IEP2** — RK3588's fixed-function image-enhancement/deinterlacing block.
  The BSP MPP driver exposes it through `/dev/mpp_service` as client type 28.
- **VDPP** — Video Decoder Post-Processor. A separate Rockchip hardware family
  instantiated on SoCs including RK3528 and RK3576, but not RK3588. Its MPP
  client type is 29.
- **vproc** — libmpp's decoder-side video-processing layer. It notices an
  interlaced decoded frame, obtains an IEP context, and invokes IEP2 when that
  backend is available.
- **`rockchip,iep-v2`** — the RK3588 BSP device-tree compatible selected by
  `mpp_iep2.c`.
- **`MPP_DEVICE_IEP2` / client 28** — the matching kernel and userspace MPP
  device ID.
- **`MPP_DEVICE_VDPP` / client 29** — the distinct VDPP device ID. Its presence
  in a multi-SoC enum or defconfig does not prove an RK3588 VDPP instance.
- **I5O2 / I5O1 / I2O2 / I1O1** — IEP2 field-input/output modes documented by
  the RK3588 TRM. The names describe how many fields are considered and how
  many outputs are produced.
- **TFF / BFF** — top-field-first / bottom-field-first interlaced ordering.
- **ME / MC / MD / EEDI** — motion estimation, motion compensation, motion
  detection, and edge-dependent interpolation used by the deinterlacer.
- **pulldown detection** — cadence detection/reconstruction for film-derived
  interlaced material.
- **MPP taskqueue 6** — the taskqueue association in the RK3588 IEP2 DT node.
  It is not a userspace client number.
