# vendor-libraries/mpp/ — librockchip_mpp

The userspace MPP library (`librockchip_mpp`): bitstream parsing, codec state,
buffer pools, register-table generation, and the MPP ioctl surface. Library
source lives in the sibling `mpp-rockchip` tree.

## Brief

| Field | Contents |
|-------|----------|
| Purpose | How libmpp is structured internally and where it meets `/dev/mpp_service`. |
| Developer focus | Parser/HAL selection, buffer and frame ownership, ioctl batching, fast mode, KMPP evolution, and public-API compatibility. |
| Owns | The MPP library docs under [`docs/`](docs/mpp-library-architecture.md), this front door, and [`keywords.md`](keywords.md). |
| Depends on | The classic MPP userspace API/headers and a compatible [`../../kernel-drivers/mpp/`](../../kernel-drivers/mpp/README.md) service for runtime validation. |
| Code lives in | `mpp-rockchip` (`mpp/`, HAL, `mpp_service` client). |
| Current state | Source-built path hardware-validated via the tests. The VP9 repeated-reference presentation defect is [fixed, validated, and public](../../findings/2026-08-04-libmpp-vp9-show-existing-reference-slot-leak.md#2026-08-05-repair-and-validation) at `yisding/ysp/main@a8b19653`; PPA binary publication and installed-package integration remain. See [`../../status.md`](../../status.md#watch-w25). |

## Scoped docs

| Doc | One-liner |
|-----|-----------|
| [`docs/mpp-library-architecture.md`](docs/mpp-library-architecture.md) | Internal libmpp architecture — context object, task queues, decoder/encoder flows, HAL selection, buffer system, KMPP hooks, with a source map. |
| [`docs/mpp-ioctl-batch-mode.md`](docs/mpp-ioctl-batch-mode.md) | The `/dev/mpp_service` ioctl surface — `MPP_IOC_CFG_V1`, `MppReqV1`, `MULTI_MSG`/`LAST_MSG` chaining, `DELIMIT` tile packing, and the dormant cross-session batch server (with its rise-and-removal git history). |
| [`docs/mpp-fast-mode.md`](docs/mpp-fast-mode.md) | Decoder fast mode (fast parse) — the default-on, per-instance parse/decode pipeline: 3-deep task queue, HAL register ring, the parser back-pressure gate, capability negotiation, and per-codec support matrix. |
| [`docs/mpp-kmpp-reverse-engineering.md`](docs/mpp-kmpp-reverse-engineering.md) | Reverse-engineering notes on Rockchip's newer KMPP path and the kernel-shared-object boundary. |
| [`docs/mpp-rust-rewrite-assessment.md`](docs/mpp-rust-rewrite-assessment.md) | Cost/scope of a Rust rewrite of classic `librockchip_mpp` keeping the same public API. |

Shared cross-library explanation: [`../docs/how-the-userspace-libs-work.md`](../docs/how-the-userspace-libs-work.md).
Kernel ABI: [`../../kernel-drivers/docs/dev-uapis.md`](../../kernel-drivers/docs/dev-uapis.md).
Project vocabulary: [`keywords.md`](keywords.md).
