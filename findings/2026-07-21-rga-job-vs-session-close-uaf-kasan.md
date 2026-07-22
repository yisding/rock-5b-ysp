# RGA in-flight job outlives its session: KASAN use-after-free on the session object

> Scope: RK3588 RGA (`/dev/rga`) on the forward-port kernel
> `linux-6.18-rkvenc-av1-fwport` (RGA series `0044`–`0056`, MPP `0053`–`0056`),
> `drivers/video/rockchip/rga3/rga_job.c` — the RGA2 IRQ-thread completion
> path (`rga_request_release_signal()` → the job's `job->session` dereferences)
> vs `rga_release()` (the `/dev/rga` close path that frees the session).
> Source: **MEASURED** on debug build `P70a5-C4ad2` (`CONFIG_KASAN=y`,
> booted, md5-verified), driven by `kernel-drivers/tests/rga-session-uaf.sh
> cross` with the below-4G CMA heap fix so async blits actually submit.
> Date: 2026-07-21
> Trust: **MEASURED** (KASAN slab-use-after-free, full alloc/free stacks
> captured) / **CODE-INSPECTED** (the racing paths and the missing reference)
> / **INFERRED** (the fix direction).

> **2026-07-21 fixed (patch `0057`, awaiting booted gate).** The job now takes
> its own `rga_session_get()` when it caches `job->session` in
> `rga_job_commit()` and drops it in `rga_job_free()` (NULL-guarded for the
> early-error paths). See "Fix" below.

## Why this is distinct from `0052`

`0052` closed a **request** double-free: four paths retire the `rga_request`
initial reference and any two can race, double-putting it. That fix holds — on
`P70a5` the `cross` reproducer produces **no** request double-free and **no**
refcount underflow.

This is a **second, independent** use-after-free on a **different object**:
the `rga_session` itself. `0052` guarantees the *request* is freed exactly
once; it does nothing about the **job**, which caches a bare `job->session`
pointer and outlives the session.

## The measurement

`P70a5-C4ad2`, live KASAN, `rga-session-uaf.sh cross` (64000 async submits,
0 submit failures once the blit lands on a below-4G CMA buffer so RGA2 accepts
it):

```
BUG: KASAN: slab-use-after-free in rga_request_release_signal+0xc40/0xe58
Read of size 4 at addr ffff00011fb62e04 by task irq/71-rga2/131
  rga_request_release_signal+0xc40/0xe58
  rga_isr_thread+0x8c/0x160
  irq_thread_fn / irq_thread / kthread

Allocated by task 16917:
  rga_session_init+0x78/0x648
  rga_open+0x28/0x80          <- the object is an rga_session

Freed by task 16917:
  rga_session_kref_release+0xe4/0x128
  rga_release+0x11c/0x158
  __fput -> __arm64_sys_close  <- freed when the owning fd closes

The buggy address is located 4 bytes inside of freed 256-byte region
```

The freed object is the `rga_session` (`kmalloc-256`, allocated by
`rga_session_init`). The read is 4 bytes at offset **+4**, which is
`session->tgid` in `struct rga_session { int id; pid_t tgid; ... }`. The
accessor is the async job-completion path running in `irq/71-rga2`.

## Root cause

`struct rga_job` caches the owning session but takes **no reference**:

```c
/* rga_job_commit(), rga_job.c:427 */
job->session = request->session;   /* bare pointer, no rga_session_get() */
```

The completion path dereferences it from the hardware IRQ thread, long after
the ioctl returned:

- `rga_job.c:260`  `job->session->last_active = job->timestamp.hw_done;`
- `rga2_reg_info.c:3310`, `rga3_reg_info.c:2233`  `job->session->last_active = now;`
- `rga_job.c:1010` `... request->session->pname ...`

The session **is** refcounted (`session->refcount`), and the **request** holds
a ref (`rga_session_get()` in `rga_request_alloc()`, dropped in
`rga_request_free()`). But that reference is retired when the *request*
retires — and on owning-fd close `rga_request_session_destroy_abort()` retires
every request of the session, then `rga_release()` calls `rga_session_put()`
on the session's own reference. If an async **job** is still executing on
hardware (or being drained in the IRQ thread) at that moment, nothing holds
the session alive: the request refs are gone and the job never had one. The
session is freed and the completing IRQ thread reads `job->session->tgid` /
`->last_active` / `->pname` out of freed memory.

The `session->release` flag + `release_rwsem` only gate **new** submits during
teardown (`down_read` at submit, `down_write` at close). They do **not** wait
for already-running hardware jobs to finish, so they cannot cover this window.

## Fix (`0057`)

Give the job an independent session reference for its whole lifetime:

- `rga_job_commit()`: `rga_session_get(request->session);` immediately after
  `job->session = request->session;`.
- `rga_job_free()` (the single terminal free reached by both the kref path and
  the `err_free_job` early-error path): `if (job->session)
  rga_session_put(job->session);`. `rga_job_alloc()` uses `kzalloc`, so
  `job->session` is NULL on jobs freed before commit assigns it — the NULL
  guard makes those paths safe.

With the job holding a ref, `rga_session_put()` at close cannot free the
session while a job is in flight; the last put comes from the completing job's
`rga_job_free()`, after all `job->session` dereferences are done.

## Gate

Re-run `rga-session-uaf.sh cross` (async_submits > 0, i.e. on a below-4G CMA
buffer) under KASAN on a `0057`-carrying build: the run must be
slab-use-after-free-free with the journal showing zero fatal signatures.

## Test-harness note

The `cross` reproducer previously reported `async_submits=0` because its
dma-heap list named only `system*`/`cma*` aliases that do not exist on Armbian
6.18 (only `default_cma_region`, `reserved`, `system` are present). On a >4G
board it fell through to `system`, which returns memory above 4G; the small
16×16 RGBA blit only maps to RGA2 (core 0x4), which the `0047` under-4G
exclusion then correctly rejects ("no core match ... under-4G memory limit").
The reproducer now prefers `default_cma_region` (below 4G) so a valid async
job actually submits and the cross-session window opens. This is why the UAF
was not seen on earlier boots — the race window was never exercised.
