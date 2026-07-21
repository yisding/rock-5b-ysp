# kernel-drivers/av1/ — RK3588 AV1 decode

The RK3588 AV1 decode path and why it sits apart from the RKVDEC2 H.264/H.265/VP9
driver, plus the BSP bugs an experimental RKMPP AV1 port exposed. RK3588 AV1 is
**not** in the *shipped base* forward-port (`Pb6ab`) — but the **av1-fwport
variant** (`linux-6.18-rkvenc-av1-fwport`, board build `P1c9d`) adds
`mpp_av1dec.c` + VSI-IOMMU and is **hardware-validated bit-exact as of
2026-07-04** (see [`docs/av1-rk3588.md`](docs/av1-rk3588.md) § 2026-07-04 update).

## Brief

| Field | Contents |
|-------|----------|
| Purpose | Explain the separate AV1 decoder block/driver, the audit findings from porting it, and the clean-room RKMPP rewrite boundary. |
| Developer focus | Keep the AV1 block, VSI-IOMMU provider, vendor-MPP userspace expectations, rewrite design, and mainline Hantro/V4L2 alternative clearly separated. |
| Owns | [`docs/av1-rk3588.md`](docs/av1-rk3588.md), [`docs/av1-bsp-audit.md`](docs/av1-bsp-audit.md), [`docs/av1-bsp-forward-port-review-2026-07-20.md`](docs/av1-bsp-forward-port-review-2026-07-20.md), [`docs/av1-rewrite-assessment.md`](docs/av1-rewrite-assessment.md), and [`keywords.md`](keywords.md). |
| Depends on | The AV1-capable kernel/DT variant, VSI-IOMMU wiring, and compatible MPP/FFmpeg userspace; the base forward-port does not supply this driver. |
| Code lives in | The AV1 decoder path in the sibling kernel trees; the AV1 fork-port work is tracked in `linux-6.18-rkvenc-av1-fwport`. |
| Current state | **Hardware-validated (2026-07-04) on the av1-fwport board build** (`P1c9d`, kernel `6.18.37 #8`): AV1DEC probes, is exposed through `/dev/mpp_service`, and decodes bit-exact — but the av1-fwport variant is separate from the *shipped base* forward-port (`Pb6ab`, which has no `mpp_av1dec.c`). See [`docs/av1-rk3588.md`](docs/av1-rk3588.md) § 2026-07-04 update, [`../../status.md`](../../status.md), and [`../docs/forward-port-status.md`](../docs/forward-port-status.md) § AV1. |

## Scoped docs

| Doc | One-liner |
|-----|-----------|
| [`docs/av1-rk3588.md`](docs/av1-rk3588.md) | The RK3588 AV1 decode path and why it is separate from RKVDEC2. |
| [`docs/av1-bsp-audit.md`](docs/av1-bsp-audit.md) | BSP bugs the experimental RKMPP AV1 port exposed. |
| [`docs/av1-bsp-forward-port-review-2026-07-20.md`](docs/av1-bsp-forward-port-review-2026-07-20.md) | Adversarial review of the pinned BSP and current 6.18 export: unresolved memory safety, session lifetime, DMA provenance, IOMMU, recovery, and maintenance findings. |
| [`docs/av1-rewrite-assessment.md`](docs/av1-rewrite-assessment.md) | Difficulty, architecture gaps, implementation order, and validation gates for adding AV1 to the clean-room `/dev/mpp_service` rewrite. |

Project vocabulary: [`keywords.md`](keywords.md).
