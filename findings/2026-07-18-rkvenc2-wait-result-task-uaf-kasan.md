# KASAN: rkvenc2_wait_result reads task->state after freeing the task (forward-port-introduced)

> Scope: ROCK 5B on the KASAN+ramoops forward-port kernel `Pe8d3-C4ad2`
> (`6.18.38-current-rockchip64`, forward-port series 0001–0042)
> Source: boot `91445572` kernel log
> (`/home/yi/Code/rockchip-conformance/logs/forward-port/kasan-boot-91445572/`);
> triggered by the gnome-remote-desktop hardware H.264 encoder
> Date: 2026-07-18
> Trust: MEASURED (full symbolized KASAN report) / CODE-INSPECTED (root cause and
> introducing commit) / CONFIRMED (alloc/free/use in one task, one function)

## Result

Booting the KASAN kernel and starting a remote-desktop session produced a
**slab-use-after-free in `rkvenc2_wait_result`**, which is why the desktop was
slow to come up: gnome-remote-desktop encodes the screen with the RK3588
hardware H.264 encoder over MPP, so its encoder thread (`mpp_h264e_3566`) drives
this path on every frame. KASAN's handler is `_noabort`, so the box stayed up
(same `boot_id`, no panic), but the encoder task is freed and then dereferenced
each time this path runs.

This is a **distinct bug** from the reset-session double-free fixed in `0042`
([finding](./2026-07-18-mpp-reset-session-dma-double-free-kasan.md)), and unlike
that one it was **introduced by the forward-port**, not inherited from the
vendor BSP.

## The trace

```text
BUG: KASAN: slab-use-after-free in rkvenc2_wait_result+0xda8/0xed0
Read of size 8 at addr ffff0001334411d0 by task mpp_h264e_3566/4237
Call trace:
  rkvenc2_wait_result+0xda8/0xed0
  mpp_msgs_wait+0xfc/0x1f8
  mpp_dev_ioctl_common.isra.0+0xab8/0x1010
  mpp_dev_ioctl / __arm64_sys_ioctl / el0_svc

Allocated by task 4237:
  rkvenc_alloc_task            ← struct rkvenc_task, kmalloc-8k
  mpp_process_task_default / task_msgs_add / ioctl

Freed by task 4237:
  kfree
  rkvenc_free_task
  mpp_free_task
  rkvenc2_wait_result+0x588/0xed0   ← freed from *inside* wait_result
  mpp_msgs_wait / ioctl
```

Same task allocates, frees, and re-reads the object; the read is 4560 bytes into
the freed 8192-byte region.

## Root cause

`rkvenc2_wait_result()` (`mpp_rkvenc2.c:2707`), `task_done_ret` path:

```c
ret = rkvenc2_task_default_process(mpp, task);          /* 2751 */
if (!ret && test_bit(TASK_STATE_ABORT, &task->state))   /* 2752  <-- use-after-free */
        ret = -EIO;
return ret;
```

`rkvenc2_task_default_process()` calls `rkvenc2_task_pop_pending()`, which ends
in `kref_put(&task->ref, mpp_free_task)` (`mpp_rkvenc2.c:2637`). Both statics are
inlined into `rkvenc2_wait_result`, so the free frame shows as
`rkvenc2_wait_result+0x588 → mpp_free_task`. When that put drops the last
reference — the hardware worker has already completed and released its ref by the
time the blocking waiter returns from `wait_event_interruptible(... TASK_STATE_DONE)`
— the task is freed. Line 2752 then reads `task->state` through `test_bit`,
which is the `+0xda8` use-after-free.

The KASAN timing widens the window (every access instrumented), which is why a
latent race surfaces reliably here, but the ordering bug is unconditional: the
code reads freed memory whenever `default_process` released the final ref.

## Provenance: forward-port-introduced

`git blame` puts line 2752 in forward-port commit `23ff47eab6f6`
("forward-port MPP core and rkvdec2/rkvenc2 to 6.18"), inside the
`v6.18..HEAD` range. The pristine Rockchip BSP (`rockchip-kernel` `develop-6.1`)
has no such line — it simply `return rkvenc2_task_default_process(mpp, task);`
with no post-call `task->state` read. The forward-port added abort-status
propagation (returning `-EIO` when the task was aborted) but placed the
`task->state` read after the call that can free the task. So unlike the
reset-session double-free, this UAF is ours.

## The abort check itself is intended — only its placement is wrong

The `test_bit(TASK_STATE_ABORT)` → `-EIO` is not stray: it propagates an
aborted/timed-out encode task to userspace as an error instead of a silent
success. The forward-port mirrored it from the decoder, whose
`rkvdec2_wait_result()` does the identical thing (`mpp_rkvdec2_link.c:1484`):

```c
ret = rkvdec2_result(mpp, mpp_task, msgs);
if (!ret && test_bit(TASK_STATE_ABORT, &mpp_task->state))   /* read state ... */
        ret = -EIO;
mpp_session_pop_done(session, mpp_task);                    /* ... then pop/free */
```

In the decoder the pop-and-free (`mpp_session_pop_done`) is a **separate call
after** the abort check, so the read is safe. The encoder differs in one way
that the forward-port missed: its pop-and-free is **inside**
`rkvenc2_task_default_process()` (→ `rkvenc2_task_pop_pending` → `kref_put`), so
the mirrored check landed *after* the free. The behavior is wanted; the ordering
is the defect.

## Fix

Read the abort flag **before** the task can be freed, then propagate it — which
also makes the encoder match the decoder's read-then-pop ordering:

```c
bool aborted;
...
aborted = test_bit(TASK_STATE_ABORT, &task->state);
ret = rkvenc2_task_default_process(mpp, task);   /* may free task */
if (!ret && aborted)
        ret = -EIO;
return ret;
```

`TASK_STATE_ABORT` is already set before the waiter is released (via
`rkvenc2_task_timeout_process()` / abort handling), so sampling it before
`default_process` preserves the intended semantics without touching freed memory.

## Next gate

1. Apply the fix (forward-port patch 0043) and rebuild the KASAN kernel.
2. Reboot, start a remote-desktop session (the natural reproducer), and confirm
   no `rkvenc2_wait_result` KASAN report — pair with the encode cases in the MPP
   suite.
3. With `0042` already verified, a clean encoder path clears the last known
   memory-safety blocker before resuming full forward-port conformance.
