# AV1 rewrite backend: three-region sparse ABI on the mpp-rewrite core with a kernel-owned AFBC block

> Scope: kernel-drivers/av1 + kernel-drivers/mpp (clean-room rewrite track, C## row 8/11 context)
> Source: `~/Code/kernel/linux-6.18-rk-av1-rewrite` branch `rk3588-rewrite-av1-6.18` @ `e58c57e50d0a0`, `drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c`; DT in `arch/arm64/boot/dts/rockchip/rk3588-rock-5b.dtsi`
> Date: 2026-07-29
> Trust: SOURCE-INSPECTED

## Result

Branch `rk3588-rewrite-av1-6.18` carries an AV1 decoder backend for the
mpp-rewrite driver — the first rewrite path that exposes RK3588 AV1 through
`/dev/mpp_service` (the rewrite track previously routed AV1 to V4L2 stateless
only; [rewrite-driver track](../kernel-drivers/docs/rewrite-drivers.md) §
"Important codec boundary" describes the pre-branch state). It is a four-commit
spur on merge-base `c5faabf9d00b0`:

- `3327030e09029` — add AV1 rewrite backend
- `a5624fa024766` — keep RKVDEC KUnit images off stack
- `402fc9c0bd785` — document and harden AV1 rewrite ABI
- `e58c57e50d0a0` — harden AV1 DMA recovery

Design facts, all read from the driver source:

**Hardware admission.** New compatible `rockchip,av1-decoder` (match table
`rk_mpp_hw_of_match`), backend name `av1dec`, probe-time identity register must
read `0x80019000` (`RK_MPP_AV1_HW_ID`). Register layout, `err_mask 0x7e000`, and
the three register classes match the vendor `mpp_av1dec.c` `av1dec_hw_info` —
this is the Verisilicon-derived AV1 VPU at `fdc70000` behind the VSI IOMMU
(`"rockchip,rk3588-av1-iommu", "verisilicon,iommu-1.2"`).

**Three-region sparse ABI.** Userspace addresses one flat register space; the
driver maps ABI offsets to MMIO regions positionally: VCD @ `0x00000`
(min window `0x800`), CACHE @ `0x10000` (min `0x298`), AFBC @ `0x20000`
(min `0x350`). `rk_mpp_reg_region_for_span()` requires each request to fall
entirely inside one region; per-region image buffers are allocated lazily.
The AV1 fd-translation tables total 103 entries (67 VCD + 24 cache + 12 AFBC),
which exceeds the fixed `RK_MPP_MAX_REG_TRANS_NUM = 80`, so per-job
import/binding arrays grow dynamically (`rk_mpp_job_append_reg_binding()`).

**Kernel-owned AFBC block.** Raw userspace register writes into region 2 are
skipped for AV1 clients in `rk_mpp_job_write_regs()`; the whole AFBC
configuration is derived from the *validated* VCD image
(`rk_mpp_av1_build_afbc_config()`, run once in `.validate` and once in
`.submit`): dimensions word 4, bit depth word 8, padding word 503, tile bits in
PP config word 321. The AFBC output word (505) must equal the translated IOVA of
a retained dma-buf binding — a literal address fails with `-EINVAL` — and the
computed header+payload span is bounds-checked against the dma-buf size with
overflow-checked arithmetic (`rk_mpp_av1_afbc_required_span()`, `-ERANGE`).
Programming publishes all parameters, `wmb()`, then pulses the update latch.

**IRQ topology.** Primary IRQ is platform index 0; register `0x0004` is
simultaneously start/enable/status/clear. The AFBC interrupt is an auxiliary
`IRQF_SHARED` handler on platform index 2, gated by `aux_irqs_active` and
`pm_runtime_get_if_in_use()`, and it is mandatory: `rk_mpp_av1_validate()`
refuses jobs when the core has no aux IRQ registered. The board DT declares a
third interrupt (`irq_cache`, index 1) that the driver never claims.

**VSI IOMMU provider.** Fault-handler registration tries
`rockchip_iommu_set_fault_handler()` and falls back to
`vsi_iommu_set_fault_handler()` on `-ENODEV`; post-fault recovery uses
`vsi_iommu_refresh()` (Rockchip cores use `iommu_flush_iotlb_all()`). Because
VSI masks its fault source in the provider IRQ, the fault worker refreshes the
IOMMU even when it finds no job. `e58c57e` also added the
`rk_mpp_hw_take_irq_job()` fault-generation guard now used by all three
backends, so an IRQ thread cannot steal a job from a pending fault worker.
`drivers/iommu/vsi-iommu.c` on this branch is a 6.18 backport of the upstream
driver extended with the provider-hook layer (fault callback plumbing, IRQ
mask, pm-runtime guards) that upstream v7.2-rc5 does not have.

**DT binding is board-level and load-bearing.** `rk3588-base.dtsi` keeps the
mainline `rockchip,rk3588-av1-vpu` compatible with a single `0x800` window; the
rewrite binds only because `rk3588-rock-5b.dtsi` retypes `&av1d` to
`rockchip,av1-decoder` with three reg windows (`vcd`/`cache`/`afbc`) and three
IRQs. The same pattern holds for the rkvdec2 nodes (board retype of
`rockchip,rk3588-vdec`).

## Boundary

Source-inspected only. No board evidence of AV1 decode through the rewrite path
is recorded here — no conformance run, no KASAN boot with this backend
exercised. The mainline rewrite branch (`rk3588-rewrite-mainline`) has no AV1
backend; this design exists only on the 6.18 AV1 spur. The `irq_cache`
observation (declared but unclaimed) is a gap statement, not a defect proof —
whether the cache block can raise an interrupt the driver must service is
untested.

## Why it matters / follow-up

This is the kernel half that the direct `/dev/mpp_service` AV1 userspace design
([av1-direct-mpp-service-backend](../video-libraries/vaapi/docs/av1-direct-mpp-service-backend.md))
would submit to. The branch forked before 19 hardening commits on
`rk3588-rewrite-6.18`; see
[the companion gap finding](2026-07-29-av1-rewrite-branch-hardening-gap-and-backport.md)
for the backport record.
