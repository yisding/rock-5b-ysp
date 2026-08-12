# Forward-port 6.18.43 conformance isolates oversized RGA2 USERPTR SWIOTLB segments

> Scope: RK3588 forward-port RGA2 USERPTR mapping and the production
> conformance gate on the installed 6.18.43 kernel
> Source: booted `6.18.43-ysp-rockchip64`, run
> `20260808-113642-conformance-results.tsv`; fixed
> `rk3588-video-6.18@b54ba6079824b`, `rga_mm.c`
> `rga_mm_map_virt_addr()` / `rga_mm_get_rga2_sgt()`
> Date: 2026-08-08
> Trust: **MEASURED** / **CODE-INSPECTED** / **ROOT-CAUSED** /
> **FIX-COMPILE-VERIFIED** / **PARTIAL**

> **Corrected 2026-08-11 by**
> [`2026-08-11-forward-port-rga2-contiguous-userptr-rejection.md`](2026-08-11-forward-port-rga2-contiguous-userptr-rejection.md).
> Exact `0001`–`0096` is now published, installed, and booted. The original
> 2 MiB SWIOTLB rejection is absent, but a high physically contiguous USERPTR
> is rejected by an earlier policy decision; patch `0097` repairs that
> follow-on path and remains runtime-unverified.

## Result

The published 6.18.43 forward-port package now boots with its matching YSP
DTB and reaches the media devices. `run-conformance.sh` passed system identity,
the target/configuration matrix, ABI replay, and all 12 required MPP cases. It
then stopped at librga: 28 of 31 required cases passed, while
`rga_cvtcolor_gray256_demo`, `rga_transform_center_rotate_demo`, and
`rga_rop_demo` failed. GStreamer and FFmpeg were not reached, so this is a
partial 6.18.43 campaign rather than a full conformance result.

The three failures share one pre-hardware mapping mechanism. Each official
sample imports multi-megabyte `malloc` buffers as USERPTR. Gray256 conversion,
ROP, and the center-rotate sample's follow-up fill are RGA2-only operations on
RK3588. The first rotate step in the center-rotate sample succeeds on RGA3;
its left-border `imfill()` is the operation that fails on RGA2.

RGA2 has a 32-bit DMA mask, so high pages must be bounced below 4 GiB through
SWIOTLB. The forward-port's transient USERPTR remap rebuilt the pinned pages
with `sg_alloc_table_from_pages()`, which may merge physically adjacent pages
into entries larger than the DMA backend accepts. All three failed cases
presented a 2 MiB entry. SWIOTLB rejected each one even though only 268, 22, or
716 of 32,768 slots were in use:

```text
rga2 fdb80000.rga2: swiotlb buffer is full (sz: 2097152 bytes), total 32768 (slots), used ...
rga: dma_map_sg failed! ret = 0
rga: RGA2: can not map over-4G buffer below 4G (-22); use below-4G (e.g. CMA/DMA32) buffers
```

The 64 MiB pool was not exhausted. The failing unit was one SG entry larger
than SWIOTLB's 256 KiB per-map ceiling. The driver returned before hardware
start; the suite's postflight scan found zero IOMMU faults, warnings, oopses,
or other fatal signatures. The samples' missing `/data` fixture message is
not causal: they generate fallback input, and the same message appears in
passing samples.

## Evidence

- **Identity:** `uname` reports `6.18.43-ysp-rockchip64`; installed image,
  DTB, and headers are
  `6.18.43+rk3588av1fwport20260807-0ubuntu1~rk1`; `/boot/dtb` resolves to
  `/boot/dtb-6.18.43-ysp-rockchip64`.
- **Exercise:** `sudo bash kernel-drivers/tests/run-conformance.sh`, production
  forward-port profile.
- **Stage signal:** system-info, matrix identity, ABI, and MPP passed; librga
  failed after 5.633 seconds; overall exit 1 after 12.403 seconds.
- **Artifacts:** external run root
  `../rock-5b/build/rockchip-conformance/logs/forward-port/20260808-113642-*`.
  SHA-256: conformance result
  `88d3ce25930586e5c90fcc0f50899d0374dc386578907e41aefbdde3cfb9a861`;
  librga summary
  `6eb29f4682bd9395116fbdb8b4d5207a11096769cb181824b64e98fabc8b7352`;
  new dmesg
  `e54d2944333d824551002316785143cc991f9312b7d4f69213d45c0d3f47715c`.

## Fix

Forward-port patch `0093`, source commit `b54ba6079824b`, builds only USERPTR
SG tables that will be mapped by RGA2 with
`sg_alloc_table_from_pages_segment()` and the selected device's
`dma_max_mapping_size()`. It applies to both direct RGA2 USERPTR imports and
the transient handle remap that failed here. RGA3/IOMMU and physical-import
SG coalescing retain their previous behavior.

The exported patch passes `scripts/checkpatch.pl --strict`. A clean archived
source at the exact commit compiled
`drivers/video/rockchip/rga3/rga_mm.o` with the central ccache; the object
SHA-256 is
`b1d2fb072b6900f186999beff3c74e61ede4d48496e55a9dfd39bf62ca4d60c2`.
The fix is included in the signed `0001`–`0096` source package
`6.18.43+rk3588av1fwport20260808-0ubuntu1~rk1`, whose client-side `dput`
transfer completed. That package is now Published, installed, and booted. Its
production run contains none of the former oversized-SG signatures and passes
the two previously failing center-rotate and ROP cases; gray256 reaches a
separate pre-mapping admission defect fixed by source patch `0097`.

## Boundary

The measured failure belongs to the published/installed `0001`-`0092`
package. The `0093` repair now has source, style, focused-compile, package,
publication, install, boot, and partial runtime proof as part of `0001`–`0096`:
its exact oversized-SG failure is absent, but full conformance remains red at
the separate policy defect owned by the 2026-08-11 finding.
Splitting entries removes the per-entry ceiling but does not make the total
SWIOTLB pool unlimited. Concurrent workloads can still exhaust it and must
continue to fail cleanly. This production boot provides no KASAN or lockdep
evidence.

## Verification gate

Build, package, install, and boot exact source patch `0097` while retaining a
recovery kernel and verifying the YSP DTB link. Repeatedly pass the three
historical RGA2 USERPTR cases with no `swiotlb buffer is full`, RGA2 map, or
under-4-GiB policy rejection and a clean kernel-log interval. Then rerun the
complete production conformance matrix so the previously unreached GStreamer
and FFmpeg stages execute. Exact-tail KASAN/lockdep and targeted hostile gates
remain separate qualification work.
