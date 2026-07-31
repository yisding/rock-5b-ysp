# Wedge-week retrospective: what would have caught each failure class before boot

> Scope: rewrite driver wedges, harness false-reds, and validator
> coverage losses across 2026-07-26 → 2026-07-30; prevention levers
> Source: [`soft-CCU wedge #1`](2026-07-29-rewrite-soft-ccu-dual-core-wedge.md),
> [`soft-CCU wedge #2 / group power`](2026-07-30-rewrite-soft-ccu-split-critical-section-h265-wedge.md),
> [`KUnit gate false-red`](2026-07-30-rewrite-kunit-gate-false-red-harness-defects.md),
> [`minimal-hard-IRQ plan`](../kernel-drivers/docs/rewrite-minimal-hard-irq-plan.md)
> Date: 2026-07-30
> Trust: MEASURED (failure inventory) + DESIGN (prevention levers; the
> adoption list at the end is proposed, not implemented)

## The four failure classes

1. **Silent interconnect wedges** — arm/start split (07-29), then the
   group-power/autosuspend race (07-30). Board-killing, zero trace,
   root-caused only through reboot-cycle discriminators.
2. **Harness false-red** — a fully green boot failed the KUnit gate on
   four defects of the gate itself (dash parser, dead `debug_locks`
   sysctl path, fatal-regex matching passing test names, stale
   manifest), plus the evidence audit's unsatisfiable `-g` binding.
3. **Silent validator death** — lockdep was dead after the first decode
   IRQ on every 6.18.40 debug boot (recursion report, then the
   wait-context report; each first report disables the validator and
   masks the next), unnoticed for days.
4. **Cross-tree drift** — the `eb78ceed` amend fixlets never replayed to
   mainline; the existing identity gate only runs inside the heavyweight
   build gate, so nothing noticed at commit time.

## What would have caught class 1 — and what could not have

Honesty first: the core mechanism (a write to a clock-gated register
file stalling the AXI fabric) is an *undocumented hardware semantic*.
No static analyzer, sanitizer, or lockdep variant models it; the gating
behavior itself is still INFERRED. The leverage was elsewhere:

- **Invariant extraction as a rewrite step.** The BSP's single taskqueue
  worker made "never touch a gated core" true for free; the rewrite
  dissolved that structure into fine-grained locks without ever writing
  the invariant down, so no review could check code against it. A
  reimplementation from a reference should enumerate everything the
  reference gets for free from its *shape* (serialization, ordering,
  power sequencing) and either keep the mechanism or state and enforce
  the invariant. Deliverable shape: a per-block **concurrency and power
  contract** ("MMIO to core X requires X powered, ungated, token T
  held"), sibling to the minimal-hard-IRQ plan.
- **Coarse first, refine with evidence.** Fine-grained locking preceded
  the first full conformance pass. A BSP-equivalent single ordered
  workqueue per coordinator would have been immune to this entire class;
  splitting it belonged *after* a green baseline, justified by numbers.
- **Fail-loud accessors.** A debug-build `rk_mpp_hw_write()` wrapper
  asserting the contract (power reference held, required lock held)
  turns "silent hang one write later" into a WARN at the violating
  site. Both wedge windows were assertable without knowing the gating
  semantics.
- **Adversarial timing.** The group-power race lived in a 200 ms
  autosuspend window. A stress profile forcing autosuspend delay to ~0
  would have made it near-deterministic — found in an afternoon, not
  three days. Same philosophy as KASAN: widen the window until the bug
  cannot hide.
- **Sequence coverage.** All three wedges were order-dependent; the
  suite runs one fixed order. A case-pair matrix plus a
  session-lifecycle fuzzer (random open/submit/close across codecs with
  randomized 0–500 ms idle gaps — the gap dimension being exactly the
  autosuspend window) reaches these systematically. The ioctl fuzzer
  covers the syscall surface, not lifecycle timing.

## What would have caught class 2

One unifying cause: **fixtures modeled the author's assumptions instead
of captured reality** (KTAP-spec dash form; a bare-`0/1` lockdep file no
kernel produces). Standing policy: every format a gate parses gets at
least one **golden fixture generated from a real boot's artifacts**,
refreshed on kernel moves; the 07-01 journal replay that verified the
fixed gate is exactly what should persist as a selftest input. The stale
manifest and the half-done `uname -v` migration were paired-change
atomicity failures with an *existing* but unwired check — the
enforcement belongs in the kernel-commit ritual (pre-push hook running
`check_kunit_manifest` and `check_cross_tree_identity`), not only inside
the full build gate.

## What would have caught class 3

Treat **validator health as a gated signal, continuously**. Lockdep
reports once and turns itself off, so its absence is silent by design;
the coverage the KASAN/lockdep kernel exists for was gone after the
first decode IRQ on every boot for days. Remedies: assert
`debug_locks == 1` (and kmemleak health) in every suite **postflight**,
not only the boot-time KUnit gate — a report firing between suites or
before the dmesg baseline is invisible today; give every profile a
boot-interval fatal scan (the forward-port profile has none — verified
2026-07-30, its artifacts contain no lockdep-kill markers, which is
*probably* genuine health but currently indistinguishable from a
missing gate). Also: a `diffconfig` against the previous build,
persisted in evidence, so checking-behavior changes arriving with base
bumps are a reviewable line item instead of archaeology.

## What already worked — keep deliberately

Per-case `sync` + `PROGRESS` markers (every wedge localized to the exact
case), `RuntimeWatchdogSec=60s` (self-recovering board), the
discriminator method (solo/pair/single-core runs falsified two wrong
hypotheses cheaply), and findings trust-tag discipline (MEASURED vs
INFERRED kept the gating model honest through two revisions).

## Adoption shortlist (proposed, none implemented yet)

| # | Item | Class | Effort |
|---|------|-------|--------|
| 1 | Debug-build contract assertions in MMIO accessors (power ref + lock) | 1 | small driver series |
| 2 | Autosuspend≈0 stress profile + session-lifecycle/pair-sequence harness mode | 1 | harness + one boot knob |
| 3 | Golden fixtures from captured artifacts for every gate parser (policy + backfill) | 2 | small, incremental |
| 4 | Validator-health postflight in all suites + boot-interval scan for all profiles | 3 | harness only |
| 5 | Commit-ritual hooks: manifest sync, cross-tree identity, config diff | 2/4 | scripts exist, wire-up only |

Items 1–2 would likely have converted this week's three board-killing
wedges into same-day WARNs or deterministic repros; 3–5 would have
prevented essentially every harness and coverage failure in the
inventory.

## Adoption status (2026-07-30, same day)

- **Item 4 — done.** `suite-common.sh` reads `debug_locks` from
  `/proc/lockdep_stats` in every suite postflight and fails with
  `status=lockdep-disabled`; six selftest cases in
  `suite-common-selftest.sh`.
- **Item 2 — done.** `pm-stress-knobs.sh` (autosuspend→0, `PM_STRESS=1`
  in the runner with an EXIT-trap restore) and
  `rewrite-case-pair-matrix.sh` (30 ordered decode pairs, `sync`-per-pair
  so a wedge-reboot names the killer ordering); both self-validate.
- **Item 5 (cheap) — done.** `kunit-manifest-check.sh` + the
  `install-kernel-hooks.sh` pre-commit guard (installed into the shared
  kernel git dir; end-to-end tested), and `build-kernel.sh` config-delta
  history/printing. The guard proved itself immediately: the concurrent
  AV1 session's 89→90 KUnit-case bump landed paired with the manifest.
- **Item 1 — done.** MMIO power-contract assertions
  (`rk_mpp_hw_assert_powered`, debug-only `WARN_ONCE` on
  `power_count <= 0`) at the six soft-CCU/decode write sites, plus the
  two KUnit fixtures made assertion-safe. Committed 6.18
  `06ab78b696157`, cherry-picked mainline `8e163b3920237`
  (driver file byte-identical across both tips); compile-verified on
  6.18. Boot boundary to watch (per the patch notes): the assert is
  per-block, not whole-mask, and `reset_soft_ccu_job` is the one
  recovery-path site whose live power state to confirm on the first
  KASAN boot.
- **Item 3 — deferred** (fixture wins already banked when the gate
  parsers were fixed; standing golden-fixture policy is the remaining
  bit).
