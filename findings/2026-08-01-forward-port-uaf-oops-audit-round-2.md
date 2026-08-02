# Forward-port UAF/oops audit round 2: 18 defects, 7 of them unprivileged memory corruption

> Scope: the forward-port kernel drivers (`drivers/video/rockchip/mpp/`,
> `drivers/video/rockchip/rga3/`) plus the packaged/published kernel.
> Source: `../rock-5b/kernel/linux-6.18-rkvenc-av1-fwport`, branch
> `rk3588-video-6.18`, audited at `14c0456c4108c` (mainline `v6.18` + patches
> `0001`–`0080`); package
> `linux-rockchip64-ysp_6.18.41+rk3588av1fwport20260801-0ubuntu1~rk1`.
> Date: 2026-08-01
> Trust: **SOURCE-INSPECTED** (every defect below re-checked in the tree by the
> author, not only by the finding agent) / **PACKAGE-VERIFIED** (published orig
> tarball) / **FIX-COMPILE-VERIFIED** — the fixes in [Fix](#fix) build clean at
> `W=1` but **nothing has been booted, and no reproducer has been run for any
> defect**, pre-fix or post-fix.

## Result

A second systematic audit, covering ground the
[2026-07-29 audit](2026-07-29-forward-port-warn-oops-audit-and-fixes.md)
did not reach, found **18 further defects**. Seven are unprivileged memory
corruption or a deterministic oops rather than a splat, and **two of those are
single-ioctl, no-race, no-timing** — materially easier to hit than anything in
the July 29 set. Fifteen are now fixed; see [Fix](#fix) for what was
deliberately left open and why.

**Almost all of it is Rockchip's BSP code, not forward-port regression.** The
four worst all trace to `924f4232546df`, the initial vendor import, so Rockchip's
shipping BSP and every downstream vendor kernel built on it carry the same
defects. Two exceptions are ours and are named as such (R7, M1).

### Unprivileged, single ioctl, no race

| # | Defect | Where | Consequence |
|---|---|---|---|
| R1 | `rga_ioctl_import_buffer()` validates the buffer count and array pointer but **never the `type` field**. `RGA_DMA_BUFFER_PTR` (type 3) then casts the user's raw `u64` to a `struct dma_buf *`. `get_dma_buf()` dereferences `dmabuf->file`, `dma_buf_attach()` takes `dmabuf->resv` as a lock and makes an **indirect call through `dmabuf->ops->attach`**. | `rga_drv.c:672-681`, `rga_mm.c:704-714`, `rga_dma_buf.c:560,591-608` | arbitrary kernel-pointer dereference, arbitrary `atomic_long_inc`, controlled indirect call — a local privilege-escalation primitive |
| R2 | `RGA_PHYSICAL_ADDRESS` (type 2) import validates only that each page is linear-mapped RAM (`virt_addr_valid(phys_to_virt(addr))`), which is true of all kernel text, data, heap and page tables. The result is DMA-mapped `DMA_BIDIRECTIONAL` and usable as a blit destination. | `rga_mm.c:397`, `:1049-1076` | attacker-controlled DMA **read and write** of arbitrary kernel RAM |
| M4 | `MPP_CMD_INIT_DRIVER_DATA` does `if (mpp->grf_info->grf)` with no NULL check. Only rkvdec2/rkvenc2 assign `grf_info`; `mpp_av1dec.c` never does and its device struct is `devm_kzalloc`'d. | `mpp_common.c:1470`; cf. `mpp_rkvdec2.c:1224`, `mpp_rkvenc2.c:2561` | NULL deref at address `0x8`; three ioctls, fully deterministic. Live on this board (`CONFIG_ROCKCHIP_MPP_AV1DEC=y`, `av1d` is `status = "okay"` in `rk3588-rock-5b.dtsi:102-121`) |
| E1 | `rkvenc_get_class_reg()` returns `task->reg[i].data + (addr - base_s)` **without checking the class buffer was allocated**. Class buffers are lazily allocated only for classes a register write overlaps. `int_sta_base = 0x2c` lies in CLASS_BASE `[0x0000,0x0058)`, so a task writing only CLASS_PIC leaves the pointer NULL and `rkvenc_finish()`'s `if (reg)` guard passes on the value `0x2c`. | `mpp_rkvenc2.c:932`, `:846-857`, `:2060-2062` | write through `0x2c`. Taken inside `try_process_running_task()`'s `disable_irq()`/`enable_irq()` bracket, and both VEPU580 cores share one taskqueue kthread, so **all hardware encode stops permanently**; `panic_on_oops` makes it a panic |

E1 was independently confirmed in the compiled object: `rkvenc_finish+0x1a4`
tests `(data + off) == 0`, not `data == 0`.

### Unprivileged, racy — use-after-free

| # | Defect | Where | Consequence |
|---|---|---|---|
| R3 | `rga_ioctl_blit()`'s error path calls `rga_request_free()`, the **raw destructor that ignores the kref** (every other retire path uses `rga_request_release_ref()`/`rga_request_put()`), while `rga_request_config()` holds a reference across a sleeping `kmalloc_array` + `copy_from_user`. | `rga_drv.c:971`; `rga_job.c:1247-1257`, `:1550-1565` | UAF write into freed slab, then `kfree()` of a pointer read out of it — an attacker-influenced free; then refcount underflow and cascading double-free |
| A1 | `rkvdec2_soft_ccu_dequeue()` sets `TASK_STATE_HANDLE` unconditionally, calls the **non-sync** `cancel_delayed_work()`, and then frees the task. The non-CCU paths in the same file correctly use `cancel_delayed_work_sync()` (`:1145`, `:1197`, `:1229`). | `mpp_rkvdec2_link.c:1946-1947`, `:1972` | `rkvdec2_ccu_timeout_work` resumes on freed memory: `set_bit()` UAF write, then `atomic_inc()` through a `struct mpp_dev *` re-read from freed memory. **Soft-CCU, i.e. this board** (`rockchip,ccu-mode = <1>`) |
| M1 | `MPP_CMD_SET_SESSION_FD`'s new fd validation was inserted **after** the message-flush that already dropped the previous session's file reference, and the mismatch path does not update `session`. | `mpp_common.c:1761-1779`; `put_task_msgs()` `fdput` at `:320-322` | dangling `session` used for every later message: `copy_from_user` of 160 attacker-chosen bytes into the freed object and an **indirect call through `session->process_task`**. **Forward-port regression** — introduced by `40871595bbd19` (2026-07-22) |
| M2 | `mpp_translate_reg_address()` bounds `tbl[i]` once, then re-reads it twice **after** `mpp_task_attach_fd()` sleeps in a dma-buf import. `session->trans_table` is rewritten from userspace with no lock. | `mpp_common.c:2144` vs `:2171-2172`; writer `:1483` | classic double-fetch: 4-byte store at a freely chosen index up to 256 KiB past `task->reg[]` |
| A3 | `mpp->cur_task` is set in the CCU dispatch path and **never cleared** — there is no `cur_task = NULL` anywhere in `mpp_rkvdec2_link.c`, because the CCU dequeue calls `->finish`, never `->isr`. The IOMMU hard-IRQ handler dereferences it and walks `task->mem_region_list`, whose head lives inside the freed task. | `mpp_rkvdec2_link.c:2257` vs `:2123-2125`; `mpp_common.c:2402-2405` | wild list walk in hard IRQ. Stale **by construction** on this board's dispatch path, not merely unlocked |
| I1 | `mpp_dma_release_fd()` ends in an **unconditional `kref_put()`** with no check that the caller ever acquired a reference, and `MPP_CMD_RELEASE_FD` takes an array of up to 80 fds with no rejection of a repeat. | `mpp_iommu.c:194-221`; `mpp_common.c:1625-1632`; import at `mpp_iommu.c:335-346` | drives a buffer an in-flight task still references to zero: attachment unmapped and IOVA freed **under live DMA**, then the slot is recycled under the task's stale pointer, ending in refcount underflow or an over-`dma_buf_put`. Applies to rkvdec2, rkvenc2 and av1dec alike |
| J1 | (known-open, re-verified and **worse than recorded**) `job->task_list` borrows `request->task_list`; `rga_job_done()` clears `running_job` then walks it. | `rga_job.c:138`, `:264`, `:274`, `:285`; `rga2_reg_info.c:3356`; `rga_mm.c:3141` | UAF write in the OSD read-back. **`RGA_IOC_REQUEST_CANCEL` reaches it in two ioctls with no fd close**, and it is cross-process (see R4) |

### Unprivileged — ownership, leaks, disclosure

| # | Defect | Where | Consequence |
|---|---|---|---|
| R4 | **Request IDs carry no ownership check anywhere.** `rga_request_lookup()` is a bare `idr_find`; `rga_ioctl_request_cancel()` and the config/submit handler are not even passed the session. IDs come from `idr_alloc_cyclic` starting at 1. | `rga_job.c:743`; `rga_drv.c:863`, `:1121-1133` | any `/dev/rga` opener can cancel or reconfigure another process's in-flight request — this is what makes R3 and J1 scriptable rather than self-inflicted |
| R5 | `rga_mm_lookup_external()`'s `RGA_PHYSICAL_ADDRESS` arm matches `temp_buffer->phys_addr == memory` over the **global** idr with no `type` check, and every non-contiguous import stores `phys_addr = 0`. | `rga_mm.c:1266-1274` | importing `{memory=0, type=2}` returns another process's handle with a reference taken — cross-process disclosure and corruption |
| R7 | Patch `0079` cleared `buffer->session` on release to fix a UAF, but the **de-duplicating import path never re-assigns ownership** and session teardown skips any buffer whose session does not match. | `rga_mm.c:3171-3183`, `:3276`, `:3304-3305` | import twice, release once, exit → buffer, pinned pages, IOVA mapping and an `mmget()` reference leak **permanently** (no module-unload path). Unprivileged, repeatable to OOM. **Forward-port regression, in the shipped kernel** |
| M5 | Every error return in `mpp_collect_msgs()` between `get_task_msgs()` and `put_task_msgs()` leaves the msgs object on the busy list, so the next call `kzalloc`s a fresh one. | `mpp_common.c:286-306`, returns at `:1718,1725,1743,1809,1815,1829` | 488 B per failed ioctl, `GFP_KERNEL` **without `__GFP_ACCOUNT`**, so it escapes memcg limits. Superset of known F16 |
| E2 | `rkvenc_dump_session()` prints a user-controlled `u64` with `%8s` — a *width*, not a precision — so `vsnprintf` runs `strlen()` off the end of the 8-byte field. | `mpp_rkvenc2.c:2224-2227`; store at `:2133-2134` | kernel-heap over-read printed into two **0444** procfs files (`sessions-info`, `sessions-summary`) |

### Lower severity / not reachable on this board

- **A4** — a timed-out task is retired and freed without quiescing its core, and
  the reset is deferred while any sibling core is busy
  (`mpp_rkvdec2_link.c:1935`, `:1963`, `:2365-2381`). Supplies the mechanism by
  which A3's fault lands on an "idle" core.
- **A5** — `MPP_FLAGS_REG_FD_NO_TRANS` lets a client put raw IOVAs into decoder
  address registers (`mpp_common.c:1496`, `mpp_rkvdec2.c:391`). BSP design, but
  **this port widened the blast radius**: both decoder IOMMUs now share one CCU
  domain (`mpp_iommu.c:636`), so a raw IOVA reaches every other rkvdec session.
- **A6 / M-remove** — `mpp_dev_remove()` never clears `srv->sub_devices[]`, so
  after a root unbind an unprivileged `MPP_CMD_INIT_CLIENT_TYPE` binds to freed
  memory (`mpp_common.c:2634-2642`). MPP twin of the catalogued
  `rga_drv_remove()` item.
- **A7** — `atomic_set(&queue->reset_request, 0)` discards a request raised
  during the reset (`mpp_rkvdec2_link.c:2038,2045`). Hang class, not oops.
- **E3** — `rkvenc2_set_rcbbuf()` reaches the same NULL-based class write with a
  user-chosen offset (`mpp_rkvenc2.c:1117-1129`). **DT-gated off on RK3588** —
  no `rockchip,rcb-iova` on the encoder nodes, so `sram_iova == 0`.
- **A8** — hard-CCU resend re-initialises a live `delayed_work`
  (`mpp_rkvdec2_link.c:2947`, `:2977`). **Hard-CCU only, DT-unreachable here.**
- **M3** — `MPP_CMD_INIT_CLIENT_TYPE`'s `-EBUSY` re-init guard is not atomic and
  straddles a sleeping 6816-byte allocation, permitting a double
  `list_add_tail` (`mpp_common.c:1435-1440`, `:492`). `CONFIG_DEBUG_LIST` is off.

## Correction to a known-open item: `cur_task` is read by four handlers, not one

The ledger records `mpp_iommu_handle()` as the unlocked hard-IRQ reader of
`mpp->cur_task`. That function is the *fallback* handler, and on this board it
is installed for **av1dec only**. The handlers actually installed for the
decoder and encoder are three further functions with the identical defect, none
previously catalogued: `rkvdec2_soft_ccu_iommu_fault_handle()`
(`mpp_rkvdec2_link.c:2123,2125`) and both arms of `rkvenc2_iommu_fault_handle()`
(`mpp_rkvenc2.c:3501/3507` and `:3519/3524`).

This composes with the missing fault-handler quiescence:
`rk_iommu_call_fault_handler()` snapshots the handler, **drops `fault_lock`**,
and only then invokes it (`rockchip-iommu.c:994-999`; `vsi-iommu.c:207-215` is
the same shape), while `mpp_dev_irq()` retires the handler on every completed
rkvenc2 job. So a callback that raced a completion can still be executing while
the worker frees the task.

**A design that satisfies both conflicting fixes, with no sleeping call on the
clear path** (the 07-29 panic was a sleeping quiescence tail, so this matters):
invoke the handler *inside* the `fault_lock` section rather than after it, which
makes the existing pointer-swap setter its own quiescence barrier; then remove
the inverted `dev_lock → fault_lock` edge by having
`mpp_iommu_dev_activate()`/`_deactivate()` do their provider calls outside
`dev_lock`; then pin the task with `queue->running_lock` — the lock that
actually covers it, and which two of the four handlers already take — rather
than with `dev_lock`. Resulting order is `fault_lock → running_lock`, with no
cycle. Every callback that would now run under `fault_lock` was already
atomic-safe (MMIO, `printk`, atomics, `kthread_queue_work`, `rcu_read_lock`).
**Not implemented here** — it changes provider lock ordering and deserves its
own patch and review cycle.

## The rewrite driver is not exposed to R1/R2

Checked for contrast, because the board is currently booted on the rewrite
kernel: `rk_rga_import_buffer()` accepts only `RGA_DMA_BUFFER` and
`RGA_VIRTUAL_ADDRESS` and returns `-EOPNOTSUPP` for everything else
(`rga-rewrite/rga_rewrite.c:24615-24623`). Neither R1 nor R2 exists there. This
is a real point in the rewrite's favour and worth citing in the
rewrite-vs-forward-port comparison.

## Provenance

`git log -S` on the defining expression puts R1, R2, R3, E1 and M4 all in
`924f4232546df` — the initial vendor import. They are **BSP-inherited**: present
in Rockchip's shipping code and in every downstream vendor kernel built on it,
not created by this port. The exceptions are **M1** (`40871595bbd19`, whose new
fd validation was inserted after the flush) and **R7** (`c10074f4474e0`, patch
`0079`), both ours. **A5**'s shared-domain widening is also ours, though the
underlying flag is BSP.

## Reachability

`/dev/rga` and `/dev/mpp_service` are `crw-rw----` root:video with POSIX ACLs
granting `group:gdm` and `user:gdm-greeter`. So the exposed boundary on this
board is the logged-in user (group `video`) and the **pre-login greeter
account** — not an arbitrary local user. The greeter path is the one that
matters: it is unauthenticated attack surface that runs before anyone logs in.
The 0444 procfs files (E2, and the IOVA/pid disclosure in
`/proc/mpp_service/sessions-summary`) are readable by *any* local user.

## Package state

The published `…20260801` orig is **clean of the provenance contamination** that
caused the 07-29 ISR panic: `drivers/iommu/rockchip-iommu.c` is byte-identical
to the forward-port tree, `rockchip_iommu_set_fault_handler()` is a plain
pointer swap under `fault_lock`, the whole `drivers/video/rockchip/` tree
matches, and the only path matching `rewrite` is an unrelated mainline BPF
selftest. It was built by Launchpad and installed from
`ppa.launchpadcontent.net/yi-ding/ubuntu-rock-5b`, and it carries the audited
code (`ROCKCHIP_MPP_SERVICE`, `MULTI_RGA`, `MPP_AV1DEC` all `=y`).

The owner booted it on 2026-08-01 and reports it functional. That is meaningful
evidence for the `0076`–`0080` bounds and lifetime patches not having regressed
ordinary decode/encode/blit — the main regression risk the July 29 audit
flagged. It is **not** evidence against anything in this document: the config
carries no KASAN, no lockdep, no `DEBUG_ATOMIC_SLEEP` and no `DMA_API_DEBUG`
(only `CONFIG_SLUB_DEBUG=y`, i.e. infrastructure with no poisoning absent
`slub_debug=`), so a UAF would corrupt silently rather than report. The journal
has since rotated past that boot (258 MB used; retained boots reach back only to
15:41 PDT), so no kernel log survives on the board.

## Fix

Five commits on `rk3588-video-6.18`, `14c0456c4108c..78a4d1a903700`. The driver
directories build clean: `make W=1 drivers/video/rockchip/{mpp,rga3}/` gives
**0 warnings, 0 errors**.

| Commit | Covers |
|---|---|
| `a88f4fdfccda5` | M4, M2, M1, M5 (MPP core) |
| `874fbff8ba504` | I1 (`MPP_CMD_RELEASE_FD` refcount authentication) |
| `57585821dcef5` | E1, E2 (encoder) |
| `1b4b65b57e7c2` | A1, A3 (decoder soft-CCU) |
| `78a4d1a903700` | R1, R2, R5, R4, R3, R7 (RGA ioctl boundary and import ownership) |

Two structural changes are worth calling out because they are more than a check:

- **`struct mpp_dma_buffer` gained `static_cnt`.** Nothing previously
  distinguished a reference handed to userspace by `MPP_CMD_TRANS_FD_TO_IOVA`
  from one held by an in-flight task, so no version of `MPP_CMD_RELEASE_FD`
  could have been safe. The pool already separates the two producers via
  `static_use`; the count makes the release path give back only what it took.
- **`struct rga_internal_buffer` gained `import_cnt`.** RGA ownership was a
  single `session` pointer against a multi-reference kref, which is why patch
  `0079` had to choose between a UAF and a leak. Counting import references
  lets ownership drop with the last one instead of the first.

**Deliberately not fixed here**, each for a stated reason: **J1** (the borrowed
`job->task_list`) — the candidate fixes either change ownership semantics or
sever the OSD write-back channel, and R4's ownership check removes the
cross-process reach in the meantime; **A4** (retiring a timed-out task without
quiescing its core) — needs the reset-actor design already open in
[the 08-01 finding](2026-08-01-rkvdec-self-reset-and-iommu-restore-gaps.md);
**the IOMMU quiescence/`cur_task` redesign** above; and the root-only unbind
items (**A6**, `rga_drv_remove()`, `rga_init()`).

## Boundary

- **Nothing here has been booted, reproduced, or compiled with a fix.** Every
  claim is traced from source. Two were additionally checked against compiled
  objects (E1, M2).
- The race-dependent items (R3, A1, M1, M2, M3, J1) are confirmed as *code
  defects* — the object is freed while another path holds or re-reads it, with
  no lock, reference, or handshake. Whether a given attempt wins the race is
  unmeasured.
- R2's cross-process consequence and A4's cross-session DMA consequence are
  reasoned, not observed.
- Coverage is source inspection only. The IOMMU seam (`mpp_iommu.c`,
  `rockchip-iommu.c`, `vsi-iommu.c`) is audited separately and is **not**
  included here. Register-*value* arithmetic in the vdpu383/384a paths, and the
  RGA register builders, were spot-checked only — the latter were swept
  exhaustively by the July 29 audit and remain clean.

## Verification gate

The smallest run that would close the top four: build a `forward-port-debug`
kernel at `14c0456c4108c` with KASAN, `DEBUG_ATOMIC_SLEEP`, `DEBUG_LIST` and
lockdep, boot it, and run each single-ioctl probe below, expecting a clean
`-EINVAL`/`-EOPNOTSUPP` and taint 0 once fixed:

| Probe | Expected post-fix |
|---|---|
| `RGA_IOC_IMPORT_BUFFER` with `type = 3` (`RGA_DMA_BUFFER_PTR`) | `-EOPNOTSUPP`, taint 0 |
| `RGA_IOC_IMPORT_BUFFER` with `type = 2` and a kernel physical address | `-EINVAL`, taint 0 |
| `RGA_IOC_IMPORT_BUFFER` with `{memory = 0, type = 2}` after another process imports a userptr | fresh handle or `-EINVAL`, never the other session's |
| `INIT_CLIENT_TYPE(MPP_DEVICE_AV1DEC)` then `MPP_CMD_INIT_DRIVER_DATA` | `-EINVAL`, taint 0 |
| encoder task writing only CLASS_PIC, then wait for the 500 ms timeout | task fails cleanly, encoder still usable |
| import a buffer twice, release once, exit; read `/sys/kernel/debug/rkrga/mm_session` | no orphaned buffer |
| `cat /proc/mpp_service/rkvenc-core0/sessions-info` after filling `codec_info[]` with 8 non-NUL bytes | no KASAN slab-out-of-bounds |
| `MPP_CMD_TRANS_FD_TO_IOVA` one fd, then `MPP_CMD_RELEASE_FD` with that fd twice | second release `-EINVAL`, decode unaffected, taint 0 |
| decode loop while a second thread spams `MPP_CMD_INIT_TRANS_TABLE` with `{0xFFFF}` | `-EINVAL`, no KASAN report |

Because every fix is compile-only, the **regression** gate matters as much as
the defect gate: the existing MPP matrix, FFmpeg codec suite, librga smoke and
ABI replay from the
[runbook](../kernel-drivers/docs/kernel-validation-runbook.md) must stay green,
since six of the fixes add new rejection paths (`-EOPNOTSUPP`, `-EPERM`,
`-EINVAL`) on ioctls that working userspace exercises.

## Why it matters

Six of these are unprivileged memory corruption reachable through device nodes
the desktop session and the gdm greeter already hold open, and two need no race
at all. The same class as [W19](../status.md#watch-w19). Because the four worst
are BSP-inherited, they are vendor-notification material under the
[disclosure posture](../../rock-5b-security/) — Rockchip PSIRT for the MPP/RGA
core, with no CVE requested — and the two forward-port regressions (M1, R7) are
ours to fix outright. R7 in particular is a live unprivileged OOM path in the
kernel currently published to the PPA.
