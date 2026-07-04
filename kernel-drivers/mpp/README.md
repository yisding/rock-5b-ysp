# kernel-drivers/mpp/ — MPP service + codec cores

The MPP service core (`/dev/mpp_service`) and the rkvenc2/rkvdec2 codec drivers
(VEPU580 encoder, VDPU381 decoder). Driver code lives in the sibling kernel trees
under `drivers/video/rockchip/mpp/`.

Shared driver architecture, uAPI, device tree, patches, scripts, and tests are at
the [`kernel-drivers/README.md`](../README.md) top level (one combined series covers
mpp+rga). This sub-project holds MPP-specific notes.

## Brief

| Field | Contents |
|-------|----------|
| Purpose | The vendor MPP service model — sessions, tasks, IOMMU, multi-core dispatch — and the encoder/decoder asymmetries. |
| Code lives in | `linux-6.18-rkvenc*` / `rockchip-kernel` `drivers/video/rockchip/mpp/` (`mpp_service.c`, `mpp_rkvenc2.c`, `mpp_rkvdec2*.c`). |
| Current state | Encode + decode hardware-validated on the combined kernel. See [`../docs/forward-port-status.md`](../docs/forward-port-status.md) and [`../../status.md`](../../status.md). |

## Scoped docs

| Doc | One-liner |
|-----|-----------|
| [`docs/ioctl-collector.md`](docs/ioctl-collector.md) | Kernel-side trace of `mpp_collect_msgs`: how one `MPP_IOC_CFG_V1` batch is walked into task containers, and why `LAST_MSG` is a whole-syscall terminator (one per ioctl) while `SET_SESSION_FD` is the real per-batch delimiter. |
| [`docs/multicore-scheduling.md`](docs/multicore-scheduling.md) | Why RK3588 multi-core decode is hard (per-stream DPB dependency), and where a scheduler would live; soft/hard CCU consequences. |

Start with the shared [`../docs/how-the-drivers-work.md`](../docs/how-the-drivers-work.md)
for the end-to-end layer model, then [`../docs/dev-uapis.md`](../docs/dev-uapis.md)
for the ioctl ABI. Decoder CCU/IOMMU specifics are in
[`../iommu/`](../iommu/README.md). Project vocabulary: [`keywords.md`](keywords.md).
