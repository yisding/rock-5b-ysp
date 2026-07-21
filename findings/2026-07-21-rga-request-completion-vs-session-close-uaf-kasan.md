# RGA `rga_request` completion races session-close: KASAN use-after-free on the current forward-port tip

> Scope: RK3588 RGA (`/dev/rga`) on the forward-port kernel
> `linux-6.18-rkvenc-av1-fwport@162edad7bb9c7` (RGA series `0044`–`0051`),
> `drivers/video/rockchip/rga3/rga_job.c` — `rga_request_release_signal()`
> (the RGA2 IRQ-thread completion path) vs
> `rga_request_session_destroy_abort()` (the `/dev/rga` close path).
> Source: measured on debug build `P7589-C4ad2` (`#7`, `CONFIG_KASAN=y`),
> driven by `kernel-drivers/tests/rga-session-uaf.sh cross`.
> Date: 2026-07-21
> Trust: **MEASURED** (KASAN slab-use-after-free + refcount underflow, full
> alloc/free stacks captured) / **CODE-INSPECTED** (the racing paths) /
> **INFERRED** (the exact double-put root cause and the fix direction).

> **2026-07-21 fixed (patch `0052@c46bfd6622ba6`, awaiting booted gate).**
> Root cause confirmed by full reference-model tracing: a request holds a
> single initial reference from `rga_request_alloc()` (`kref_init`), and
> **four** paths retire it by calling `rga_request_put()` on that reference —
> async completion (`rga_request_release_signal()`'s "current submit request
> put"), the cancel ioctl, submit-time abort (`rga_request_release_abort()`),
> and owning-session close (`rga_request_session_destroy_abort()`). Jobs hold
> **no** request reference (they store `request_id` and re-look-it-up), so
> nothing serialises completion against close beyond the manager lock — and
> the manager lock only orders the two puts, it does not stop both from
> firing. Fix: a new `rga_request_release_ref()` helper drops the initial
> reference exactly once under the manager lock, guarded by a
> `release_ref_dropped` flag; all four retire paths route through it. The
> completion path's own look-up reference is unaffected and still balances its
> final put, so the request is freed exactly once by whichever path retires it
> first. Compiles clean; checkpatch-clean (bar a false-positive `Fixes:`
> suggestion from the KASAN text in the log). Booted gate: a quiet `cross` run
> with `async_submits > 0` under KASAN on the next debug build.

## Result — a distinct, unfixed UAF (distribution blocker)

The `cross` reproducer, written to trip the *buffer* force-free UAF that
patch `0040` already closes, instead surfaced a **different** use-after-free
that the current tip does **not** fix: the `rga_request` object itself is
freed by the session-close path while the RGA2 IRQ completion thread is still
signalling it.

```
BUG: KASAN: slab-use-after-free in do_raw_spin_trylock+0x84/0x1f8
Read of size 4 at addr ffff00004f7b10c8 by task irq/71-rga2/132
Call trace:
 do_raw_spin_trylock
 _raw_spin_lock_irqsave
 __wake_up
 rga_request_release_signal+0x530/0xec0     ← wake_up(&request->finished_wq)
 rga_isr_thread
 irq_thread_fn / irq_thread / kthread

Allocated by task 47031:
 rga_request_alloc+0x98/0x658
 rga_ioctl (RGA_IOC_REQUEST_*)

Freed by task 47031:
 kfree
 rga_request_free+0x140/0x2d0
 rga_request_kref_release+0x13c/0x2b0
 rga_request_session_destroy_abort+0x2a0/0x3a8
 rga_release+0x80/0x158                      ← /dev/rga close
 __fput / __arm64_sys_close
```

Immediately after, on the same CPU/task, the final put in the same function
underflowed the refcount — the smoking gun for an unbalanced (double) put:

```
refcount_t: underflow; use-after-free.
WARNING: ... refcount_warn_saturate+0x110/0x1a0
 rga_request_release_signal+0x650/0xec0
 rga_isr_thread / irq_thread / kthread
```

The freed object is `kmalloc-512` (the `rga_request`), freed 200 bytes into
the region — consistent with `&request->finished_wq.lock` being read by
`wake_up()` after the free.

## Mechanism (inspected)

`rga_request_release_signal()` (rga_job.c:1097) is the per-job completion
callback run from the RGA2 IRQ thread. On the terminal job it:

1. looks up the request under `request_manager->lock` and takes a reference
   (`rga_request_get`, :1121);
2. in the finished branch drops the **submit** reference
   (`/* current submit request put */`, :1156–1159);
3. re-takes the manager lock, `wake_up(&request->finished_wq)` (:1165), then
   drops the reference from step 1 (:1167).

`rga_request_session_destroy_abort()` (rga_job.c:927) runs on `/dev/rga`
close and, for every request owned by the closing session, calls
`rga_request_put()` — also dropping the **submit** reference.

When a session closes with a request still in flight, both paths put the same
conceptual submit reference: the completing job's step 2 and the close path's
`rga_request_put` **double-drop it**. The reference the IRQ thread took in
step 1 is meant to keep the object alive across `wake_up`, but the double put
drives the refcount to zero and frees the request *before* step 3 finishes —
so `wake_up(&request->finished_wq)` reads freed slab memory and the final put
underflows. The `rga_request_get`/`put` bracket does not actually make the
completion path safe against a concurrent owner-drop of the submit ref,
because the abort path assumes the submit ref is still theirs to release.

This is orthogonal to the already-landed fixes: `0040` (buffer force-free by
kref), `0041` (MPP procfs unlink), `0042` (MPP reset session DMA double
free), `0043` (RKVENC2 wait-result task UAF). None touch the
`rga_request`-vs-completion lifetime.

## Reproduction

- Kernel: `linux-6.18-rkvenc-av1-fwport@162edad7bb9c7`, debug build
  `P7589-C4ad2` (`#7`, KASAN, ramoops/pstore armed).
- Command: `RGA_UAF_ITERS=5000 RGA_UAF_BURST=64
  kernel-drivers/tests/rga-session-uaf.sh cross`.
- The run reported `async_submits=5952 submit_fail=4907` — i.e. ~1045 real
  async jobs entered the cross-session window, which is what makes a quiet
  run meaningful and a splat conclusive. KASAN fired once, deterministically,
  during the burst; the box stayed up (the faulting access is a `trylock`
  read that KASAN poisoned rather than a write), RGA remained live
  afterward.
- The `leak` and `leak (fork)` modes stayed **quiet** (5000/5000 each), as
  expected — they exercise the refcount-1 buffer path `0040` fixed, not this
  request race.

## Boundary / caveats

- The **double-put root cause is INFERRED** from the refcount underflow plus
  the two racing `rga_request_put` sites; it is not yet confirmed by
  instrumentation. The UAF and the underflow themselves are MEASURED with
  full stacks.
- Single captured occurrence this boot. It should be re-confirmed on a fresh
  boot (the current boot's slab is now KASAN-poisoned at that object), and
  the fix validated by a quiet `cross` run with `async_submits > 0`.
- Cross mode is destructive by design; the deterministic capture here landed
  on a `trylock` *read*, but a different scheduling could hit a write and
  crash. Run only on a disposable KASAN board.

## Why it matters / follow-up

- **Distribution blocker.** This is a remotely-plausible teardown race
  (any process that closes `/dev/rga` while an async RGA job it or a peer
  submitted is still completing), reachable without special privilege beyond
  `/dev/rga` access, and it corrupts kernel slab. It must be fixed before the
  forward-port kernel is offered to a broader audience.
- **Fix direction (to design + verify, not yet written):** make exactly one
  of {completion, session-close abort} responsible for the submit reference.
  Options: have `rga_request_session_destroy_abort()` quiesce in-flight jobs
  (as `rga_request_kref_release` already does via
  `rga_request_scheduler_job_abort`) before dropping the ref, or gate the
  submit-ref put behind an atomic "already-completing" flag so the abort
  detaches `->session` and skips the put when the request is mid-signal —
  mirroring the `->session`-detach-on-surviving-reference shape of the `0040`
  buffer fix. Whatever the shape, `rga_request_release_signal` must hold a
  reference that cannot be defeated by a concurrent owner drop across its
  entire `wake_up` + final-put tail.
- Reproducer and this finding supersede the open question in
  [`2026-07-17-rga-session-close-uaf.md`](./2026-07-17-rga-session-close-uaf.md)
  about what `cross` would trip: it trips *this* request-lifetime UAF, not the
  buffer force-free (which `0040` closes and which `leak` confirms quiet).
- Tracks as a new forward-port watchlist blocker; the next RGA patch in the
  series (`0052`) should carry the fix, with the booted gate being a quiet
  `cross` run under KASAN.
