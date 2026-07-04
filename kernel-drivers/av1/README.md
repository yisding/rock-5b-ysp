# kernel-drivers/av1/ — RK3588 AV1 decode

The RK3588 AV1 decode path and why it sits apart from the RKVDEC2 H.264/H.265/VP9
driver, plus the BSP bugs an experimental RKMPP AV1 port exposed. RK3588 AV1 is
**not** part of the validated RKMPP path shipped by this repo.

## Brief

| Field | Contents |
|-------|----------|
| Purpose | Explain the separate AV1 decoder block/driver and the audit findings from porting it. |
| Code lives in | The AV1 decoder path in the sibling kernel trees; the AV1 fork-port work is tracked in `linux-6.18-rkvenc-av1-fwport`. |
| Current state | Outside the validated RKMPP decode path; see [`../../status.md`](../../status.md) and [`../docs/forward-port-status.md`](../docs/forward-port-status.md) § AV1. |

## Scoped docs

| Doc | One-liner |
|-----|-----------|
| [`docs/av1-rk3588.md`](docs/av1-rk3588.md) | The RK3588 AV1 decode path and why it is separate from RKVDEC2. |
| [`docs/av1-bsp-audit.md`](docs/av1-bsp-audit.md) | BSP bugs the experimental RKMPP AV1 port exposed. |

Project vocabulary: [`keywords.md`](keywords.md).
