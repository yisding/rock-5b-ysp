# KASAN caught the preflight Oops: MPP_CMD_RESET_SESSION double-frees session->dma

> Scope: ROCK 5B on the exact 6.18.38 forward-port stack rebuilt with generic
> inline KASAN + lockdep + built-in ramoops (`P712f-C40aa`,
> `6.18.38-current-rockchip64`)
> Source: run `20260718-054814-kasan-narrowed` under
> `/home/yi/Code/rock-5b/build/rockchip-conformance/logs/forward-port/`; narrowed
> ABI-replay → one-shot `/proc/mpp_service` snapshot reproduction
> Date: 2026-07-18
> Trust: MEASURED (full symbolized KASAN report) / CODE-INSPECTED (root cause and
> fix site) / CONFIRMED (allocation, free, and use stacks all name the same site)

## Result

The narrowed reproduction fired a **KASAN slab-use-after-free on the first
pass**, during the ABI-replay session churn — before the procfs snapshot, not
during it. This overturns the leading inference of the
[preflight-Oops finding](./2026-07-17-forward-port-conformance-preflight-oops.md):
the crash is not a `/proc/mpp_service` read race and is not an incomplete
variant of patch `0041`. It is a plain **double-free of `session->dma`** caused
by `MPP_CMD_RESET_SESSION` failing to clear the pointer after destroying the
object.

Because KASAN's report handler here is `__asan_report_load8_noabort`, the box
did **not** panic or reboot (same `boot_id` before and after, `/sys/fs/pstore`
empty). The full allocation/free/use stacks reached the live kernel log, which
is exactly the evidence the ordinary kernel could not produce.

## The trace

```text
BUG: KASAN: slab-use-after-free in __mutex_lock+0xcf0/0x10b0
Read of size 8 at addr ffff00012621dad8 by task mpp_worker_9/108
CPU: 1 ... Comm: mpp_worker_9 ... 6.18.38-current-rockchip64 #21
Call trace:
  __mutex_lock+0xcf0/0x10b0
  mutex_lock_nested
  mpp_dma_session_destroy+0x48/0x278        ← re-locks dma->list_mutex on freed dma
  mpp_session_deinit_default+0x10c/0x2d8
  mpp_session_deinit+0x1b8/0x750
  mpp_session_cleanup_detach+0x264/0x5a8
  rkvdec2_soft_ccu_worker+0x1404/0x2910     ← async worker, later than the ioctl
  kthread_worker_fn / kthread / ret_from_fork
```

The object is `kmalloc-8k` (the `struct mpp_dma_session`). Both the allocation
and the free happen in the same syscalling task (6951); the use is on the
rkvdec2 worker kthread:

```text
Allocated by task 6951:
  mpp_dma_session_create+0x50/0x378
  mpp_process_request  ...  mpp_dev_ioctl  ...  __arm64_sys_ioctl   (MPP_CMD_INIT_CLIENT_TYPE)

Freed by task 6951:
  kfree+0x2bc/0x5e0
  mpp_dma_session_destroy+0x1fc/0x278
  mpp_process_request+0x136c/0x1ff0
  mpp_dev_ioctl  ...  __arm64_sys_ioctl                             (MPP_CMD_RESET_SESSION)
```

## Root cause

`MPP_CMD_RESET_SESSION` in `mpp_process_request()`
(`drivers/video/rockchip/mpp/mpp_common.c:1414`) destroys the DMA session but
leaves the dangling pointer in place:

```c
mpp_iommu_down_write(mpp->iommu_info);
ret = mpp_dma_session_destroy(session->dma);   /* kfree(dma) inside */
mpp_iommu_up_write(mpp->iommu_info);
return ret;                                     /* session->dma still points at freed memory */
```

`mpp_dma_session_destroy()` (`mpp_iommu.c:348`) ends in `kfree(dma)`. It does
not, and cannot, NULL the caller's `session->dma`. Every **other** destroy site
clears the pointer immediately afterward:

- `mpp_session_deinit_default()` — `mpp_common.c:420`: `session->dma = NULL;`
- `rkvdec2_link` teardown — `mpp_rkvdec2_link.c:1511`: `session->dma = NULL;`

The reset path is the only one that does not. So after a session issues
`MPP_CMD_RESET_SESSION`, its later teardown — here the deferred
`rkvdec2_soft_ccu_worker` → `mpp_session_cleanup_detach` →
`mpp_session_deinit_default` — sees a non-NULL `session->dma`, calls
`mpp_dma_session_destroy()` a second time, and faults taking
`mutex_lock(&dma->list_mutex)` on the freed object.

The ABI probe reaches this deterministically: `abi-probe.c:460` issues
`MPP_CMD_RESET_SESSION` on the live MPP session, then closes it, and the async
rkvdec2 worker performs the second destroy.

## Attribution boundary

This is a distinct defect from the two session-lifetime fixes already in this
kernel. Patch `0040` is the RGA session-close reference-lifetime fix; patch
`0041` unlinks MPP sessions from procfs visibility before private teardown.
Neither touches the reset-session destroy path, and the trace never enters
procfs or RGA code. The earlier `rkvenc_dump_session()` NULL-deref
([finding](./2026-07-17-mpp-procfs-session-teardown-oops.md)) is also unrelated:
that was a proc reader racing encoder close; this is a self-inflicted
double-free with no reader involved.

The 2026-07-17 preflight attribution to a "recursive `/proc/mpp_service`
snapshot race" was **wrong**: the fault reproduces during ABI replay's
reset+close sequence, and the procfs snapshot in this run completed cleanly
afterward (`status=0`). The random non-canonical address seen on the ordinary
kernel is consistent with reading through the freed 8 KiB object once its
contents were reused.

## Provenance: pre-existing vendor BSP defect, not forward-port-introduced

The bug predates this project. In the forward-port tree, `git log -L` on the
handler shows the whole `RESET_SESSION` block — missing NULL included — arrived
in the single wholesale vendor MPP import (`924f4232546d`); no later forward-port
commit touches it. The pristine Rockchip BSP (`rockchip-kernel` `develop-6.1`,
HEAD `b4ef083dc0c3`) carries the byte-identical handler with no `session->dma =
NULL`. The vendor added that guard to its two *other* destroy sites
(`mpp_session_deinit_default` at `mpp_common.c:406`, rkvdec2-link teardown at
`mpp_rkvdec2_link.c:1490`) and missed only the reset path. It stayed latent
because sessions rarely issue `MPP_CMD_RESET_SESSION` before close; the ABI probe
drives exactly that sequence.

## Fix

One line, mirroring the two correct sites: NULL `session->dma` after the reset
destroy so teardown cannot re-free it.

```c
case MPP_CMD_RESET_SESSION: {
    ...
        mpp_session_clear_pending(session);
        mpp_iommu_down_write(mpp->iommu_info);
        ret = mpp_dma_session_destroy(session->dma);
        session->dma = NULL;                    /* add: prevent double-free at deinit */
        mpp_iommu_up_write(mpp->iommu_info);
    ...
}
```

Guarding `mpp_session_deinit_default()`'s `if (session->dma)` already exists, so
the NULL is sufficient; no second guard is needed.

**Applied** as forward-port commit `83e4d357f8d2` (tree
`linux-6.18-rkvenc-av1-fwport`, on top of `df0d7037213c` = patch `0041`), which
regenerates as forward-port userpatch `0042`. In that tree the handler sits at
`mpp_common.c:1461` and the NULL is added at `:1478`; the line numbers earlier
in this finding (`:1414`) are from the `linux-6.18-rkvenc` reference tree used
during root-cause inspection.

**VERIFIED FIXED (2026-07-18).** The KASAN kernel was rebuilt with `0042`
(`Pe8d3-C4ad2`; the built worktree source carries `session->dma = NULL` at
`mpp_common.c:1478`) and booted. Re-running the identical narrowed reproduction
(run `20260718-093751-kasan-narrowed`) exercised `RESET_SESSION` (ret=0) and
produced `flagged_kernel_lines=0`: the double-free signature
(`mpp_dma_session_destroy`/`__mutex_lock` UAF) appears zero times this boot,
versus a first-pass hit on `P712f`. `abi_status=1` is only the two pre-existing
RGA contract gaps (`RGA2_GET_RESULT` errno 22, unsupported `RGA_IOC_REQUEST_CONFIG`
returns success), not memory safety. The reset-session double-free is resolved.

Note: the same boot surfaced a **separate** encoder use-after-free in
`rkvenc2_wait_result` driven by the remote-desktop H.264 encoder — unrelated to
this reset-session bug. See
[`2026-07-18-rkvenc2-wait-result-task-uaf-kasan.md`](./2026-07-18-rkvenc2-wait-result-task-uaf-kasan.md).
Resume the full MPP suite only after that one is also resolved.

## Secondary (non-crash) observations

The ABI replay still reports its two known contract failures, unchanged from the
prior run and independent of the crash: `RGA2_GET_RESULT` returns `EINVAL`
(errno 22) and an unsupported `RGA_IOC_REQUEST_CONFIG` returns success instead
of `EFAULT`. These are conformance-contract gaps tracked separately, not
memory-safety bugs.

## Follow-up gate

The one-line fix, KASAN rebuild, and narrowed clean reproduction are complete.
The separate `rkvenc2_wait_result` UAF subsequently found on that build is also
fixed and KASAN-verified as patch `0043`. The remaining gate is to rebuild the
production/PPA forward-port with both patches, isolate the functional
multi-instance/slice anomalies seen during the contended KASAN run, and resume
full conformance plus rollback validation.
