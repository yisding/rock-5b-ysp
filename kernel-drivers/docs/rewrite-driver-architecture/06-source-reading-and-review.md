# Source reading, review checklist, and glossary

[← Observability and testing](05-observability-and-testing.md) ·
[Guide home](README.md) · [Next: ownership-refactor case study →](07-ownership-refactor-case-study.md)

## 10. A practical source-reading order

The sources are large because implementation and KUnit tests share one
translation unit. Read by concepts rather than top to bottom. The symbol order
below describes the as-built post-Phase-5 model. Before a pin-specific review,
select the exact tree through
the [rewrite evidence owner](../rewrite-drivers.md#6-status--citable-location)
or [source map](../../../docs/source-trees.md#8-rewrite-driver-tree) and verify
that these symbols still delimit the same responsibilities.

### 10.1 MPP

1. Read the top-level structures:
   `rk_mpp_service`, `rk_mpp_session`, `rk_mpp_job`, `rk_mpp_hw`,
   `rk_mpp_import`, `rk_mpp_reg_builder`, `rk_mpp_reg_image`,
   `rk_mpp_reg_result`, `rk_mpp_activation`,
   `rk_mpp_activation_resources`, `rk_mpp_activation_ref`,
   `rk_mpp_activation_claim_token`,
   `rk_mpp_reset_domain`, `rk_mpp_cluster`, `rk_mpp_dma_group`, and
   `rk_mpp_backend_ops`.
2. Read `rk_mpp_init()`, `rk_mpp_hw_probe()`, `rk_mpp_open()`.
3. Follow one ioctl:
   `rk_mpp_ioctl()` -> `rk_mpp_collect_msgs()` ->
   `rk_mpp_process_request()`.
4. Follow job construction:
   `rk_mpp_job_add_request()` -> register storage/translation ->
   `rk_mpp_reg_builder_seal()` -> const backend validation ->
   `rk_mpp_job_submit()`.
5. Follow execution:
   `rk_mpp_scheduler_work()` -> backend `submit(image)` -> the backend's
   owner-specific `publish_and_start()` helper.
6. Follow one normal completion:
   backend hard IRQ -> backend IRQ thread -> exact activation claim ->
   `rk_mpp_activation_complete_claim()` -> `rk_mpp_job_complete()` ->
   `rk_mpp_session_poll_job()`.
7. Follow `rk_mpp_activation_try_reclaim()` for a retired retry predecessor.
8. Read timeout/fault recovery, quarantine, and then platform remove.
9. Read permanent DMA isolation last; it makes more sense after normal
   ownership is clear.

### 10.2 RGA

1. Read `rk_rga_service`, `rk_rga_session`, `rk_rga_request`, `rk_rga_job`,
   `rk_rga_acquire_set`, `rk_rga_import`, `rk_rga_task_exec`,
   `rk_rga_task_exec_ref`, `rk_rga_task_plan`, `rk_rga_job_mapping`, and
   `rk_rga_hw`. Separate aggregate job fields from one execution's fields.
2. Read `rk_rga_init()`, `rk_rga_hw_probe()`, `rk_rga_open()`.
3. Follow legacy `rk_rga_ioctl_blit()` first because it creates one task.
4. Then read request create/config/submit to see snapshot ownership.
5. Read import preparation and image-layout/provenance validation, keeping
   import capability separate from execution mapping.
6. Follow `rk_rga_job_submit()` through `rk_rga_acquire_set` and release-fence
   handling.
7. Follow `rk_rga_job_queue()` -> core selection -> `rk_rga_hw_dispatch()` ->
   active execution install -> `rk_rga_backend_start()`.
8. Follow execution mapping -> `rk_rga_task_plan_build()` -> one RGA2 and one
   RGA3 plan-consuming emitter -> execution `publish_and_start()`.
9. Follow hard IRQ -> typed `irq_ref` -> exact claim ->
   `rk_rga_task_exec_retire_engine()` -> `rk_rga_hw_finish_job_locked()`.
10. Follow one next-task successor and one same-task fallback to see why they
    allocate new execution storage, then follow `rk_rga_task_exec_try_reclaim()`
    and final job release to see why RGA retains that bounded storage after its
    hardware resources are reclaimable.
11. Finish with timeout/fault recovery, quarantine, close, and hardware remove.

After tracing the current types, read the
[as-built ownership comparison](04-design-lessons.md#61-as-built-ownership-after-the-refactor)
and then the [refactor case study](07-ownership-refactor-case-study.md). Use the
[ownership-refactor plan](../rewrite-ownership-refactor-plan.md) when you need
the implementation checkpoints rather than the teaching narrative.

Searching for these symbol families reveals the ownership seams:

- `rk_mpp_cluster*`, `rk_mpp_reset_domain*`, and `rk_mpp_dma_group*` show how
  shared topology, reset epochs, translation refresh, power leases, and
  terminal isolation remain distinct authorities.
- `rk_mpp_activation*` shows typed reference get/clone/move/put, exact active
  claims, distinct retry successors, closure/quarantine evidence, stable
  terminal arbitration, coherent resource handoff, central completion, and
  reclaim.
- `rk_mpp_reg_builder*` and `rk_mpp_job_sealed_image()` show the one-way
  command boundary; `rk_mpp_reg_result` shows why readback is separate.
- `rk_rga_task_exec*` shows the typed active/IRQ/timeout/fault owners and sole
  execution retirement engine; `rk_rga_hw_finish_job_locked()` is the separate
  whole-job orchestrator.
- `rk_rga_acquire_set*` shows callback/cancel ownership before hardware
  admission, while `rk_rga_task_plan*` and the emitters show immutable semantic
  input after selected-core validation.

Cluster admission, coordinator-power ownership, and further consolidation of
MPP reset/IOMMU recovery policy remain later architecture work. RGA2
large-segment staging and all current-tip runtime qualification remain separate
gates, not exceptions to the completed source ownership model.

Use `rg` to navigate by symbol:

```bash
rg -n 'rk_mpp_reg_builder_seal|rk_mpp_activation_complete_claim|claim_quarantine|rk_mpp_hw_remove' \
  drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c

rg -n 'rk_rga_acquire_set|rk_rga_task_plan_build|rk_rga_task_exec_retire_engine|rk_rga_hw_finish_job_locked' \
  drivers/video/rockchip/rga-rewrite/rga_rewrite.c
```

---

## 11. Questions to ask during review

For every new ioctl or feature:

1. Are all userspace counts and sizes bounded before allocation/copy?
2. Does checked arithmetic cover every size and address calculation?
3. Is all asynchronous input copied into kernel-owned memory?
4. Which lifetime is logical-job state, and which belongs to one activation or
   task execution?
5. Is the selected DMA device fixed before mapping?
6. Can file-descriptor reuse defeat cache identity?
7. Does validation publish a const sealed image or immutable plan, with
   hardware results stored elsewhere?
8. Are active ownership and the exact watchdog generation published before the
   start/doorbell write?
9. Can IRQ, timeout, close, fault, and remove all race for retirement?
10. What typed claim makes exactly one of them the owner?
11. Can stale delayed work affect a replacement activation/execution?
12. Does retry, fallback, or next-task progression allocate distinct storage
    before the predecessor's async owners drain?
13. Is DMA stopped before mappings or command buffers are freed?
14. What happens if reset itself fails—restore, isolate, or quarantine?
15. Does remove block admission before it drains?
16. Does remove wait for references before devres frees MMIO/IRQ state?
17. Is completion signaled only after cache sync and copyback?
18. Are lock order and callback context documented?
19. Is the error path covered by KUnit or fault injection, and does the source
    audit reject a new bypass writer?
20. Is there an observable counter proving the intended path ran?

If any answer is "the global pointer probably still exists," the ownership
model needs more work.

---

## 12. Glossary

| Term | Meaning in these drivers |
|------|--------------------------|
| **ABI/uAPI** | Binary ioctl contract between userspace and kernel |
| **device tree** | Firmware data describing which hardware exists and how its registers, IRQs, clocks, resets, power, and IOMMUs are wired |
| **platform driver** | Kernel driver that binds those device-tree hardware nodes |
| **misc device** | Simple character-device registration used to create `/dev/mpp_service` or `/dev/rga` |
| **probe/remove** | Platform-driver callbacks that acquire/publish a hardware instance and later stop/unpublish it |
| **ioctl** | Device-specific syscall used by a process to send an ABI command |
| **job** | One accepted userspace transaction and its aggregate result; it may contain several physical attempts |
| **activation** | One admitted MPP hardware attempt, including retry-specific resources and terminal evidence |
| **task execution** | One RGA task attempt on one selected core, including mappings, command image, async references, and copyback duty |
| **sealed image / immutable plan** | Validated command representation that production backends may read but no longer mutate |
| **CCU** | Codec coordination unit for multicore scheduling/execution |
| **DCHS** | RKVENC2 dual-core handshake state patched per active encoder job |
| **DMA** | Hardware reading or writing memory directly, independently of CPU loads/stores |
| **DMA-BUF** | Refcounted shared-buffer object represented to userspace by an fd |
| **DMA mapping** | Device-specific translation/cache ownership for a buffer |
| **scatterlist/SG table** | Kernel description of the memory segments backing a DMA mapping |
| **IOMMU** | Translates an IOVA issued by hardware to physical memory |
| **IOVA** | Device-visible virtual address; meaningful only in its DMA/IOMMU context |
| **IDR** | Kernel integer-ID-to-pointer map used for RGA handles/requests |
| **MMIO** | Memory-mapped device registers accessed with `readl`/`writel` |
| **RCB** | Decoder row/column scratch buffer represented by DMA-coherent memory |
| **reference count** | Number of live ownership claims preventing an object from being freed |
| **mutex** | Sleep-capable lock used to serialize longer process/threaded operations |
| **spinlock** | Non-sleeping lock used for short state changes visible to hard IRQ context |
| **runtime PM** | Kernel framework that powers devices on demand |
| **devres/`devm_*`** | Device-managed resource lifetime that automatically releases probe resources after remove has logically drained them |
| **hard IRQ** | Non-sleeping interrupt top half |
| **threaded IRQ** | Sleep-capable interrupt continuation |
| **workqueue** | Process-context execution for deferred scheduling/recovery |
| **KUnit** | Linux in-kernel unit-test framework used for the hardware-independent cases |
| **acquire fence** | Dependency that must complete before this job starts |
| **release fence** | Completion object signaled after this job and memory effects finish |
| **quarantine** | Fail closed after unproved stop/isolation: stop routing and retain the exact execution plus DMA-visible resources instead of pretending cleanup succeeded |
| **generation** | Monotonic attempt identity paired with an object reference to reject stale callbacks |
| **provenance** | The actual backing object/range behind a submitted address or handle |
| **terminal isolation** | Fail-closed proof that a failed engine can no longer DMA |

---

## 13. The mental model to keep

For both drivers, reduce the architecture to this invariant:

```text
No untrusted request reaches hardware until it is copied, bounded, resolved,
retained, and converted into a sealed image or immutable plan.

No asynchronous path dereferences an activation/task execution without a typed
reference, exact generation, and a lock or published-state rule.

No logical job is confused with a replaceable hardware attempt: retry,
fallback, and next-task progression get distinct execution storage.

No completion becomes visible until hardware has stopped using memory and all
required DMA synchronization/copyback has finished.

No teardown frees hardware resources until admission is closed, callbacks are
drained, active work is quiesced or isolated, and references are gone.
```

Those rules are the transferable part of the rewrite drivers. The register
definitions are RK3588-specific; the ownership discipline applies to almost
every kernel driver that performs asynchronous DMA.

---

[← Observability and testing](05-observability-and-testing.md) ·
[Guide home](README.md) · [Next: ownership-refactor case study →](07-ownership-refactor-case-study.md)
