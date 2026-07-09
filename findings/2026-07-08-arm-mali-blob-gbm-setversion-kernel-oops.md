# ARM Mali blob GBM path kernel-Oopses in drm_setversion on the Radxa 5.10 vendor kernel

promoted → [`../video-libraries/mesa/docs/arm-mali-blob-stack.md`](../video-libraries/mesa/docs/arm-mali-blob-stack.md) (2026-07-08)

The GBM-path kernel Oops (NULL-deref in `drm_setversion`, then the
`rockchip_drm_lastclose -> drm_master_internal_acquire` teardown deadlock) now
lives in that doc's "Runtime Results (measured 2026-07-08)" section.
