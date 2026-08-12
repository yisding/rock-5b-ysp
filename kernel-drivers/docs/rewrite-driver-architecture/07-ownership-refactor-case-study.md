# Chapter 7: the ownership refactor as a kernel-driver case study

[← Source reading and review](06-source-reading-and-review.md) ·
[Guide home](README.md)

This chapter explains the Phase 0–5 ownership refactor as one connected design
exercise: what was wrong with the old shape, what changed, why the order
mattered, and how a new kernel-driver developer should work in the resulting
code.

It is not a runtime status claim. Phases 4 and 5 are source- and
compile-complete at the pinned 2026-08-11 snapshots, but those exact tips still
need boot, runtime KUnit, sanitizer, recovery, media, differential-output,
performance, and soak qualification. The [rewrite status owner](../rewrite-drivers.md#6-status--citable-location)
and [validation plan](../rewrite-validation-plan.md) own that moving boundary.

## 14. The problem was duplicated ownership, not missing helper functions

The drivers already had many sound local practices: copied requests, retained
imports, refcounted hardware, active slots, generation checks, reset recovery,
and fail-closed isolation. The recurring defects appeared where one logical
job covered several different physical lifetimes.

Before the refactor:

- an MPP job was both the userspace transaction and the convenient home for
  resources belonging to one hardware attempt;
- an RGA job was both the whole multi-task request and the current task/core
  execution;
- IRQ, timeout, IOMMU fault, close, abort, remove, shutdown, retry, and fallback
  each knew part of the cleanup protocol;
- validation happened, but later code could still patch the representation
  that had been validated; and
- several important rules were conventions repeated at call sites rather than
  properties of a type or owner.

That shape produced “missed twin” defects. Fixing one completion tail or one
emitter did not prove that a sibling path followed the same rule. Examples that
motivated the work included reset paths that refreshed IOMMU state
inconsistently, RGA multi-task recovery that differed from IRQ completion,
post-validation register patching, and geometry normalization duplicated
between validators and emitters.

The refactor therefore used this rule:

> If several asynchronous paths must agree on a resource's final state, give
> that resource one owner and route every path through the owner's transition
> API.

It deliberately preserved the ABI, hardware backends, and accumulated tests.
This was not another clean-room rewrite.

## 15. What changed, phase by phase

| Phase | Structural change | Why it came at that point |
|-------|-------------------|---------------------------|
| 0 | Pinned both kernel lines; froze manifests, writer inventories, counters, and evidence classes. | A large lifetime migration needs a source-bound baseline and must not turn known red results into accidental green claims. |
| 1 | Put reset, active slots, dispatch leases, power/refresh/isolation, terminal writes, execution-map teardown, and START behind funnels and assertions without intentionally changing behavior. | A funnel first reveals every writer and creates one later migration point. |
| 2 | Made MPP reset-domain and cluster ownership real, added the member-core power lease, typed recovery results, and IRQ/register epoch leases. | An activation cannot own a run safely until shared hardware effects have stable authorities. |
| 3 | Made `rk_mpp_activation` the owner of one admitted MPP attempt, including retry, terminal arbitration, resource drain, quarantine, and reclaim. | MPP had the more complicated shared-CCU retry/recovery graph; proving the attempt model there established the hardest lifetime rules first. |
| 4 | Made `rk_rga_task_exec` the owner of one RGA task/core attempt, added typed async references, one retirement engine, a whole-job orchestrator, execution mappings, and `rk_rga_acquire_set`. | RGA needed the same attempt/job split, adapted to multi-task progression, fences, fallback, and copyback. |
| 5 | Sealed MPP register images, separated command/result storage, made RGA emitters consume immutable plans, and replaced temporary START funnels with owner-specific publication operations. | Validation can become one-way only after the object that owns the resulting image and runtime overlay is clear. |

### 15.1 Phase 0: freeze evidence before moving lifetimes

The baseline did more than record a commit hash. It separated evidence that is
easy to conflate:

- source identity and cross-kernel byte equality;
- warning-fatal builds under normal, test-disabled, memory, and race profiles;
- the exact named KUnit manifest;
- boot and runtime KUnit;
- normal consumer workloads and differential output;
- reset/fault/close/remove recovery; and
- sanitizer, performance, and soak results.

It also inventoried direct writers: reset controls, active slots, generations,
terminal states, outcomes, power fields, IOMMU recovery, task advancement,
mapping/command teardown, and doorbells. That inventory later became the
mechanical source audit.

The important lesson is that a known failure can be a baseline only when it is
bounded and attributed. Silent corruption, unexplained DMA faults, or an
unproved stop cannot be normalized into “expected red.” In this project the
operator explicitly allowed source-only work to proceed before the exact tips
were boot-qualified; the documentation kept that exception visible instead of
promoting compile evidence into a runtime claim.

### 15.2 Phase 1: create funnels before changing owners

Phase 1 wrapped existing behavior in singular APIs and added lock/ownership
assertions. The funnels covered:

- MPP reset-domain operations;
- MPP and RGA active-slot access;
- the RKVDEC session-dispatch lease;
- temporary `publish_and_start()` paths;
- MPP power and IOMMU refresh/isolation transitions;
- MPP outcome/terminal writers; and
- RGA execution-map retirement.

This is a useful refactoring technique in kernel code. Moving fields and
changing behavior in the same patch makes a regression difficult to classify.
A behavior-preserving funnel gives every current caller one destination, lets
lock assertions expose an invalid context, and gives review tooling a small
allowlist. The real owner can then replace the funnel's internals later.

### 15.3 Phase 2: shared MPP hardware became explicit authorities

MPP's decoder cores are not independent devices in every mode. A coordinator,
member cores, reset lines, and DMA/IOMMU relationships can participate in one
hard-CCU operation. Phase 2 introduced the objects needed to express those
facts:

- `rk_mpp_reset_domain` gained stable identity, members, serialized physical
  reset transactions, and monotonically recorded reset epochs;
- `rk_mpp_cluster` gained stable coordinator/member topology and became the
  funnel for CCU running lists, link ownership, arm, and START mechanics;
- `rk_mpp_cluster_power_lease` replaced a fixed powered-core array with one
  refcounted hold over the exact participating members;
- single-core and hard-CCU recovery began returning typed effects with
  separate `quiesced` and `reusable` decisions;
- hard-CCU recovery deduplicated the already pinned participants' DMA groups
  and refreshed each affected group once before reuse; and
- each START published a bounded register lease containing the live reset
  epoch and, for direct work, activation generation. Reset or final register
  power loss revokes the lease before MMIO becomes unsafe.

Two distinctions are especially transferable:

```text
quiesced  = the old operation is stopped enough to retire its resources
reusable  = the hardware and translations are safe for a new operation
```

Terminal isolation may prove the first while deliberately denying the second.
Likewise, a reset domain and a DMA group describe different physical
relationships; combining them merely because both participate in recovery
would encode a false topology.

### 15.4 Phase 3: an MPP job stopped pretending to be one attempt

MPP now distinguishes the logical job from each physical activation:

```text
job: userspace request, imports, sealed register image, result
  ├── first activation (embedded)
  └── retry activation(s) (separately allocated)
```

The migration was intentionally incremental:

1. Embed activation identity and move generation, absolute deadline, exact
   session-dispatch identity, and selected hardware into it.
2. Change active and timeout slots to name the exact activation.
3. Route every detach through one reasoned claim owner.
4. Allocate a distinct successor for hard-CCU retry instead of rewriting the
   predecessor in place.
5. Retain exact group/core closure evidence for the predecessor.
6. Give active, timeout, claim, retry, and quarantine owners typed
   `{activation, generation}` references. Each reference also retains the
   containing job and supports explicit get/clone/move/put operations.
7. Move attempt-bounded CCU/link/DCHS/power/timing resources into
   `rk_mpp_activation_resources` and transfer that complete record during
   retry.
8. Accumulate terminal reasons, choose the final result with stable priority,
   and let one completion tail drain resources, release selected-core/dispatch
   ownership, publish `DONE`, and attempt reclaim.

The resulting lifecycle is:

```text
UNINSTALLED -> SLOTTED -> CLAIMED -> RETIRED -> RECLAIMABLE
                      \-> QUARANTINED
SLOTTED -> SUPERSEDED -> RETIRED -> RECLAIMABLE
```

The states answer different questions. `CLAIMED` says one terminal contender
owns the slot reference. `RETIRED` says the attempt has acceptable clean or
recovered terminal evidence. `RECLAIMABLE` additionally says resources were
drained or handed off and every external owner is gone. `QUARANTINED` says
cleanup is unsafe, so the exact references and resources remain owned through
reboot.

Stable terminal arbitration matters because asynchronous arrival order is not
policy. An IRQ racing a fault or teardown must not produce a different public
result merely because one CPU acquired the lock first. Each reason records its
candidate result; one fixed priority chooses the outcome after the owner has
the relevant evidence.

### 15.5 Phase 4: one RGA job can contain several executions

RGA has a different reason to split job from execution. A multi-task request
runs tasks serially, and a selected-device failure can retry the same task on a
different hardware family. The logical job persists across both transitions.

`rk_rga_task_exec` now owns:

- task index, selected core, and monotonic generation;
- execution mappings plus direct/staged and copy-owner state;
- RGA2 internal-MMU tables;
- the coherent command allocation and immutable task plan;
- USERPTR device/CPU ownership and copyback duty;
- power and hardware timing;
- IRQ observations; and
- `UNINSTALLED`, `SLOTTED`, `CLAIMED`, `RETIRED`, `RECLAIMABLE`, or
  `QUARANTINED` state.

The hardware's active, IRQ, timeout, and queued IOMMU-fault edges all retain
typed `{exec, generation}` references paired with a job reference. The sole
retirement engine accepts the exact claim plus a DMA-stop verdict:

```text
DMA stopped
  -> CPU sync/copyback
  -> release mappings and RGA2 MMU
  -> free command allocation
  -> power off
  -> RETIRED -> RECLAIMABLE when refs drain

DMA stop not proved
  -> restore exact typed owner to active slot
  -> QUARANTINED
  -> retain mappings, command, power, and copyback obligations
```

The retirement engine does not advance the request or signal the fence. Only
the whole-job orchestrator may increment `current_task`, create the next-task
or same-task-fallback successor, publish the aggregate result, and signal the
release fence. That split prevents IRQ and recovery from growing subtly
different multi-task tails.

Acquire fences received their own `rk_rga_acquire_set`. The set contains the
waiters, sentinel count, cancellation ownership, work item, result, and owning
job. Callback and cancel contend for each waiter with an atomic claim; exactly
one zero-crossing queues the work. This is a lifetime before hardware
execution, so it does not belong in `rk_rga_task_exec` either.

### 15.6 Phase 5: validation and publication became one-way

Phase 5 removed the remaining “validated, then later patched” convention.

MPP now uses:

```text
OPEN rk_mpp_reg_builder
  -> collect writes/reads/offsets/RCB and translate buffers
  -> clone readback destinations into rk_mpp_reg_result
  -> release-publish SEALED
  -> const rk_mpp_reg_image for validate/submit
```

Every builder mutator rejects post-seal use. Runtime DCHS state is an
activation resource overlay, not a write into the command image. IRQ/readback
data goes into the separate result object.

RGA now validates the selected-core operation into an immutable
`rk_rga_task_plan`. All production emitters consume the plan; none accepts
`struct rga_req` or reads `job->tasks`. The raw ABI request remains parser and
validator input, while the plan carries normalized geometry, formats, flags,
and the selected RGA2/RGA3 backend profile.

Finally, RKVENC, direct/soft/hard RKVDEC, AV1, RGA2, and RGA3 use owner-specific
publication operations. Each verifies the exact sealed image or plan, publishes
active/watchdog ownership, orders command/register stores, and writes START or
the doorbell last. This closes the immediate-completion window in the source
model: an interrupt cannot legitimately observe an unowned image or unarmed
timeout.

### 15.7 The post-refactor audit found boundaries outside the new owners

The clearer ownership graph made a useful follow-up possible. A source audit at
6.18 `d9cbcf21cda1` and mainline `b6335efd8f98` did not replace the Phase 0–5
owners; it checked the boundaries immediately outside them and hardened these
cases:

- the driver Kconfig now states its real Rockchip-IOMMU prerequisite;
- the MPP UAPI keeps a fixed 64-bit pointer field on the wire, while the kernel
  decodes it into a private native-pointer type guarded by layout assertions;
- RGA preflights direct requests before retaining imports, rejects invalid sync
  modes, and fails closed when fields the emitters do not implement would
  otherwise be silently ignored;
- long-term RGA USERPTR pins are charged against a service-wide budget, and
  import-ioctl rollback retains the exact object even if another thread removes
  its public handle;
- an IOMMU fault is latched in the exact task execution before allocating an
  optional event record, so atomic-allocation failure or a racing clean IRQ
  cannot erase the fault result;
- RGA successor executions still get distinct addresses, but their bounded
  storage stays on the job until final job release. This avoids an eager-free
  race between lockless final puts from IRQ, timeout, and fault observers; and
- system suspend closes admission, proves the core idle, drains timeout/fault
  callbacks, unregisters the fault handler, disables IRQ delivery, and only
  then force-suspends. Resume restores those owners before reopening admission.

This follow-up supplies a second lesson: a good internal owner does not remove
the need to audit ABI layout, build dependencies, resource budgets, allocation
failure, ioctl publication, and system power transitions. It makes those
outside edges easier to name. The follow-up tips pass the named-manifest and
updated ownership-source checks, but they do not inherit the Phase 4/5 compile
or runtime evidence.

## 16. Why this sequence made sense

### 16.1 Owners before file layout

The drivers and their in-source tests are large, but splitting files first
would have mixed code motion with lifetime changes. The refactor kept the
translation units stable so review could see field moves, reference transfers,
and terminal convergence. Phase 6 can split files along the owners that
actually emerged.

### 16.2 Shared hardware before individual attempts

An MPP activation cannot decide whether a cluster reset or DMA refresh is safe
without stable cluster, reset-domain, and DMA-group authorities. Phase 2 made
those facts explicit before Phase 3 depended on them for retry and retirement.

### 16.3 Identity before reclamation policy

The first activation/execution objects were embedded. This changed ownership
without immediately changing allocation lifetime. Distinct successor storage
came only after every dereference-capable async edge carried a typed reference
and generation. MPP can then reclaim a drained retry predecessor when external
references vanish. RGA deliberately keeps its bounded successor allocations on
the whole job until final release because several asynchronous final puts can be
lockless. Correct identity is mandatory; eager freeing is a separate policy,
not an automatic reward for refactoring.

### 16.4 Retirement before immutable recipes

Sealing an image is useful only when runtime-only data has somewhere else to
live. Activation/execution resource owners made it possible to remove DCHS,
mapping, command, copyback, and IRQ state from the validated representation.

### 16.5 Mechanical rules after singular owners

A source audit is most valuable when a rule has one legitimate owner. “No
active-slot writes outside this helper” is reviewable. “Most paths should
probably do similar cleanup” is not. The audit now rejects the missed-twin
patterns the object model was designed to remove, while KUnit tests the helper
semantics.

## 17. What this means for a new kernel-driver developer

The most important change is where you start a modification. Do not begin at
the terminal caller that exposed a symptom; begin at the object whose lifetime
the change affects.

| If you are changing… | Start with… | Preserve this invariant |
|----------------------|-------------|-------------------------|
| MPP retry, timeout, IRQ, fault, abort, or remove | `rk_mpp_activation`, its typed refs, closure, and central completion | One attempt identity; one terminal policy; no `DONE` before drain/release. |
| MPP CCU reset, member power, or translation recovery | cluster, reset-domain, DMA-group, and typed recovery-result methods | Reset effect, DMA refresh/isolation, quiescence, and reuse remain distinct. |
| MPP message/register handling | open builder, seal point, const image, separate result | No command mutation after `SEALED`. |
| RGA mapping, USERPTR, command memory, IRQ, timeout, or fault | `rk_rga_task_exec` and the retirement engine | Execution resources are released only with DMA-stop proof and while the IOMMU power domain is live. |
| RGA next task or RGA2/RGA3 fallback | whole-job orchestrator | Allocate a distinct successor, retain its storage through job release, and let only the orchestrator change `current_task` or signal the fence. |
| RGA format/geometry/feature support | validator and `rk_rga_task_plan`, then a plan-consuming emitter | Raw requests never leak into emission. |
| Acquire-fence or close/cancel behavior | `rk_rga_acquire_set` | Exactly one waiter claim and exactly one pending-count zero crossing. |
| A new START path | the owner-specific `publish_and_start()` operation | Active identity and timeout exist before the barrier and doorbell. |
| UAPI, USERPTR, or system-suspend behavior | wire-layout assertions, service pin budget, and suspend admission/drain | The internal owner remains valid across the ABI, resource-accounting, and device-power boundary. |

Three practical habits follow.

First, write down the ownership transfer using verbs such as **get**, **clone**,
**move**, **claim**, **retire**, **quarantine**, and **put**. A copied pointer is
not an ownership transfer.

Second, keep four mechanisms separate:

| Mechanism | Proves |
|-----------|--------|
| Reference | The object allocation remains alive. |
| Lock | The protected state is stable during this critical section. |
| Generation | The callback belongs to this attempt rather than a successor. |
| State/closure record | This transition is legal and terminal evidence is sufficient. |

Most asynchronous paths need all four.

Third, treat quarantine as correct ownership, not as a leak to “clean up.” If
reset or isolation did not prove that DMA stopped, freeing mappings merely
makes counters look tidy while creating a use-after-free window for hardware.
Retaining resources until reboot is the safe result.

### 17.1 A safe first source-reading exercise

Trace one normal and one failure path without reading the whole files:

```bash
rg -n 'rk_mpp_reg_builder_seal|rk_mpp_activation_complete_claim|rk_mpp_activation_try_reclaim' \
  drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c

rg -n 'rk_rga_task_plan_build|rk_rga_task_exec_retire_engine|rk_rga_hw_finish_job_locked' \
  drivers/video/rockchip/rga-rewrite/rga_rewrite.c
```

For each function, record the incoming reference, required lock, state
transition, resources transferred, and condition that permits the next owner
to proceed. Then inspect the corresponding KUnit case and ownership-audit rule.

## 18. What is proved and what remains

At the pinned Phase 4/5 completion snapshot, both maintained kernel lines have
byte-identical tracked rewrite sources, ABI/Kconfig/UAPI surfaces, and exact
named test manifests. The ownership and fixture-debt audits pass, all eight
warning-fatal build profiles pass, and the test-disabled ABI-mutation gate
fails when it should. KUnit source cases cover the new state machines, sealed
builder, immutable-plan replay, typed references, retirement, and orchestrator
boundaries.

The newer boundary-hardening tips keep the 109-MPP/152-RGA named manifest and
pass the updated 2,313-signal-per-tree ownership inventory. Those are source
checks only. Their compile, checkpatch, boot, and runtime qualification remains
unrecorded, so the Phase 4/5 build evidence must not be silently carried
forward.

The Phase 4/5 record proves that source model is present and compiles under the
intended configurations. It does not prove:

- that the exact tips boot or that their KUnit cases pass at runtime;
- real immediate-IRQ and delayed old-generation timing;
- reset, timeout, IOMMU-fault, forced-quarantine, close, or unbind behavior on
  the board;
- correct pixels, compressed layouts, or codec bitstreams;
- performance, sanitizer cleanliness, fuzz resistance, or soak stability; or
- the still-separate RGA2 large-segment staging feature.

Phase 6 remains file splitting and test rationalization after the ownership
graph is stable. Phase 7 remains the complete qualification ladder. MPP cluster
admission/coordinator-power policy and some recovery composition also remain
explicit architecture work. Those boundaries are valuable teaching material
too: a good object model reduces the places a hardware discovery must change,
but it never substitutes for hardware evidence.

---

[← Source reading and review](06-source-reading-and-review.md) ·
[Guide home](README.md)
