# RGA `mm_session` debugfs read is a use-after-free on a freed `task_struct` (+ unkillable D-state hang)

> Scope: forward-port RGA driver (`rga3`/`rga2`, `rk_vcodec` sibling) on the `6.18-rkvenc-fwport` KASAN+lockdep build; handler `rga_mm_session_show()` behind `/sys/kernel/debug/rkrga/mm_session`
> Source: on-hardware KASAN report captured 2026-07-22 22:38 PDT while running the root-gate `rga-mmu-debug.sh` after the 320K-submit RGA cross-session UAF stress; kernel `6.18.38-current-rockchip64`, build `6.18-rkvenc-fwport`
> Date: 2026-07-22
> Trust: MEASURED (KASAN slab-use-after-free) / SOURCE-CONFIRMED (root cause + provenance) / FIX-RUNTIME-VERIFIED (Pc1f8-C9fc5, 2026-07-23)

## Result

Reading `/sys/kernel/debug/rkrga/mm_session` on the forward-port build triggers a
**KASAN slab-use-after-free** while acquiring `rga_drvdata->mm->lock` in
`rga_mm_session_show()`, then the reading process wedges **uninterruptibly
(D state), cannot be killed, and needs a reboot**.

```
BUG: KASAN: slab-use-after-free in mutex_can_spin_on_owner+0x35c/0x3b0
  rga_mm_session_show+0xdc   (== mutex_lock(&mm_session->lock))
buggy object → cache task_struct (size 8256)
  Freed by task 0: free_task / __put_task_struct / __put_task_struct_rcu_cb / rcu_core
```

**Root cause — from OUR forward port, not the BSP.** Forward-port commit
`bc086cbe03d72c` ("rkvenc forward-port", 2026-07-17; the RGA lifetime rework of
the `0052`/`0057` lineage) rewrote `rga_mm_session_release_buffer()`
(`rga_mm.c`). The BSP frees each of the exiting session's buffers with
`rga_mm_force_releaser_buffer()` **while continuously holding `mm->lock`** inside
`idr_for_each_entry()`. The forward-port replaced that with
`kref_put(&buffer->refcount, rga_mm_kref_release_buffer)` — and
`rga_mm_kref_release_buffer()` **drops and re-acquires `mm->lock`** around the
sleeping `rga_mm_unmap_buffer()` (`mutex_unlock` … `mutex_lock`). So on the
last-reference path the lock is released **mid-iteration** during session
teardown. Under heavy churn this leaves `rga_drvdata->mm->lock` owned by a task
that has since exited and had its `task_struct` RCU-freed; the next `mm->lock`
waiter (`rga_mm_session_show`) enters the mutex adaptive-spin path
(`mutex_can_spin_on_owner` reads the freed owner `task_struct`) → KASAN UAF, and
then blocks forever on the permanently-held lock (D state).

Companion defect in the same commit: it added `buffer->session = NULL` for
still-shared buffers but did not update `rga_mm_session_show()`, which
dereferences `dump_buffer->session->tgid` unconditionally → a NULL-deref once any
shared buffer's owner exits.

Both are **root-reachable** (debugfs is root-only). The UAF is exposed by session
churn — any RGA client that imports buffers and exits — and the 320K-submit
`rga-session-uaf.sh cross` run plus the librga demos in `rga-mmu-debug.sh`
immediately before supplied it.

## Evidence and reproduction

- **Identity:** ROCK 5B, `6.18-rkvenc-fwport` KASAN+lockdep build; `rga3` ×2 +
  `rga2` probed; debugfs `rkrga/` present.
- **Trigger:** run RGA jobs from processes that exit (e.g. `rga-session-uaf.sh
  cross`, or any librga client), then `cat /sys/kernel/debug/rkrga/mm_session`
  (as root). Reproduced via `kernel-drivers/tests/rga-mmu-debug.sh`, which reads
  `$RGA_DEBUGFS/mm_session`.
- **Pass/fail signal:** KASAN `slab-use-after-free in mutex_can_spin_on_owner`
  with `rga_mm_session_show` in the trace; the `cat` PID goes to state `D` and
  survives `SIGKILL`.
- **Artifacts:** full report at scratchpad `fwport-test/08-rga-mm-session-uaf.txt`
  (174 lines); not committed (raw machine capture).
- **Do NOT re-read the file to "confirm"** — each read spawns another unkillable
  D-state task.

## Fix

Committed `e7eaa8f8c69b4` on `linux-6.18-rkvenc-av1-fwport`
(`bsp-high-port-20260722`): free the last reference in
`rga_mm_session_release_buffer()` with `rga_mm_force_releaser_buffer()` (frees
under the held `mm->lock`, as the BSP does) instead of the lock-dropping
`kref_put(rga_mm_kref_release_buffer)`, so no lock is dropped mid-iteration; the
`refcount>1` path only decrements and is unchanged. Plus a NULL guard on
`dump_buffer->session` in `rga_mm_session_show()`. Both changed objects
(`rga_mm.o`, `rga_debugger.o`) **compile clean** (native arm64, no warnings).

## Boundary

Root cause and provenance are source-confirmed (BSP diff + `git blame` of
`bc086cbe03d72c`). **RUNTIME-VERIFIED 2026-07-23** on debug build `Pc1f8-C9fc5`
(carries `0071` = `e7eaa8f8c69b4`): a 320K-submit `rga-session-uaf.sh cross`
churn ran clean with a healthy post-churn RGA re-check, and the `rga-mmu-debug`
root gate — which reads `/sys/kernel/debug/rkrga/mm_session`, the exact operation
that hard-wedged the pre-fix kernel — **completed with no D-state task and no
KASAN report**. On a non-KASAN production kernel the pre-fix lock-drop would leave
the leaked lock silent (no UAF report) but the permanent D-state hang on the freed
mutex would still occur, so this is a real production defect, not a debug-only
artifact.

## Why it matters / follow-up

New forward-port RGA defect distinct from the `rga_request` close-race UAFs
(`0052`/`0057`): this is **session-teardown lock discipline** vs. the debugfs
session dump. Belongs in the submit-now/CVE consideration set alongside the other
RGA UAFs (root-reachable UAF + unkillable-hang DoS). Landed: `e7eaa8f8c69b4`
folded into the tracked series as `0071`, packaged in debug build `Pc1f8-C9fc5`,
booted, and runtime-verified 2026-07-23 (see Boundary).

Immediate recovery for the current boot: the D-state `cat` cannot be killed, and
the running kernel still has the bug; **reboot** to clear the wedged task (mind
the separate intermittent boot-hang, watchlist `W20`).
