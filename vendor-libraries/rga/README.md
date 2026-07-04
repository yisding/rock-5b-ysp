# vendor-libraries/rga/ — librga

The userspace RGA library (`librga`): the 2D API, buffer import (fd or virtual
address), command normalization, and core-profile selection over `/dev/rga`.
Source lives in the sibling `librga` / `librga-src` trees.

## Brief

| Field | Contents |
|-------|----------|
| Purpose | How to use librga well, and the 10-bit (P010/P210) RKRGA ABI facts. |
| Code lives in | `librga` (upstream `airockchip/librga` lineage) and the patched `librga-src` (`github.com/yisding/librga` `main` @ `a632217`). |
| Current state | Scale/color-convert validated through FFmpeg; the P010/P210 fix is exported as [`patches/`](patches/) and has an opt-in direct `librga-smoke.sh` hardware case, but still needs recorded hardware validation. See [`../../status.md`](../../status.md). |

## Scoped docs

| Doc | One-liner |
|-----|-----------|
| [`docs/librga-guide.md`](docs/librga-guide.md) | librga guide for users and media developers — what RGA acceleration is and how to use the library well. |
| [`docs/librga-p010-p210-rkrga.md`](docs/librga-p010-p210-rkrga.md) | The P010/P210 10-bit RKRGA investigation and the userspace fix series (`is_10b_compact`/`is_10b_endian`), plus shipping guidance. |
| [`docs/librga-rust-rewrite-assessment.md`](docs/librga-rust-rewrite-assessment.md) | Cost/scope of a Rust `librga` rewrite vs the `rga-rewrite` kernel-driver track. |
| [`patches/`](patches/) | Source patch series from `2cffdf6` to the fixed `a632217` tree. |

Shared cross-library explanation: [`../docs/how-the-userspace-libs-work.md`](../docs/how-the-userspace-libs-work.md).
Kernel side: [`../../kernel-drivers/rga/`](../../kernel-drivers/rga/README.md).
Project vocabulary: [`keywords.md`](keywords.md).
