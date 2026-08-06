# Validation index — RGA/MPP driver testing (both tracks)

Router for “how are these drivers tested, what evidence class answers my
question, and where is the current verdict?” This page intentionally carries no
moving commit, package, case-count, result matrix, or gap ladder.

The forward-port and rewrite tracks share much of the harness, but they have
different qualification boundaries. Follow the concern map below instead of
inferring one track's state from the other.

## Source-of-truth map (don't re-derive these elsewhere)

| Concern | Maintained owner |
|---------|------------------|
| Current public verdict and one next proof | [`status.md` tracks 1, 2, and 4](../../status.md#dashboard) |
| Rewrite risk-ordered plan and definition of done | [`rewrite-validation-plan.md`](./rewrite-validation-plan.md) |
| Rewrite build/conformance commands and result interpretation | [`tests/rewrite-conformance.md`](../tests/rewrite-conformance.md) |
| Generic kernel install, recovery, smoke, safety, stress, and evidence ladder | [`kernel-validation-runbook.md`](./kernel-validation-runbook.md) |
| Forward-port capability/evidence basis | [`forward-port-status.md`](./forward-port-status.md) |
| Rewrite capability/evidence basis | [`rewrite-drivers.md`](./rewrite-drivers.md) |
| Exact KUnit case contract | [`rewrite-kunit-manifest.tsv`](../tests/rewrite-kunit-manifest.tsv) |
| Test tools and quick on-ramp | [`tests/README.md`](../tests/README.md) |
| AV1-specific rewrite boundary | [AV1 rewrite assessment](../av1/docs/av1-rewrite-assessment.md) |
| Fresh run evidence not yet promoted | [findings inbox](../../findings/README.md) |
| Private destructive and memory-safety harnesses | the sibling `rock-5b-security` repository, as scoped by [`CONTRIBUTING.md`](../../CONTRIBUTING.md#running-the-validation-gates-that-need-both-repositories) |

A dated audit is not a live owner. The
[2026-07-17 conformance-gap audit](./rewrite-conformance-gap-audit.md) is a
frozen inspection record; use it only for its pin-specific reasoning and the
origin of gates that were later incorporated into the plan and runbook.

## Comparative disposition

Use the forward-port as the production oracle until status track 4 records that
the rewrite definition of done has closed. The durable distinction is:

| Track | Role | Qualification question |
|-------|------|------------------------|
| Forward-port | BSP-derived implementation and current differential oracle | Does the exact maintained package retain its established ABI, media, safety, recovery, and integration boundaries? |
| Rewrite | Public-API-only reimplementation with explicit ownership and fail-closed goals | Does it match the oracle's observable outputs and survive the additional hostile lifetime, recovery, fuzz, soak, and performance gates? |

The [rewrite project](./rewrite-drivers.md) owns the architectural comparison.
The dashboard owns which evidence is current; this router does not copy either.

## Coverage matrix — what is proven, per track

Choose the evidence owner by proof class:

| Proof class | Operational owner | Result/evidence owner |
|-------------|-------------------|-----------------------|
| Source/config/build identity | [rewrite conformance build gate](../tests/rewrite-conformance.md#rewrite-clean-build-gate) | rewrite or forward-port project document; fresh run may remain a finding |
| Boot identity, rollback, smoke, and sanitizer gates | [kernel validation runbook](./kernel-validation-runbook.md) | track project document plus compact status boundary |
| Exact rewrite KUnit execution | [rewrite post-reboot preflight](../tests/rewrite-conformance.md#post-reboot-identity-and-ownership-preflight) | rewrite project document |
| ABI replay and consumer suites | [rewrite conformance runbook](../tests/rewrite-conformance.md) | track project document; artifact/log bundle remains external |
| Forward-port ↔ rewrite differential comparison | [suite comparators](../tests/rewrite-conformance.md#running-the-suites-and-comparators) | rewrite project document |
| Fault, close/reset/unbind, fuzz, and memory safety | public runbook plus the sibling private-security scope named above | project document records bounded result without importing private triggers |
| Soak and production performance | [kernel validation runbook](./kernel-validation-runbook.md#step-8-soak) and rewrite acceptance policy | project document and status only if the public boundary changes |

A lower proof class cannot substitute for a higher one. In particular,
device-free validation, compilation, or KUnit cannot establish correct
pixels/bitstreams, real IRQ/reset behavior, soak safety, or production
performance.

## Consolidated gap list

Current gaps are deliberately not restated here:

| Question | Where to look |
|----------|---------------|
| What single result advances each public track now? | [status next gates](../../status.md#next-gates) |
| What must the rewrite eventually prove? | [rewrite plan phases and §7 definition of done](./rewrite-validation-plan.md) |
| What does the maintained rewrite evidence already establish? | [rewrite project §6](./rewrite-drivers.md#6-status--citable-location) |
| What remains for forward-port release qualification? | [forward-port evidence owner](./forward-port-status.md) and status tracks 1–2 |
| What remains for rewrite AV1 specifically? | [AV1 rewrite assessment](../av1/docs/av1-rewrite-assessment.md) |
| Why do several current gates exist? | frozen [conformance-gap audit](./rewrite-conformance-gap-audit.md) |

## The consistent plan to fully test the rewrite

Start at [`rewrite-validation-plan.md`](./rewrite-validation-plan.md). It owns
the risk order, fault/fuzz scope, and ship/no-ship definition. Execute the
selected phase through [`tests/rewrite-conformance.md`](../tests/rewrite-conformance.md),
which delegates generic install/recovery/safety work to the
[kernel validation runbook](./kernel-validation-runbook.md) and identifies the
private-security prerequisites where needed.

Record one correlated run as one finding until its useful conclusion is
promoted. Update status only when the public verdict or its one next proof
changes.

## Test-harness cleanup backlog (organization)

The non-qualification harness-maintenance scope moved to
[rewrite validation plan §8](./rewrite-validation-plan.md#8-scoped-harness-maintenance-backlog).
It cannot satisfy or reorder the production gates.
