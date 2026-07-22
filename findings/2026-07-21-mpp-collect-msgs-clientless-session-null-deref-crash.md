# MPP client-less session NULL-deref hard crash — VP9 `show_existing_frame` corrupts buffer state, async worker faults

*(The `not find client 0` symptom surfaces in `mpp_collect_msgs`; the fatal
deref is in the async task worker `mpp_task_worker_default`. Filename kept for
link stability.)*

> Scope: RK3588 MPP (`/dev/mpp_service`, `rk_vcodec`) on the forward-port
> kernel, KASAN debug build `P7589-C4ad2` (`#7`).
> Source: journal of the crashed boot (`boot -1`, 14:44:07 → 15:12:27 crash),
> `rk_vcodec` `mpp_process_request()` / `mpp_collect_msgs()` /
> `mpp_dev_ioctl_common()`, and the **async task worker
> `mpp_task_worker_default()`** (`mpp_common.c:982`, unguarded
> `task->session->mpp` deref at `:1003`); reproduced from
> `~/Code/rockchip-vaapi` by a parallel agent on the VP9 vectors below.
> Date: 2026-07-21
> Trust: **MEASURED** (the oops line + driver error trail + a repeatable
> trigger sequence + the ~47 s delayed-fault timing + userspace buffer-refcount
> assertions on the trigger vector) / **STRONGLY INFERRED** (the crash site: an
> async worker NULL-deref of a torn-down session's pending task — from the
> delayed-fault timing plus the guarded-vs-unguarded `session->mpp` asymmetry) /
> still **UNPROVEN at the PC** (no call trace survived — ramoops does not
> persist across reset here; see the [ramoops
> finding](./2026-07-21-ramoops-not-preserved-across-warm-reset-rk3588.md)).

## Result — a second, *fatal* kernel bug, distinct from the RGA UAF

The same P7589 boot that surfaced the RGA `rga_request` completion-vs-close
UAF at 15:05 (KASAN-caught, non-fatal — fixed by `0052`) later took a
**hard, fatal oops** at 15:12:27 in the **MPP / `rk_vcodec`** path — a
different subsystem. The board locked up and had to be power-cycled.

The proximate trail, verbatim from the journal (last lines before the reset):

```
rk_vcodec: mpp_process_request:1550: pid 68650 not find client 0
rk_vcodec: mpp_collect_msgs:1727: session 0 process cmd 403 ret -22
rk_vcodec: mpp_dev_ioctl_common:1844: collect msgs failed -22
rk_vcodec: mpp_process_request:1550: pid 68650 not find client 0
rk_vcodec: mpp_collect_msgs:1727: session 0 process cmd 403 ret -22
rk_vcodec: mpp_dev_ioctl_common:1844: collect msgs failed -22
rk_vcodec: mpp_collect_msgs:1727: session 0 process cmd 400 ret -22
rk_vcodec: mpp_dev_ioctl_common:1844: collect msgs failed -22
Unable to handle kernel paging request at virtual address dfff800000000363
```

`dfff800000000000` is the arm64 KASAN shadow offset, so the fault is a KASAN
shadow access for an original pointer of `0x363 << 3` ≈ `0x1b18` — a small
offset off a **NULL base pointer**. That is exactly consistent with the
preceding `not find client 0`: the session's client lookup returned NULL, the
driver logged it and returned `-EINVAL` (`ret -22`) a few times, but a
subsequent access on that client-less session dereferenced the NULL client
(a `client->…` field at offset ~0x1b18) and oopsed fatally instead of failing
safe.

pid 68650 (session 0) was issuing MPP message-collect / poll commands (cmd
`403`=0x193, `400`=0x190) against a session whose client had already been
destroyed/reset — a use-after-teardown of the session→client link. This is in
the same family as the MPP session-teardown fixes already in the series
(`0041` procfs unlink before free, `0042` `session->dma` clear after
`RESET_SESSION`) but is a **distinct** site.

**Both logged sites fail safe — the crashing deref is elsewhere.** Reading the
driver (`mpp_common.c`): `mpp_process_request()` at :1550 handles the NULL
client in its `default:` case by logging `not find client` and returning
`-EINVAL`; `mpp_collect_msgs()` at :1727 propagates that `-EINVAL` up cleanly
(the `collect msgs failed -22` at `mpp_dev_ioctl_common:1844`). The journal
shows **three** such clean `-EINVAL` cycles (cmd 403, 403, 400) and *then* the
fault — so the oops is **not** at :1550/:1727. The `not find client 0` lines
are a **symptom** (that session's `session->mpp` is NULL), not the crash.

## Root-cause candidate: the async worker derefs a torn-down session's task

The crash was **not synchronous** with an ioctl. Per the reproducing agent, the
last actual hardware decode finished at ~15:11:40 and the fault landed at
**15:12:27 — ~47 s later**, with only header/checksum shell commands in between.
A delayed fault means a **deferred kernel context** tripped over state left
corrupted by the decode, not the decode syscall itself.

That points at the MPP task worker. `mpp_task_worker_default()` (a
`kthread_work` handler, `mpp_common.c:982`) pops a pending task and does, at
**`:1003`**, an **unguarded**:

```c
mpp = task->session->mpp;          /* :1003 — no NULL check */
...
if (mpp->dev_ops->prepare)         /* :1011 — derefs mpp */
```

The **ioctl** path reads the identical field but guards it — `mpp_process_task_default()` at `:615`:

```c
struct mpp_dev *mpp = session->mpp;
if (unlikely(!mpp)) { ... return -EINVAL; }   /* :618 — the guard the worker lacks */
```

So a task submitted while the session was healthy, left **pending** when the
session's client is later torn down (`session->mpp` set NULL — the same "not
find client 0" condition), gets popped by the async worker which derefs the now
-NULL `mpp` → the fatal near-NULL fault. `mpp->dev_ops` + `->prepare` is a
function-pointer read a small offset off NULL, matching the observed
`~0x1b18`. This is the guarded-vs-unguarded asymmetry that makes the worker the
prime suspect; it is a **distinct** site from the series' existing MPP
teardown fixes (`0041` procfs unlink, `0042` `session->dma` clear).

## What ran / how it was reached (reproducer)

Traced by a parallel agent in `~/Code/rockchip-vaapi`. The trigger is the VP9
`show_existing_frame` conformance vector, which stresses reference-buffer
management — and it corrupted MPP/`rk_vcodec` buffer state through **two
independent userspace paths**:

1. **~15:11:18 — VA-API path segfaults.**
   `ffmpeg -hwaccel vaapi -vaapi_device /dev/dri/renderD128 -i
   tests/vectors/vp90-2-10-show-existing-frame2.webm -an -f null -` (the
   `rockchip-vaapi` driver, `LIBVA_DRIVER_NAME=rockchip`) **segfaulted**
   (PID 62468). The shell used `;` not `&&`, so it continued.
2. **~15:11:34–40 — direct RKMPP decode asserts on buffers.**
   `ffmpeg -hwaccel rkmpp -i vp90-2-10-show-existing-frame2.webm …` (PID 63196)
   produced **invalid reference-count and buffer-slot assertions and leaked
   buffers** on the same vector.
3. **15:12:20** — last shell command (awk/join on framemd5 files, no HW).
4. **15:12:27** — the fatal `rk_vcodec` paging fault, ~7 s later, with **no HW
   decode command in the interval** — i.e. a deferred worker firing on the
   corrupted state.

The reproducing agent's note: *"Re-running the first two sequences may crash
the machine again."* So this is a **repeatable** trigger. `show_existing_frame`
(display an already-decoded reference frame with no new frame data) and the
companion `vp90-2-20-big_superframe-01.webm` both stress buffer/reference
ownership; the underlying decode-side defect is the VP9 reference-buffer
refcount mismanagement that produced the userspace assertions, and the kernel's
sin is turning that corrupted state into a fatal crash instead of failing safe.

**Caveat on attribution.** The processes that decoded (62468 VA-API, 63196
RKMPP) differ from `pid 68650` seen at the crash instant, and no call trace
survived, so the exact PID→fault link is not proven — but the vector, the
two-path buffer corruption, and the ~47 s deferred timing make the chain strong.

## What ran / how it was reached (original journal view)

The crashing-boot journal showed MPP **decode** activity — `mpp[63274]`/
`mpp[63353]` logging `mpp_dec: can not enable fast parse while hal not support`
at 15:11:39–40 — then the client-less collect loop and crash at 15:12:27, with
`not find client 0` appearing **only** at the crash instant.

## Was anything captured? (ramoops / journal)

- **ramoops/pstore: nothing** — and it turns out ramoops would not have
  captured this crash regardless. It was originally assumed the hard
  power-cycle wiped the DRAM-backed ramoops
  (`ramoops: using 0xd0000@0x118000`), but a later controlled test showed even
  a clean `panic=10` **self-reboot** leaves `/sys/fs/pstore` empty on this
  board: RK3588 re-initializes DRAM on every reset and this Armbian firmware
  does not preserve the `0x118000` window. So pstore cannot capture crashes
  here at all — see
  [`ramoops-not-preserved-across-warm-reset-rk3588`](./2026-07-21-ramoops-not-preserved-across-warm-reset-rk3588.md).
  The next boot confirmed empty (`systemd-pstore.service … skipped, unmet
  condition ConditionDirectoryNotEmpty=/sys/fs/pstore`).
- **journal: the crash line only.** The oops header
  (`Unable to handle kernel paging request …`) was the last line flushed; the
  Mem-abort details, PC/LR, and call trace never reached persistent storage
  because the crash killed logging before flush.

## Fix

Two layers; **layer 1 is implemented**, layer 2 is not.

1. **Kernel — worker fails safe (implemented, `0053@98232d5c06fab`,
   checkpatch-clean, compiles).** Investigating the guard turned up that the
   orphan is un-disposable, not just un-dereferenceable, so the fix is four
   coordinated edits in `mpp_common.c`:
   - the worker (`mpp_task_worker_default`) now fetches the device via
     `mpp_get_task_used_device()` (honouring `task->mpp`, like every other
     task site) and, if NULL, logs and **drops** the orphaned task instead of
     dereferencing it;
   - `mpp_taskqueue_pop_pending()` dropped its `!task->session->mpp` guard
     (kept `!task->session`) — that guard made a NULL-device task
     **unremovable**, so the pre-existing abort branch would have **spun
     forever** and leaked it;
   - `mpp_free_task()` skips the device-side free and the `mpp->task_count`
     decrement when there is no device (an orphan never bound one / never
     incremented it), so freeing the orphan does not itself NULL-deref;
   - `try_process_running_task()` skips a running entry whose device is NULL
     rather than dereferencing `mpp->irq`.

   Net: a torn-down/never-bound session's task becomes a dropped task + error
   log instead of a hard lockup. This defends the crash; it does **not** fix
   the upstream corruption.
2. **Decode side — the VP9 `show_existing_frame` reference-buffer refcount
   bug (not fixed).** The userspace assertions (invalid ref counts, buffer-slot
   asserts, leaked buffers) point at MPP's VP9 `show_existing_frame`/superframe
   buffer ownership mishandling the shared reference frame — the trigger that
   drives the session into the bad state. Likely in `librockchip_mpp` VP9
   (`vp9d`) buffer/slot management rather than the kernel.

**Related sibling — fixed (`0054@e4c9b62669526`).** `mpp_wait_result_default()`
(`mpp_common.c`, the synchronous poll/wait path) had the same
`mpp->dev_ops->result` deref without a NULL guard — the synchronous twin of
the worker bug. `0054` guards it right after the device fetch (before the poll
and the blocking wait), failing and dropping a device-less task in every mode
(`mpp_free_task` is NULL-safe as of `0053`, so the pop is safe). Not the
observed crash (that path is synchronous; the reported fault was the ~47 s
deferred worker), but the same bug class on the sibling path, now closed.

## Boundary / how to confirm the crash site

- **The PC is not yet proven.** The worker NULL-deref at `:1003`/`:1011` is a
  strong candidate (delayed-fault timing + guarded-vs-unguarded asymmetry +
  near-NULL offset), but no call trace survived, so it remains inference.
- **Get the trace:** because ramoops does not persist across reset on this board
  (see the ramoops finding), capture off-board — **serial console on `ttyS2`
  @ 1500000** (immune to the reset) or netconsole — while re-running the
  reproducer. A captured PC/call-trace at `mpp_task_worker_default` would
  confirm layer 1.
- **Reproduce under KASAN (repeatable):** on the P9c12 KASAN kernel, re-run the
  VA-API + RKMPP `vp90-2-10-show-existing-frame2.webm` sequences above (the
  reporting agent warns this may crash the box again). A KASAN report on the
  client-less worker access would name the exact field and path. Do this only
  with serial capture attached, since the fault hard-locks the board and — per
  the ramoops finding — nothing on-board survives.

## Why it matters

A **fatal, unprivileged-reachable kernel crash** in the core decode path (any
process that can open `/dev/mpp_service` and drive a session into the
client-less collect state) is a **distribution blocker on par with — and more
severe in impact than — the RGA UAF**: it hard-locks the machine rather than
being caught by KASAN. It must be root-caused (with a trace) and fixed before
the forward-port kernel ships broadly. Tracked alongside the
[RGA request UAF finding](./2026-07-21-rga-request-completion-vs-session-close-uaf-kasan.md).
