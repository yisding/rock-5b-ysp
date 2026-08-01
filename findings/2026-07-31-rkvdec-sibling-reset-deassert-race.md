# rkvdec soft-CCU sibling power-on can cancel a peer core's recovery reset

> Scope: kernel-drivers/mpp — clean-room rewrite MPP driver, rkvdec2 soft-CCU
> reset/recovery path on RK3588 (ROCK 5B)
> Source: `linux-6.18-rkvenc` @ `rk3588-rewrite-6.18` d9992e32dc17 —
> `mpp_rewrite.c` `rk_mpp_hw_power_on()` (~:11388), `rk_mpp_hw_reset_active()`
> (~:11556), `rk_mpp_rkvdec2_power_on_ccu_cores()` (~:3096),
> `rk_mpp_rkvdec2_acquire_soft_ccu()` (~:11214); DT `rk3588-base.dtsi`
> Date: 2026-07-31
> Trust: DESIGN, CODE-INSPECTED, CONFIG-INSPECTED — the mechanism and its
> reachability on this board are established from source and the live device
> tree. The race has **not** been observed executing; the counter added in
> d9992e32dc17 exists to settle that before the fix lands.

## Result

`rk_mpp_hw_power_on()` deasserts the target core's reset unconditionally:

    mpp_rewrite.c:11388   ret = reset_control_deassert(hw->resets);

It runs on **every** call, not only on a 0 → 1 power transition — `power_count`
is incremented afterwards at ~:11397 and never consulted first — and the
controls are `devm_reset_control_array_get_optional_exclusive()` (~:16699). For
*exclusive* controls `reset_control_deassert()` always drives the hardware;
there is no shared refcount to defer it.

`rk_mpp_hw_reset_active()` pulses the same line:

    mpp_rewrite.c:11556   reset_control_assert() / udelay(10) / reset_control_deassert()

`rk_mpp_rkvdec2_acquire_soft_ccu()` reaches `power_on()` for **sibling** cores
via `rk_mpp_rkvdec2_power_on_ccu_cores()` (call at ~:11270), holding only the
*submitting* core's `run_lock`; `srv->hw_lock` is dropped before the power loop
at ~:3116. A sibling's own reset pulse runs under that sibling's `run_lock`. No
lock is common to the two paths, so they can overlap:

    core0: submit -> acquire_soft_ccu -> power_on(core1) -> deassert(core1)
    core1: timeout/error -> reset_active(core1) -> assert .. udelay(10) .. deassert

core0 can end core1's pulse a couple of microseconds into the intended ten.
core1's own deassert then no-ops, `reset_active()` returns 0, `stop_active()`
returns 0, and the job is completed as recovered — with the core never having
been reset. Latched error and DMA state survives into the next job on that core:
corrupt output, or no completion interrupt and a watchdog timeout per frame.

Reachable on this board, not merely in the abstract:

- `rkvdec-ccu@fdc30000` has `rockchip,ccu-mode = <1>` in the live device tree,
  and `RK_MPP_RKVDEC_CCU_MODE_SOFT` is `1` (`mpp_rewrite.c:98`). The soft-CCU
  path is the one in use.
- The sibling power-on at ~:11270 is on that soft path, despite the
  "HARD-CCU chain" wording in the comment at ~:3118, which describes the
  *other* caller (~:12242).
- Reset controls are per-core and distinct: `video-codec@fdc38000` takes
  `SRST_A_RKVDEC0`/`SRST_H_RKVDEC0` and `video-codec@fdc40000` takes
  `SRST_A_RKVDEC1`/`SRST_H_RKVDEC1`. So the only cross-core writer of a core's
  reset line is this sibling power-on path, and keying any serialisation on the
  CCU node is correct.

`power_off()` never asserts (~:11406), so the pulse is the only thing this can
corrupt.

## Boundary

Not observed executing. Everything above is read from source and the live DT;
no run has yet shown the overlap happening, which is exactly why the counter
landed first. Frequency is unknown and plausibly low — it needs a reset on one
core concurrent with a submit on a sibling in the same CCU group, and resets
only follow an error or timeout.

Says nothing about the encoder (rkvenc2 has its own CCU and was not analysed
for this), about hard-CCU mode, or about single-core configurations. Does not
establish that any observed decode corruption to date was caused by this; no
field failure has been attributed to it.

## Root cause

A core's reset line is a shared resource with two independent writers and no
serialisation between them. The driver treats "deassert" as an idempotent
part of powering a block up, which is true in isolation but false while a peer
is mid-pulse.

## Fix

Not yet implemented. Proposed: a per-reset-domain mutex — the domain being a
CCU group — taken as an **innermost leaf** around reset-control operations only:

- `rk_mpp_hw_reset_active()`: lock → assert → udelay → deassert → unlock.
- `rk_mpp_hw_power_on()`: lock → deassert → unlock, around the deassert alone,
  not around `pm_runtime_resume_and_get()` or `clk_bulk_prepare_enable()`.

Deadlock-free by construction: both critical sections touch nothing but the
reset controller and take no further locks. A concurrent `power_on` then lands
either wholly before the pulse (which re-asserts afterwards) or wholly after it
(a redundant deassert of an already-deasserted line). Both are correct.

All callers are sleepable — threaded IRQ handlers, work items, ioctl paths; no
hardirq caller exists — so a `struct mutex` is viable, and `udelay(10)` under it
is what the code already does under `run_lock`.

Scope the lock to cores with a CCU group (`hw->ccu_node != NULL`). A core with
no group has no second writer, and `power_on()` is on the per-submit path, so a
single global reset mutex would add contention across encoder, decoder and AV1
for no benefit.

Implementation shape:

1. `struct rk_mpp_hw` gains `struct mutex reset_domain_lock_self` plus a
   `struct mutex *reset_domain_lock` pointing at the domain's shared lock, or at
   its own when there is no group.
2. Resolve the pointer at CCU attach, which already handles probe ordering with
   `-EPROBE_DEFER`.
3. Route both sites through small helpers so no call site open-codes the
   pairing. Keep `handle_reset_failure()` outside the lock — it takes
   `srv->hw_lock` and must not nest under a leaf.
4. Optional, separately reviewable: make `power_on()` skip the deassert when it
   did not perform the 0 → 1 transition. That removes a pointless MMIO write per
   submit and shrinks the window independently, but it is a behaviour change on
   the sibling path and belongs in its own commit so it can be reverted alone.

## Verification gate

Ordered, because a passing functional test after a timing fix proves nothing on
its own:

1. **Reachability, before any behaviour change.** `sudo EXPECT=contended bash
   kernel-drivers/tests/rewrite-reset-contention.sh` must show a non-zero
   `mpp:reset_deassert_contended_count` delta on a kernel carrying d9992e32dc17.
   If it stays zero, the fix is not yet justified and the frequency claim above
   is wrong — raise `RESET_LOOPS`/`RESET_SURVIVORS` first, then re-examine
   whether the window is reachable at all in this configuration.
2. **Regression, after the lock.** `sudo EXPECT=clean bash
   kernel-drivers/tests/rewrite-reset-contention.sh` on the same workload that
   produced step 1's non-zero delta. Meaningless without step 1.
3. **No perturbation.** `mpp-suite.sh` plus the encode/decode/transcode tests on
   the KASAN kernel, watching decoder `hw_total_ns`/`hw_max_ns` — a leaf lock on
   the submit path should not move them measurably. If it does, the domain
   scoping is wrong.

## Why it matters / follow-up

The failure mode is the bad kind: recovery reports success while leaving the
core unrecovered, so the damage surfaces later as corrupt output or a stalled
core with nothing in the log tying it back. It also undermines every other
recovery path, since they all funnel through `rk_mpp_hw_stop_active()`.

Sequence after the current kernel is validated; this touches the reset path
recovery depends on and should land on a known-good baseline with step 1's
evidence in hand.
