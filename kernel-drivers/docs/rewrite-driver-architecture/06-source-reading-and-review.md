# Source reading, review checklist, and glossary

[← Observability and testing](05-observability-and-testing.md) ·
[Guide home](README.md)

## 10. A practical source-reading order

The sources are large because implementation and KUnit tests share one
translation unit. Read by concepts rather than top to bottom. The symbol order
below describes the as-built model, not the proposed object names in the
ownership refactor. Before a pin-specific review, select the exact tree through
the [rewrite evidence owner](../rewrite-drivers.md#6-status--citable-location)
or [source map](../../../docs/source-trees.md#8-rewrite-driver-tree) and verify
that these symbols still delimit the same responsibilities.

### 10.1 MPP

1. Read the top-level structures:
   `rk_mpp_service`, `rk_mpp_session`, `rk_mpp_job`, `rk_mpp_hw`,
   `rk_mpp_import`, `rk_mpp_reset_domain`, `rk_mpp_dma_group`, and
   `rk_mpp_backend_ops`.
2. Read `rk_mpp_init()`, `rk_mpp_hw_probe()`, `rk_mpp_open()`.
3. Follow one ioctl:
   `rk_mpp_ioctl()` -> `rk_mpp_collect_msgs()` ->
   `rk_mpp_process_request()`.
4. Follow job construction:
   `rk_mpp_job_add_request()` -> register storage/translation ->
   `rk_mpp_job_submit()`.
5. Follow execution:
   `rk_mpp_scheduler_work()` -> backend `submit()`.
6. Follow one normal completion:
   backend hard IRQ -> backend IRQ thread -> `rk_mpp_job_complete()` ->
   `rk_mpp_session_poll_job()`.
7. Read timeout/fault recovery and then platform remove.
8. Read permanent DMA isolation last; it makes more sense after normal
   ownership is clear.

### 10.2 RGA

1. Read `rk_rga_service`, `rk_rga_session`, `rk_rga_request`, `rk_rga_job`,
   `rk_rga_import`, `rk_rga_job_mapping`, and `rk_rga_hw`. Notice that the
   whole job still carries fields for its current task execution.
2. Read `rk_rga_init()`, `rk_rga_hw_probe()`, `rk_rga_open()`.
3. Follow legacy `rk_rga_ioctl_blit()` first because it creates one task.
4. Then read request create/config/submit to see snapshot ownership.
5. Read import preparation and image-layout/provenance validation.
6. Follow `rk_rga_job_submit()` through acquire/release fence handling.
7. Follow `rk_rga_job_queue()` -> core selection -> `rk_rga_hw_dispatch()` ->
   `rk_rga_backend_start()`.
8. Read one RGA2 and one RGA3 validator/emitter.
9. Follow hard IRQ -> IRQ thread -> mapping clear -> task advance/completion.
10. Finish with timeout/fault recovery, close, and hardware remove.

After tracing the current types, read the
[as-built/target comparison](04-design-lessons.md#61-as-built-strengths-and-remaining-ownership-debt)
and then the [ownership-refactor plan](../rewrite-ownership-refactor-plan.md).
Searching the implementation for `rk_mpp_cluster` now finds topology plus the
hard-CCU group-reset validator/owner and member-core power lease. Searching for
`rk_mpp_activation` now finds the Phase 3A embedded current-attempt
generation/deadline record, not an activation-typed slot or transition engine.
`rk_rga_task_exec` and `rk_rga_acquire_set` should still return no definitions;
cluster admission, coordinator-power ownership, retained MPP retirement, and
complete reset/IOMMU recovery consumers should likewise remain absent until
their separate checkpoints land.

Use `rg` to navigate by symbol:

```bash
rg -n 'rk_mpp_job_submit|rk_mpp_hw_recover_active|rk_mpp_hw_remove' \
  drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c

rg -n 'rk_rga_job_submit|rk_rga_hw_dispatch|rk_rga_hw_recover_active' \
  drivers/video/rockchip/rga-rewrite/rga_rewrite.c
```

---

## 11. Questions to ask during review

For every new ioctl or feature:

1. Are all userspace counts and sizes bounded before allocation/copy?
2. Does checked arithmetic cover every size and address calculation?
3. Is all asynchronous input copied into kernel-owned memory?
4. Which object owns each buffer, fence, job, and hardware reference?
5. Is the selected DMA device fixed before mapping?
6. Can file-descriptor reuse defeat cache identity?
7. Is command emission complete before the start/doorbell write?
8. Can IRQ, timeout, close, fault, and remove all race for completion?
9. What atomic claim makes exactly one of them the winner?
10. Can stale delayed work affect a replacement job?
11. Is DMA stopped before mappings or command buffers are freed?
12. What happens if reset itself fails?
13. Does remove block admission before it drains?
14. Does remove wait for references before devres frees MMIO/IRQ state?
15. Is completion signaled only after cache sync and copyback?
16. Are lock order and callback context documented?
17. Is the error path covered by KUnit or fault injection?
18. Is there an observable counter proving the intended path ran?

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
| **quarantine** | Permanently stop routing work to hardware after unsafe recovery |
| **generation** | Monotonic activation identity used to reject stale callbacks |
| **provenance** | The actual backing object/range behind a submitted address or handle |
| **terminal isolation** | Fail-closed proof that a failed engine can no longer DMA |

---

## 13. The mental model to keep

For both drivers, reduce the architecture to this invariant:

```text
No untrusted request reaches hardware until it is copied, bounded, resolved,
retained, and validated.

No asynchronous path dereferences an object without a reference and a lock or
published-state rule.

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
[Guide home](README.md)
