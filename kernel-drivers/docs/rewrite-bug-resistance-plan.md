# Rewrite-driver bug-resistance plan (defense-in-depth beyond ownership)

> Status: proposed plan; first steps landed as recorded in the Current
> boundary below
> Scope: `mpp-rewrite` / `rga-rewrite` sources and this repository's build,
> source-audit, and test tooling
> Source reviewed: `rk3588-rewrite-6.18@d9cbcf21cda1c047c053447a48a908dcb6e4c5d6`
> and `rk3588-rewrite-mainline@b6335efd8f98bedabf426a80d224f85a266c8ea4`
> Pairs with:
> [ownership refactor plan](rewrite-ownership-refactor-plan.md),
> [validation plan](rewrite-validation-plan.md),
> [2026-08-02 adversarial review](rewrite-driver-adversarial-review-2026-08-02.md),
> [retrospective](../../findings/2026-08-01-rewrite-driver-retrospective.md)
> Date: 2026-08-25

> **Current boundary (2026-08-25):** proposal plus first landed steps.
> Maintained tips have moved past the review pins to
> `rk3588-rewrite-6.18@9030386c8bcca6d2970c0886ec3f1b3dd8dca36b` /
> `rk3588-rewrite-mainline@a7a308ab63454108ca8c6f4987580c73af71543e`
> (driver sources remain byte-identical across both trees); no package or
> boot contains any of this work, and Phase 6 file motion plus the exact-tip
> boot checkpoint remain open under [status track 4](../../status.md).
> Landed so far, each validated at source/tooling level only:
> **W5 items 1 and 2–4** — build-gate `memory` profile mirrors the board
> kernel's `DEBUG_OBJECTS` family and debug-kernel.md documents it (compile
> evidence deferred), plus §9 now documents KFENCE (soak kernel C only),
> stale-memory hardening (`INIT_ON_FREE_DEFAULT_ON` as the remaining
> candidate), and the perf-comparability rule (compile evidence deferred);
> **W2 part 2** — the writer-inventory gate
> ([`../tests/rewrite-writer-inventory.py`](../tests/rewrite-writer-inventory.py)
> with checked baseline) is wired into every audit mode of
> [`../tests/rewrite-build-gate.sh`](../tests/rewrite-build-gate.sh), with a
> device-free `--self-test`; **W2 parts 1 and 3** — the four owning-module
> Coccinelle rules under [`../tests/coccinelle/`](../tests/coccinelle/) plus
> the graceful [`rewrite-coccinelle-gate.sh`](../tests/rewrite-coccinelle-gate.sh)
> and [`rewrite-sparse-gate.sh`](../tests/rewrite-sparse-gate.sh) lanes
> (both packaged `coccinelle`/`sparse` on this arm64 release; `smatch` pinned
> source build; all degrade to bootstrap notes when tools absent, `STRICT=1`
> for CI);
> **W3 steps 0–1** — seam inventory and scenario reconciliation are complete
> as analysis; see
> [the seams/arbitration finding](../../findings/2026-08-25-rewrite-hardware-sim-seams-and-arbitration-inventory.md);
> **W3 step 4 / W4 model** — the standalone MPP precedence checker
> ([`mpp-activation-precedence-checker.py`](../tests/mpp-activation-precedence-checker.py))
> and invariant-sweep model
> ([`rewrite-invariant-sweep.py`](../tests/rewrite-invariant-sweep.py))
> are landed as device-free Python self-tests (no kernel build).
> W1, W3 steps 2–3, the board parts of W4, and W6 remain unstarted and
> correctly sequenced behind Phase 6 motion, cluster authority, or board
> access.

## Result

The ownership refactor removes, at the pinned source tips (not yet booted),
the structural bug class: shared state with many equivalent writers. This
plan adds layers that catch what survives that refactor, each aimed at a
defect class this project has actually hit:

| Layer | Catches | Evidence it is needed |
|---|---|---|
| Type-carried invariants | a generation compared against the wrong owner's cookie; a reason value OR'd across families; post-seal image writes | generations are bare `u64` (`mpp_rewrite.c` activation/quarantine/register-lease/IRQ/fault fields); terminal reasons merge via `BIT(reason)` into plain `u32` masks; the RCB fix patched an image after "final" validation |
| Stronger mechanical guards | the next structural twin introduced by a future patch | round 3 found 11 defects of which 8 were missed twins; the ownership plan's source-audit rules remain text-shaped |
| Simulated hardware edge | IRQ/timeout/fault interleavings that only manifest on a board | soft-CCU wedge, USERPTR map-before-power fault, dispatch race were all board-only discoveries |
| Runtime self-verification | silent invariant violations during long runs | quarantine exists because stop proof can silently fail; no on-board check re-verifies retained resources |
| Sanitizer/config additions | watchdog/delayed-work double-init and soak-latent stale-memory classes | the watchdog-target and RGA fault-lifetime follow-up classes; the board debug kernel already carries `DEBUG_OBJECTS`, but the build-gate `memory` profile and its documentation do not |
| Fuzzing escalation | cross-call lifetime races single-ioctl mutation cannot reach | validation-plan §5 fuzzers have never run under KCOV/KASAN |

**Priority boundary:** status track 4 owns the order of record — boot and
qualify the exact boundary-hardening tips before further architecture or
tooling changes. This plan does insert workstreams into the post-checkpoint
order (see [Sequencing](#sequencing)); each insertion is named there instead
of being claimed as neutral.

## Non-goals

- No new abstraction layer over the owners, no Rust, no ABI-visible behavior
  change. Two deliberate, disclosed exceptions: W4's debug-build-only
  stalled-transition escalation changes a user-visible failure mode on debug
  kernels, and W4's pattern-integrity check adds one fail-closed condition to
  reclaim-after-proof release. Neither touches production admission or
  completion semantics on non-debug builds.
- No quarantine-policy relaxation; W4 only adds evidence requirements.
- No claim transfers from source evidence to booted evidence anywhere in this
  plan; each workstream names its own gate class.
- Source changes remain byte-identical across both maintained kernel lines,
  replayed by the existing mechanical workflow (`cmp -s` identity check in
  [`../tests/rewrite-build-gate.sh`](../tests/rewrite-build-gate.sh)).
- Fuzzer grammar stays in the private `rock-5b-security` repository; refer to
  it by name, without links, per CONTRIBUTING.

## W1 — Type-carried invariants (source-only)

1. **Opaque generation handles.** Wrap every owner's cookie in a distinct
   single-member struct (`rk_mpp_activation_gen`, `rk_reset_epoch`,
   `rk_register_lease_gen`, `rk_rga_exec_gen`, …) with typed
   compare/increment/clone/move helpers. Cross-owner comparisons become
   compile errors; same-owner semantics stay identical. Same size and
   alignment; these are internal cookies with no wire or ABI shape. A
   hostile-use scan at review time found no array indexing, division, shifts,
   truncation, or serialization of generation values — only increments,
   overflow-skip logic, and literals such as `U64_MAX`, all absorbable by the
   typed helpers.
2. **Typed reason values and masks.** Terminal reasons, trigger reasons, and
   reset effects become distinct types, and the `BIT(reason)` merge sites gain
   a distinct mask type with typed set/test/clear helpers. Plain `__bitwise`
   enums alone do NOT reach the mask merges — the helpers rewrite every
   `BIT(reason)` site, which is what makes cross-family OR a type error.
3. **Builder/sealed split as distinct types.** Submission receives a sealed
   type it cannot obtain from a builder; RGA emitters receive
   `rk_rga_task_plan`, not a request. The Phase 5 seal already exists
   (`rk_mpp_reg_builder_seal` publishes via `smp_store_release`; consumers
   take `const struct rk_mpp_reg_image *` and non-sealed acquisition fails
   closed), so this deepens an existing boundary rather than creating one.
4. **Sparse lock annotations** (`__must_hold`, `__acquires/__releases`) on
   owner methods, encoding the lock table from the ownership plan beside the
   methods it constrains.

Order note: run W1 *after* Phase 6 file motion and the MPP cluster-authority
work, matching the ownership plan's recommended order. Retyping touches
nearly every generation-bearing line; inserting it before the motion would
put a large semantic diff inside the motion's before/after window and defeat
the pure-motion verification strategy. If operational pressure ever pulls W1
ahead of a later qualification campaign, budget a fresh exact-tip checkpoint
between W1 and that campaign rather than inheriting older boot evidence.

Gate: all eight warning-fatal profiles (four per kernel line) plus the
test-disabled ABI-mutation gate pass on both lines; object sizes recorded
before/after (type wrappers must not change layout); KUnit manifest unchanged;
a direct `make C=1` sparse pass reports zero new type errors until the W2
triaged lane exists to take over that duty.

## W2 — Mechanical guard upgrade (repository tooling)

1. **One owner for the source-audit rules.** This workstream is the
   implementation vehicle for the ownership plan section "source-audit rules
   worth making mechanical" — all of it, not a subset: Coccinelle semantic
   patches for the call-graph rules (reset-success reaching re-admission
   without refresh/isolation proof, writes through sealed images, START/
   doorbell MMIO outside `publish_and_start()`, emitters accepting raw
   requests), and the existing text audit continues as the fast path for the
   syntactic rules. One allowlist lives behind one gate; the ownership plan's
   list gains a disposition column here rather than a second mechanism.
2. **Inventory-diff gate — landed 2026-08-25.**
   [`../tests/rewrite-writer-inventory.py`](../tests/rewrite-writer-inventory.py)
   inventories slot-reference mentions, terminal-state writers (RGA scoped to
   execution-lifecycle function names), generation-cookie writers including
   the `_seq` allocator and AV1 AFBC cookies, dispatch-lease writes,
   reset-control API calls, and `publish_and_start` call sites against a
   checked, head-pinned baseline wired into every build-gate audit mode.
   Doorbell MMIO stays guarded by the ownership audit's
   `start-doorbell-write` allowlist rather than a duplicate rule here. The
   inventory audits production text only, using the same
   `IS_ENABLED(CONFIG_…)` marker discipline as the ownership audit, so test
   translation units are judged by their own rules. Per-commit history
   replay remains future work; today's gate compares working trees against
   the committed baseline.
3. **Static-analysis lane** added to
   [`../tests/rewrite-build-gate.sh`](../tests/rewrite-build-gate.sh) as a
   separate triaged profile: sparse and coccinelle are available from Ubuntu
   apt on this arm64 host; **smatch is not packaged** and requires a source
   build at a pinned upstream commit (it bundles its own sparse copy), so the
   lane starts sparse+coccinelle and adopts smatch only once that build is
   scripted and replayable. Findings move into a fatal allowlist as they are
   dispositioned, exactly like the existing warning-fatal policy.

Negative-test gate: deliberately reintroducing one violation in a scratch
copy of the driver must fail the corresponding rule (the same self-testing
pattern as the deliberate ABI-mutation gate).

## W3 — Simulated hardware edge in isolated-lifecycle KUnit

0. **Seam inventory — complete 2026-08-25** (analysis; see
   [the seams/arbitration finding](../../findings/2026-08-25-rewrite-hardware-sim-seams-and-arbitration-inventory.md)):
   - **MPP already has the seam**: backends dispatch through
     `struct rk_mpp_backend_ops { validate, submit, irq, thread,
     quiesce_aux_irqs }` and the primary handler forwards to
     `ops->irq()`, so a test-supplied ops struct delivers synthetic status
     through the production claim path with no new production fields; the
     reset domain already substitutes `rk_mpp_kunit_reset_ops`. The generic
     IRQ prelude, AFBC aux handler, watchdog timers, and IOMMU-fault
     callbacks stay outside backend ops and must be driven through existing
     knobs.
   - **RGA has no seam**: MMIO runs through two `static inline` helpers (42
     regex matches including definitions; one translation unit) with a single
     threaded-IRQ registration and no ops indirection on the IRQ/MMIO path.
     Introducing substitutability is an explicit, separately gated production
     change; the alternative must meet the same review bar. The decision
     stays open until RGA scenario work is scheduled.
1. **Scenario reconciliation — complete 2026-08-25**: MPP's
   `rk_mpp_activation_reason_arbitration_kunit` already exhausts every
   ordered pair of all ten transition reasons at the policy level, so a
   hand-enumerated pairwise trigger checklist is NOT new coverage for MPP —
   it is subsumed. The genuine MPP gap is delivery-level interleaving through
   trigger adapters, which the direct `note_reason()`/`arbitrate()` calls
   never exercise. RGA has no arbitration policy surface at all (no
   `note_reason`/`arbitrate`); mapping where its retirement precedence lives
   precedes any ported case, so nothing is double-booked into the manifest.
2. **Deterministic scenario set** (to build): adapter-level delivery for
   immediate completion after doorbell, spurious/stormy DONE, stuck BUSY,
   delayed stale-generation events, and error bits, over both MPP activations
   and — once its seam decision exists — RGA task executions.
3. **Seeded randomized interleavings.** A seeded PRNG schedules trigger
   arrival over the simulated engine; fixed seeds keep failures reproducible.
4. **Precedence property test.** The MPP policy table is already exhaustively
   pair-tested in-source; extract that same table once into a standalone
   exhaustive checker mirrored by a named KUnit case so it becomes a verified
   artifact independent of the embedded suite.

Placement constraints: these are lifecycle-layer cases, so they live behind
the isolated-lifecycle Kconfig symbols (default n), not the device-free
parsing layer. The simulator avoids real workqueues and timers wherever the
scenario permits — completion-callback invocation directly — because every
new stack async owner fails the fixture-debt audit today; where a timer-backed
scenario genuinely earns its place, the audit baseline gains an explicit
capped allowance documented in
[`rewrite-kunit.md`](rewrite-kunit.md) in the same series.

Timing: land before the booted fault-injection/recovery matrix (validation
plan §4, status track 4's wider gates), so hardware surprises during that
campaign get deterministic device-free reproductions. It cannot precede the
first exact-tip boots; those stay first per track 4.

Gate: every scenario deterministic, named in
[`rewrite-kunit-manifest.tsv`](../tests/rewrite-kunit-manifest.tsv), green
under the lifecycle configuration on both lines; precedence checker exhaustive
over the documented trigger set; net manifest delta accounts for every
replaced case.

## W4 — Board-runtime self-verification

1. **debugfs invariant sweep.** One command samples the owner graph and
   reports one of three verdicts per subsystem: **clean**, **violated**, or
   **skipped-inconclusive**. It uses trylock discipline only, never holds a
   run/coordinator lock while dumping, and treats raw-spinlock-protected
   state (aux/regs) as atomic snapshots rather than walking under them. A
   wedged RETIRING path holding locks therefore yields skipped-inconclusive,
   not a hung gate — and W4.3 exists to escalate precisely that condition.
   Checks when sampling succeeds: active slot entries RUNNING/PUBLISHED with
   armed deadlines, tombstones retaining claimed references, counter-sum
   balance, map/pin gauges against import references. Callable manually and
   required by
   [`../tests/rewrite-recovery-stress.sh`](../tests/rewrite-recovery-stress.sh)
   after every injected-fault iteration, accepting clean-or-skipped and
   failing on violated.
2. **Quarantine residual-write detector (scoped down from "poison-and-prove").
  ** Only driver-private coherent allocations participate — concretely the
   RGA command buffer; imported dma-buf frames are exporter-owned shared
   memory and are excluded unconditionally, and MPP quarantines retain
   exporter-owned attachments rather than driver-owned DMA staging, so MPP
   has no legitimate poison target today. After quarantine transfer owns the
   buffer, fill it with a pattern; a later mismatch is positive evidence of a
   device write and escalates to stronger quarantine plus diagnostics. An
   intact pattern proves only that nothing wrote — a wedged engine that still
   *reads* the buffer stays undetected — so intactness NEVER authorizes
   release; the existing stop/reset/isolation proof remains the sole release
   criterion. Coherent memory makes the pattern immediately visible to both
   sides without cache-maintenance ambiguity.
3. **Stalled-transition escalation.** In debug builds, an activation or task
   execution remaining RETIRING beyond a generous bound raises a diagnostic
   dump and moves to quarantine-with-evidence instead of hanging silently.
4. **Counter deliverables are kernel changes.** Any gauge the sweep needs
   that does not exist today (completed-unpolled jobs, map/pin-to-import
   equality) is an explicit deliverable of this workstream, implemented
   under the normal byte-identical dual-line replay discipline — not assumed
   to exist.

Gate: recovery-stress runs record sweep verdicts per iteration; an injected
residual-write failpoint produces escalation and a counter delta, never a
release; a stalled-engine injection produces the dump and quarantine path on
a booted debug kernel.

## W5 — Sanitizer/config additions (configuration only)

1. **Close the `DEBUG_OBJECTS` documentation/profile gap.** The board debug
   kernel already selects `DEBUG_OBJECTS` (+TIMERS/+WORK/+FREE/+RCU_HEAD) in
   its instrumentation fragment; the gap is that
   [`debug-kernel.md`](debug-kernel.md)'s option tables omit the family and
   the build-gate `memory` profile does not mirror it. Add both, and verify
   coexistence with the gate profile's KASAN settings at the next memory-
   profile build (no conflict is known; the board kernel has effectively
   co-shipped them already).
2. **KFENCE in the production kernel C** only — debug-kernel.md documents why
   it stays off beside KASAN. Low-overhead UAF tripwire during soak, with the
   honest caveat that its sampled pool gives low detection probability per
   fault; it supplements, not replaces, dedicated sanitizer passes.
3. **Soak-config stale-memory options.** Verify the current flavor config
   first: at review time the 6.18 worktree config already had
   `INIT_ON_ALLOC_DEFAULT_ON=y` and hardened usercopy enabled, leaving
   `INIT_ON_FREE_DEFAULT_ON` as the actual candidate. Enable what is missing
   after confirming the flavor's effective provenance.
4. **Perf comparability rule.** If soak and performance share kernel C, any
   init-on-* option added for soak requires re-measured paired forward-port
   baselines under identical options, or soak and perf split into separate
   kernels. The forward-port perf-ratio gate is meaningless across differing
   hardening options.

Gate: all build-gate profiles remain warning-fatal green; the next booted
Kernel A and kernel C runs record the changed configs beside their results.

## W6 — Fuzzing escalation (board work, private-repo coordination)

1. **Stateful syzkaller sequences** over import/config/submit/cancel/close
   lifetimes with resource modeling, including the compat ioctl grammar MPP
   routes through the same handler. Grammar lives in `rock-5b-security`;
   seeds come from ftrace/strace captures of conformance runs per validation
   plan §5.
2. **Differential fuzzing.** Feed mutated-but-valid inputs to forward-port
   and rewrite kernels under identical assets; compare errno class and output
   hash. Attribution discipline: a forward-port failure on input the rewrite
   rejects cleanly is a forward-port finding, not a rewrite regression, and
   vice versa; divergences land as findings either way.

Depends on the validation plan §5 safety prerequisites: sacrificial board,
IOMMU containment on, serial console, ramoops, netboot recovery.

Gate: syzkaller runs under KCOV+KASAN with coverage of the recovery lines
improving over the P2 gcov baseline; differential corpus recorded with
per-input verdict tables on both kernels.

## Sequencing

```text
exact-tip checkpoint boots (status track 4, unchanged priority)
  └─ W5 config items ride those boots
W3 steps 0-1 (seam inventory + scenario reconciliation) — COMPLETE
   2026-08-25 as analysis; outcome recorded in the W3 section
W2 part 2 (writer-inventory gate) — LANDED 2026-08-25 in this repository,
   wired into every rewrite-build-gate.sh audit mode with a device-free
   --self-test
W2 parts 1+3 (Coccinelle rules + sparse/smatch lane) — LANDED 2026-08-25
   as checked-in .cocci under coccinelle/ plus graceful
   rewrite-coccinelle-gate.sh and rewrite-sparse-gate.sh (both degrade to
   bootstrap notes when tools absent, STRICT=1 for CI)
W3 step 4 / W4 model — LANDED 2026-08-25 as device-free Python
   self-tests: mpp-activation-precedence-checker.py and
   rewrite-invariant-sweep.py
W5 items 2–4 (KFENCE/soak/perf) — LANDED 2026-08-25 as §9 in
   debug-kernel.md (documentation + operator guidance; board build deferred)
[ownership plan queue, unchanged] Phase 6 file motion → cluster authority
W1 types             → after motion, per the ownership plan's order;
                        fresh exact-tip checkpoint required before any
                        qualification comparison that straddles it
W3 steps 2–3         → scenarios once their seam decision exists (MPP can
                        start without one; see the finding)
W4 board parts       → runtime gates need boards (self-test model landed)
W6 fuzzing           → last among board work; needs security-repo harnesses
```

Each workstream lands as independently bisectable commits replayed to both
kernel lines; repo-side tooling lands in this repository and passes
`bash scripts/check-repo.sh`.

## Definition of done

Scoped to what each workstream's gate actually establishes:

- Cross-generation misuse cannot compile (W1 gate: typed handles plus typed
  reason masks, sparse-clean).
- The ownership plan's mechanical source-audit rules are enforced by exactly
  one gate with one allowlist, and a deliberately reintroduced twin fails the
  build (W2 negative tests).
- The enumerated trigger-permutation set has deterministic device-free
  reproductions, with replaced legacy cases removed in the same commits
  (W3 manifest accounting). Documented DCHS and HARD-CCU sequences beyond
  that set remain board-matrix coverage, not simulator claims.
- Recovery-stress iterations record sweep verdicts, and quarantined
  driver-private coherent buffers carry an escalation-only residual-write
  detector whose intactness never releases resources (W4).
- Soak kernels surface stale-memory and double-init classes they previously
  could not, with perf comparability preserved against the forward port
  (W5 config records).
- The fuzzer explores whole lifetimes under KCOV+KASAN, and differential
  runs produce per-input verdict tables (W6).

Each property above is claimed only for the evidence class its workstream
gate defines.
