# kernel-drivers/av1/ — RK3588 AV1 decode

The RK3588 AV1 decode path and why it sits apart from the RKVDEC2 H.264/H.265/VP9
driver, plus the BSP bugs porting the RKMPP AV1 backend exposed. AV1 is part of
the forward-port kernel: `mpp_av1dec.c` plus the VSI-IOMMU provider, **hardware-
validated bit-exact as of 2026-07-04** on board build `P1c9d` (see
[`docs/av1-rk3588.md`](docs/av1-rk3588.md) § 2026-07-04 update). The clean-room
MPP rewrite now contains a separate VPU981/VSI backend in both maintained
source branches, but it has no rewrite-kernel hardware result.

## Brief

| Field | Contents |
|-------|----------|
| Purpose | Explain the separate AV1 decoder block/driver, the audit findings from porting it, and the source-versus-hardware boundary of the clean-room RKMPP backend. |
| Developer focus | Keep the AV1 block, VSI-IOMMU provider, vendor-MPP userspace expectations, rewrite backend, and mainline Hantro/V4L2 alternative clearly separated. |
| Owns | [`docs/av1-rk3588.md`](docs/av1-rk3588.md), [`docs/av1-bsp-audit.md`](docs/av1-bsp-audit.md), [`docs/av1-bsp-forward-port-review-2026-07-20.md`](docs/av1-bsp-forward-port-review-2026-07-20.md), [`docs/av1-rewrite-assessment.md`](docs/av1-rewrite-assessment.md), and [`keywords.md`](keywords.md). |
| Depends on | A kernel/DT selecting the RKMPP consumer model, VSI-IOMMU wiring, and compatible MPP/FFmpeg userspace. AV1 decode is part of the single forward-port line (`0007` plus the Verisilicon IOMMU provider in `0005`) and of both maintained rewrite source branches. |
| Code lives in | Forward port: `linux-6.18-rkvenc-av1-fwport` branch `rk3588-video-6.18`. Rewrite: `linux-6.18-rkvenc@rk3588-rewrite-6.18` and `linux@rk3588-rewrite-mainline`. |
| Current state | **Forward-port hardware-validated (2026-07-04):** `P1c9d` exposed AV1DEC through `/dev/mpp_service` and decoded bit-exact. **Rewrite source/build only (2026-08-04):** tips `33c30ec6989e` and `9e503f6b16df` contain byte-identical class-aware AV1/VSI/AFBC driver sources and pass the normal focused build, but no rewrite boot or AV1 decode exists. See [`docs/av1-rk3588.md`](docs/av1-rk3588.md), [`../../status.md`](../../status.md), and [`../docs/rewrite-driver-architecture/02-mpp-driver.md`](../docs/rewrite-driver-architecture/02-mpp-driver.md#39-decoder-backends-and-ccu-modes). |

## Scoped docs

| Doc | One-liner |
|-----|-----------|
| [`docs/av1-rk3588.md`](docs/av1-rk3588.md) | The RK3588 AV1 decode path and why it is separate from RKVDEC2. |
| [`docs/av1-bsp-audit.md`](docs/av1-bsp-audit.md) | BSP bugs the experimental RKMPP AV1 port exposed. |
| [`docs/av1-bsp-forward-port-review-2026-07-20.md`](docs/av1-bsp-forward-port-review-2026-07-20.md) | Adversarial review of the pinned BSP and current 6.18 export: unresolved memory safety, session lifetime, DMA provenance, IOMMU, recovery, and maintenance findings. |
| [`docs/av1-rewrite-assessment.md`](docs/av1-rewrite-assessment.md) | Historical implementation assessment, what landed, and the still-open hardware validation gates for the clean-room `/dev/mpp_service` backend. |

Project vocabulary: [`keywords.md`](keywords.md).
