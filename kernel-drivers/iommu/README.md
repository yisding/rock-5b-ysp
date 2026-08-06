# kernel-drivers/iommu/ — CCU / IOMMU memory path

The codec memory path: per-core IOMMUs, dma-buf mapping, and the decoder's
Central Control Unit (CCU). Holds the net-new CCU MMU/IOMMU plan and the SOFT/HARD
CCU finding from the rewrite track.

## Brief

| Field | Contents |
|-------|----------|
| Purpose | How dma-buf buffers get device-side addresses (IOVAs) through each core's IOMMU, and how the decoder CCU shares that across a cluster. |
| Developer focus | Domain sharing, map/unmap lifetime, fault attribution, SOFT/HARD CCU dispatch, and the public-DMA-API constraints of the rewrite. |
| Owns | The four-part IOMMU/DMA explainer, [`docs/mpp-ccu-iommu-plan.md`](docs/mpp-ccu-iommu-plan.md), [`docs/rewrite-hard-ccu-finding.md`](docs/rewrite-hard-ccu-finding.md), and [`keywords.md`](keywords.md). |
| Depends on | Rockchip IOMMU and dma-buf kernel infrastructure, effective RK3588 DT bindings, and the MPP/RGA drivers that consume the domains. |
| Code lives in | Rockchip IOMMU + MPP service code in the sibling kernel trees (`drivers/iommu/rockchip-iommu.c`, `mpp/mpp_iommu.c`, `mpp_rkvdec2*.c`). |
| Current state | CCU IOMMU plan implemented in the rewrite track; SOFT/HARD CCU finding resolved. See [`../docs/rewrite-drivers.md`](../docs/rewrite-drivers.md) and [`../../status.md`](../../status.md). |

## Explainer series (start here)

A from-first-principles walkthrough of the whole IOMMU story on RK3588, concept →
hardware → driver code → cross-version DMA contracts. Read in order if you're
new to it.

| Doc | One-liner |
|-----|-----------|
| [`docs/01-iommu-primer.md`](docs/01-iommu-primer.md) | What an IOMMU is and why it exists (vendor-neutral): the three problems it solves, the vocabulary, where it sits in the Linux DMA stack, and the `dma_map_sg` coalescing detail everything else hinges on. |
| [`docs/02-rk3588-iommu-hardware.md`](docs/02-rk3588-iommu-hardware.md) | The RK3588 silicon: one IOMMU per block (topology), the 2-level DTE→PTE page table + walk math, the 32-bit-IOVA/40-bit-physical asymmetry, register/command map, fault mechanism, and the separate AV1D (Verisilicon) provider. |
| [`docs/03-bsp-iommu-code.md`](docs/03-bsp-iommu-code.md) | What the RGA and MPP drivers actually do: internal-MMU (RGA2) vs external-IOMMU (RGA3), shared domains, the buffer-import → single-segment-contract → program-IOVA flow, RGA userptr-IOMMU fallback userptr mapping, the CCU cluster domain, and the forward-port hardening. |
| [`docs/04-dma-mapping-porting-contracts.md`](docs/04-dma-mapping-porting-contracts.md) | Why identical client code behaves differently across BSP, forward-port, and rewrite kernels: allocation vs mapping geometry, DMA masks and limits, SWIOTLB's per-map ceiling, RGA2 page-offset preservation, USERPTR vs DMA-BUF ownership, legal fallback patterns, failure signatures, and a porting checklist. |

## Scoped docs

| Doc | One-liner |
|-----|-----------|
| [`docs/mpp-ccu-iommu-plan.md`](docs/mpp-ccu-iommu-plan.md) | The net-new CCU MMU/IOMMU plan (shared-domain conversion, map/unmap count handling for large dma-buf mappings). |
| [`docs/rewrite-hard-ccu-finding.md`](docs/rewrite-hard-ccu-finding.md) | The RKVDEC2 SOFT/HARD CCU rewrite finding and its validation gap — an exemplary self-describing finding (scope/provenance/date/MEASURED labeling). |

Project vocabulary: [`keywords.md`](keywords.md).
