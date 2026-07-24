# RKNPU forward-port scoping: 8.6k lines, three hard spots, smaller than the MPP/RGA port

> Scope: BSP `drivers/rknpu` (driver 0.9.8) as a forward-port candidate onto
> the ysp 6.18 forward-port kernel; support-coverage row C16.
> Source: `rockchip-kernel@b4ef083dc0c3` `drivers/rknpu/`;
> `linux-6.18-rkvenc@1fe46df86f1c` (v6.18-239) for the mainline-side
> `drivers/accel/rocket` and `rk3588-base.dtsi` observations;
> ysp 6.18 `drivers/soc/rockchip/` contents.
> Date: 2026-07-24
> Trust: SOURCE-INSPECTED for the code/dependency analysis; INFERRED for the
> effort estimates.

## Result

The BSP RKNPU driver is **8,598 lines across 12 C files** — about a fifth of
the MPP+RGA code already forward-ported (MPP ~27.1k, RGA3 stack ~19.1k) — and
most of it is conventional platform/DRM driver material (`dma_fence`,
`sync_file`, clocks, resets, regulators, per-core job queues, IRQ completion).
It already carries dense `LINUX_VERSION_CODE` compat ifdefs (18 in
`rknpu_gem.c` alone), but nothing past its native 6.1. The port effort
concentrates in three places:

1. **`rknpu_iommu.c` (619 lines) — the one file needing design work, and the
   same disease already cured for MPP/RGA.** It casts `domain->iova_cookie`
   to a private mirror of `struct iommu_dma_cookie`
   (`rknpu_iommu_dma_alloc_iova()`, `rknpu_iommu_dma_map_sg()`) and runs its
   own IOVA allocation inside the DMA-cookie domain, plus multi-domain
   switching via `iommu_attach_device()`/`iommu_detach_device()`
   (`rknpu_iommu_switch_domain()`, used by the runtime for >4G model address
   spaces). The cookie-layout cast is flatly dead on 6.18 (private header,
   changed layout). Needs the forward-port patches `0003`/`0006`/`0013`
   treatment: own an unmanaged paging domain with a driver-owned IOVA
   allocator instead of poking the DMA cookie. Also affected:
   `iommu_domain_alloc(bus)` is gone (→ `iommu_paging_domain_alloc(dev)`),
   and the BSP-only `rockchip_iommu_is_enabled()` export needs a substitute.

2. **`rknpu_devfreq.c` (871 lines) — depends on BSP soc infrastructure the
   6.18 tree does not carry.** It calls `rockchip_opp_select`
   (`rockchip_init_opp_table`, pvtpll, read-margin, nvmem cells),
   `rockchip_system_monitor_*`, and `rockchip_ipa_*` — none present in the
   ysp 6.18 `drivers/soc/rockchip/` (mainline grf/io-domain/dtpm only).
   Escape hatch: the file is compiled only under `CONFIG_PM_DEVFREQ` and
   `include/rknpu_devfreq.h` provides complete static-inline no-op stubs, so
   a local Kconfig knob that stubs it out (fixed safe clock at probe) is the
   clean initial port; a plain mainline `devfreq` + `dev_pm_opp` rewrite
   (~200–300 new lines) restores DVFS later.

3. **Hardware-claim conflict with mainline `rocket`.** The 6.18 tree ships
   `drivers/accel/rocket` and `rk3588-base.dtsi` already declares per-core
   `rockchip,rk3588-rknn-core` nodes (`rknn_core_0` @ `fdab0000`, …) with
   their own `rknn_mmu_*` IOMMU nodes. Rocket is not compatible with
   `librknnrt` (different UAPI; Mesa/Teflon userspace), so the RKNN stack
   requires disabling rocket and replacing those nodes with the BSP-style
   single `rknpu` node + IOMMU — the same DT surgery pattern as forward-port
   patches `0002`/`0009`. This is an explicit ABI decision: carrying the
   vendor ABI that mainline rejected in favor of rocket, for the same
   silicon.

The mechanical remainder: `rknpu_gem.c` (1,757 lines) is standard
shmem/CMA-backed GEM + dma-buf whose 6.18 churn is `pfn_t` removal (~3
`vmf_insert_mixed`/`__pfn_to_pfn_t` sites) plus pruning ancient version
branches. Scope cuts that simplify a first port: drop the `DMA_HEAP` memory
manager (depends on the BSP-only `DMABUF_HEAPS_ROCKCHIP_CMA_HEAP`; DRM GEM is
the Kconfig default and what librknnrt uses) and skip `SRAM`/`rknpu_mm.c`
(needs a BSP DT reserved-SRAM node; Kconfig-optional, `NO_GKI`-gated).

**Effort estimate (INFERRED):** with the MPP/RGA IOMMU-integration experience
transferring directly, roughly 2–4 focused days to a probing, compiling
driver (devfreq stubbed, SRAM off, DRM GEM only) and 1–2 weeks to validated
on-board inference against RKNN Runtime 2.3.2 — meaningfully smaller than the
MPP/RGA port was.

## Evidence and reproduction

- **Identity:** code-only scoping; no board run. BSP donor
  `rockchip-kernel@b4ef083dc0c3` (6.1.141), mainline-side observations from
  `linux-6.18-rkvenc@1fe46df86f1c`.
- **Exercise:** line counts via `wc -l` over `drivers/rknpu/`; dependency
  sweep via grep for `rockchip_*` externs, `LINUX_VERSION_CODE`, and
  IOMMU/DMA/pfn API touchpoints; `Kconfig`/`Makefile` read for optionality
  (`rknpu-$(CONFIG_PM_DEVFREQ) += rknpu_devfreq.o`, memory-manager choice);
  ysp 6.18 `drivers/soc/rockchip/` and `drivers/accel/` listings;
  `rk3588-base.dtsi` grep for `rknn`.
- **Key anchors:** `rknpu_iommu.c` `rknpu_iommu_dma_alloc_iova()` /
  `rknpu_iommu_switch_domain()`; `include/rknpu_devfreq.h` stub block;
  `rknpu_gem.c` `rknpu_gem_fault()` (`__pfn_to_pfn_t`); Kconfig
  `ROCKCHIP_RKNPU_DRM_GEM` vs `ROCKCHIP_RKNPU_DMA_HEAP` choice.
- **Sizes:** rknpu 8,598; MPP 27,136; RGA3 stack 19,068 (same `wc -l`
  method, donor tree).
- **Artifacts:** none.

## Boundary

- No compile or boot attempt was made; the estimate is calibrated against the
  MPP/RGA port history, not measured.
- librknnrt's minimum-driver-version handshake was not re-verified against a
  ported 0.9.8 (the runtime checks a minimum driver version — keep the
  version reporting intact; tuple per `kernel-drivers/rknpu/README.md`:
  RKNN Runtime 2.3.2).
- The rocket/vendor coexistence analysis covers hardware claim and DT only;
  no attempt to run both stacks side by side.
- The [2026-07-16 driver-quality finding](./2026-07-16-rockchip-bsp-driver-quality.md#rknpu-deep-dive-capable-fixed-stack-unsafe-multi-client-abi)
  stands after any port: the UAPI round-trips raw kernel pointers
  (`obj_addr`) and dereferences them on submit, so node access remains a
  security boundary. Porting preserves that; acceptable under the image's
  single-user assumption but must be restated in the port's documentation.

## Why it matters / follow-up

Sizes the third BSP accelerator stack (support-coverage row C16, currently
`UNASSESSED`) as a bounded work package rather than an unknown. If picked up,
the first validated on-board inference becomes the C16 evidence. Natural
sequencing: after the current forward-port tail stabilizes, since the rknpu
IOMMU rewrite reuses the same reviewers and patterns as `0003`–`0017`.
