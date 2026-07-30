# Forward-port MPP/RGA WARN/oops audit: 18 defects found and fixed

> Scope: the forward-port kernel drivers (`drivers/video/rockchip/mpp/`,
> `drivers/video/rockchip/rga3/`) plus the Rockchip/VSI IOMMU providers.
> Source: `../kernel/linux-6.18-rkvenc-av1-fwport`, branch `rk3588-video-6.18`,
> audited at `12a7da02bea83` (mainline `v6.18` + patches `0001`–`0075`);
> fixes at `febed97bc4597`, `4dba1f42ab2b7`, `b7883d72b7467`, `c10074f4474e0`,
> exported as [`0076`–`0079`](../kernel-drivers/patches/forward-port-rk3588/README.md).
> Date: 2026-07-29
> Trust: **SOURCE-INSPECTED** / **COMPILE-VERIFIED** (fixes) /
> **FIX-COMPILE-VERIFIED** — no runtime gate has been run against any fix.

## Result

A systematic audit for code that can produce a kernel **WARNING or oops** found
**18 distinct defects**, all now fixed in four patches. Twelve are reachable by
any process that can open `/dev/mpp_service` or `/dev/rga` — on this board that
group includes the gdm greeter — and five of those are unprivileged kernel-heap
corruption rather than a mere splat.

The audit deliberately started from the class that panicked this board on
2026-07-29 ([ISR fault-handler
panic](2026-07-29-mpp-isr-fault-handler-clear-sleeps-panics-idle-task.md)):
a sleeping call reached from atomic context. **That specific defect is not in
this tree** — see [Negative results](#negative-results) — but the same shape
turned up once more in `rkvenc_run()`, and the hunt surfaced the rest.

### Fixed: user-reachable memory corruption

| # | Defect | Where | Consequence |
|---|---|---|---|
| 1 | `mpp_check_req()` clamped an over-long request to the **overflow amount** (`req_off + size - max_size`) instead of the space left (`max_size - req_off`). At `req_off == max_size` the clamp is an identity. `req_off` was also a signed `int`, so an offset ≥ `0x80000000` went negative and passed every bound. | `mpp_common.c` | `copy_from_user()` of an attacker-chosen length past a `kzalloc`'d task; and an MMIO walk far past the register ioremap |
| 2 | `mpp_translate_reg_offset_info()` did `reg[elem[i].index] += offset` with `index` a raw user `u32`. Existing hardening bounds the element *count*, never the index. | `mpp_common.c` | arbitrary-add primitive anywhere in a 16 GiB window above `task->reg[]` |
| 3 | `mpp_translate_reg_address()` indexed `mpp->var->trans_info[]` with a format read straight out of a user-written register word. `RKVDEC_GET_FORMAT()` masks to 10 bits; `rkvdec_v2_trans[]` has **4** entries. | `mpp_common.c` | ~16 KiB OOB read returning a garbage table pointer that is then dereferenced |
| 4 | The same function used `session->trans_table[]` entries as register indexes. `MPP_CMD_INIT_TRANS_TABLE` validates only the byte count, so each `u16` is arbitrary. | `mpp_common.c` | OOB read **and write** up to 256 KiB past `task->reg[]` |
| 5 | `req_over_class()`/`rkvenc_update_req()` computed `offset + size - 4` in `u32`. A wrapped end still passes, then makes `e < s`, so `e - s + 4` underflows to ~4 GiB. Both call sites discarded the return value. | `mpp_rkvenc2.c` | `copy_from_user()` of ~4 GiB into a `base_e - base_s + 4` byte allocation |
| 6 | Encoder per-class buffers (as small as `0x5c` bytes) were indexed by `trans_info[fmt]` entries and by `fmt` itself without bounds. | `mpp_rkvenc2.c` | OOB read/write on a small heap object |
| 7 | `rga_alloc_virt_addr()` never checked the computed buffer size. `rga_image_size_cal()` returns a negative errno for an unsupported format and `memory_parm->size` is an unvalidated `u32`; the value lands in an `unsigned long` and becomes a `memcpy()` length. The existing `!count` guard misses it because `img_size + offset` promotes to `size_t` and wraps back to a plausible page count for any page offset above 14. | `rga_mm.c` | `memcpy()` of ~2⁶⁴ bytes; both sibling import paths already had the `<= 0` check |

### Fixed: use-after-free and lifetime defects

| # | Defect | Where | Consequence |
|---|---|---|---|
| 8 | `MPP_CMD_RESET_SESSION` destroyed `session->dma` and published the NULL outside `srv->session_lock`. The **world-readable** (0444) procfs `sessions-summary` walks the session list under exactly that lock and then takes `session->dma->list_mutex`. | `mpp_common.c` | mutex taken in freed memory; `mpp_session_deinit()` already unlinks under that lock for this reason |
| 9 | `rga_iommu_intr_fault_handler()` read `scheduler->running_job` and wrote `job->state`/`job->ret` with no lock and no reference, **from the IOMMU hard-IRQ handler**. Every other reader holds `irq_lock`; the isr thread frees the job right after `rga_job_done()` clears it, and the handler's own `soft_reset()` busy-waits up to a millisecond. | `rga_iommu.c` | UAF **write** into a `kfree`'d job |
| 10 | `mpp_dma_release_buffer()` cleared `sgt`/`attach`/`dmabuf` *after* `dma_buf_detach()` freed the scatterlist. `mpp_dma_buf_sync()` reads `buffer->sgt` unlocked and dereferences `sgt->sgl` unconditionally, from the task worker and the IRQ completion path. | `mpp_iommu.c` | walk of a freed sg table |
| 11 | `rga_mm_release_buffer()` dropped a session's import reference but left `buffer->session` set. Handles are global and neither getter nor releaser checks ownership, so a session could import, let another session's job take a reference, release its own, then on close hit the "refcount == 1 means the last reference is mine" branch. | `rga_mm.c` | buffer freed under a still-running job |
| 12 | `rga_request_submit()`'s `err_put_current_mm` path read and cleared `request->current_mm` with **no lock**, while the completion path does the same under `request->lock` — as do three other sites. | `rga_job.c` | both drop the same `mm_struct` reference, tearing down the address space of a live process |
| 13 | `rga_request_manager_show()` snapshotted `task_list` under the lock, released it, then looped to the **live** `request->task_count` over the **stale** pointer. `rga_request_config()` swaps that list and frees the old one. | `rga_debugger.c` | walk of freed memory with a bound describing a different array |

### Fixed: WARN, atomic-context and wild-pointer defects

| # | Defect | Where | Consequence |
|---|---|---|---|
| 14 | `rkvenc_run()` called `mpp_clk_safe_disable()`/`_enable()` inside the `preempt_disable()` window opened by `mpp_task_run_begin()`. Those reach `clk_prepare_enable()`, which takes the clk framework's `prepare_lock` **mutex**. | `mpp_rkvenc2.c` | "BUG: sleeping function called from invalid context"; real "scheduling while atomic" when contended. Same shape as the 07-29 panic. VEPU510 (RK3576) only, not RK3588 |
| 15 | `rkvdec2_hard_ccu_resend_tasks()` had `WARN_ON(!tbl)` on an empty `unused_list` — which is the ordinary state of a saturated pipeline, for a condition the next line already handles. | `mpp_rkvdec2_link.c` | splat, and a reboot on `panic_on_warn`. HARD-CCU only; this board's DT is soft-CCU |
| 16 | `mpp_iommu_reserve_iova()`/`_unreserve_iova()` cast `domain->iova_cookie` to a private shadow struct after testing only non-NULL. In 6.18 that member is a **union arm** discriminated by `domain->cookie_type`. | `mpp_iommu.c` | an MSI cookie / fault handler / iommufd page table would be walked and mutated as an rb-tree. Latent: a normal DMA domain really is `IOMMU_COOKIE_DMA_IOVA` |
| 17 | Four debugfs write handlers did `buf[len - 1] = '\0'` after only rejecting `len > sizeof(buf) - 1`. `write(fd, "", 0)` reaches `->write` with count 0. | `rga_debugger.c` | one-byte stack OOB write at `buf[-1]`; root-only |
| 18 | The userptr path called `pfn_to_page()` on a PFN from `follow_pfnmap_start()`, which is reached precisely for `VM_PFNMAP`/`VM_IO` ranges where there is frequently no `struct page`. The result goes to `sg_alloc_table_from_pages()` and is DMA-mapped. One error arm also skipped `follow_pfnmap_end()`. | `rga_mm.c` | wild `struct page *` from a vmemmap hole into a DMA-mapped scatterlist |

Defects 2, 5, 16, 10 and 18 are the previously catalogued D01–D05 in
the vendor-driver latent-defect catalogue (private `rock-5b-security` repository),
analyzed 2026-07-27 with proposed fixes and never applied. They are now fixed.

## The fixes

Four commits on `rk3588-video-6.18`, exported as patches `0076`–`0079`:

| Patch | Commit | Covers |
|---|---|---|
| `0076` | `febed97bc4597` | defects 1–4, 8 (MPP core) |
| `0077` | `4dba1f42ab2b7` | defects 16, 10 (MPP IOMMU) |
| `0078` | `b7883d72b7467` | defects 5, 6, 14, 15 (codec drivers) |
| `0079` | `c10074f4474e0` | defects 9, 7, 11, 12, 13, 17, 18 (RGA) |

Two structural changes are worth calling out because they are more than a
bounds check:

- **`struct mpp_dev_var` gained `trans_count`**, set from `ARRAY_SIZE()` in all
  14 `.trans_info =` initialisers, plus a new checked accessor
  `mpp_get_trans_info()`. Nothing previously carried the array length, so *no*
  caller could have bounded the format index correctly.
- **`mpp_translate_reg_address()` and `mpp_translate_reg_offset_info()` now take
  a register count.** Callers pass `ARRAY_SIZE(task->reg)` (rkvdec2) or the
  per-class allocation size (rkvenc2, av1dec), which differ by two orders of
  magnitude — the encoder's `CLASS_BASE` buffer is 23 registers against the
  decoder's 360.

Deliberately *not* changed: `rga_mm_force_releaser_buffer()` still frees in
place under `mm->lock`. The kref release callback drops that lock mid-iteration,
which previously wedged session teardown in an unkillable D state with a KASAN
UAF on a freed `task_struct`; defect 11 is closed by correcting the ownership
test instead.

## Boundary

**Every fix is compile-verified only.** `make W=1` over
`drivers/video/rockchip/` is clean (0 warnings, 26 objects) and the four
patches replay from `12a7da02bea83` to a byte-identical tree, but **no fix has
been booted, and no reproducer has been run for any defect** — pre-fix or
post-fix. The reachability arguments are traced from source, not observed on
silicon.

Three fixes change behaviour in ways a runtime gate must confirm:

- The `mpp_check_req()` rewrite makes previously-accepted requests fail. Normal
  decode stays far inside the bounds, but a userspace library that relied on the
  old sloppy clamp would now get `-EINVAL`.
- Holding `irq_lock` across `rga_iommu_intr_fault_handler()` extends a hard-IRQ
  critical section over `soft_reset()`'s ~1 ms busy-wait. That was already true
  of the timeout path, but it is now also true on the fault path.
- `rga_request_manager_show()` holds `request->lock` across up to 256
  `seq_printf()` groups. `seq_printf()` does not sleep, but the section is long.

Defect coverage is bounded by what source inspection can reach. The RGA
register builders were swept exhaustively and are clean, but `rga_policy.c`,
`rga_hw_config.c` and the DT were only spot-checked.

## Known-open defects, not fixed here

Recorded so they are not re-derived. None is fixed; each has a stated reason.

| Defect | Why not fixed now |
|---|---|
| `job->task_list` is a **borrowed pointer** into `request->task_list`; `rga_job_done()` clears `running_job` before `rga_mm_unmap_job_info()` and `rga2_read_back_reg()` dereference it, so a concurrent `close()` can free the request first. CONFIRMED UAF (a write, in the OSD read-back). | The fix (`kmemdup` the list into the job) changes ownership semantics and severs the OSD `cur_flags` write-back channel. Deserves its own patch and review. |
| `mpp_iommu_handle()` reads `mpp->cur_task` and walks `task->mem_region_list` from hard IRQ with no lock or reference. PLAUSIBLE. | Its candidate fix takes `dev_lock` inside the fault handler, which interacts with the quiescence question below — the two proposed fixes impose **opposite** lock orders. Must be designed together. |
| Clearing a provider fault handler has **no quiescence**: `rk_iommu_call_fault_handler()` snapshots the handler, drops `fault_lock`, then invokes it, so a handler can still be running after `set_fault_handler(NULL)` returns. PLAUSIBLE, unbind/rmmod window only. | Same conflict. Note the 07-29 panic was caused by a *sleeping* quiescence tail; any fix must stay atomic-safe on the clear path. |
| `rga_drv_remove()` leaves a `devm`-freed scheduler in `rga_drvdata->scheduler[]`, which the 1 Hz hrtimer keeps dereferencing from hard IRQ. CONFIRMED. | Root-only sysfs unbind; `CONFIG_ROCKCHIP_MULTI_RGA=y` means no module unload. |
| `rga_init()`'s error unwind never calls `misc_deregister()` and leaves `rga_drvdata` dangling rather than NULL. CONFIRMED. | Reachable only if `rga_dma_buf_pool_init()` fails at late_initcall. |
| `rga_ioctl()` dereferences `scheduler[0]` when no core probed. | Not reachable on this board; `/dev/rga` exists unconditionally, so it matters for a DT where RGA is absent. |
| `rga_policy.c` indexes `data->win[2]` without consulting `data->win_size`, which is 2 for `rga2p_lite_1103b_data`. | RV1103B only; not this SoC. |
| `mpp_attach_workqueue()` re-assigns `core_id` on collision *after* the bounds check, so a fifth device on one taskqueue writes `queue->cores[4]`. | Needs ≥5 devices on one `rockchip,taskqueue-node`; this DT has at most 2. |
| `rkvenc_alloc_task()` publishes the `0x5c`-byte `CLASS_BASE` buffer as `mpp_task->reg`, which `mpp_task_dump_reg()` walks as `reg[160..253]`. | Gated behind the `DEBUG_DUMP_ERR_REG` debug bit; KASAN-reportable rather than a guaranteed oops. |
| `rga_mm_unmap_channel_job_buffer()` `kfree()`s without NULLing, unlike its two siblings. | No second call could be proven — every call site claims the job under `irq_lock` first. |
| RGA2 `palette_mode` is unvalidated and feeds a shift of 4–255. | UB, but arm64 masks the shift; `CONFIG_UBSAN` is off, so no splat. |
| `rga_mm` passes a raw physical address as a DMA handle to `dma_sync_single_for_device()` and syncs a `dma_map_sg()` mapping with `dma_sync_single_*`. | DMA-API contract violations that only splat under `CONFIG_DMA_API_DEBUG`, which `~rk2` turned off. |

<a id="negative-results"></a>

## Negative results

Worth recording because they close open questions.

- **The forward port never carried the sleeping fault-handler tail.**
  `rockchip_iommu_set_fault_handler()` (`drivers/iommu/rockchip-iommu.c:1474`)
  and `vsi_iommu_set_fault_handler()` (`vsi-iommu.c:885`) are plain pointer
  swaps under `fault_lock` — no `platform_get_irq()`, no `synchronize_irq()`.
  The `mpp_dev_irq()` → `mpp_iommu_dev_deactivate()` →
  `mpp_iommu_clear_fault_handler()` chain that panicked the board is
  non-sleeping end to end here. This corroborates the [orig-provenance
  finding](2026-07-29-production-6-18-40-orig-is-rewrite-composite-snapshot.md):
  the bad code reached the *package*, not the branch. This tree also has no
  `rockchip_iommu_sync_fault_handler()` — it never needed one, which is why the
  quiescence gap above is open.
- **The RGA register builders are clean.** The `WARN_ON(param == 0)` in
  `rga2_scale_down_bilinear_protect()` was brute-forced over the entire legal
  RGA2 domain (src 2–8192 × dst 2–8191, both axes, all `sw > dw`): **0 WARNs,
  0 non-terminations, max 342 iterations.** It fires only for a zero
  destination extent, which `rga2_check_param()` rejects before the builder
  runs. Every division and table index in `rga2_reg_info.c`/`rga3_reg_info.c`
  is likewise blocked by the `check_param` minima.
- **No sleeping call in any hard-IRQ or IOMMU fault handler**, beyond defect 14.
  All MPP IRQ registrations are primary handlers with `thread_fn == NULL`; their
  call graphs contain only MMIO, `udelay`, `printk`, `kfifo`, `wake_up`,
  `kthread_queue_work`, `spin_lock_irqsave` and the atomic-safe
  `pm_runtime_get_if_in_use()`/`clk_bulk_enable()` provider helpers.
  RGA's `soft_reset` busy-waits with `udelay(1)` only.
- **The tree is compiler-clean.** `make W=1` over the driver directory produces
  zero warnings across 26 objects, and no function has a stack frame above
  1024 bytes (largest: `rga2_init_reg`, 576 B).
- **The shared RGA3/IOMMU IRQ line is correctly declared.** `rga3_core0` and
  `rga3_0_mmu` share `GIC_SPI 114` and both register `IRQF_SHARED`; RGA uses
  `devm_ioremap()` rather than `devm_ioremap_resource()`, so the overlapping
  `reg` windows do not collide.

## Verification gate

The smallest run that would close this: build a `forward-port-debug` kernel from
`c10074f4474e0` with KASAN plus `CONFIG_DEBUG_ATOMIC_SLEEP` and `lockdep`, boot
it, and run the existing MPP/RGA conformance set
([runbook](../kernel-drivers/docs/kernel-validation-runbook.md)) with a clean
journal — proving the bounds changes did not break ordinary decode/encode/blit.

Targeted probes worth writing, each requiring a disposable boot:

| Probe | Expected post-fix |
|---|---|
| `MPP_CMD_SET_REG_ADDR_OFFSET` with `index = 0xFFFFFFFF` | `-EINVAL`, taint 0 |
| `MPP_CMD_SET_REG_WRITE` at `offset = sizeof(task->reg)`, `size = 0x10000` | clamped to 0, taint 0 |
| `MPP_CMD_SET_REG_WRITE` at `offset = 0x80000000` | `-EINVAL`, taint 0 |
| A decoder register word with `fmt = 1023` | `-EINVAL`, taint 0 |
| `MPP_CMD_INIT_TRANS_TABLE` with `{0xFFFF}` then any blit | `-EINVAL`, taint 0 |
| `MPP_CMD_SET_REG_WRITE` with `offset = base_s + 0x40`, `size = 0xFFFFFFC0` | `-EINVAL`, taint 0 |
| `RGA_IOC_IMPORT_BUFFER` with an unsupported format and page offset ≥ 15 | clean `-EINVAL`, taint 0 |
| `mmap()` of `/dev/mem` passed to RGA as a userptr | `RGA_OUT_OF_RESOURCES`, taint 0 |
| `write(debugfs_fd, "", 0)` on `rkrga/debug` | `-EINVAL`, taint 0 |
| RESET_SESSION loop against `cat /proc/mpp_service/sessions-summary` | no KASAN report |

## Why it matters

Five of these are unprivileged kernel-heap corruption reachable through the
same device node the desktop session already holds open, the same class as
[W19](../status.md#watch-w19). Defects 1–6 and 9–13 are **BSP-inherited** — the
broken code is Rockchip's, not the forward port's.
Defect 16 is `PORT`-class (a 6.18 union that the BSP's older headers did not
have), and defect 14 is BSP code that only a non-RK3588 part reaches.

The audit also gives the vendor-driver latent-defect catalogue (private
`rock-5b-security` repository)
catalog its resolution: all five entries are fixed, and the "checked and found
correct" table there remains valid.
