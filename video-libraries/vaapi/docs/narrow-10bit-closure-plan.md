# Plan: close the narrow AFBC 10-bit gap — per-core imcheck honesty + linear-NV15 narrow path

> **Frozen successor stub.** The 2026-07-29 plan combined two independent
> workstreams. Workstream B was declined on 2026-08-04: visible 10-bit widths
> below 68 remain permanently unsupported by `rockchip-vaapi`. Workstream A
> remains useful but is owned by librga's
> [detailed implementation plan](../../../vendor-libraries/rga/docs/imcheck-per-core-implementation.md).
> This file retains the original headings so old links keep resolving; it is
> not a live execution plan.

The original source basis was librga fork `26a50ef`, rockchip-vaapi
`3f1aaa0`, and the paired RGA kernel policy described by
[`source-trees.md`](../../../docs/source-trees.md). Those immutable pins explain
the decision; they do not claim current branch or package state.

## Non-goals

- Do not relax the vendor-published 68-pixel RGA3 range.
- Do not invent AFBC padding or a software AFBC decoder for one synthetic case.
- Do not create a second public librga API or wrapper library.
- Do not turn the declined VA-API path back into backlog without a named real
  workload and a new decision.

## Workstream A — librga per-core imcheck honesty

**Disposition: routed, still valid.** The problem and implementation belong to
librga, not to the VA-API driver's capability backlog.

### A.1 Design decision: fix in the fork, not a separate library

`imcheck` and `improcess` are already the choke points used by consumers.
Making their existing `IM_STATUS_NOT_SUPPORTED` answer reflect per-core
constraints requires no new public symbol or type. A side library would help
only clients rewritten to call it and would leave existing callers exposed to
accept-then-kernel-refusal behavior.

### A.2 Current state (why imcheck lies)

At the pinned source, librga retained per-core hardware versions but merged
format, feature, and size tables into one permissive union before checking a
job. Storage-mode support and RGA3's minimum active width were therefore not
evaluated as one per-core conjunction. A job could pass userspace validation
even though the kernel scheduler had no eligible core.

### A.3 Changes

The canonical
[per-core implementation plan](../../../vendor-libraries/rga/docs/imcheck-per-core-implementation.md)
owns the internal capability classes, matching algorithm, diagnostics, commit
shape, and source anchors. No VA-API-specific copy is maintained here.

### A.4 Tests and acceptance

The librga plan owns descriptor-only boundary cases, kernel-log negative
checks, regression suites, table-drift checks, ABI containment, and its
acceptance signal. VA-API consumes the honest answer but does not own that
test matrix.

### A.5 Risks

The lasting risks are capability-table drift and false rejection on unmeasured
SoCs. Keep unknown rows permissive, compare modeled limits with the paired
kernel, and preserve the existing public ABI.

## Workstream B — linear-NV15 narrow path in rockchip-vaapi

**Disposition: declined 2026-08-04.** The durable capability decision and
rationale live at
[Declined: narrow AFBC 10-bit below 68 pixels](../README.md#declined-narrow-afbc-10-bit-below-68-pixels).
The subsections below record what was considered, not work to schedule.

### B.1 Current state

The accepted driver policy requests AFBC V2 for 10-bit decode and rejects
visible widths below 68 before submission. MPP's AFBC NV15 output can be read
only by RGA3, whose active-width floor excludes that geometry. RGA2 can accept
narrower 10-bit raster but cannot read AFBC.

### B.2 Fallback ladder (target behavior)

The superseded target would have kept AFBC-to-RGA for widths at or above 68,
requested linear NV15 below 68, used RGA opportunistically if a core matched,
and otherwise repacked compact NV15 to P010 on the CPU. The CPU branch was the
guaranteed design anchor; none of these branches became capability policy.

### B.3 Phase 0 — retire the UNVERIFIED assumptions

Two unanswered spikes were identified: whether MPP would emit usable linear
NV15 for the narrow vector, and whether any RGA core would accept its measured
layout. Neither spike ran. The decision did not depend on disproving them.

### B.4 Implementation

The superseded design would have selected linear output at context creation,
carried raw byte stride through decode, and added a CPU compact-NV15-to-P010
bit relocation under DMA-BUF synchronization. No implementation should be
inferred from this description.

### B.5 Tests and acceptance

The superseded acceptance target was an exact 64-pixel Main10 decode with no
kernel `no core match` message, no regression at the 68-pixel boundary or
ordinary AFBC geometries, and unchanged sanitizer/throughput gates. It was
never an achieved result.

### B.6 Risks

MPP might reject linear NV15, a late failure would be less graceful than the
current up-front refusal, and new layout code would add maintenance for a
vanishingly narrow case. Those costs outweighed one synthetic conformance
vector and no identified real content.

## Sequencing

There is no Workstream B sequence. Applications software-decode the refused
geometry. Workstream A proceeds independently through the
[librga-owned plan](../../../vendor-libraries/rga/docs/imcheck-per-core-implementation.md).
Reconsidering B requires a new live plan, named workload, current source
inspection, and explicit capability-policy change.
