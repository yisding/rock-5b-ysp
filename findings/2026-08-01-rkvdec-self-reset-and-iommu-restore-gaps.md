# The rkvdec2 hardware self-resets on error; the rewrite driver neither detects it nor restores the IOMMU

> Scope: kernel-drivers/mpp — clean-room rewrite MPP driver, rkvdec2 error/IRQ
> path on RK3588. Compared against the RK3588 TRM, the Rockchip 6.1 BSP, and
> mainline `rkvdec`.
> Source: `linux-6.18-rkvenc` @ `rk3588-rewrite-6.18` `b37f6e9825b1` —
> `mpp_rewrite.c` `err_mask` (~:1581), `rk_mpp_rkvdec2_thread()` (~:14518),
> `rk_mpp_hw_refresh_iommu()` (~:12104). TRM Part 1 v1.0
> `RKVDEC_SWREG224_STA_INT` (p. 518), `RKVDEC_CCU_SWREG20` (p. 536).
> Date: 2026-08-01
> Trust: **TRM-CONFIRMED** (register semantics quoted from the vendor TRM) +
> SOURCE-INSPECTED (our driver, the BSP, and mainline) + **NOT MEASURED** —
> no failure has been attributed to any gap below, and none has been
> instrumented. Discovered by verifying our findings against public sources,
> not by observing a defect.

## Result

The RK3588 decoder **resets itself** on most error conditions. The TRM is
explicit, per bit, in `RKVDEC_SWREG224_STA_INT` at offset `0x0380` — the same
register our driver reads as `RK_MPP_RKVDEC_INT_STA_BASE`:

| Bit | Name | TRM says |
|---:|---|---|
| 9 | `sw_softreset_rdy` | *"When it is 1'b1, it says that softreset has been done."* |
| 7 | `sw_colmv_ref_error_sta` | *"inter module read the invalid dpb frame… It will self reset the hardware."* |
| 5 | `sw_dec_timeout_sta` | *"decoder has been idling for too long. It will self reset the hardware"* |
| 4 | `sw_dec_error_sta` | *"an error is found in input data stream decoding. It will self reset the hardware."* |
| 3 | `sw_dec_bus_sta` | *"there is error on the axi bus, it will self reset hardware."* |

Our `err_mask` is `0xf0` — bits 4–7. **Three of those four bits are documented
self-reset conditions.** So by the time the IRQ thread runs
`rk_mpp_rkvdec2_reset_soft_ccu_job()`, the core has in most cases already reset
itself, and the driver's `reset_control` assert/`udelay(10)`/deassert lands on
top of a hardware reset it does not know happened.

That is a **third reset actor** we had not modelled. The
[sibling deassert race](2026-07-31-rkvdec-sibling-reset-deassert-race.md)
analysis assumed two writers of a core's reset state — the core's own recovery
and a sibling's power-on. There are three.

## Four specific gaps

1. **`sw_softreset_rdy` (bit 9) is never read.** `grep -i softreset` over
   `mpp_rewrite.c` returns nothing. We have the bit — the full `INT_STA` word is
   fetched into `irq_status` — we simply never test it. Mainline does
   (`rkvdec.c`, `VDPU381_STA_INT_SOFTRESET_RDY`), and uses it as the trigger for
   IOMMU recovery.

2. **The IOMMU is not reprogrammed after a self-reset.** The decoder's IOMMU is
   embedded inside the decoder, so a self-reset resets it too. Mainline's fix:

   > *"On errors, the rkvdec chip self resets. This can clear the addresses
   > programmed in the iommu. This case is signaled by the RKVDEC_SOFTRESET_RDY
   > status bit."*

   and, because the IOMMU framework has no restore call, it attaches and
   detaches an empty domain to force a reprogram. Our
   `rk_mpp_hw_refresh_iommu()` calls `iommu_flush_iotlb_all()` on the rockchip
   provider — a TLB invalidate, which does not rewrite the DTE base address or
   the enable bit.

   **Open question, not a confirmed defect:** rockchip-iommu reprograms on
   runtime resume, and our IRQ thread calls `rk_mpp_hw_power_off()` after
   recovery, so a power cycle between jobs may mask this entirely. Pipelined
   jobs that hold the power reference would not. This needs a targeted test
   before it is called a bug.

3. **`sw_dec_bus_sta` (bit 3) is outside `err_mask`.** An AXI bus error
   self-resets the hardware and we would complete the job as successful. Worth
   context: **the BSP also uses `err_mask = 0xf0`** (`mpp_rkvdec2_link.c:82`
   and `:145`), and mainline's VDPU381 register header defines no bus-error bit
   either. So this is a gap shared with both references rather than a rewrite
   regression, and no run has ever been observed setting it. Recorded because
   the TRM documents it and nobody handles it, not because it has bitten.

4. **`SWREG20_CCU_CORE_REQ_TIMEOUT_E` (`0x0050`) is never programmed.** The TRM:
   *"When ccu start core to work, but too long to fetch ack, it will unload such
   core."* It defaults to 0 — "can't timeout". Our driver has no constant for
   the offset. This is the only documented mechanism by which the CCU abandons
   an unresponsive core, and it sits disabled.

## Why it matters

The immediate value is corrective rather than a bug fix: **the error path is
not what we thought it was.** Every reset-path conclusion drawn so far — the
deassert race, the reset-domain lock, the wedge analysis — was reasoned about
as if the driver's `reset_control` pulse were the reset. For bits 4, 5 and 7 it
is a *second* reset following a hardware one that has already completed.

This does not invalidate the
[deassert race](2026-07-31-rkvdec-sibling-reset-deassert-race.md), which is
measured and concerns the driver's own pulse being truncated by a sibling. It
does mean the wedge hypothesis space is larger than the two candidates in
[the wedge finding](2026-08-01-rewrite-soft-ccu-cross-core-reset-wedge.md), and
that any model of "what state the core is in" during recovery needs the
hardware's own reset in it.

## Verification steps

Ordered cheapest first; none has been run.

1. **Count it.** Add a `softreset_rdy` counter alongside the existing reset
   counters and re-run the contention harness. Reading a bit we already fetch
   costs nothing, and it answers whether the hardware is self-resetting under
   our provocation at all — and how it correlates with the ~4300 driver resets
   per 60 s run.
2. **Test the IOMMU question.** Establish whether the DTE base survives a
   self-reset in practice, e.g. by reading back the IOMMU registers after an
   error IRQ on a job that holds the power reference across the recovery.
3. **Only then** decide whether to adopt mainline's attach/detach-empty-domain
   restore, widen `err_mask` to bit 3, or enable the CCU request timeout. Each
   is a behaviour change on the recovery path and belongs in its own commit.

## Boundary

Nothing here is measured. No failure, corruption, or wedge has been attributed
to any of the four gaps. Gap 3 is shared with the BSP and mainline. Gap 2 may
be fully masked by runtime PM. The finding exists because verifying our
hardware model against the vendor TRM and the upstream driver turned up
behaviour we had not accounted for, and that is worth recording before it is
rediscovered the expensive way.

Says nothing about rkvenc2, AV1, or hard-CCU mode.
