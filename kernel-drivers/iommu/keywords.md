# kernel-drivers/iommu — keywords

CCU / IOMMU memory-path terms. Cross-cutting vocabulary is in
[`../../glossary.md`](../../glossary.md).

- **CCU** — **Central Control Unit**: the per-cluster block that picks an idle core
  and shares clocks/IOMMU. The **decoder's CCU is a real MMIO block** (`@fdc30000`);
  the encoder has a virtual driver-side coordinator rather than a separate CCU
  block, while its cores perform the hardware **DCHS** handshake.
- **IOMMU / MMU / IOVA** — the codec's address translator: gives a dma-buf a
  device-side address (IOVA) so the hardware can read/write it. Each core has its
  own IOMMU node.
- **dma-buf** — a kernel-shared, fd-passed, zero-copy buffer (codec ↔ GPU ↔ display).
- **dma-heap** — `/dev/dma_heap/*`, the allocator `rkmpp` draws frame/stream
  buffers from; without access the encoder dies at init.
- **soft / hard CCU** — the decoder CCU's dispatch modes; the SOFT/HARD finding is in
  [`docs/rewrite-hard-ccu-finding.md`](docs/rewrite-hard-ccu-finding.md).
- **shared IOMMU domain** — the CCU conversion that maps a cluster's cores into one
  domain; map/unmap counting for large dma-buf mappings. See
  [`docs/mpp-ccu-iommu-plan.md`](docs/mpp-ccu-iommu-plan.md).
- **RCB** — codec scratch buffers for row/column processing; RK3588 decoder RCB
  is SRAM-backed, while encoder RCB is only optionally plumbed and currently
  unbacked by encoder SRAM in DT. Distinct from link mode. See
  [`../../glossary.md`](../../glossary.md) and
  [`../mpp/docs/rcb-sram.md`](../mpp/docs/rcb-sram.md).
