# vendor-libraries/rga/ — librga

The userspace RGA library (`librga`): the 2D API, buffer import (fd or virtual
address), command normalization, and core-profile selection over `/dev/rga`.
Source lives in the sibling `librga` / `librga-src` trees.

## Brief

| Field | Contents |
|-------|----------|
| Purpose | How to use librga well, and the 10-bit (P010/P210) RKRGA ABI facts. |
| Developer focus | Buffer imports, format/stride flags, core-profile negotiation, fences, 10-bit layout compatibility, and the public IM2D/legacy API boundary. |
| Owns | The librga docs under [`docs/`](docs/librga-guide.md), the exported [`patches/`](patches/), this front door, and [`keywords.md`](keywords.md). |
| Depends on | A compatible [`../../kernel-drivers/rga/`](../../kernel-drivers/rga/README.md) `/dev/rga` ABI, dma-buf allocation/access, and consuming tests or media applications. |
| Code lives in | `librga` (upstream `airockchip/librga` lineage) and the patched `librga-src` (`github.com/yisding/librga` `main` @ `26a50ef`). |
| Current state | Scale/color-convert has FFmpeg evidence, and the direct librga probes now distinguish the exercised P010/NV15 cases from the still-broader P010/P210 shipping claim. The exported source patches remain paired with kernel-side 10-bit layout changes; [`status.md` W13](../../status.md#watch-w13) owns the latest hardware and packaging boundary. |

## Scoped docs

| Doc | One-liner |
|-----|-----------|
| [`docs/librga-guide.md`](docs/librga-guide.md) | librga guide for users and media developers — what RGA acceleration is and how to use the library well. |
| [`docs/librga-p010-p210-rkrga.md`](docs/librga-p010-p210-rkrga.md) | The P010/P210 10-bit RKRGA investigation and the userspace fix series (`is_10b_compact`/`is_10b_endian`), plus shipping guidance. |
| [`docs/librga-rust-rewrite-assessment.md`](docs/librga-rust-rewrite-assessment.md) | Cost/scope of a Rust `librga` rewrite vs the `rga-rewrite` kernel-driver track. |
| [`patches/`](patches/) | Source patch series from `2cffdf6` to the fixed `a632217` tree. |
| [`UPSTREAMING.md`](UPSTREAMING.md) | Per-item upstream submission decisions for the librga fork's local delta. |

Shared cross-library explanation: [`../docs/how-the-userspace-libs-work.md`](../docs/how-the-userspace-libs-work.md).
Kernel side: [`../../kernel-drivers/rga/`](../../kernel-drivers/rga/README.md).
Project vocabulary: [`keywords.md`](keywords.md).
