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
> SOURCE-INSPECTED (our driver, the BSP, and mainline) + **MEASURED**
> (2026-08-01, `#27 gb37f6e9825b1`) — the AXI-bus-error bit fires on roughly
> half of all interrupts under the corrupt-stream provocation, alone, with no
> IOMMU faults; `softreset_rdy` was never observed. Discovered by verifying
> our model against public sources, then measured off instrumentation that
> already existed.

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

## Measured (2026-08-01)

Sampled off the existing debug event ring during the lock-gate run — no kernel
change. Fourteen `irq` events, **all** on `fdc38100`/`fdc40100` `rkvdec2`, so
no register-layout mixing with the encoder. Only **two distinct `INT_STA`
values appear**, seven of each:

| Value | Bits | Meaning | In `err_mask` `0xf0`? |
|---|---|---|---|
| `0x23` | 0, 1, **5** | `sw_dec_timeout_sta` — hardware decode timeout | **yes** → reset taken |
| `0xb` | 0, 1, **3** | `sw_dec_bus_sta` — **AXI bus error** | **no** → no reset, no recovery |

- **Bit 3 fires on ~50% of interrupts** under the corrupt-stream provocation.
  It is not a theoretical condition.
- **`bus_with_rdy = 0`** — bit 3 never co-occurs with `sw_dec_rdy_sta` (bit 2).
- **`iommu_fault_count = 0`** across the run, so these are not IOMMU faults
  being reported twice by another route.
- **`softreset_rdy` (bit 9) was never observed**, on either value.
- The 50/50 split is corroborated independently by the counters:
  `reset_count / dispatched_job_count` = 5060/9787 = **51.7%**, matching the
  7-of-14 sample almost exactly. Half the jobs reset (the `0x23` half); the
  other half do not (the `0xb` half).

Two honest limits. The ring holds 64 entries so this is the tail of the run,
not a census. And the TRM says bits 3 and 5 both self-reset the hardware, yet
bit 9 never appeared alongside them — the self-reset may still occur with its
completion not visible in the same status read, or the driver may ack the
status before the bit latches. The negative result is recorded as-is rather
than explained away.

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
   detaches an empty domain to force a reprogram.

   **Corrected 2026-08-01:** an earlier draft of this finding said we do a TLB
   flush after our reset. We do not — not on this path. `iommu_refresh_count`
   moved by **0** across **5060 resets** in run `155714`. The soft-CCU error
   path is `rk_mpp_rkvdec2_reset_soft_ccu_job()` → `rk_mpp_hw_stop_active()`,
   and it never calls `rk_mpp_hw_refresh_iommu()` at all; the call site at
   ~:12491 belongs to a different (fault/timeout) path. So after a hardware
   self-reset the driver does nothing to the IOMMU — neither the flush nor the
   reprogram.

   **Still not a confirmed defect.** `iommu_fault_count` is also 0 across the
   same run, so nothing is actually mistranslating. The likely reason is that
   rockchip-iommu reprograms on runtime resume and the IRQ thread calls
   `rk_mpp_hw_power_off()` after every job, so the power cycle restores it for
   free. Pipelined jobs holding the power reference across a self-reset are the
   case that would not be covered, and that case has not been constructed.

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

1. **Read it off the existing instrumentation — no kernel change required.**
   `rk_mpp_rkvdec2_thread()` already records every interrupt into the debug
   event ring with its raw `irq_status`, and
   `rk_mpp_debug_events_show()` prints that word in hex as field 11 of
   `/sys/kernel/debug/rk_mpp_rewrite/events`. Both bits of interest are
   therefore observable on any kernel carrying the ring:

   ```
   sudo sh -c 'echo 2 > /sys/kernel/debug/rk_mpp_rewrite/trace_mask'   # TRACE_IRQ
   sudo RESET_DURATION_S=5 bash kernel-drivers/tests/rewrite-reset-contention.sh
   sudo cat /sys/kernel/debug/rk_mpp_rewrite/events |
     awk '$3=="irq" { n++; v=strtonum($11)
                      if (int(v/512)%2) sr++      # bit 9 softreset_rdy
                      if (int(v/8)%2)   bus++     # bit 3 dec_bus_sta
                      if (int(v/4)%2)   rdy++ }   # bit 2 dec_rdy_sta
          END { print "irq:", n, "softreset_rdy:", sr+0,
                      "bus:", bus+0, "rdy:", rdy+0 }'
   sudo sh -c 'echo 0 > /sys/kernel/debug/rk_mpp_rewrite/trace_mask'
   ```

   The ring holds only `RK_MPP_DEBUG_EVENT_COUNT` = **64** entries and the
   provocation produces thousands of interrupts per second, so this samples
   rather than counts — which is sufficient to answer "does it ever happen",
   and is why the run above is 5 s rather than 60. A dedicated counter is only
   worth adding if the sample says the bits are interesting, and adding one has
   a known cost: the last two counters added to `struct rk_mpp_service` tripped
   `-Wframe-larger-than=2048` in two KUnit fixtures and needed a prep commit.

   Run this **before** booting the reset-domain-lock kernel if convenient. Not
   because the lock would perturb it — the lock serializes `reset_control`
   calls and cannot affect whether the hardware self-resets — but because the
   pre-lock kernel is the cleaner baseline to quote later.
2. **Test the IOMMU question.** Establish whether the DTE base survives a
   self-reset in practice, e.g. by reading back the IOMMU registers after an
   error IRQ on a job that holds the power reference across the recovery.
3. **Only then** decide whether to adopt mainline's attach/detach-empty-domain
   restore, widen `err_mask` to bit 3, or enable the CCU request timeout. Each
   is a behaviour change on the recovery path and belongs in its own commit.

## What to do about bit 3 specifically

`sw_dec_bus_sta` deserves its own answer, because the obvious move — widen
`err_mask` to `0xf8` — is the wrong first step.

**What happens today.** `irq_status & 0xf0` is false, so the error branch is
skipped entirely: no reset, no IOMMU refresh, and
`rk_mpp_job_complete(job, ret)` runs with `ret` from the register readback,
normally 0. The job is reported to userspace as **successful**. Meanwhile the
hardware has self-reset mid-decode, so the frame is incomplete, and per the
mainline analysis the self-reset has also cleared the decoder's embedded IOMMU.
The same `err_mask` also feeds the job-result path at ~:3083, so it is the
userspace-visible contract, not just an internal branch.

**Why it might matter more than a stray error bit.** An AXI error response is
what you would expect from a DMA to an unmapped page, or to a region behind a
block that is gated or in reset. That makes bit 3 the plausible *survivable*
cousin of the [interconnect wedge](2026-08-01-rewrite-soft-ccu-cross-core-reset-wedge.md):
the case where the fabric returns an error instead of stalling forever. If it
is being set during our provocations we are discarding direct evidence of the
pathology we have spent three days chasing.

**Why not to just widen the mask.** Three reasons to measure first:

- **The BSP uses `0xf0` too** (`mpp_rkvdec2_link.c:82`, `:145`), on shipping
  silicon, and mainline's VDPU381 header defines no bus-error bit at all.
  Diverging from both references on an unobserved condition is how you acquire
  a regression nobody can bisect.
- **Co-assertion is unknown.** If bit 3 is ever set alongside `sw_dec_rdy_sta`
  (bit 2, picture decoded), widening the mask would start failing and resetting
  on frames that completed fine. The vendor's `0xf0` may be deliberate for
  exactly that reason.
- **We may already handle it by another route.** A rockchip-IOMMU fault raises
  the IOMMU's own interrupt, which the driver handles via `iommu_fault_pending`.
  If bus errors co-occur with IOMMU faults, treating bit 3 as an error too
  would double-handle the same event.

**Staged disposition**, gated on the step-1 sample above:

| Sample result | Action |
|---|---|
| Bit 3 never sets | Leave `err_mask` alone; keep a tripwire so we learn if it ever does |
| **← selected** Sets *without* bit 2, and not alongside an IOMMU fault | Strong case to widen to `0xf8` — hardware already self-reset, the frame is bad, and recovery plus IOMMU refresh is the consistent response |
| Sets *with* bit 2, or alongside IOMMU faults | Do **not** widen. Handle separately: refresh the IOMMU and count it, without changing the userspace job result |

**The measurement selected the middle row**: bit 3 fires alone, never with
bit 2, with `iommu_fault_count` at 0. On the stated criteria that is the
"widen to `0xf8`" case.

Two things temper it, and neither was known when the criteria were written:

- **Userspace is not being silently lied to.** The per-frame error flag reaches
  applications by a different channel — `mpi_dec_test` logs `decode get frame N
  err 1` throughout these runs. What is missing is the *driver's* recovery
  bracket (reset, IOMMU handling, counters), not the userspace signal. That
  lowers the severity from "silent corruption" to "unaccounted-for hardware
  error", which is still worth fixing but is not urgent.
- **Widening roughly doubles reset traffic under this provocation** — every
  `0xb` job would take the reset path that only the `0x23` half takes today.
  On clean streams bus errors presumably never occur, so the steady-state cost
  should be nil, but that assumption should be measured on a normal decode
  before the change lands, not after.

So: widen, but as its own commit, with a before/after reset-rate comparison on
an ordinary decode, and with the `err_mask` KUnit expectation updated to
`0xf8U` and a comment explaining why we diverge from the BSP's `0xf0`.

Any change must also update `KUNIT_EXPECT_EQ(test, info->err_mask, 0xf0U)`
(~:5616), which is a deliberate gate on this constant rather than an
incidental assertion — a good place to record the reasoning in the commit.

## Boundary

Nothing here is measured. No failure, corruption, or wedge has been attributed
to any of the four gaps. Gap 3 is shared with the BSP and mainline. Gap 2 may
be fully masked by runtime PM. The finding exists because verifying our
hardware model against the vendor TRM and the upstream driver turned up
behaviour we had not accounted for, and that is worth recording before it is
rediscovered the expensive way.

Says nothing about rkvenc2, AV1, or hard-CCU mode.
