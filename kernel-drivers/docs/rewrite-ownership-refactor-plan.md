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

The plan is based on `linux-6.18-rkvenc` branch `rk3588-rewrite-6.18` at
`8042f13c54591` on 2026-08-01. Function names below are anchors, not line-number
claims. No kernel was changed, compiled, or booted while writing this plan.

## Result

Do not replace the current drivers wholesale. Refactor them around two smaller
runtime units:

- an MPP **activation**, admitted and recovered by an explicit hardware
  cluster; and
- an RGA **task execution**, which owns the selected hardware, mappings,
  command buffer, and one trip through the active slot.

Those objects address the latent-risk areas directly. MPP's reset-domain lock
fixed the measured sibling reset/deassert wedge, but the domain still owns only
a mutex while group power, CCU MMIO, reset results, and IOMMU refresh remain in
different objects and paths. RGA's common recovery tail fixed one multi-task
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
| `rk_mpp_service` | hardware registry, scheduler queue, diagnostics | reset-domain table, DMA groups, DCHS global state, and topology are adjacent but not composed into a cluster owner |
| `rk_mpp_reset_domain` | one lock keyed by CCU node | no members, reset phase/epoch, operation API, or proof that all reset writers pass through it |
| `rk_mpp_dma_group` | IOMMU group, normal/isolation domains, member list, terminal isolation | no refresh epoch or explicit relation to the CCU/reset group whose recovery requires it |
| `rk_mpp_hw` | private MMIO, clocks, IRQ, queue and active slot | also acts as coordinator, reset client, group-recovery participant, timeout owner, and IOMMU-fault owner |
| `rk_mpp_job` | accepted message set, retained imports, selected hardware and result | also carries group power references, CCU membership, mutable register image, slice state, activation timing, and backend recovery state |

The current reset-domain lock is evidence that the object boundary is right,
not that the migration is finished. `rk_mpp_hw_power_on()` and
`rk_mpp_hw_reset_active()` take the domain lock around direct reset-control
calls, while coordinator stop and recovery use additional locks and paths. The
driver can therefore state the invariant only by auditing every caller.

### RGA

| Current object | Useful ownership already present | State that is still at the wrong altitude |
|---|---|---|
| `rk_rga_session` | per-open imports, requests, jobs, close barrier | little should move out; this is already the correct user-ownership boundary |
| `rk_rga_import` | retained buffer identity, provenance, pages and refcount | also carries selected-device mapping state for userptr, coupling a session capability to hardware removal and global import serialization |
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
`job->rkvdec_ccu_powered_cores[]` themselves.

The first migration targets are `rk_mpp_rkvdec2_acquire_soft_ccu()`,
`rk_mpp_rkvdec2_power_on_ccu_cores()`,
`rk_mpp_rkvdec2_program_soft_ccu()`,
`rk_mpp_rkvdec2_start_soft_ccu_job()`, and the CCU job/list helpers. A group
power lease replaces the job's fixed array of powered cores. The lease records
exactly which runtime-PM references were acquired and releases them once,
regardless of completion reason.

### Expand `rk_mpp_reset_domain` from a lock into the reset authority

The existing object should own permission to invoke reset operations even when
the physical `struct reset_control` remains stored on a member core. Add:

- member registration and an immutable domain identity;
- `IDLE`, `POWER_DEASSERT`, `RESETTING`, `FAILED`, and `QUARANTINED` state;
- a monotonically increasing reset epoch;
- the core or cluster responsible for the current operation;
- counters for pulse, deassert, refusal, and overlap detection; and
- methods for power-on deassert, recovery pulse, coordinator stop, and terminal
  isolation.

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
- power and group leases;
- DCHS/CCU/link participation acquired for this run;
- IRQ and fault snapshots associated with the generation;
- `PREPARED`, `PUBLISHED`, `RUNNING`, `RETIRING`, `RETRYING`, `RETIRED`, and
  `QUARANTINED` state; and
- the one terminal result claimed for the activation.

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
  -> release mappings/link/DCHS/power leases
  -> publish job state and wake poll/fence waiters
  -> release hardware and kick the scheduler
```

Backend hooks may read status, stop a core, rebuild a descriptor, or prepare a
retry. They return decisions and hardware facts to the engine; they do not own
the common tail.

This is the right home for the current generation and absolute-deadline fields.
It also replaces the need for each path to remember DCHS release, CCU power
transfer, timeout cancellation, IOMMU refresh, and scheduler wakeup separately.

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

Add a task-execution object, initially embedded in `rk_rga_job` and reused only
after it reaches `RETIRED`. It owns:

- one validated task plan;
- eligible hardware mask and selected `rk_rga_hw` reference;
- every execution map and RGA2 MMU table for that task;
- command allocation and immutable emitted image;
- userptr device/CPU synchronization and copyback obligation;
- power reference, active generation, timeout deadline, IRQ/fault status and
  measured hardware time; and
- one transition from active to retired.

Change `rk_rga_hw::active_job` to `active_exec`. Then
`rk_rga_hw_finish_job_locked()`, `rk_rga_hw_recover_active()`, timeout, IOMMU
fault, session abort, and remove all claim and retire an execution. Only the
job orchestrator handles the result:

```text
execution retired successfully
  -> destroy execution resources
  -> advance current_task
  -> build/select/queue next execution

execution retired with failure
  -> destroy execution resources
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

## One transition engine per active object

MPP activation and RGA task execution should follow the same rule even if they
do not share C code:

1. a small slot lock protects only pointer, generation, IRQ snapshot, and claim;
2. the winning trigger records a reason and moves the object to `RETIRING`;
3. a sleepable engine owns stop/reset/refresh and all slow teardown;
4. the engine publishes exactly one retry, final result, or quarantine; and
5. object destruction happens only after callbacks, worker references, and the
   active slot are gone.

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
| cluster transition mutex | CCU admission, group power, group recovery | only cluster methods take it; no ioctl parser or emitter does |
| hardware run mutex | one core's sleepable start/retire operation | never substitutes for a cluster/reset-domain invariant |
| reset-domain mutex | reset-control operations and reset state | innermost sleepable leaf; no allocation or callbacks |
| active-slot spinlock | active pointer, generation, claim and status snapshot | bounded; no MMIO requiring clocks to stay live unless the IRQ-safe register lease is held |
| IRQ raw lock | a bounded registers-live/aux-MMIO lease | no allocation, callback, refcount destructor, or unbounded loop |
| import/map mutex | one import or cached-map registry | never held across page pinning or a whole candidate map build |

This table is a target to validate with lockdep, not permission to mechanically
nest every row. If hardware forces a reverse acquisition, change the object
API so one owner hands off state rather than adding an exception comment.

## Refactor sequence

Every step below is a sequence of small commits. Feature additions are frozen
from phase 1 until the ownership and hardware gates for phase 5 pass.

### Phase 0 — freeze a source-bound baseline

- Pin the exact 6.18 and mainline rewrite tips and prove the tracked driver,
  UAPI, ABI, Kconfig, and test manifests are byte-identical where intended.
- Record build, KUnit, boot, normal workload, reset-contention, recovery, and
  differential-oracle results separately. A known failure is acceptable if it
  is named; an unrecorded baseline is not.
- Generate inventories of every direct reset-control call, active-slot write,
  power-reference field, IOMMU refresh/isolation call, MPP terminal entry, RGA
  task-advance call, command-buffer writer, and raw-task emitter.
- Freeze the expected debug counters and event fields used by hardware gates.

Acceptance: the same immutable source archive reproduces both builds and every
known baseline result has an evidence path.

### Phase 1 — create write funnels without changing behavior

- Wrap every MPP reset call in a reset-domain operation, even while the wrapper
  initially delegates to the current implementation.
- Put active-slot reads/writes behind typed helpers for both drivers.
- Put MPP power lease acquisition/release, IOMMU refresh/isolation, and RGA
  execution-map teardown behind singular APIs.
- Add assertions that old fields and new embedded-object views agree. Keep the
  assertions until the last old-field user is removed.

Acceptance: source-audit allowlists show no direct writer outside the owning
module/section; compiled behavior and hardware counters are unchanged.

### Phase 2 — make MPP reset and cluster ownership real

1. Expand `rk_mpp_reset_domain` with members, state and epoch.
2. Construct `rk_mpp_cluster` during topology validation and attach cores,
   coordinator, reset domain and DMA groups.
3. Replace `job->rkvdec_ccu_powered_cores[]` with a cluster power lease.
4. Move CCU arm/start, job-list/link ownership and group admission into cluster
   methods.
5. Move software reset, hardware self-reset classification, IOMMU refresh and
   quarantine into one cluster recovery result.
6. Make hard IRQ respect the IRQ-safe reset/register lease and leave all slow
   work to the thread.

Acceptance requires more than KUnit: repeat the reset-contention gate with both
cores resetting; normal single- and multi-stream decode; kill/close/reset
stress; timeout and IOMMU-fault injection; suspend refusal; unbind/rebind; and
clean ramoops/dmesg. `iommu_refresh_count` must agree with the reset effects the
new owner reports, including the paths that previously reset without refresh.

### Phase 3 — migrate MPP active lifetime and retirement

1. Embed and initialize `rk_mpp_activation` in the current job.
2. Move generation, absolute deadline, selected hardware, CCU/DCHS/link and
   power leases into it.
3. Change the hardware slot from job to activation in one reviewable commit,
   keeping adapter helpers for old callers.
4. Route IRQ, timeout, fault, abort, close, remove and shutdown to one transition
   engine.
5. Delete duplicate terminal tails only after source audit proves every trigger
   reaches the engine.

Design the activation for rkvdec2 retry and group recovery from the beginning;
do not prove a simplified type on rkvenc2 and then add bypass fields for CCU.

Acceptance: generation-replacement KUnit tests, DCHS and slice cases, CCU retry
tests, fault/timeout/abort races under KASAN+KCSAN+lockdep, and hardware recovery
with no job/power/import/callback counter leak.

### Phase 4 — split RGA task execution from the whole job

1. Embed `rk_rga_task_exec` and move selected hardware, mappings, MMU table,
   command allocation, userptr sync state, timing, generation and IRQ status.
2. Change the hardware slot to an execution pointer.
3. Make one retirement engine destroy the execution and return one result to
   the job orchestrator.
4. Let only the orchestrator advance `current_task`, complete the job, and
   signal the release fence.
5. Split import capabilities from device/domain execution maps and shorten the
   global import-lock window.
6. Encapsulate acquire callbacks in `rk_rga_acquire_set` without changing their
   zero-crossing protocol.

Acceptance: multi-task success and every-task-position failure through IRQ,
timeout, fault, cancel, close and unbind; RGA3-to-RGA2 fallback; userptr
head/tail copyback; mapping failure at each allocation point; acquire abort at
each callback-arming point; and zero live map/pin/fence/job counters after each
run.

### Phase 5 — make validation and emission one-way

- Introduce the MPP builder/seal boundary and reject every post-seal write.
- Introduce `rk_rga_task_plan`; convert one measured copy/scale/convert profile
  end to end before broad feature families.
- Convert emitters by semantic family and delete raw-task access as each family
  moves.
- Add independently specified golden command/register expectations and the
  byte-exact forward-port differential.

Acceptance: no MPP backend receives a mutable register image; no RGA emitter
receives `struct rga_req`; source audit rejects both regressions. The open
byte-exact FBC/AFBC and real-hardware geometry questions remain hardware gates,
not conclusions inferred from a new type.

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
- MPP CCU member walks, coordinator `run_lock`, or group power arrays outside
  cluster code;
- MPP active-slot assignment outside activation helpers;
- MPP reset success followed by re-admission without a recorded refresh,
  power-cycle proof, or isolation outcome;
- writes through an MPP sealed-image pointer;
- RGA active-slot assignment outside task-execution helpers;
- RGA execution mapping or command cleanup from the whole-job destructor;
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
| CCU/DCHS power and retirement twins | several fixed call-site omissions and group power carried by each job | cluster power lease + activation | soft/hard CCU retry/abort/remove matrix, DCHS multi-core stress |
| post-validation MPP register writes | RCB instance fixed; recurrence is structurally possible while image stays mutable | sealed image owned by activation | source gate: no post-seal writer; byte-exact oracle |
| RGA multi-task recovery | one omission fixed by a common helper; current job still mixes task and request lifetime | task execution + job orchestrator | fail each task position through every terminal trigger |
| RGA userptr import serialization and pin budget | source-inspected global-lock window and missing locked-memory accounting | import capability + execution/cached map | concurrent import/release/remove stress and resource-limit tests |
| RGA validator/emitter geometry or feature mismatch | multiple twin fixes; three compressed-layout questions still need hardware | immutable validated task plan | golden commands plus real small/rotated/compressed pixel cases |
| acquire-fence close/cancel lifetime | current protocol reviewed clean but spans many fields and contexts | acquire set | callback-arm failure matrix, close/cancel/KCSAN stress |

## The first patch stack

A practical first series should stop before touching RGA validation or broad
file layout:

1. add generated writer/terminal-path inventories and baseline evidence pins;
2. introduce MPP reset-domain operation wrappers with no behavior change;
3. expand the reset-domain object and migrate every direct reset writer;
4. construct cluster membership and expose read-only topology diagnostics;
5. introduce a refcounted cluster power lease and remove the job's powered-core
   array;
6. return reset effects and require DMA-group refresh/isolation before
   re-admission;
7. add the IRQ-safe reset/register epoch check;
8. embed `rk_mpp_activation` and move generation/deadline/lease state;
9. convert the active slot and terminal triggers;
10. consolidate retirement and remove the old paths;
11. run and record the full MPP object/refcount plus board recovery gate; and
12. only then start the analogous RGA task-execution series.

Each numbered item may need several commits, but no commit should combine a
new object, a behavior fix, and broad code motion. When migration exposes a
latent defect, first add a reproducing test or counter, land the narrow fix,
then resume the ownership move. That keeps `git bisect` capable of distinguishing
an architecture regression from a newly discovered pre-existing bug.

## Definition of done

The ownership refactor is complete when all of these are true:

- every shared MPP reset, CCU power, recovery, IOMMU refresh, and quarantine
  transition has one object owner;
- each MPP hardware slot contains one activation, and every terminal trigger
  reaches its single transition engine;
- each RGA hardware slot contains one task execution, while the job owns only
  whole-request sequencing, result, and fences;
- buffer identity/pinning is independent of a selected RGA device mapping;
- no RGA global registry lock is held across page pinning or map construction;
- MPP submission consumes a sealed image and RGA emission consumes a validated
  plan;
- source-audit rules reject direct writers and raw-representation leaks;
- temporary mirror fields and adapters are gone;
- both rewrite branches remain mechanically replayed and byte-compared; and
- the complete hardware validation plan passes with no unexplained reset,
  mapping, power, callback, job, or fence counter delta.

This does not claim that better objects can replace hardware evidence. Their
value is narrower and important: they reduce the number of places where a
future hardware discovery or recovery fix must be applied from many similar
paths to one responsible owner.
