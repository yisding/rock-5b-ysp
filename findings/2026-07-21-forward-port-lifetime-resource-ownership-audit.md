# Forward-port MPP/RGA lifetime and resource-ownership audit

> Scope: RK3588 vendor MPP, RKVDEC2, RKVENC2, AV1, and RGA3 drivers in the
> Linux 6.18 forward-port series through `0054`; resource ownership during
> submit, completion, reset, close, probe failure, and remove/unbind.
> Source: forward tree `linux-6.18-rkvenc-av1-fwport@e4c9b62669526` and the
> tracked [`forward-port-rk3588-av1`](../kernel-drivers/patches/forward-port-rk3588-av1/README.md)
> series, compared directly with Rockchip BSP `develop-6.1@b4ef083dc0c3` and
> `develop-6.6@1ba51b059f25`.
> Date: 2026-07-21
> Trust: **CODE-INSPECTED** / **SOURCE-INSPECTED** / **INFERRED** for
> schedule-dependent impact; previously captured KASAN failures are linked and
> retain their own **MEASURED** tags.

## Result

The current forward-port driver still has at least three high-confidence paths
to a use-after-free that were not in the existing crash ledger:

1. RGA's global `RGA_IOC_RELEASE_BUFFER` can consume the reference held by an
   in-flight job and free the job's buffer and DMA mapping underneath it.
2. Two MPP result waiters can receive the same unreferenced task pointer; the
   first waiter can free the task while the second is still using it.
3. MPP embeds delayed timeout work in the task, schedules it without a task
   reference, cancels it non-synchronously in IRQ context, and can free the
   task while the callback is still executing.

All three are inherited from the Rockchip BSP. The audit also found two
important forward-port cleanup regressions:

- patches `0053`/`0054` prevent the inherited device-less-task NULL
  dereferences by dropping the task, but `mpp_free_task()` cannot invoke a
  concrete backend destructor once the device is gone. The allocation and its
  dma-buf/register assets are leaked, and an orphan already on the running list
  is never retired.
- patch `0040` correctly replaced the BSP's RGA session-close force-free UAF
  with a `kref_put()`, but the underlying object has only one `session` owner
  field despite global cross-session de-duplication. Duplicate and
  cross-session import references can now survive without any session able to
  reclaim them.

The broad attribution is therefore not "the port created a defective driver."
Most lifetime defects are byte-equivalent or semantically unchanged BSP code
that the port made reachable on 6.18. The clear forward-port-introduced
exceptions in this audit are the `0053`/`0054` destructorless orphan cleanup,
the persistent leak shape created by `0040` on top of a BSP ownership model,
the VSI callback synchronization contract, and a conditional shared-domain
remove failure. The previously measured RKVENC post-free read fixed by `0043`
is also ours; the other measured crashes in the table below are BSP defects.

This was a static ownership audit. No driver fixes were made and none of the
new race schedules was exercised on hardware. A code-confirmed ownership
violation is not labeled **MEASURED** until its targeted KASAN/fault-injection
gate has run.

## Source states and attribution method

There are several deployed or recorded forward-port states. The findings below
are against the latest tracked source, not necessarily the package currently
running on a board.

| State on 2026-07-21 | Effective tail | Relevance |
|---|---:|---|
| Published forward-port PPA | `0041@df0d7037213c3` | Does not contain the known `0042` reset or `0043` encoder fixes. |
| Recorded local 20260720 package | `0043@655d178191807` | Built locally; not the current tracked tail. |
| Later debug-kernel record | through `0052@c46bfd6622ba6` | `0052` was built; its targeted booted cross-session gate remained pending in the finding. |
| Current tracked source | `0054@e4c9b62669526` | Audit baseline. A clean package rebuild and complete booted gate are still pending. |

Patch `0001` is a wholesale vendor import, so ordinary `git blame` makes BSP
lines look locally authored. Attribution here instead compares the exact
function bodies with both pinned BSP branches:

- **BSP** — the deficient logic exists in the donor.
- **forward port** — the donor lacks it and a local commit introduced it.
- **mixed** — the BSP supplied the root ownership flaw, while a local API,
  resource type, or remediation changed the failure mode or expanded impact.
- **not carried** — a BSP-private path is absent from this port.

Evidence strength is independent of provenance. **CODE-INSPECTED** means the
reference imbalance or invalid ordering follows from the code;
**INFERRED** means the final crash schedule or hardware effect has not yet been
observed; and **MEASURED** is reserved for a captured runtime result.

Direct comparisons supporting the provenance labels include:

- BSP 6.1 and 6.6 `mpp_common.c` are byte-identical, as are their
  `mpp_iommu.c` files.
- the imported `rga_job.c` is byte-identical to BSP 6.1.
- the imported `rga_mm.c` differs near the top for forward-port adaptation,
  but the global handle, kref, partial-acquisition, and import-unwind bodies
  discussed below are donor code.

## New high-priority lifetime failures

### F1. RGA release can free a buffer owned by an in-flight job

- **Severity:** high
- **Evidence:** code-confirmed ownership violation; UAF/hardware effect inferred
- **Attribution:** **BSP**

`rga_ioctl_release_buffer()` accepts only one or more global numeric handles.
It receives no session identity, accepts duplicate handles, and has no record
of which kind of owner supplied each aggregate kref. `rga_mm_release_buffer()`
looks up the global IDR object and unconditionally calls `kref_put()`.

An async job gets the same `struct rga_internal_buffer` from the IDR in
`rga_mm_get_buffer()`, increments the same kref, and retains a direct pointer
until `rga_mm_put_buffer()`. The last put runs
`rga_mm_kref_release_buffer()`, which removes the IDR entry, unmaps the
backing store, and frees the object.

The failing ownership sequence is:

1. import creates reference 1;
2. an async job takes reference 2 and retains the buffer pointer;
3. userspace releases the handle once, consuming the import reference;
4. the same session releases the handle again, supplies it twice in one
   release array, or another session releases the globally visible handle;
5. that release consumes the job's reference, so the kref callback unmaps and
   frees the object while the job or hardware still uses it;
6. completion dereferences and puts the freed pointer.

Stable anchors are `rga_drv.c:rga_ioctl_release_buffer()`,
`rga_mm.c:rga_mm_release_buffer()`, `rga_mm_get_buffer()`,
`rga_mm_put_buffer()`, and `rga_mm_kref_release_buffer()`. The same global
release contract and aggregate kref are present in both BSPs.

The ownership repair needs a per-session import ledger or per-session import
count associated with the global object. A release must consume only an
outstanding import reference owned by the calling session; it must never
decrement an undifferentiated kref that may belong to a running job. The
runtime gate should repeatedly release a duplicated handle while an async RGA
job is held in flight, under KASAN and refcount diagnostics.

### F2. Concurrent MPP result waiters can share and free one raw task

- **Severity:** high
- **Evidence:** code-confirmed missing ownership reference; race impact inferred
- **Attribution:** **BSP**

`mpp_session_get_pending_task()` selects the first session task under
`pending_lock`, releases the lock, and returns the raw pointer without a
`kref_get()`. `mpp_wait_result_default()` then waits, reads backend results,
and removes the session-list reference. RKVENC2's custom result path follows
the same pattern. The file operations do not serialize two result ioctls on
one session.

Two threads sharing one MPP fd can therefore both fetch the same task. Once
hardware has dropped the queue reference, waiter A can process and pop the
session reference, running the backend destructor and `kfree()`. Waiter B can
then resume in `wait_event`, the backend `result` operation, slice FIFO
handling, logging, or its own list pop with the freed pointer. Besides the UAF,
two RKVENC slice consumers can race the same FIFO.

Patch `0043` fixed a narrower single-caller post-free read in the custom
RKVENC path. It does not give either generic or custom waiters an ownership
reference and does not close this race. The lookup/wait design is inherited
from the BSP.

The repair is either an exclusive per-session result-consumer lock or a real
waiter kref acquired under `pending_lock` and released after all result access,
combined with a once-only task removal rule. The gate should use two threads
issuing poll/blocking result ioctls through the same fd, with completion timing
varied under KASAN and refcount debugging.

### F3. Embedded MPP timeout work can outlive and use the task

- **Severity:** high
- **Evidence:** high-confidence, schedule-dependent UAF
- **Attribution:** **BSP**

`struct mpp_task` embeds `timeout_work`. `mpp_task_run_begin()` schedules it
without taking a task reference. The normal hard-IRQ path wins the
`TASK_STATE_HANDLE` bit and calls non-synchronous
`cancel_delayed_work()`. If the callback has already started, cancellation
returns false but completion continues.

A concrete interleaving is:

1. the timeout callback starts, derives `task` with `container_of()`, and is
   preempted before or during its state/session accesses;
2. the IRQ wins logical completion and its non-sync cancel cannot stop the
   running callback;
3. the IRQ queues the device worker; completion wakes userspace and drops the
   queue reference;
4. a waiter drops the final session reference;
5. AV1, RKVDEC2, or RKVENC2 backend `free_task()` finalizes and directly
   `kfree()`s the containing task;
6. the timeout callback resumes and touches the freed task, or the workqueue
   core completes bookkeeping on an embedded work item whose storage is gone.

The task state bit arbitrates which path handles logical completion. It does
not pin the storage containing the delayed work. Stable anchors are
`mpp_common.c:mpp_task_timeout_work()`, `mpp_task_run_begin()`,
`mpp_dev_irq()`, `mpp_task_finish()`, and the three backend `free_task()`
implementations. The schedule, non-sync cancellation, and direct-free design
are unchanged BSP code.

A safe design needs a delayed-work-owned task kref, or a process-context
`cancel_delayed_work_sync()` before any path can drop the last task reference.
It must not attempt synchronous cancellation from hard IRQ context.

### F4. The `0053`/`0054` orphan path reaches zero refs without a destructor

- **Severity:** high leak/wedge for the crash-recovery path
- **Evidence:** code-confirmed
- **Attribution:** **forward port** remediation regression; the guarded NULL
  dereferences themselves are **BSP**

Patches `0053` and `0054` make a device-less task disposable from the async
worker and synchronous waiter. `mpp_taskqueue_pop_pending()` is allowed to
drop the queue reference even when no device is recoverable, and
`mpp_free_task()` skips `mpp->dev_ops->free_task()` when `mpp == NULL`.

That backend callback is not optional bookkeeping: the AV1, RKVDEC2, and
RKVENC2 implementations are the only paths that finalize task allocations and
call `kfree()`. When the final kref reaches zero without `mpp`, the concrete
task, register storage, imported dma-buf references, and per-task regions are
left allocated. If the orphan has already reached the running list,
`try_process_running_task()` only skips it, retaining the queue reference and
potentially wedging teardown indefinitely.

The inherited bug was the unchecked device dereference. The resource leak is
ours because `0053`/`0054` introduced the device-less pop/free behavior without
preserving immutable backend/destructor identity in the task. A robust repair
should store a type-stable destructor or owning backend identity at allocation
time, then define one explicit orphan-retirement path that removes every list
ownership reference and runs finalization exactly once.

### F5. Patch `0040` converts a BSP force-free UAF into unmatched RGA refs

- **Severity:** high for long-running/restarting workloads
- **Evidence:** code-confirmed permanent asset leak
- **Attribution:** **mixed** — BSP ownership model; forward-port leak shape

RGA de-duplicates external buffers globally. Re-importing the same backing
object increments its kref and returns the existing handle, even across
sessions, but the object stores only one `internal_buffer->session` pointer:
the first importer.

Patch `0040` correctly stopped close from force-freeing that object while a
different session or job still holds a reference. Its replacement cleanup
visits only objects whose one owner pointer matches the closing session,
drops one ref, and clears that owner pointer if references survive.

This makes the following leak deterministic:

1. session A imports X; refcount is 1 and owner is A;
2. A imports X again, or session B imports X; refcount is 2 but owner is still A;
3. B's close finds no object it owns;
4. A's close clears the only owner field and drops one reference;
5. the remaining import reference has no session that can discover and retire
   it, so the IDR entry, dma-buf, attachment, SG/DMA mapping, and IOVA survive.

The original BSP one-owner/global-de-dup model caused the already documented
session-close force-free UAF. Patch `0040` is the right immediate safety move,
but one pointer cannot account for aggregate krefs. The complete repair is the
same per-session import ledger needed by F1.

### F6. Repeated static MPP translations outlive a freed session container

- **Severity:** high resource leak and stale ownership state
- **Evidence:** code-confirmed
- **Attribution:** **BSP**

`MPP_CMD_TRANS_FD_TO_IOVA` imports with `static_use=1`. Repeating a translation
for an existing fd increments the embedded buffer's kref. The object occurs
only once in `static_list`, so `mpp_dma_session_destroy()` drops exactly one
reference and then unconditionally frees the parent `mpp_dma_session`.

With a duplicate reference still held, the child's release callback does not
run: its dma-buf ref, attachment, SG mapping, and IOMMU mapping remain live.
The child is embedded in the freed parent and its `buffer->dma` backpointer is
stale, so there is no safe later owner capable of completing cleanup. This is
not merely a session-bounded leak.

Static lookup should either return a borrowed mapping without taking another
caller reference, or destruction must force every embedded slot through a
deterministic unmap/detach path before freeing the parent.

### F7. PFNMAP fallback DMA-maps pages it does not own

- **Severity:** high if the fallback is used
- **Evidence:** ownership gap code-confirmed; final stale-DMA effect inferred
- **Attribution:** **mixed** — BSP ownership flaw, forward-port API adaptation

When GUP fails or is partial, RGA walks a PFN-mapped VMA, converts each PFN
with `pfn_to_page()`, constructs an SG table, and retains a DMA/IOMMU mapping
for asynchronous use. The forward port adapted the private BSP page-table walk
to `follow_pfnmap_start()`/`follow_pfnmap_end()`, but neither version takes a
page reference, pins the backing object, registers an MMU notifier, or defines
an invalidation contract.

The path holds the `mm_struct`, which preserves the address-space object but
does not stop another thread from `munmap()`ing the VMA or releasing its
device/file allocation. Cleanup confirms the gap: only the positive GUP result
count is put, while fallback pages have no reference to release.

The path should be restricted to an import API with an explicit backing-store
lifetime, or acquire an enforceable page/backing reference and invalidation
mechanism. `mmgrab()`/`mmget()` alone are insufficient.

### F8. RCB pages are freed before their IOMMU mapping is removed

- **Severity:** high under remove/unbind concurrency
- **Evidence:** invalid teardown ordering code-confirmed; reachability-dependent
  impact inferred
- **Attribution:** **BSP**

Both RKVDEC2 and RKVENC2 allocate RCB pages and map them at fixed IOVAs. Their
free helpers call `__free_pages()` before `iommu_unmap()`, and their remove
paths invoke RCB teardown before `mpp_dev_remove()`. The generic remove path
does not first drain tasks, work, timeout callbacks, IRQ threads, or hardware.

This returns pages to the allocator while the IOVA still maps them. Reuse can
therefore overlap DMA through the stale mapping; active hardware can write into
memory already allocated to another owner. The safe order is: block new
submissions, drain work/IRQs/hardware, unmap the IOVA, then free pages and
release reservations.

## Other newly identified ownership and teardown defects

| ID | Finding and stable anchors | Consequence | Attribution / evidence |
|---|---|---|---|
| F9 | `mpp_dev_remove()` does not drain queues/work/timeouts or clear `srv->sub_devices[]`; service removal leaves existing fds with raw service/device pointers. | Hot-unbind can dereference devm-freed `mpp_dev`, queue, or service state. | **BSP**; high-confidence, conditional UAF. |
| F10 | VSI fault handling snapshots callback/token, unlocks, and calls it; unregistering a handler does not wait for an already snapshotted invocation. | AV1 unbind/fault race can call into devm-freed AV1/MPP state. | **forward port** callback contract combined with BSP's failure to drain/unpublish: **mixed**; inferred race. |
| F11 | `mpp_attach_service()` can publish a core into the live queue, then fail reset-group validation; `mpp_dev_probe()` returns without detaching it. | `queue->cores[]` and `dev_list` retain a pointer after devm frees the device. | **BSP**; code-confirmed error-path UAF. |
| F12 | MPP service starts devm-queue worker threads without checking `kthread_run()` with `IS_ERR()` and does not stop them on several later probe failures. | Live worker can use a freed queue after probe failure; remove can pass an `ERR_PTR` to `kthread_stop()`. | **BSP**; code-confirmed conditional UAF. |
| F13 | `rga_dma_fence_get_fd()` installs a sync-file fd before request/legacy-async copyout; copyout failure does not close the installed fd. | Invisible fd, sync_file, and fence leak; retries can exhaust the process fd table. | **BSP**; code-confirmed. |
| F14 | RGA is `tristate`; exported sync-file fences reference module-static ops and a heap context lock, but holding the sync-file fd does not pin the RGA module/context after `/dev/rga` closes. | A modular/DKMS unload followed by fence poll/close can use freed context or unloaded ops. | **BSP**; high-confidence but inactive in the checked built-in `CONFIG_ROCKCHIP_MULTI_RGA=y` target. |
| F15 | `rga_init()` ignores failures from the memory, request, session, fence-context, and debugger initializers after registering the misc device; exit assumes the managers exist. | Allocation pressure can expose a partially initialized live device and NULL-deref on ioctl/unload. | **BSP**; code-confirmed error path. |
| F16 | A final `MPP_CMD_SET_SESSION_FD` message is neither queued for request cleanup nor returned to the idle pool; `clear_task_msgs()` frees ext-fd messages without `fdput()`. | A target session can retain a file reference to itself, pinning the session, tasks, DMA mappings, and device assets indefinitely. | **BSP**; code-confirmed. |
| F17 | Repeating `MPP_CMD_INIT_CLIENT_TYPE` overwrites `session->dma`/`mpp` and `list_add_tail()`s the same `session_link` again. | Old DMA session leak, list corruption, and old tasks potentially finalized through a different backend/container type. | **BSP**; deterministic ABI misuse. |
| F18 | `mpp_dma_find_buffer_fd()` returns a raw reusable slot after unlocking; release/import take or drop refs later, after the slot may have reached zero and been moved to `unused_list`. | ABA race can release/unmap a newly reused buffer, return the wrong IOVA, or corrupt refs. | **BSP**; high-confidence race. |
| F19 | `RESET_SESSION` waits on `task_count`, but task allocation/import happens before that count is incremented. Patch `0042` clears the destroyed pointer but adds no admission serialization. | Reset can destroy DMA ownership beneath an allocating task, leaving unmapped IOVAs and cleanup through destroyed/NULL state. | **BSP root**, incomplete forward-port remediation; high-confidence race. |
| F20 | Shared-domain unbind can fail to restore a secondary's default domain, retain pointers borrowed from the owner, and return an error; owner teardown ignores the error and clears/frees the shared state. | Later secondary map/reset can use a freed rwsem or stale domain. | **forward port**; medium-confidence because it requires default-domain reattach failure. |
| F21 | A failed `MPP_CMD_TRANS_FD_TO_IOVA` batch or final copyout does not roll back earlier imports. | Unique mappings pin assets and consume the 60-slot session pool until close; duplicate entries feed F6's permanent leak. | **BSP**; code-confirmed. |
| F22 | RGA request creation inserts an IDR request and takes a session ref before copying the ID to userspace; copyout failure does not retire it. | An undisclosed request and session ref remain until close; repeated faults grow the table. | **BSP**; code-confirmed, session-bounded. |

## Previously catalogued defects still open at `0054`

These were corroborated during this audit but are not presented as newly
discovered here.

| Defect | Current consequence | Attribution | Prior evidence / candidate design |
|---|---|---|---|
| AV1 attachment table accepts element 80 of `mem_regions[80]`, while AV1 exposes 103 translations. | The 81st entry overwrites task state, abort flags, delayed work, and later ownership fields; likely subsequent UAF/workqueue/list corruption. | **BSP**; very high confidence. | [`AV1 forward-port review`](../kernel-drivers/av1/docs/av1-bsp-forward-port-review-2026-07-20.md). |
| Custom MPP translation table entries are not class-bounded; AV1 reuses one table for 512-, 166-, and 212-word register banks. | Register-bank OOB read and possible IOVA write. | **BSP**. | Same AV1 review. |
| RGA `rga_mm_get_buffer_info()` failure and multi-plane/top-level acquisition errors do not release all already acquired refs/mappings. | Persistent buffer refs; patches `0050`/`0051` expanded the partial object with page-table DMA and bounce assets. | **BSP root, forward-port-expanded impact**. | `cleanup-split/0059` and `0060` are old design evidence, not directly applicable to the current structures. |
| RGA batch import does not retire handles created before a later import or copyout failure. | Live-session IDR/mapping leak. | **BSP**. | `cleanup-split/0043`. |
| RGA import maps backing storage before `idr_alloc_cyclic()`; IDR failure frees the object without unmapping. | dma-buf attachment, mapping, page-pin, or virtual-map leak. | **BSP**. | `cleanup-split/0062`. |
| RGA acquire-fence get/callback/error paths omit matching fence puts. | dma-fence leaks on successful and failed jobs. | **BSP**. | `cleanup-split/0053`/`0054`. |
| RKVDEC2 link init leaks its coherent table if the following pointer-array allocation fails. | Probe/fault-injection DMA allocation leak. | **BSP**. | `cleanup-split/0015`. |
| RKVENC2 can jump to task free after allocating per-class messages without releasing them. | Per-task allocation leak on extraction failure. | **BSP**. | `cleanup-split/0020`. |
| RGA runtime-PM get is not balanced when clock enable fails during probe. | PM usage-count leak on probe failure. | **BSP**. | `cleanup-split/0048`. |

The 65-patch [`cleanup-split`](../kernel-drivers/patches/cleanup-split/README.md)
series is useful prior analysis and fix design, but it targets an older source
state, has an acknowledged compile failure in patch `0024`, contains later
strengthenings that were not re-reviewed as a whole, and has never passed its
runtime gate. In particular, the MPP DMA reference fix must remain atomic
across lookup and callers, while the old RGA partial-unwind patch no longer
accounts for the `0050`/`0051` page-table and bounce assets. Those patches
should not be applied blindly to `0054`.

## Attribution of the crashes and fixes already observed

This table attributes the defective code, not the tree in which KASAN happened
to expose it.

| Patch / observed issue | Defect origin | Basis |
|---|---|---|
| `0040`: RGA session close force-frees a buffer still referenced by another session or job | **BSP** | Donor close ignored aggregate krefs. The forward fix is local; F5 records the ownership leak it leaves. See the [original finding](./2026-07-17-rga-session-close-uaf.md). |
| `0041`: MPP procfs observes private session state during teardown | **BSP** | Service unlink occurred after private/DMA teardown in donor code. See the [captured Oops](./2026-07-17-mpp-procfs-session-teardown-oops.md). |
| `0042`: `RESET_SESSION` DMA double-free | **BSP** | Donor destroyed `session->dma` without clearing the pointer. See the [KASAN finding](./2026-07-18-mpp-reset-session-dma-double-free-kasan.md). F19 remains after the sequential double-free fix. |
| `0043`: RKVENC wait-result reads `task->state` after final put | **forward port** | Local commit `23ff47eab6f68` added the post-processing read; BSP returned directly. See the [KASAN finding](./2026-07-18-rkvenc2-wait-result-task-uaf-kasan.md). |
| `0052`: RGA request completion races close and double-drops the initial request ref | **BSP** | The same competing retirement puts exist in BSP `rga_job.c`; observation on the port does not make the defect local. See the [KASAN finding](./2026-07-21-rga-request-completion-vs-session-close-uaf-kasan.md). |
| `0053`: async MPP worker NULL-dereferences a device-less task | **BSP** | BSP worker has the same unchecked device dereference. The forward repair introduces F4's destructorless leak. |
| `0054`: synchronous MPP wait-result twin | **BSP** | BSP generic waiter has the same unchecked device dereference. The forward repair shares F4. See the [combined crash record](./2026-07-21-mpp-collect-msgs-clientless-session-null-deref-crash.md). |
| `0051`: transient RGA2 bounce direction and copy-back mistakes found during its gate | **forward port** | They arose in the new over-4G DMA/swiotlb design and were amended within `0051`; donor BSP has no equivalent path. |

## Recommended repair order and proof

Before wider distribution of the current tail:

1. Fix the direct task/buffer lifetime violations: F1 global RGA release,
   F2 concurrent result consumers, F3 timeout-work ownership, and F4 orphan
   task destruction.
2. Fix the deterministic object overwrites and reset/lookup races already open:
   the AV1 80/103 attachment bound, F18 DMA lookup ABA race, and F19 reset
   admission race.
3. Replace RGA's single-owner buffer field with a per-session import ledger,
   closing F1 and F5 together. A local extra `kref_get()` or a conditional
   `kref_put()` will only move the leak/UAF boundary.
4. Drain device activity and exported callbacks before teardown, then reverse
   the RCB mapping/free order (F8–F12). Treat modular fence lifetime separately
   or prohibit the modular configuration until it is owned correctly.
5. Close permanent asset leaks (F6, F7, F13, F16, F21) and then the bounded
   probe/copyout/partial-import unwinds.

Targeted validation should include:

- KASAN, refcount diagnostics, DMA API debugging, IOMMU fault logging, and
  lockdep on the debug kernel;
- duplicate/cross-session RGA handle releases while a real async job remains
  active;
- two generic and two RKVENC custom result consumers sharing one MPP fd;
- forced timeout/IRQ overlap with a deliberately stalled timeout callback;
- device-less pending and running tasks with explicit allocation, dma-buf,
  attachment, and mapping counters checked after close;
- repeated same-fd RGA imports across two sessions and repeated static MPP
  translations, followed by close/reset;
- fault injection at every RGA manager allocation, MPP worker creation, link
  table allocation, IDR allocation, and final `copy_to_user()`;
- platform-driver unbind with active tasks/fences, plus a modular RGA unload
  test if that configuration remains supported.

Every quiet race gate must record that it achieved real async submissions or
the intended failure injection. A run that never enters the ownership window
does not validate the repair.

## Boundary

- The three newly identified UAF schedules and the conditional remove/probe
  failures were not reproduced during this audit. Their code paths and missing
  ownership rules were inspected; final runtime effects remain **INFERRED**.
- Existing KASAN findings remain measured evidence only for their captured
  defect and source tail. They do not prove later patches or adjacent paths are
  safe.
- Line numbers drift between `0053`, `0054`, and the BSPs. Function names and
  pinned commits above are the stable anchors.
- The fixed-DT ROCK 5B workload does not normally hot-unbind built-in MPP/RGA
  components, but probe/remove ownership is still relevant to fault injection,
  module/DKMS configurations, and failed boot probes.
- This audit did not assess functional codec correctness, information leaks,
  or security policy except where they change memory/resource ownership.
