# vendor-libraries/mpp/ — librockchip_mpp

The userspace MPP library (`librockchip_mpp`): bitstream parsing, codec state,
buffer pools, register-table generation, and the MPP ioctl surface. Library
source lives in the sibling `mpp-rockchip` tree.

## Brief

| Field | Contents |
|-------|----------|
| Purpose | How libmpp is structured internally and where it meets `/dev/mpp_service`. |
| Code lives in | `mpp-rockchip` (`mpp/`, HAL, `mpp_service` client). |
| Current state | Source-built path hardware-validated via the tests; see [`../../status.md`](../../status.md). |

## Scoped docs

| Doc | One-liner |
|-----|-----------|
| [`docs/mpp-library-architecture.md`](docs/mpp-library-architecture.md) | Internal libmpp architecture — context object, task queues, decoder/encoder flows, HAL selection, buffer system, KMPP hooks, with a source map. |
| [`docs/mpp-kmpp-reverse-engineering.md`](docs/mpp-kmpp-reverse-engineering.md) | Reverse-engineering notes on Rockchip's newer KMPP path and the kernel-shared-object boundary. |
| [`docs/mpp-rust-rewrite-assessment.md`](docs/mpp-rust-rewrite-assessment.md) | Cost/scope of a Rust rewrite of classic `librockchip_mpp` keeping the same public API. |

Shared cross-library explanation: [`../docs/how-the-userspace-libs-work.md`](../docs/how-the-userspace-libs-work.md).
Kernel ABI: [`../../kernel-drivers/docs/dev-uapis.md`](../../kernel-drivers/docs/dev-uapis.md).
Project vocabulary: [`keywords.md`](keywords.md).
