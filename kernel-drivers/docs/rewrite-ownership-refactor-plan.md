# Rewrite-driver ownership refactor plan

This is an implementation plan for evolving the existing `mpp-rewrite` and
`rga-rewrite` drivers toward the ownership model described in the
[rewrite-driver retrospective](../../findings/2026-08-01-rewrite-driver-retrospective.md).
It is deliberately not a second clean-room rewrite. The goal is to preserve the
working ABI, hardware backends, and accumulated tests while moving the most
failure-prone state into objects that make invalid cross-path combinations hard
to express.

The priority is **ownership before convention**:

1. make shared reset, CCU, DMA/IOMMU, activation, and per-task execution state
   real owners;
2. route every writer and terminal event through those owners;
3. only then make request-to-command ordering structural with validated plans
   and sealed register images; and
4. postpone broad file moves, naming cleanup, and test rationalization until
   the ownership graph has stopped changing.

> **Status — 2026-08-09:** Phase 1 is source-complete, all six Phase 2
> source items are implemented, Phase 3A embedded the first MPP
> current-attempt record, Phase 3B binds the per-session RKVDEC dispatch
> lease to that exact embedded address, and Phase 3C moves the retained
> selected-core reference into it at `rk3588-rewrite-6.18@a72abb9809fc`
> and `rk3588-rewrite-mainline@2ea836184b5f`. Their tracked
> rewrite/Kconfig/ABI/uAPI files are byte-identical. Phase 1 funnels reset
> backends, both active slots, RKVDEC dispatch and power leases,
> publication/start, MPP outcome publication, and RGA execution-map retirement;
> run-lock and final-lease assertions freeze their current contracts. Phase 2
> replaces the reset-domain mutex pointer with a stable service-owned
> identity/member object and routes complete single-target power deassert and
> recovery pulses through its state and nonzero epoch. A service-owned
> `rk_mpp_cluster` records member topology, a borrowed
> coordinator, singular construction reset authority, and derived DMA-group
> count. The existing hard-CCU participant pulse now validates its already
> reference-pinned coordinator/cores through that view and records the entire
> physical sequence as one non-interleavable reset-domain epoch. A refcounted
> cluster power lease replaces the job's fixed powered-core array and follows
> the existing coordinator chain without cycling member power. Cluster methods
> now own the running list, link relinks, completion/resend snapshots, and
> soft/hard CCU arm and publication mechanics. Single-core reset, soft-CCU
> reset, idle fault, and hard-CCU group reset now return typed
> quiesced/reusable results. Group recovery deduplicates the reference-pinned
> participants' DMA groups, refreshes each once, and refuses resend when any
> group is not reusable. Every START now publishes a bounded register lease;
> hard IRQ records its reset epoch and direct-core active generation, reset or
> final register-power loss revokes it, and the IRQ thread refuses absent or
> stale records. Coordinator per-job power and descriptor admission remain
> unchanged. Phase 3A moves the active generation and absolute watchdog
> deadline out of `rk_mpp_hw` into an embedded `rk_mpp_activation`, while the
> hardware slot and timeout target intentionally remain job-pointer adapters.
> Phase 3B replaces the session/job boolean pair with one non-refholding
> `session->rkvdec_dispatch_owner` pointer. Access and mutation remain under
> `srv->sched_lock`, foreign release cannot clear another activation's lease,
> and final job release fails closed rather than freeing storage still named by
> the session. The pointer is current-storage identity, not a retained attempt:
> hard-CCU retry still rewrites the same embedded record in place.
> Phase 3C removes the duplicate `rk_mpp_job::hw` storage: selection and
> drop remain the only ref-changing writers, install asserts the selected
> core matches the active hardware, and retry preserves that exact pointer.
> Retained attempts, fresh retry objects, state transitions, and terminal
> arbitration remain later Phase 3 work. The 1406-signal source-pinned
> production audit freezes those activation, IRQ, and recovery seams plus
> the earlier reset-domain, cluster construction, group-reset, power-lease,
> and CCU runtime seams; the KUnit-debt audit remains 306 signals, and the
> manifest is 102 MPP plus 152 RGA cases. There is still no retained MPP
> attempt/transition engine, `rk_rga_task_exec`, or `rk_rga_acquire_set`.
>
> The predecessor Phase 1 source `ab69ece998642` is packaged as inspected
> `rewrite-debug` package P692f with stamp `(gab69ece99864)`, but it remains
> uninstalled and unbooted. On 2026-08-08 the operator explicitly authorized
> source-only Phase 2 work without waiting for that qualification. This changes
> sequencing only: no boot, runtime KUnit, decoder, RGA, reset-contention, or
> recovery claim transfers to the new tips.

The plan was derived from `linux-6.18-rkvenc` branch
`rk3588-rewrite-6.18@8042f13c54591` on 2026-08-01 and was rechecked for
structural applicability against the patch-equivalent `19634f4eebba` rebase on 2026-08-04. Function names
below are anchors, not line-number claims. No kernel was changed, compiled, or
booted while originally writing this plan; the later build result above only
establishes the unrefactored current tip.

## Result

Do not replace the current drivers wholesale. Refactor them around two smaller
runtime units:

- an MPP **activation**, admitted and recovered by an explicit hardware
  cluster; and
- an RGA **task execution**, which owns the selected hardware, mappings,
  command buffer, and one trip through the active slot.

Those objects address the latent-risk areas directly. MPP's reset domain now
owns stable identity, membership, single-target state and cluster-validated
group-pulse epochs. A refcounted lease owns the member-core power holds, but it
still transfers through legacy jobs; coordinator power, CCU MMIO, reset
results, and IOMMU refresh remain in different objects and paths. RGA's common recovery tail fixed one multi-task
advance omission, but a job still mixes whole-request lifetime with the
resources and state of its current hardware task.

The desired ownership graph is:

```text
MPP service
├── cluster (CCU membership, admission, group power, recovery, quarantine)
│   ├── reset domain (all reset operations and reset epochs)
│   ├── DMA group (domain attachment, refresh epochs, terminal isolation)
│   ├── coordinator
│   └── member cores
└── session
    └── job (accepted user transaction and result)
        └── activation (one admitted hardware lifetime)
            ├── session dispatch lease
            ├── cluster/power lease
            ├── selected core and active generation
            ├── immutable register image
            └── timeout/fault/retirement state

RGA service
├── hardware cores
└── session
    ├── import capability (buffer identity, provenance, pins)
    └── configured request
        └── submitted job (whole-request result and fences)
            ├── acquire set
            └── task execution (one task on one selected core)
                ├── execution mappings
                ├── command image
                └── activation/timeout/fault/retirement state
```

The boxes are not an instruction to allocate everything separately. Several can
begin as embedded structs inside the current job so the migration changes
ownership before it changes allocation or lifetime.

## Why object ownership comes first

Recent fixes repeatedly repaired a convention at one call site while leaving a
structural twin behind:

- an MPP register image was revalidated, then changed by a later RCB write;
- DCHS lifetime serialization reached most terminal paths but missed another;
- RGA IRQ completion advanced a multi-task job correctly while recovery did
  not;
- one RGA3 emitter normalized rotated geometry while its sibling consumed the
  wire representation; and
- five MPP reset paths did not perform the IOMMU refresh done by two other
  paths.

Another ordering checklist would improve review but would not remove the
choice from each path. An owner can. If only a reset-domain method may touch a
reset control, no new caller can forget the shared-domain exclusion. If the
active slot contains an activation and only its transition engine can retire
it, IRQ, timeout, fault, abort, and remove cannot grow independent cleanup
tails. If an emitter receives an immutable validated task plan, it cannot
reinterpret raw geometry.

## Current objects and the seams to change

### MPP

| Current object | Useful ownership already present | State that is still at the wrong altitude |
|---|---|---|
| `rk_mpp_service` | hardware registry, scheduler queue, diagnostics, reset-domain and shadow-cluster registries | DMA groups, DCHS global state, and topology are recorded but not yet composed into admission/recovery ownership |
| `rk_mpp_reset_domain` | stable node identity, member lifetime, mutex, single-target operations, one cluster-validated epoch for each hard-CCU group pulse, and typed single/group effect/epoch results | IRQ lease and quarantine authority remain absent |
| `rk_mpp_cluster` | stable CCU identity, unbounded member lifetime, borrowed coordinator, core/type summary, singular reset authority, derived DMA relationship count, hard-CCU reset-participant validation, member power-lease identity, coordinator running-list/link ownership, soft/hard arm/START publication, and typed single/group reuse gating | descriptor admission, quarantine policy, and complete activation lifetime remain outside cluster ownership |
| `rk_mpp_cluster_power_lease` | refcounted exact member-core power/hardware references; transfers unchanged along the existing coordinator chain and releases once | remains attached to one legacy job at a time until an activation object owns the complete admitted lifetime; coordinator power remains per-job |
| `rk_mpp_dma_group` | IOMMU group, normal/isolation domains, member list, terminal isolation, and serialized per-group refresh used by hard recovery | no retained refresh epoch or admission authority |
| `rk_mpp_activation` | embedded current-attempt backpointer, retained selected-core reference, nonzero hardware generation, absolute watchdog deadline, and exact identity named by the session-dispatch owner; all selected-core writes and dispatch-owner accesses are hard-allowlisted | retry still overwrites this storage in place; CCU/link/DCHS, power leases, async snapshots, state, and terminal ownership remain outside it |
| `rk_mpp_hw` | private MMIO, clocks, IRQ, queue, job-pointer active/timeout adapters, and monotonic activation-generation allocator | also acts as coordinator, reset client, group-recovery participant, and IOMMU-fault owner; the slot is not yet activation-typed |
| `rk_mpp_job` | accepted message set, retained imports, result, and embedded current-attempt record | also carries a temporary cluster-lease pointer, coordinator power, CCU membership, mutable register image, slice state, activation timing, and backend recovery state |

The current reset-domain and cluster objects prove reset transaction ownership,
not that the whole cluster migration is finished. `rk_mpp_hw_power_on()` and
`rk_mpp_hw_reset_active()` invoke complete single-target operations, while
hard-CCU coordinator stop validates its existing participant snapshot and owns
one group epoch. The fixed powered-core array is gone, but the new cluster
lease still transfers through legacy jobs and coordinator power remains
per-job. Single-core and hard-CCU group reset effects are coupled to IOMMU
refresh and expose separate retirement/reuse decisions; the group path
deduplicates the already reference-pinned participants' DMA groups before it
permits resend. Descriptor admission, a retained refresh epoch, and quarantine
authority remain outside this typed result.

### RGA

| Current object | Useful ownership already present | State that is still at the wrong altitude |
|---|---|---|
| `rk_rga_session` | per-open imports, requests, jobs, close barrier | little should move out; this is already the correct user-ownership boundary |
| `rk_rga_import` | retained buffer identity, provenance, pages and refcount; selected-device USERPTR mapping state was removed on 2026-08-06 | long-term USERPTR pin accounting remains absent, and execution maps are still fields of the broad job rather than a distinct execution object |
| `rk_rga_request` | configured request and retained inputs | mutable raw tasks remain the representation later validators and emitters inspect |
| `rk_rga_job` | submitted lifetime, session link and final result | owns all tasks, all mappings, current-task hardware, command allocation, acquire callbacks, release fence, timing and recovery state |
| `rk_rga_hw` | private MMIO, clocks, reset, queue and active slot | active slot points at the whole multi-task job rather than the current execution unit |

`rk_rga_job` is the key seam. Its mappings and command buffer are created for
the current task and cleared before advancing, but the type does not express
that narrower lifetime. Every completion path must remember which fields are
per-job and which are per-task.

## Target MPP owners

### `rk_mpp_cluster`: shared hardware is a resource, not a convention

Create one cluster per validated CCU topology. It owns:

- the coordinator and member-core set;
- admission while recovery or member removal is in progress;
- the continuous coordinator arm-to-START critical section;
- group power leases and the set of cores covered by each lease;
- shared descriptor/link membership;
- reset-domain and DMA-group links;
- recovery generation and quarantine reason; and
- membership changes during probe, remove, suspend, and resume.

The cluster need not assume that CCU, reset, generic-power, and IOMMU groupings
are identical. RK3588 topology may give one cluster links to several owners.
Probe must validate those relationships and reject an ambiguous combination;
it must not merge objects solely because two device-tree nodes happen to share
an ancestor.

Move these responsibilities behind cluster methods:

```c
int rk_mpp_cluster_acquire(struct rk_mpp_activation *activation);
int rk_mpp_cluster_arm_and_start(struct rk_mpp_activation *activation);
enum rk_mpp_recovery_action
rk_mpp_cluster_recover(struct rk_mpp_activation *activation,
                       enum rk_mpp_stop_reason reason);
void rk_mpp_cluster_release(struct rk_mpp_activation *activation);
void rk_mpp_cluster_remove_member(struct rk_mpp_cluster *cluster,
                                  struct rk_mpp_hw *hw);
```

These names are illustrative. The contract matters: callers request an
operation; they do not take `ccu->run_lock`, walk siblings, or maintain
raw member-core power arrays themselves.

The first migration targets now route through
`rk_mpp_cluster_power_lease_acquire()`, `rk_mpp_cluster_arm_soft_ccu()`,
`rk_mpp_cluster_start_ccu_job()`, and the cluster running-list/link helpers. A
group power lease replaces the job's fixed array of powered cores. The lease
records exactly which runtime-PM references were acquired and releases them
once, regardless of completion reason.

### Finish expanding `rk_mpp_reset_domain` into the reset authority

The object now owns stable membership and single-target operations even while
the physical `struct reset_control` remains stored on a member core. Finish the
authority by adding the cluster-owned group paths that remain:

- coordinator/group stop and terminal isolation methods;
- a cluster result that relates the reset epoch to DMA refresh/isolation;
- quarantine publication and refusal semantics after topology validation; and
- an IRQ-safe register-lease view tied to the completed reset epoch.

After migration, no production code outside the reset-domain implementation
may call `reset_control_assert()` or `reset_control_deassert()` for MPP. This
is more important than the exact state enum: one authority must see every
writer, including group power-on and force-stop paths.

Hard IRQ cannot take the domain mutex. It should not perform reset-sensitive
MMIO by sampling an informal condition either. Publish a small IRQ-safe
`reset_epoch`/`registers_live` snapshot under the existing raw lock, let the
hard handler claim and acknowledge only when the snapshot is valid, and defer
all reset-dependent work to the thread. This closes the residual architecture
question left after the reset-domain lock removed the measured wedge.

### Keep `rk_mpp_dma_group` distinct and make recovery use it

The DMA group is already a first-class object and should not be collapsed into
the CCU cluster. Extend its API with:

- a domain/attachment generation;
- one refresh method returning whether translations were restored;
- a transition to terminal isolation that is idempotent;
- a member-removal barrier; and
- diagnostics that identify the reset and activation generation which caused
  the refresh.

Reset must return an explicit effect, not just `0`:

```c
enum rk_mpp_reset_effect {
        RK_MPP_RESET_NONE,
        RK_MPP_RESET_TRANSLATIONS_LOST,
        RK_MPP_RESET_TERMINALLY_ISOLATED,
};
```

The cluster recovery method consumes that effect and cannot publish a recovered
core until the DMA group has refreshed the IOMMU or terminally isolated the
group. This makes the five reset-without-refresh paths converge structurally.
It also gives hardware self-reset status a place in the model: the backend may
report that translations were lost even when software did not issue the reset
pulse.

Migrate `rk_mpp_hw_refresh_iommu()`, `rk_mpp_dma_group_isolate()`,
`rk_mpp_hw_stop_active()`, `rk_mpp_rkvdec2_reset_soft_ccu_job()`, timeout,
abort, CCU drain, and IOMMU-fault recovery through this contract. A source gate
must reject a reset-success path that reaches re-admission without a refresh,
power-cycle proof, or isolation result.

### `rk_mpp_activation`: one admitted hardware lifetime

Embed an activation in `rk_mpp_job` first. It owns:

- a reference to the accepted job, selected core, cluster and DMA group;
- the active generation and absolute watchdog deadline;
- the RKVDEC session-dispatch lease acquired by the scheduler for this attempt;
- power and group leases;
- DCHS/CCU/link participation acquired for this run;
- IRQ and fault snapshots associated with the generation;
- `PREPARED`, `PUBLISHED`, `RUNNING`, `RETIRING`, `RETIRED`, `QUARANTINED`,
  and `RECLAIMABLE` state; and
- the one terminal result claimed for the activation.

An activation is one hardware **attempt**, not one logical job across retries.
The scheduler acquires the session-dispatch lease under its admission lock before
removing an RKVDEC job from the queue and transfers that lease to the activation.
Normal retirement releases it only after the exact hardware generation has left
the active slot and all DMA-capable backend participation is quiescent. An abort
may release it only after proving that the dispatch cannot still start or own
hardware. Reset or stop failure transfers the lease to quarantine instead of
reopening the session. Encoder jobs do not acquire this lease, and independent
decoder sessions remain eligible for different cores.

Retry creates a fresh activation with a new monotonic generation and a new
deadline; it never moves an old activation through a `RETRYING` state. Before
the old activation becomes `RECLAIMABLE`, it transfers the session lease under
the admission lock directly to the new attempt or to a typed retry-handoff owner
that keeps the session closed while embedded storage drains. There is no
release/reacquire window in which a later same-session job can overtake the
retry. If a backend needs an old attempt to remain addressable for delayed work,
allocate attempts separately or retain the embedded storage until every
asynchronous reference drains.

Change `rk_mpp_hw::active_job` and `timeout_job` to activation pointers only
after all access is behind slot helpers. IRQ, timeout, IOMMU fault, session
abort, unbind, and shutdown may only attempt to claim the exact activation and
generation. They must not complete a job directly.

The transition engine then performs the slow work:

```text
claim activation + reason
  -> quiesce backend and auxiliary IRQs
  -> recover cluster/reset domain
  -> refresh or isolate DMA group
  -> choose retry, fail, or quarantine
  -> if retry and quiesced: transfer the session lease to the new attempt/handoff owner
     and release only old-attempt resources after quiescence
  -> else if final and quiesced: release mappings/link/DCHS/power/session leases
  -> else: transfer every DMA-reachable resource and lease to quarantine
  -> publish job state and wake poll/fence waiters
  -> release hardware and kick the scheduler
```

Backend hooks may read status, stop a core, rebuild a descriptor, or prepare a
retry. They return decisions and hardware facts to the engine; they do not own
the common tail.

This is the right home for the current generation and absolute-deadline fields.
It also replaces the need for each path to remember DCHS release, CCU power
transfer, session-dispatch release, timeout cancellation, IOMMU refresh, and
scheduler wakeup separately.

### Quarantine owns what cannot safely be released

Quarantine is an owner, not merely a terminal enum. A quarantined activation or
task execution transfers its exact slot/generation identity, command or register
image, execution mappings, imported-buffer and scratch references, DMA-group or
domain references, power/cluster participation, and any session-dispatch lease
that still excludes successor work into a refcounted tombstone. No destructor
may free DMA-reachable storage merely because the userspace job has been failed.

The transition engine may signal the user-visible job after that transfer is
complete, but close, cancel, remove, and unbind must not bypass the tombstone.
Admission remains disabled for the affected session, core, cluster, or device as
appropriate. Resources become releasable only after a later positive stop/reset
and translation-isolation proof; otherwise the tombstone intentionally survives
until reboot. Debugfs counters must distinguish live, released-after-proof, and
reboot-only quarantines, and the removal gate must prove that no callback or
worker can reach freed driver state through a retained tombstone.

### Builder and sealed MPP image

Do this after the cluster and activation migrations. Split the current
`rk_mpp_reg_image` conceptually into:

- a mutable builder that accepts register writes, fd translations, offsets,
  RCB placement, and backend fixups; and
- a sealed image exposed as `const` to submission and readback code.

The seal operation is the only transition between them. It validates the final
codec selector and every address-like word against retained imports or
kernel-owned scratch. Any DCHS, CCU, RCB, or slice patch that must happen near
START is either represented as a kernel-owned late-patch capability consumed
inside `cluster_arm_and_start()`, or must occur before sealing. Raw request
fields and mutable register pointers must not reach backend submission.

## Target RGA owners

### Keep import identity separate from execution mapping

Treat `rk_rga_import` as a session capability. It owns:

- the immutable buffer type and identity;
- dma-buf or userptr provenance;
- retained dma-buf/pages and checked logical extents; and
- the reference that lets accepted requests outlive the ioctl and close race.

It should not directly own a single selected hardware device. Move each
device/domain attachment and IOVA into a refcounted `rk_rga_exec_map`. The map
is owned by one task execution, or by an explicitly cached map object keyed by
`(import, device, domain generation)` if measurements justify caching. Hardware
remove invalidates cached maps through their own registry without changing the
identity or pin lifetime of the import.

The 2026-08-06 USERPTR power-order fix completes the ownership half of this
target without introducing a new type: imports now retain only logical
identity/backing, and `rk_rga_job_mapping` owns every selected-core USERPTR or
DMA-BUF execution view. Mapping begins after core power-on and teardown finishes
before power-off. Extracting that state into `rk_rga_exec_map` remains a type
and retirement-engine cleanup, not a prerequisite for the corrected lifetime.

Do not hold `rga->import_lock` while pinning pages or building an IOMMU mapping.
Create the candidate privately, take the lock only to recheck removal and
publish it, then discard or retain the candidate. Add locked-memory accounting
or an explicit documented resource policy for long-term userptr pins before
calling that path production-ready.

### Preserve request and job, but make them narrow

`rk_rga_request` remains the configured, reusable session object. After a
successful configuration it should expose immutable accepted inputs; a
reconfiguration builds a replacement and swaps it under the session lock.

`rk_rga_job` remains one submitted request and owns:

- the session reference and whole-request result;
- task sequence and current task index;
- priority/synchronous behavior;
- acquire-set and release-fence result; and
- the link used by close to wait for every submitted request.

It should no longer own selected hardware, execution mappings, command memory,
active generation, IRQ snapshots, or per-task timing.

### `rk_rga_task_exec`: one task, one selected core, one retirement

Add a refcounted task-execution object, initially embedded in `rk_rga_job` and
reused only after it reaches `RECLAIMABLE`. `RETIRED` means that its result is
decided; it is not proof that delayed IRQ, timeout, fault, or acquire/copyback
work has dropped the object. Every asynchronous edge carries both an execution
reference and its monotonic generation cookie. The object owns:

- one validated task plan;
- eligible hardware mask and selected `rk_rga_hw` reference;
- every execution map and RGA2 MMU table for that task;
- command allocation and immutable emitted image;
- userptr device/CPU synchronization and copyback obligation;
- power reference, active generation, timeout deadline, IRQ/fault status and
  measured hardware time; and
- one transition from active through `RETIRED` to either `RECLAIMABLE` or
  `QUARANTINED`.

As with MPP, a retry or fallback is a new execution attempt and generation, not
reinitialization of a `RETIRED` object. The old attempt reaches `RECLAIMABLE`
only after its active slot, timers, callbacks, work items, and backend references
are gone. Generation wrap must be treated as an explicit drain/reinitialize
event rather than allowing an old asynchronous event to acquire a new attempt.

Change `rk_rga_hw::active_job` to `active_exec`. Then
`rk_rga_hw_finish_job_locked()`, `rk_rga_hw_recover_active()`, timeout, IOMMU
fault, session abort, and remove all claim and retire an execution. Only the
job orchestrator handles the result:

```text
execution retired successfully
  -> drain asynchronous references to RECLAIMABLE
  -> destroy execution resources
  -> advance current_task
  -> build/select/queue next execution

execution retired with failure
  -> drain asynchronous references to RECLAIMABLE or transfer to quarantine
  -> if reclaimable: destroy execution resources
     else: leave them owned by the quarantine tombstone
  -> complete whole job and signal release fence
```

The common engine therefore cannot forget multi-task advancement: it returns a
retired execution to exactly one job-level continuation rather than spelling
that continuation in IRQ and recovery paths.

The main migration anchors are `rk_rga_job_prepare_hw_mappings()`,
`rk_rga_job_emit_cmd()`, `rk_rga_hw_start()`,
`rk_rga_hw_finish_job_locked()`, `rk_rga_hw_recover_active()`,
`rk_rga_job_advance_task()`, and `rk_rga_job_clear_mappings()`.

### `rk_rga_acquire_set`: callback lifetime as an object

The existing callback protocol is currently sound but difficult to review
because waiter pointers, arrays, pending counts, queued-work state, and abort
flags live across the job. Put them in one acquire-set object which owns:

- fence references and callback records;
- the zero-crossing/pending count;
- the work item and its queued reference;
- the single cancellation/result transition; and
- the reference returned to the job when all fences are ready.

Callbacks refer to the acquire set, not directly to a broad job. Close and
cancel ask the set to resolve once, then the job consumes the result. This is a
containment refactor, not a reason to redesign the proven `xchg()` protocol.

### Validated task plan and command image

After task-execution ownership is stable, replace the raw `struct rga_req`
hand-off with an immutable `rk_rga_task_plan`. It contains normalized
wire/canvas rectangles, layouts, formats, exact buffer roles and extents,
feature approvals, rotation/mirror representation, eligible hardware mask, and
the backend profile derived by the validator that succeeded.

RGA2/RGA3 emitters accept only that plan plus execution maps. No emitter may
read a raw UAPI task or infer a feature from raw flags. Emission produces an
immutable command image owned by the task execution. This phase removes the
rotation and validator/emitter twin class after the lifetime refactor has made
the execution boundary explicit.

The plan and execution-map type must also preserve the known RGA2 staging
boundary. Each role records whether it is direct-mapped or staged, the original
and execution extents, copy-in requirements, copyback requirements, and the
owner of staging storage. This does not preselect the fix for the current 1 MiB
SWIOTLB segment limitation; it prevents that later fix from bypassing task
ownership or inventing a second teardown path.

### Publish and start is one linearized owner operation

Sealing an image is necessary but does not publish it to hardware. Each backend
gets one typed `publish_and_start()` owner operation with this contract:

1. mappings, power/cluster leases, and an immutable image are complete;
2. the exact object pointer and generation are installed in the active slot and
   the state becomes `PUBLISHED`;
3. IRQ ownership and the absolute watchdog for that generation are armed;
4. all coherent descriptor/command stores are ordered with the DMA barrier
   required by the architecture and backend;
5. the state becomes `RUNNING` before the doorbell so an immediate IRQ observes
   a runnable generation; and
6. the MMIO start/doorbell write is the final operation.

An error before the doorbell retires the published generation through the same
engine; no caller clears the slot or tears down mappings privately. Backends may
specialize the required DMA/MMIO barrier, but they may not expose a raw start
write to callers. Source audit must reject every RKVDEC/RKVENC/RGA START or
doorbell write outside these owner operations.

## One transition engine per active object

MPP activation and RGA task execution should follow the same rule even if they
do not share C code:

1. a small slot lock protects only pointer, generation, IRQ snapshot, and claim;
2. the winning trigger moves the object to `RETIRING`, while eligible concurrent
   triggers merge typed reason bits and immutable hardware snapshots;
3. a sleepable engine owns stop/reset/refresh and all slow teardown;
4. the engine publishes exactly one retry, final result, or quarantine; and
5. object destruction happens only after callbacks, worker references, and the
   active slot are gone.

The reason set is not first-writer-wins. While the engine drains IRQs and proves
quiescence, exact-generation adapters may add evidence. Before releasing any
resource or publishing a user result, the engine closes reason collection at a
documented snapshot point and applies one common policy:

| Evidence at the snapshot | Outcome precedence |
|---|---|
| stop, reset, or translation isolation is unproved | quarantine; dominates every user-visible result |
| IOMMU fault, fatal hardware error, or reset failure | hardware failure; dominates DONE, timeout, and cancellation |
| watchdog expiry without stronger evidence | timeout failure; dominates a later uncorroborated DONE |
| remove, shutdown, session abort, or explicit cancel | the corresponding terminal cancellation/removal result |
| clean DONE with none of the above | success |

A DONE snapshot captured before a cancellation claim may complete successfully;
the reverse ordering cancels. Encode that ordering in the slot claim sequence,
not wall-clock timestamps. Evidence arriving after the snapshot is diagnostic
unless it proves that DMA quiescence was falsely assumed, in which case it may
still escalate the object to quarantine but never downgrade a fault to success.
KUnit must exercise every pairwise trigger order, including DONE+ERROR,
DONE+timeout, timeout+fault, cancel+DONE, remove+IRQ, and fault+shutdown.

Triggers are adapters:

| Trigger | Adapter may do | Adapter must not do |
|---|---|---|
| hard IRQ | bounded claim/ack/status snapshot, wake thread | reset, free, signal, copy back, map/unmap |
| threaded IRQ | claim exact generation and submit completion reason | implement a private completion tail |
| timeout | claim only the deadline's generation | extend a restored deadline or retire a replacement |
| IOMMU fault | identify affected active generation(s), stage work | refresh under live DMA or guess the owning core |
| close/cancel | disable admission and request abort | free resources still owned by a slot/callback |
| remove/shutdown | detach admission, drain workers, request quarantine | bypass the transition engine because the device is leaving |

State transitions should be checked with `WARN_ON_ONCE()` and counters in
debug builds. They should not silently coerce an unexpected state into success.

## Locks follow the owners

Write a lock table next to the new internal object declarations and enforce it
with `lockdep_assert_held()` in owner methods. A workable hierarchy is:

| Lock class | Protects | Rules |
|---|---|---|
| service topology mutex | registries and membership publication | never held across pinning, DMA mapping, runtime PM, reset, or worker drain |
| scheduler/admission mutex | queued work, scan order, and session-dispatch lease transfer | never held across backend submit, transition-engine work, or waiter wakeup |
| session/job mutex | session-visible job registry, result, and whole-request sequencing | never acquired from a hardware IRQ adapter; hand state to the engine/orchestrator instead of nesting across waits |
| cluster transition mutex | CCU admission, group power, group recovery | only cluster methods take it; no ioctl parser or emitter does |
| DMA-group transition mutex | domain membership, refresh epoch, and isolation/quarantine result | never nests inside an import/map registry lock or live-DMA map construction |
| hardware run mutex | one core's sleepable start/retire operation | never substitutes for a cluster/reset-domain invariant |
| reset-domain mutex | reset-control operations and reset state | innermost sleepable leaf; no allocation or callbacks |
| active-slot spinlock | active pointer, generation, claim and status snapshot | bounded; no MMIO requiring clocks to stay live unless the IRQ-safe register lease is held |
| IRQ raw lock | a bounded registers-live/aux-MMIO lease | no allocation, callback, refcount destructor, or unbounded loop |
| acquire-set spinlock | callback records, pending zero-crossing, cancel/result claim | callbacks take only this lock; no job/session/hardware lock acquisition or destructor |
| import/map mutex | one import or cached-map registry | never held across page pinning or a whole candidate map build |

This table is a target to validate with lockdep, not permission to mechanically
nest every row. If hardware forces a reverse acquisition, change the object
API so one owner hands off state rather than adding an exception comment.
Write the actual partial-order edges beside the table, including which pairs are
deliberately non-nesting, and assign lockdep class keys to repeated per-core,
per-cluster, per-session, and per-acquire-set instances. Transition engines and
worker drains must assert that no scheduler, session, acquire-set, or import/map
lock is held before sleeping.

## Refactor sequence

Every step below is a sequence of small commits. Feature additions are frozen
from phase 1 until the ownership and hardware gates for phase 5 pass.

### Phase 0 — freeze a source-bound baseline

- Pin the exact 6.18 and mainline rewrite tips and prove the tracked driver,
  UAPI, ABI, Kconfig, and test manifests are byte-identical where intended.
- Record build, KUnit, boot, normal workload, reset-contention, recovery, and
  differential-oracle results separately. A known failure is acceptable only
  when it is deterministic, bounded, attributed, and outside the invariants the
  next phase will preserve. Intermittent silent corruption, unexplained DMA or
  IOMMU faults, an unproved stop, and an unbooted exact tip are blockers rather
  than acceptable red baselines.
- Generate inventories of every direct reset-control call, active-slot write,
  session-dispatch lease write, power-reference field, power transition, raw
  PM/clock operation, `power_count` write, IOMMU refresh/isolation call and raw
  backend operation, job lifecycle/outcome write and publication,
  IRQ/fault/watchdog snapshot write, watchdog-arm entry, activation-timing and
  terminal/admission-state write, MPP/RGA terminal entry, RGA task-advance
  call, execution-map owner/release primitive, command-buffer writer/release,
  raw start/doorbell or IRQ-ack write, and raw task emitter.
- Freeze the expected debug counters and event fields used by hardware gates.

Acceptance: the same immutable source archive reproduces both builds and every
known baseline result has an evidence path. Ordinarily, an exact source tip
must boot before Phase 1 and pass the red/green same-session H.26x loop plus the
solo RGA3 vpp and overlay-chain replays. On 2026-08-08 the operator explicitly
deferred install and reboot qualification, so Phase 1 source-only write funnels
and assertion-only contract checks could land provisionally after
mirrored-source identity, strict checkpatch, and the device-free gates. The
exact current tips pass the focused warning-fatal `normal`, `test-disabled`,
KASAN/fault-injection `memory`, and KCSAN/lockdep `race`
provider/rewrite-object/DTB builds; the 6.18 tip also produced a full inspected
`rewrite-debug` package set with no rewrite or frame-size warning. On
2026-08-08 the operator explicitly overrode the Phase 2 sequencing gate for
source-only construction work. The deferred boot, KUnit-runtime, and hardware
gates remain mandatory before qualification or any runtime behavior claim.
If either corruption persists, land and qualify its narrow fix before advancing
beyond provisional funnels.

### Phase 1 — create write funnels without changing behavior

- Wrap every MPP reset call in a reset-domain operation, even while the wrapper
  initially delegates to the current implementation.
- Put active-slot reads/writes behind typed helpers for both drivers.
- Put RKVDEC session-dispatch acquire/transfer/release behind one lease API.
- Put every hardware start write behind a temporary `publish_and_start()` funnel
  that records the active generation and performs the existing barrier/order.
- Put MPP power lease acquisition/release, IOMMU refresh/isolation, and RGA
  execution-map teardown behind singular APIs.
- Assert the existing run-lock contracts at active publication, hardware start,
  IOMMU refresh, and RGA backend-start funnels; warn if final MPP destruction
  inherits a published/listed/powered CCU lease.
- Freeze every terminal/admission-state, IRQ/fault/watchdog snapshot,
  activation-timing, outcome, and terminal-entry mutation. Do not put them
  behind a stateless job wrapper: introduce the real transition API only with a
  retained, generation-tagged activation/task-execution object that can define
  snapshot closure.
- When a real embedded-object view is introduced, add assertions that its old
  and new fields agree. Keep the assertions until the last old-field user is
  removed; do not create shadow fields solely to manufacture this check.

Acceptance: source-audit allowlists show no unreviewed direct writer outside
the current owning module/section. Qualification must then prove compiled
behavior and hardware counters unchanged. The source-only Phase 1 boundary
remains provisional until the deferred exact-tip boot and hardware gates pass.
The operator-authorized Phase 2 source work must retain that boundary explicitly
and may not be described as runtime qualification.

### Phase 2 — make MPP reset and cluster ownership real

1. Expand `rk_mpp_reset_domain` with members, state and epoch.
2. Construct `rk_mpp_cluster` during topology validation and attach cores,
   coordinator, reset domain and the derived per-member DMA relationships.
3. Replace `job->rkvdec_ccu_powered_cores[]` with a cluster power lease.
4. Move CCU arm/start, job-list/link ownership and group admission into cluster
   methods.
5. Move software reset, hardware self-reset classification, IOMMU refresh and
   quarantine into one cluster recovery result.
6. Make hard IRQ respect the IRQ-safe reset/register lease and leave all slow
   work to the thread.

Checkpoint 1 is present at `53a7fa1acbc0` / `ba8e11de18a8`: the stable
reset-domain registry, membership lifetime, single-target state/epoch, and
complete power-deassert/recovery-pulse methods are implemented. It is only the
single-target part of item 1. The existing hard-CCU multi-member pulse still
uses the contained backend leaves and publishes no domain epoch; migrating it
before cluster construction would permit interleaving or misstate the affected
topology.

Checkpoint 2 is present at `e854cacd64c21` / `130fb983eeaf3`: the service now
constructs a stable, read-only cluster membership view after reset/DMA/core
validation and retains it through hardware drain. This completes the
construction portion of item 2 only. At that checkpoint, existing list walks
and all admission, power, reset, IOMMU, abort, and recovery decisions remained
unchanged; it supplied the topology boundary consumed by checkpoint 3 below.

Checkpoint 3 is present at `e41bdb50a9ab7` / `1c91ffc853f7a`: force-stop keeps
the old participant selection and physical line order but performs it through
one cluster-validated reset-domain transaction and one epoch. Topology mismatch
refuses before any reset write; an injectable backend test proves success,
partial failure, balance, and exact order. Failure callbacks deliberately run
after the complete physical pulse and outside the innermost domain mutex.

Checkpoint 4 is present at `129a49a2bec96` / `f03e5cd9f44d3`: a refcounted
cluster lease replaces `job->rkvdec_ccu_powered_cores[]`, validates the
selected members' cluster backpointers, and moves unchanged to the next listed
job before the old owner retires. Final release preserves power-off-before-ref
drop order. Coordinator per-job power and all selection, admission, reset, and
IOMMU policy remain unchanged at that checkpoint; checkpoint 5 supplies the
mechanical CCU arm/START and running-list/link funnel.

Checkpoint 5 is present at `805a216a1e8d1` / `4cb7913f84669`: cluster
validation now precedes new soft/hard publication, and cluster methods own
every coordinator running-list add/remove, link relink, done/resend snapshot,
reset-participant collection, soft arm/START, and hard descriptor publication.
The existing recovery/run/spin lock nesting and exact watchdog/barrier/MMIO
order remain unchanged. Item 4's ownership funnel is complete except for group
admission policy, which deliberately stays with the later typed recovery
result.

Checkpoint 6A is present at `e99b3da2f3318` / `63bbb63bec44d`: every
single-core reset and idle-IOMMU-fault path returns a typed effect, epoch,
quiescence, and reuse decision. Reset success refreshes translations before
reuse; refresh failure closes admission and attempts terminal isolation; and
soft CCU reconnect MMIO occurs only for a reusable result. Hard-CCU group reset
is intentionally left for checkpoint 6B because its one epoch affects a
reference-pinned set of cores and possibly several DMA-group views.

Checkpoint 6B is present at `43fca8a3d80cf` / `91bac563e4a5d`: hard-CCU
group reset returns the same typed recovery contract, constructs a deduplicated
set from the already reference-pinned coordinator and core participants, and
refreshes each affected DMA group exactly once before permitting resend. Any
topology, reset, or refresh failure keeps reuse false and falls back to the
existing terminal-isolation cleanup. Descriptor admission is intentionally
unchanged.

Checkpoint 6C is present at `ab9f6e2d2023f` / `5890133da0c46`: each direct
core START publishes the current reset epoch and activation generation as an
IRQ-safe register lease; hard-CCU physical members publish the reset epoch
with generation zero because the coordinator chain owns their descriptors.
Reset and final register-power loss revoke the lease before MMIO becomes
unsafe. Hard IRQ snapshots and records only a live lease, and the threaded
handler rejects missing, consumed, reset-stale, or generation-stale status
before claiming the slot. RKVENC slice FIFO and wakeup work consequently run
after that check in the thread. This completes Phase 2 item 6 without creating
the retained activation or terminal-reason owner reserved for Phase 3.

Acceptance requires more than KUnit: repeat the reset-contention gate with both
cores resetting; normal single- and multi-stream decode; kill/close/reset
stress; timeout and IOMMU-fault injection; suspend refusal; unbind/rebind; and
clean ramoops/dmesg. `iommu_refresh_count` must agree with the reset effects the
new owner reports, including the paths that previously reset without refresh.

### Phase 3 — migrate MPP active lifetime and retirement

Checkpoint 3A is present at `7548afe6a8b1b` / `af89363ffa5ed`: the job now
embeds `rk_mpp_activation`, and the hardware allocator assigns its current
nonzero generation under `hw->lock`. The same object owns the absolute
watchdog deadline and explicit validity bit, so cancel/re-arm cannot extend an
attempt and `rk_mpp_hw` no longer carries a deadline mirror. The active and
timeout slots remain retained job pointers, and hard-CCU retry deliberately
replaces the embedded record in place to preserve pre-engine behavior. This is
a representation/ownership destination, not yet an authoritative lifecycle
state, retained attempt, or terminal transition engine.

Checkpoint 3B is present at `7b9a4fe4e3eb` / `8439e3abc142`: the scheduler's
split session/job dispatch booleans are gone. One pointer in the session names
the exact embedded activation while `srv->sched_lock` is held; acquire and
release are the only writers, a sibling release is a no-op, and final job
release refuses to free still-owned storage. The pointer carries no reference
and is never dereferenced. It deliberately survives in-place hard-CCU retry,
so it does not yet provide immutable generation retention or terminal state.

Checkpoint 3C is present at `a72abb9809fc` / `2ea836184b5f`: the retained
selected-core pointer moved from `rk_mpp_job` into `rk_mpp_activation` without
changing selection, refcount, queue, completion, abort, or destructor order.
`rk_mpp_job_select_hw()` and `rk_mpp_job_drop_hw()` remain the only
ref-changing writers; final destruction retains the same fallback put after
CCU/link teardown. In-place retry preserves the pointer. The still job-owned
`rkvdec_ccu` schema and its complete reader/writer surface are hard-frozen for
the later coherent CCU/link/power migration.

1. Embed and initialize `rk_mpp_activation` in the current job.
2. Move generation, absolute deadline, selected hardware, and exact
   session-dispatch identity into it. CCU/DCHS/link and power ownership remain
   later coherent migrations.
3. Change the hardware slot from job to activation in one reviewable commit,
   keeping adapter helpers for old callers.
4. Route IRQ, timeout, fault, abort, close, remove and shutdown to one transition
   engine.
5. Make retry allocate a new attempt/generation; make quarantine transfer
   resources into a tombstone; and require `RECLAIMABLE` before embedded reuse.
6. Delete duplicate terminal tails only after source audit proves every trigger
   reaches the engine.

Design the activation for rkvdec2 retry and group recovery from the beginning;
do not prove a simplified type on rkvenc2 and then add bypass fields for CCU.

Acceptance: generation-replacement and pairwise reason-arbitration KUnit tests,
DCHS and slice cases, CCU retry tests, session-dispatch abort/reset races,
fault/timeout/abort races under KASAN+KCSAN+lockdep, and hardware recovery with
no job/power/import/callback counter leak. Forced stop/reset failure must retain
the expected tombstone and dispatch lease rather than reporting a false leak-free
success.

### Phase 4 — split RGA task execution from the whole job

1. Embed `rk_rga_task_exec` and move selected hardware, mappings, MMU table,
   command allocation, userptr sync state, timing, generation and IRQ status.
2. Give every async edge an execution reference plus generation cookie and add
   the `RETIRED` to `RECLAIMABLE` drain boundary.
3. Change the hardware slot to an execution pointer.
4. Make one retirement engine destroy or quarantine the execution and return
   one result to the job orchestrator.
5. Let only the orchestrator advance `current_task`, create retries/fallbacks,
   complete the job, and
   signal the release fence.
6. **Ownership complete; type cleanup remains:** import capabilities are split
   from device/domain execution maps and mapping work no longer runs under the
   global import lock. A later `rk_rga_exec_map` extraction can make the
   already-correct lifetime structural.
7. Model direct and staged execution maps, including copy-in/copyback ownership,
   without yet selecting the RGA2 1 MiB staging implementation.
8. Encapsulate acquire callbacks in `rk_rga_acquire_set` without changing their
   zero-crossing protocol.

Acceptance: multi-task success and every-task-position failure through IRQ,
timeout, fault, cancel, close and unbind; RGA3-to-RGA2 fallback; userptr
head/tail copyback; mapping failure at each allocation point; acquire abort at
each callback-arming point; immediate IRQ after doorbell; delayed old-generation
IRQ/timeout/fault after a successor starts; and zero live map/pin/fence/job
counters after each run. Quarantine-injection cases instead require an exact,
accounted tombstone whose resources remain pinned until isolation proof or reboot.

### Phase 5 — make validation and emission one-way

- Introduce the MPP builder/seal boundary and reject every post-seal write.
- Introduce `rk_rga_task_plan`; convert one measured copy/scale/convert profile
  end to end before broad feature families.
- Convert emitters by semantic family and delete raw-task access as each family
  moves.
- Replace the temporary start funnels with owner-specific MPP activation and RGA
  execution `publish_and_start()` operations.
- Add independently specified golden command/register expectations and the
  byte-exact forward-port differential.

Acceptance: no MPP backend receives a mutable register image; no RGA emitter
receives `struct rga_req`; source audit rejects both regressions. The open
byte-exact FBC/AFBC and real-hardware geometry questions remain hardware gates,
not conclusions inferred from a new type. Immediate-completion injection must
prove an IRQ cannot observe an unpublished image, unarmed timeout, or stale slot.

### Phase 6 — split files and rationalize tests

Only now split translation units by the owners that actually emerged. Move the
embedded KUnit blocks in pure code-motion commits and verify unchanged named
case manifests and source-audit signal counts. Then remove shadow fields,
temporary adapters, duplicate helpers, stale lock comments, and consumer-named
tests that exercise the same normalized recipe.

This phase is intentionally later than the retrospective's counterfactual
“split tests first” advice. In a fresh rewrite, early separation is cheaper. In
this existing 40,000-plus-line implementation, a large move before the object
boundaries settle would increase conflicts and obscure the ownership diffs the
refactor is meant to review.

### Phase 7 — qualify before resuming feature work

Run the complete production-readiness ladder in
[`rewrite-validation-plan.md`](rewrite-validation-plan.md): both kernel bases,
KUnit, public-ABI conformance, differential pixels/bitstreams, recovery matrix,
hostile lifecycle tests, KASAN/KCSAN/lockdep, performance, and soak. Keep AV1
DMA-retirement, hard CCU, gated-clock MMIO, and byte-exact compressed-layout
questions explicitly gated until board evidence closes them.

## Source-audit rules worth making mechanical

Extend the existing source audit so these become build/repository failures:

- MPP `reset_control_*` outside the reset-domain implementation;
- MPP CCU member walks or coordinator `run_lock` outside cluster code, and
  cluster-power-lease fields outside typed lease helpers;
- MPP active-slot assignment outside activation helpers;
- MPP session-dispatch lease mutation outside scheduler/activation helpers;
- MPP reset success followed by re-admission without a recorded refresh,
  power-cycle proof, or isolation outcome;
- writes through an MPP sealed-image pointer;
- MPP or RGA start/doorbell MMIO outside `publish_and_start()`;
- active-object state, terminal-reason, or generation mutation outside slot and
  transition helpers;
- RGA active-slot assignment outside task-execution helpers;
- RGA execution mapping or command cleanup from the whole-job destructor;
- activation or task-execution reinitialization before `RECLAIMABLE`;
- teardown of DMA-reachable mappings, commands, imports, power, or dispatch
  leases from a quarantined object without a stop/isolation proof;
- RGA `current_task++` outside the job orchestrator;
- an RGA emitter accepting `struct rga_req` or reading raw request flags; and
- fence callbacks pointing directly at a broad job after acquire-set migration.

Text search is not a formal proof, but it is an inexpensive guard against the
exact missed-twin class. Keep the allowlist small enough that a reviewer can
read every exception.

## Latent-risk map

| Risk area | Evidence boundary on 2026-08-01 | Owner that should absorb it | Gate before moving on |
|---|---|---|---|
| sibling reset/deassert and gated-register MMIO | measured wedge fixed by domain lock; hard-IRQ architecture remains a residual concern | reset domain + cluster + IRQ-safe register lease | repeated two-core reset contention and UART/ramoops-clean recovery |
| decoder self-reset and missing IOMMU refresh twins | hardware semantics measured; five software reset paths found without refresh; exact restore need remains hardware-sensitive | cluster recovery + DMA group reset effect | counters correlate reset effects to refresh/isolation; post-error decode remains correct |
| CCU/DCHS power and retirement twins | several fixed call-site omissions; member-core group power now has one refcounted lease, but that lease and coordinator power still attach to legacy jobs | cluster power lease + activation | soft/hard CCU retry/abort/remove matrix, DCHS multi-core stress |
| same-session RKVDEC overlap | ordered overlap still corrupted kernel #8; current narrow fix holds a session token through hardware retirement | session pointer now names exact embedded activation storage; retained activation/quarantine ownership remains later | exact-tip H.26x red/green loop, reset-session race, and independent-session dual-core proof |
| post-validation MPP register writes | RCB instance fixed; recurrence is structurally possible while image stays mutable | sealed image owned by activation | source gate: no post-seal writer; byte-exact oracle |
| RGA multi-task recovery | one omission fixed by a common helper; current job still mixes task and request lifetime | task execution + job orchestrator | fail each task position through every terminal trigger |
| coherent command publication before START | source defect fixed with an RGA `dma_wmb()`; runtime causality for current corruption remains open | activation/execution `publish_and_start()` | immediate-IRQ injection plus exact-tip RGA3 vpp/overlay red-green replay |
| retry, delayed callback, and quarantine ABA | generation checks exist, but broad job storage and terminal tails still permit ambiguous reuse/retention | refcounted attempt + reason engine + quarantine tombstone | delayed old-generation event matrix and forced unproved-stop retention |
| RGA userptr import serialization and pin budget | source-inspected global-lock window and missing locked-memory accounting | import capability + execution/cached map | concurrent import/release/remove stress and resource-limit tests |
| RGA2 large-segment staging | 1 MiB system-heap mapping exceeds the current SWIOTLB segment policy; implementation remains open | direct/staged execution map owned by task execution | copy-in/copyback fault matrix and exact pixels without a second teardown path |
| RGA validator/emitter geometry or feature mismatch | multiple twin fixes; three compressed-layout questions still need hardware | immutable validated task plan | golden commands plus real small/rotated/compressed pixel cases |
| acquire-fence close/cancel lifetime | current protocol reviewed clean but spans many fields and contexts | acquire set | callback-arm failure matrix, close/cancel/KCSAN stress |

## The first patch stack

A practical first series should stop before touching RGA validation or broad
file layout:

1. add generated writer/terminal/start/dispatch-lease inventories and baseline
   evidence pins, including the exact-tip booted red/green gates;
2. introduce MPP reset-domain operation wrappers with no behavior change;
3. expand the reset-domain object and migrate every direct reset writer;
4. construct cluster membership and expose read-only topology diagnostics;
5. introduce a refcounted cluster power lease and remove the job's powered-core
   array;
6. funnel CCU arm/START and running-list/link ownership through cluster
   methods without changing admission;
7. return reset effects and require DMA-group refresh/isolation before
   re-admission;
8. add the IRQ-safe reset/register epoch check;
9. funnel the existing session-dispatch token and every START write through
   typed owner helpers;
10. embed `rk_mpp_activation` and move generation/deadline/lease state;
11. convert the active slot, reason arbitration, and terminal triggers;
11. add fresh-attempt retry, `RECLAIMABLE`, and quarantine tombstones;
12. consolidate retirement and remove the old paths;
13. run and record the full MPP object/refcount plus board recovery gate; and
14. only then start the analogous RGA task-execution series.

Each numbered item may need several commits, but no commit should combine a
new object, a behavior fix, and broad code motion. When migration exposes a
latent defect, first add a reproducing test or counter, land the narrow fix,
then resume the ownership move. That keeps `git bisect` capable of distinguishing
an architecture regression from a newly discovered pre-existing bug.

## Definition of done

The ownership refactor is complete when all of these are true:

- every shared MPP reset, CCU power, recovery, IOMMU refresh, and quarantine
  transition has one object owner;
- every RKVDEC scheduler dispatch holds exactly one typed session lease until
  safe retirement or transfers it to quarantine;
- each MPP hardware slot contains one activation, and every terminal trigger
  reaches its single transition engine;
- each RGA hardware slot contains one task execution, while the job owns only
  whole-request sequencing, result, and fences;
- each retry/fallback creates a fresh monotonic attempt, and no activation or
  execution storage is reused before `RECLAIMABLE`;
- terminal reasons use the documented merge/snapshot/precedence policy, with no
  clean result able to hide stronger fault evidence;
- unproved stop/isolation transfers all DMA-reachable resources to an accounted
  quarantine tombstone instead of freeing them;
- buffer identity/pinning is independent of a selected RGA device mapping;
- RGA execution maps structurally represent direct versus staged ownership and
  copy-in/copyback obligations;
- no RGA global registry lock is held across page pinning or map construction;
- MPP submission consumes a sealed image and RGA emission consumes a validated
  plan;
- every backend publishes the exact active generation and complete image through
  one barrier-correct `publish_and_start()` operation before its doorbell;
- source-audit rules reject direct writers and raw-representation leaks;
- temporary mirror fields and adapters are gone;
- both rewrite branches remain mechanically replayed and byte-compared; and
- the complete hardware validation plan passes with no unexplained reset,
  mapping, power, callback, job, or fence counter delta.

This does not claim that better objects can replace hardware evidence. Their
value is narrower and important: they reduce the number of places where a
future hardware discovery or recovery fix must be applied from many similar
paths to one responsible owner.
