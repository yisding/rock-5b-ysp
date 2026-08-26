# Rewrite hardware-simulation seams and arbitration-case inventory

> Scope: `mpp-rewrite` / `rga-rewrite` interrupt/backend seams and terminal
> arbitration test coverage, as the input to workstream W3 steps 0–1 of the
> [bug-resistance plan](../kernel-drivers/docs/rewrite-bug-resistance-plan.md).
> Source: `rock-5b/kernel/linux-6.18-rkvenc` branch
> `rk3588-rewrite-6.18@9030386c8bcca6d2970c0886ec3f1b3dd8dca36b` and
> `rock-5b/kernel/linux` branch
> `rk3588-rewrite-mainline@a7a308ab63454108ca8c6f4987580c73af71543e`; tracked
> rewrite sources are byte-identical across the two trees at these heads.
> Date: 2026-08-25
> Trust: **CODE-INSPECTED**; no kernel was compiled or booted.

## Result

The two drivers present opposite starting points for device-free hardware-edge
simulation, and the MPP side already carries more arbitration coverage than the
plan assumed:

1. **MPP can host simulated engines today without new production fields.**
   Backends dispatch through `struct rk_mpp_backend_ops { validate, submit,
   irq, thread, quiesce_aux_irqs }`, and the single primary handler forwards
   to `hw->match->ops->irq(hw, &lease)` — so a test-supplied ops struct
   delivers synthetic status through the production claim path. Reset-domain
   testing already substitutes `rk_mpp_kunit_reset_ops` into
   `rk_mpp_reset_backend_ops`, establishing the fixture pattern. Outside ops
   remain the generic `rk_mpp_hw_irq` prelude, the AFBC aux handler, and the
   kernel timer/watchdog and IOMMU-fault-callback edges those handlers serve;
   scenarios must drive those edges through existing knobs (deadline arming,
   provider-hook invocation) rather than new seams.
2. **RGA has no substitutable seam at all.** MMIO funnels through two `static
   inline` helpers (`rk_rga_read`/`rk_rga_write`; 42 regex matches including
   the two definitions, i.e. 40 call sites) inside one translation unit, with
   one `devm_request_threaded_irq` registration and no ops indirection on the
   IRQ/MMIO delivery path (dma-fence and PM ops tables exist for framework
   contracts, not device I/O). Any simulated-edge scenario for RGA first needs
   an explicit, separately reviewed production seam (ops struct or equivalent)
   — there is no test-only shortcut.
3. **MPP reason arbitration is already exhaustively covered at the policy
   level.** `rk_mpp_activation_reason_arbitration_kunit` iterates every
   ordered pair of all ten `RK_MPP_TRANSITION_*` reasons in both directions
   and asserts order-independent results — strictly broader than any
   enumerated pairwise trigger-permutation checklist. What it does not
   exercise is
   *delivery*: the case calls `note_reason()`/`arbitrate()` directly, so
   adapter-level interleavings (IRQ vs timer vs fault callback racing the slot
   claim) remain the actual W3 scenario gap for MPP.
4. **RGA has no equivalent arbitration policy surface.** Neither
   `note_reason` nor `arbitrate` exists in the RGA source; its Phase 4
   retirement engine reaches decisions through a different shape. Porting the
   exhaustive-pair pattern to RGA first requires mapping where its retirement
   precedence actually lives; that mapping is part of the W3 scenario work,
   not a precondition this finding closes.

## Evidence anchors

| Fact | Anchor |
|---|---|
| Backend ops members | `mpp_rewrite.c:1326` (`struct rk_mpp_backend_ops`) |
| Primary IRQ forwards through ops | `mpp_rewrite.c:23296` (`hw->match->ops->irq(hw, &lease)`), registration `:24965` |
| Aux AFBC handler outside ops | `mpp_rewrite.c:24987` (`devm_request_irq(... rk_mpp_hw_aux_irq ...)`) |
| Reset-domain test substitution precedent | `mpp_rewrite.c:13686` (`rk_mpp_kunit_reset_ops`), wired at `:13811`, `:13894` |
| Exhaustive MPP pair arbitration | `rk_mpp_activation_reason_arbitration_kunit` (10×10 ordered pairs, forward/reverse equality) |
| RGA helper-only MMIO | `rga_rewrite.c:7115–7124` region (`rk_rga_read`/`rk_rga_write`), 42 regex matches including the two definitions |
| Single RGA IRQ registration | `rga_rewrite.c:27071` (`devm_request_threaded_irq(... rk_rga_irq_handler ...)`) |
| RGA lacks reason-arbitration API | zero hits for `note_reason`/`arbitrate` in `rga_rewrite.c` |

## Boundary

Source inspection only: no scenario has been built, and no statement here is
runtime evidence. The RGA seam decision (new ops indirection versus another
reviewable mechanism) remains open and belongs to the bug-resistance plan's
W3 step 0; this finding supplies the inventory that decision starts from.
