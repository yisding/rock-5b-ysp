# RCB and SRAM: codec scratch memory wiring

This note explains the memory model behind the `rockchip,rcb-*` properties and
`MPP_CMD_SET_RCB_INFO`. It is the conceptual companion to the RK3588-specific
finding in [`../../../findings/2026-07-05-rkvenc-rcb-sram.md`](../../../findings/2026-07-05-rkvenc-rcb-sram.md).

> Anchors resolve against the local source trees used on 2026-07-05:
> `../kernel/rockchip-kernel` `b4ef083dc0c3`,
> `../kernel/linux` `c092e016fd29`, and
> `../rockchip-conformance/sources/rockchip-mpp` `c2c1ee502b3a`.

## One paragraph

RCB is codec scratch memory. The video hardware needs temporary per-row or
per-column state while decoding or encoding a picture; those scratch regions are
not input frames, output frames, bitstreams, or userspace-visible results. SRAM is
one possible backing store for that scratch: small on-chip static RAM that is
faster and saves DDR bandwidth, but must still be mapped into the codec's IOMMU
address space before the hardware can use it. The driver connects the two by
allocating or locating backing memory, mapping it to a device-visible IOVA, and
programming hardware registers with `rcb_iova + offset` addresses.

## What RCB means

The upstream Rockchip V4L2 decoder code names the file
`rkvdec-rcb.c` and describes it as a "Rows and Cols Buffers manager" in the file
header. In this repo and in several vendor-code comments, "RCB" is also described
as "row-cache buffer." Those are the same class of memory for our purposes:
codec-internal scratch buffers associated with row/column processing.

What goes in RCB is codec-generation specific. For decoder paths, current source
comments and tables identify buffers such as `streamd`, `inter`, `intra`,
`filterd`, and tile row/column variants
(`drivers/media/platform/rockchip/rkvdec/rkvdec.c`, around lines 1716-1726).
The mainline decoder note summarizes these as per-picture scratch for
intra/deblock/SAO/filter work.

An RCB descriptor is not a buffer by itself. It is layout metadata:

- register index: which hardware register should receive the scratch address;
- size: how much of the scratch window this register consumes.

In the BSP `/dev/mpp_service` ABI, userspace can send descriptors with
`MPP_DEV_RCB_INFO`; the service backend emits `MPP_CMD_SET_RCB_INFO`. In the
device tree, decoder fixed RCB layouts appear as `rockchip,rcb-info`, a list of
`(register index, size)` pairs.

## What SRAM means here

SRAM is static RAM inside the SoC, not DDR memory. On RK3588 the relevant pool is
`system_sram2@ff001000`, split by the media DT into decoder pools such as
`vdec0_sram` and `vdec1_sram`.

Three details matter:

- SRAM is small and physically fixed. It is a scarce SoC resource, not a general
  dma-buf heap.
- The codec does not use a CPU virtual address. With the IOMMU enabled, the
  driver must program a device IOVA into hardware registers.
- SRAM ownership is a DT and driver contract. A phandle like
  `rockchip,sram = <&vdec0_sram>` says which hardware block owns that SRAM slice.
  Do not reuse another block's SRAM without hardware documentation.

## How they interact in the BSP

The BSP fixed-window model is:

1. DT provides `rockchip,rcb-iova = <base size>`.
2. DT provides `rockchip,sram = <&some_sram_pool>`.
3. The driver reserves the IOVA window so normal DMA mappings do not collide with
   it.
4. The driver resolves the SRAM phandle to a physical address with
   `of_address_to_resource()`.
5. The driver maps the physical SRAM into the codec IOMMU domain at the fixed
   RCB IOVA with `iommu_map()`.
6. If the requested RCB window is larger than SRAM, the BSP allocates normal
   pages and maps those immediately after the SRAM part.
7. At job setup, the driver writes `rcb_iova + offset` into each register named
   by the RCB layout.

For RKVDEC2 this is explicit in `mpp_rkvdec2.c`:

- read `rockchip,rcb-iova`, reserve the IOVA, parse `rockchip,sram`, map SRAM:
  `rkvdec2_alloc_rcbbuf()` around lines 1792-1875;
- read optional `rockchip,rcb-min-width` and `rockchip,rcb-info` around
  lines 1881-1898;
- in link mode, write each RCB register to `dec->rcb_iova + rcb_offset` and set
  the fixed-RCB latch (`mpp_rkvdec2_link.c`, around lines 2510-2535).

For RKVENC2 the BSP has the same broad shape, but the input layout usually comes
from userspace `MPP_CMD_SET_RCB_INFO` rather than DT `rockchip,rcb-info`.
`rkvenc2_set_rcbbuf()` only patches registers if `enc->sram_iova` is nonzero; if
there is no RCB backing, the descriptors are accepted but do not change the
register image.

## How they interact in mainline-style decoder code

The upstream V4L2 decoder uses a different allocation policy for the same concept:

1. A per-variant table sizes each RCB region from the coded picture dimensions.
2. `rkvdec_allocate_rcb()` tries to allocate from an SRAM gen_pool first.
3. If SRAM allocation succeeds and an IOMMU domain is active, it maps the SRAM
   physical address through the IOMMU and uses the mapped IOVA in registers.
4. If SRAM allocation fails or no SRAM pool exists, it falls back to coherent
   DMA memory in normal RAM.

Relevant anchors:

- `rkvdec-rcb.c` lines 22-26: size = multiplier times width or height.
- `rkvdec-rcb.c` lines 117-148: try SRAM first and IOMMU-map it.
- `rkvdec-rcb.c` lines 150-168: fallback to `dma_alloc_coherent()`.
- `rkvdec-vdpu381-h264.c` lines 347-349 and
  `rkvdec-vdpu383-h264.c` lines 336-340: program the RCB DMA/IOVA addresses into
  the register image.

This model is safer and more idiomatic for mainline, but it is not byte-for-byte
the BSP fixed-IOVA model.

## How the 7.2 rewrite handles RCB

The local `/dev/mpp_service` rewrite intentionally uses public DMA APIs instead
of BSP fixed-IOVA SRAM reservation. If DT provides `rockchip,rcb-iova`, the
rewrite uses the size cell to allocate per-core coherent scratch with
`dmam_alloc_coherent()` and stores the returned DMA address as `hw->rcb_iova`.
It does not parse `rockchip,sram`.

That means:

- it preserves the userspace ABI and register-patching behavior;
- it can exercise RCB descriptor logic;
- it does not prove that a path is using on-chip SRAM.

The ABI doc says this directly in `drivers/video/rockchip/mpp-rewrite/ABI.rst`
around lines 220-227.

## What RCB is not

RCB is easy to confuse with other codec memory:

- It is not the decoded frame buffer or encoded bitstream buffer.
- It is not the DPB. DPB frames are real reference pictures managed by the codec
  API and userspace.
- It is not `colmv`. Collocated motion-vector storage is separate and often lives
  in the tail of a capture buffer.
- It is not a CPU cache. "Row cache" describes hardware scratch state, not
  processor cache lines.
- It is not a magic performance flag. The hardware must actually receive RCB
  register addresses that point at a valid backing store.

## RK3588-specific state

On the studied RK3588 trees:

- RKVDEC2 is SRAM-backed:
  - core 0: `rockchip,sram = <&vdec0_sram>`,
    `rockchip,rcb-iova = <0xFFF00000 0x100000>`;
  - core 1: `rockchip,sram = <&vdec1_sram>`,
    `rockchip,rcb-iova = <0xFFE00000 0x100000>`.
- RKVENC2 has optional RCB descriptor plumbing but no SRAM-backed DT properties
  in either the 6.1 BSP RK3588 DTS or the 7.2 rewrite RK3588 DTS.

So for RK3588, "decoder RCB uses SRAM" is an observed DT/driver fact. "Encoder
RCB uses SRAM" is not supported by the current evidence.

## Why it can matter for performance

RCB traffic is intermediate codec traffic. If that traffic goes to on-chip SRAM,
it can reduce DDR reads/writes and may improve latency, throughput, or power.
That is why the decoder SRAM path is worth preserving.

But a performance claim needs proof at the register/mapping level:

- the hardware registers must be patched to RCB addresses;
- those addresses must resolve to SRAM or to a known scratch allocation;
- the codec workload must be large enough for the scratch path to matter;
- correctness must be checked under concurrent codec use.

For RK3588 RKVENC specifically, the next safe benchmark step is not to borrow
decoder SRAM. It is to instrument whether `MPP_CMD_SET_RCB_INFO` is received and
whether any register is patched. With the current unbacked encoder DT, the
expected answer is "descriptors received, no SRAM-backed register patch."

## Safety rules

- Treat SRAM ownership as hardware state. DT tells the driver which block owns
  which SRAM slice.
- Reserve or validate fixed RCB IOVA windows so they cannot overlap normal DMA
  mappings or another fixed scratch window.
- Validate user-provided RCB register indices before writing into a register
  image. The BSP audit found real out-of-bounds-write risk in this class of code.
- Keep RCB map/unmap tied to the same IOMMU domain the hardware will use.
- Do not treat coherent DMA scratch as SRAM. It may be useful, but it has a
  different performance and ownership model.
