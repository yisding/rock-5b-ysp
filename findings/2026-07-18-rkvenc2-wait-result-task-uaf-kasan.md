# KASAN: rkvenc2_wait_result reads task->state after freeing the task (forward-port-introduced)

> Scope: ROCK 5B on the KASAN+ramoops forward-port kernel `Pe8d3-C4ad2`
> (`6.18.38-current-rockchip64`, forward-port series 0001–0042)
> Source: boot `91445572` kernel log
> (`/home/yi/Code/rock-5b/rockchip-conformance/logs/forward-port/kasan-boot-91445572/`);
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

## Applied and verified

The fix is forward-port commit
`655d178191807e24e9ca4dd72e74401b449d2099` on top of `0042`; it exports as
tracked forward-port patch `0043`.

**VERIFIED FIXED (2026-07-18).** KASAN MPP-suite run
`20260718-103917-kasan-mpp-suite` exercised the encoder paths with `0042` and
`0043` present. `kernel-log-flags.txt` and `dmesg-fatal.txt` were both empty;
the original `rkvenc2_wait_result`/slab-use-after-free signature appeared zero
times, while ordinary H.264/H.265 and multi-thread H.265 encode cases passed.
The same run drove the GRD hardware encoder and produced no replacement KASAN
fault.

The original run was a memory-safety verification rather than a full
functional-suite pass: `mpi_dec_multi_h265` returned a nonzero status and both
slice cases timed out. Isolated work on 2026-07-20 showed that the multi-instance
binary returns its average FPS cast to an exit status, while the slice harness
incorrectly used the single-thread binary for callbacks that require an output
thread. Corrected run `20260720-213128-kasan-mpp-suite` passed all three
120-frame cases and recorded no kernel-fatal line. Full official-MPP run
`20260720-213542-mpp-suite` then passed all 12 selected cases.

An intentionally abusive `split_arg=4` control also exposed a separate
unchecked 256-entry slice-FIFO overflow; that robustness defect is tracked in
the
[`slice-FIFO finding`](./2026-07-20-rkvenc2-slice-fifo-terminal-drop.md) and is
not a regression in the `0043` lifetime fix.

## Remaining gate

1. **Completed:** the isolated corrected cases and full 12-case MPP matrix pass
   on the KASAN build with clean bracketed kernel logs.
2. Rebuild the production/PPA forward-port with `0042` and `0043`, then resume
   exact-image conformance and rollback validation before promoting it over the
   July 4 baseline. RGA and GStreamer still have separate open gates.
