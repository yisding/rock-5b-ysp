# Rewrite Phases 4 and 5 complete task-execution ownership and sealed emission

> Scope: Clean-room `mpp-rewrite` and `rga-rewrite` drivers; status track 4
> Source: `rk3588-rewrite-6.18@149a9ecd38f78daec7a2c6f8c6010e55ea8ad252`; `rk3588-rewrite-mainline@280181e634a3a10a3a4f1659fe7c7287f7ee3760`; `mpp_rewrite.c` builder/backend publication paths and `rga_rewrite.c` task-execution/orchestrator/emitter paths
> Date: 2026-08-11
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, FIX-COMPILE-VERIFIED, PARTIAL

## Result

Ownership-refactor Phases 4 and 5 are source-complete on both maintained
kernel lines. The tracked rewrite sources are byte-identical between them.

RGA now represents each hardware task lifetime as an `rk_rga_task_exec` with
its own selected core, typed generation references, execution mappings, RGA2
MMU tables, command allocation, USERPTR ownership, timing, IRQ observations,
and retirement state. Hardware active, IRQ, timeout, and queued IOMMU-fault
edges retain `{exec, generation}` references. One retirement engine either
proves DMA stopped and drains copyback/mappings/commands/power through
`RETIRED` to `RECLAIMABLE`, or restores the exact reference as a resource-
retaining quarantine tombstone. Only the job orchestrator advances
`current_task`, publishes the final result, signals the release fence, or
selects same-task fallback.

MPP now builds an open private register image, clones readback destinations,
and publishes `SEALED` with release/acquire ordering before backend validation
or dispatch. Backend validate/submit interfaces accept only a const image.
Runtime-only DCHS allocation is an activation resource overlay rather than a
post-seal command mutation, and IRQ/readback data is stored in the separate
result object. RKVENC, direct/soft/hard RKVDEC, AV1, RGA2, and RGA3 START paths
are owner-specific publication operations that verify the sealed plan/image,
arm the exact watchdog generation, order command/register writes, and issue
the doorbell last.

All implemented RGA semantic families now emit from an immutable
`rk_rga_task_plan`; production emitters neither accept `struct rga_req` nor
read `job->tasks`. The existing independently specified command goldens remain
the oracle, and the resize/scale golden now additionally mutates the raw
request after plan publication and proves the second command image is
unchanged. `rk_mpp_reg_builder_seal_kunit` proves result cloning and rejection
of post-seal growth. The exact named manifest is 109 MPP plus 152 RGA cases,
261 total.

The ownership audit now hard-guards the builder/seal sequence, const backend
interfaces, task plan publication, retirement ordering, RGA typed active/IRQ/
timeout owners, sole task-advance owner, mapping/command teardown owners, and
watchdog-before-doorbell ordering. It passes at 2,312 signals per tree; the
KUnit fixture-debt audit passes at 306 signals per tree. The exact source
SHA-256 values are `45a8de124ec94b28f85fd117658e560b5c9bee096a7f610bbd04b59a1b97cade`
for MPP and `0003a3912d2fabf0b9f3292b49f35171c78db16f1cb6407b784a4aee8ab2ae2d`
for RGA.

## Evidence and reproduction

- `python3 kernel-drivers/tests/rewrite-ownership-source-audit.py <6.18> <mainline>`:
  2,312 ownership signals/tree, zero new, zero absent.
- `python3 kernel-drivers/tests/rewrite-kunit-source-audit.py <6.18> <mainline>`:
  306 fixture signals/tree, zero new, zero absent.
- `bash kernel-drivers/tests/kunit-manifest-check.sh <tree>`: exact manifest on
  both trees.
- Focused arm64 `W=1` builds of both rewrite objects pass with the central
  ccache store. The clean-archive `normal`, `test-disabled`, `memory`, and
  `race` profiles pass warning-fatally on both kernel lines; the dedicated
  test-disabled gate also proves the deliberate MPP ABI mutation fails at
  compile time on both.
- Strict checkpatch over the combined source delta reports zero errors and zero
  warnings; 76 strict style checks remain, principally continuation layout.

## Boundary and next gate

This is source and compile evidence, not a hardware verdict. Neither committed
tip has been packaged, booted, or run through KUnit. It does not close RGA2
large-segment staging, compressed-layout pixel correctness, real immediate-IRQ
timing, delayed old-generation IRQ/timeout/fault delivery, forced quarantine,
KASAN/KCSAN/lockdep runtime stress, media conformance, performance, or soak.

Build, package, install, and boot the exact tips; require all 261 KUnit cases
with a fatal-free lockdep interval, then run the Phase 4 terminal/failpoint/
fallback/copyback matrix and the Phase 5 byte-exact MPP/RGA artifact
differential before making a runtime-complete claim.
