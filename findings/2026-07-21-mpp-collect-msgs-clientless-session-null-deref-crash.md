# MPP client-less session NULL-deref hard crash — `RELEASE_FD` dereferences a NULL `session->dma`

*(PROVEN root cause: `mpp_dma_release_fd()` derefs `dma->dev` on a session with
no DMA. The `not find client 0` symptom in `mpp_collect_msgs` is the preceding
commands; the fatal deref is synchronous in the ioctl thread, **not** the async
worker `mpp_task_worker_default` as originally inferred. See the PROVEN block
below. Title/filename kept for link stability.)*

> ## 2026-07-23 GATE VERIFIED on `Pc1f8-C9fc5` (carries `0058`)
>
> The proven fix (`0058`) holds on hardware. The `mpp-clientless-release-fd-uaf.c`
> reproducer — now kept in the private `rock-5b-security` repository rather than
> in this tree, and named there in every reference below — the whole trigger:
> open `/dev/mpp_service`, no `INIT_CLIENT_TYPE`,
> one `MPP_CMD_RELEASE_FD` — returns `-1`/`-EINVAL` and the board stays up with a
> clean KASAN journal (was: hard, unkillable oops on a pre-`0058` kernel). Meets
> the gate at the end of the PROVEN block below.
>
> Separately, the original VP9 `show_existing_frame` trigger vector
> (`vp90-2-10-show-existing-frame2.webm`) was run via `mpp-vp9-show-existing-repro.sh`
> — 30 loops × 4 concurrent `mpi_dec_test` — with the board **surviving** the 60 s
> deferred-fault window and a clean kernel log (`flagged_kernel_lines=0`). The
> userspace **leg-2** anomaly still fires (MPP `clear_slots_impl` slot-history
> dumps appear) but is now **non-fatal** — consistent with the crash never having
> been the VP9/async-worker path. Leg-2 (MPP-userspace buffer-slot refcount)
> remains a separate, open userspace item; the kernel is no longer crashable here.

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

> ## 2026-07-21 UPDATE — RECURRED on `P70a5-C4ad2` (`0053`+`0054`+`0055`+`0056`). The leg-3 attribution is WRONG.
>
> The **identical** crash reproduced on debug build `P70a5-C4ad2` — which
> already carries the leg-3 worker guard (`0053`) and its wait-result sibling
> (`0054`). Verbatim from `boot -1` (monotonic `1109.34s`), byte-for-byte the
> same fault address and command trail as the P7589 crash:
>
> ```
> rk_vcodec: mpp_process_request:1593: pid 23464 not find client 0
> rk_vcodec: mpp_collect_msgs:1770: session 0 process cmd 403 ret -22
> rk_vcodec: mpp_dev_ioctl_common:1887: collect msgs failed -22
> rk_vcodec: mpp_collect_msgs:1770: session 0 process cmd 400 ret -22
> Unable to handle kernel paging request at virtual address dfff800000000363
> ```
>
> **Consequences for this finding (corrections):**
>
> 1. **`0053`/`0054` do NOT fix this crash.** Because the crash survives the
>    `mpp_task_worker_default()` / `mpp_wait_result_default()` guards, the
>    fatal deref is **not** (solely) in those workers. The "STRONGLY INFERRED
>    leg-3 crash site" above is **disproven as the fix**. Leg 3's guards are
>    still correct hardening, but they are not sufficient — an unguarded
>    **sibling** NULL-deref remains, reachable from a client-less session.
>
> 2. **Corrected command decode.** `mpp_collect_msgs()` logs `req->cmd` with
>    `%x`, so the trail is **hex**: `cmd 0x400` = `MPP_CMD_RESET_SESSION`,
>    `cmd 0x403` = `MPP_CMD_SEND_CODEC_INFO` (not the decimal `0x190/0x193`
>    guessed earlier). Both hit the guarded `default:`/`RESET_SESSION` arms and
>    return `-EINVAL` **safely**; the fatal deref is **after** these returns.
>
> 3. **Independent of the RGA UAF.** At the same instant (`1109.328s`, 12 ms
>    before the MPP fault) the RGA IRQ thread logged
>    `ID[65995]: can not find internal request` — a *deferred* async
>    completion (a job stuck ~471 s, consistent with the
>    [RGA job-vs-session UAF](./2026-07-21-rga-job-vs-session-close-uaf-kasan.md)),
>    but it **failed safe** (lookup returned NULL, clean return). So the fatal
>    deref is the **MPP** side and the RGA `0057` fix will not address it.
>
> 4. **No on-board trace, no serial capture available.** Only the single fault
>    line reached journald before the hard hang (printk could not drain — the
>    fault is in an IRQ/atomic or lock-held context). The full oops went to the
>    consoles (`tty1`, `ttyS2`) but nothing was capturing `ttyS2`. Next step is
>    therefore a **code audit of every client-less-reachable NULL-deref sibling**
>    plus fail-safe hardening (as `0053`/`0054` did), and/or `pstore/blk` on the
>    boot media + `panic_on_oops=1` so `kmsg_dump` persists the ring buffer
>    across the reset the DRAM ramoops cannot survive.

> ## 2026-07-21 ROOT CAUSE PROVEN — synchronous `mpp_dma_release_fd()` NULL deref (patch `0058`). The async-worker theory below is superseded.
>
> With `panic_on_oops=0` (so a process-context oops prints its trace instead of
> rebooting) a **minimal deterministic reproducer** produced the exact crash on
> `P70a5-C4ad2`, with a full call trace — no VP9, no async worker, no race:
>
> ```
> Unable to handle kernel paging request at virtual address dfff800000000363
> KASAN: probably user-memory-access in range [0x0000000000001b18-0x0000000000001b1f]
> pc : mpp_dma_release_fd+0x38/0x148
> lr : mpp_process_request+0x1564/0x1ff0
> Call trace:
>  mpp_dma_release_fd+0x38/0x148
>  mpp_process_request+0x1564/0x1ff0
>  mpp_dev_ioctl_common.isra.0 -> mpp_dev_ioctl -> __arm64_sys_ioctl -> el0_svc
> Comm: mpp-clientless-  PID: 38208
> ```
>
> **Reproducer** (`mpp-clientless-release-fd-uaf.c`): open
> `/dev/mpp_service`, do **not** send `MPP_CMD_INIT_CLIENT_TYPE`, then send one
> `MPP_CMD_RELEASE_FD` message. That is the whole trigger.
>
> **Mechanism (offset-verified).** `pahole` puts `struct device *dev` at offset
> **6936** in `struct mpp_dma_session` (size 6944). `0x363 << 3 = 0x1b18 = 6936`
> — the fault address is precisely `((struct mpp_dma_session *)NULL)->dev`.
> `session->dma` is allocated only at `INIT_CLIENT_TYPE` (`mpp_common.c:1425`)
> and NULLed by `RESET_SESSION` (`:1521`). The `MPP_CMD_RELEASE_FD` arm of
> `mpp_process_request()` called `mpp_dma_release_fd(session->dma, fd)` with
> **no NULL guard**, and `mpp_dma_release_fd()` dereferenced `dma->dev` as its
> first statement (`mpp_iommu.c:182`). RELEASE_FD faults *before* it can log,
> which is why the last lines before the organic crash were the *preceding*
> commands (`0x403` `SEND_CODEC_INFO`, `0x400` `RESET_SESSION`, both returning
> `-EINVAL` safely) — the fatal `0x402` `RELEASE_FD` left no trace.
>
> **Corrections to everything below:** the crash is **synchronous in the ioctl
> thread**, not in an async worker; the "~47 s deferred" timing and the leg-3
> `mpp_task_worker_default` attribution are **wrong**. `0053`/`0054` are still
> valid hardening but were never relevant to this crash. It is an
> **unprivileged local DoS**: any process that can open `/dev/mpp_service` (mode
> allows the `video` group) crashes the kernel with ~10 lines of C.
>
> **Fix (`0058`, defense-in-depth):**
> 1. `mpp_dma_release_fd()` and `mpp_dma_release()` reject a NULL `dma`
>    (`mpp_iommu.c`) before dereferencing it — protects every caller.
> 2. The `MPP_CMD_RELEASE_FD` case rejects `!session->dma` up front
>    (`mpp_common.c`). It checks `session->dma`, **not** `session->mpp`, because
>    after `RESET_SESSION` `session->mpp` stays set while `session->dma` is NULL.
>
> Gate: re-run the reproducer on an `0058` build — the ioctl must return
> `-EINVAL` and the board must stay up with a clean KASAN journal.

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

## Three distinct failure legs — same vector, different bugs

The one difficult vector produces **three separate defects**; conflating them
would mis-scope the fixes. They are distinct in mechanism, memory domain, and
symptom:

| Leg | Where | Mechanism | Symptom | Status |
|-----|-------|-----------|---------|--------|
| **1. VA-API driver under-allocates vs MPP's stride** | `rockchip-vaapi` (userspace) | MPP reports a 768-byte stride for the shown frame (a previously-decoded reference is larger than the nominal 352×288 — the `show_existing_frame` tell); the driver allocated the nominal size and copied/exported the `768×288×1.5 = 331,776`-byte layout → **~27 KB CPU-copy overrun past the mmap**, caught by the MMU | **segfault** (PID 62468) | **fixed userspace-side** — conservative MPP-aligned alloc + checked NV12 copy in `rockchip-vaapi` `src/frame_layout.c`, unexpected layouts now return `VA_STATUS_ERROR_DECODING_ERROR` (`src/rockchip_drv_video.c`), regression test `tests/frame_layout_test.c`, recorded against track 14 in that repo's `docs/ROADMAP.md`. Also a **track-14 (`rockchip-vaapi`) bug** in its own right. |
| **2. MPP-core VP9 buffer-slot / refcount mismanagement** | `librockchip_mpp` (userspace) | `show_existing_frame`/superframe reference-buffer ownership mishandled (the shared reference slot) | invalid ref-counts, buffer-slot assertions, **leaked buffers** (direct RKMPP, PID 63196 — no VA-API driver involved) | **open** — the decode-side root cause; not touched by the leg-1 fix |
| **3. Kernel worker NULL-derefs a device-less session's task** | `rk_vcodec` (`mpp_common.c`, this finding) | async worker dereferences `task->session->mpp == NULL` for a torn-down/never-bound session | **hard lockup** ~47 s later (deferred) | **fixed** — `0053` (worker + orphan pop/free/running) and `0054` (wait-result sibling) |

**Why legs 1 and 3 are distinct (high confidence, not certain).** Leg 1 is a
CPU copy past a userspace mmap that hit an unmapped page → **SIGSEGV**; the MMU
stopped it, so it corrupted userspace and killed the process, it did not reach
kernel memory. Leg 3 is a NULL dereference of kernel session/task state in an
async kthread, ~47 s later. A userspace stride overrun does not make the
kernel's session lose its bound device. The one scenario that *would* unify
them — the overrun writing into a **dma-buf** whose adjacent physical pages
held kernel MPP structs — is contradicted by the segfault (an MMU-caught
unmapped-page access, not silent kernel corruption). Still unprovable without
the kernel trace ramoops ate, so held as *distinct, high-confidence*.

**How the legs interact.** Fixing leg 1 stops the VA-API segfault, which
removes *one* trigger for leg 3 (a segfaulting process closes its fd and can
race the kernel teardown into orphaning a task). But leg 3 is reachable by any
clean close-with-pending-task, and leg 2 is an independent trigger, so the
kernel guards (`0053`/`0054`) are still required, and **leg 2 remains the open
decode-side root cause** regardless of the leg-1 fix.

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
   log instead of a hard lockup. This defends the crash (leg 3 above); it does
   **not** fix the upstream corruption.
2. **Decode side — leg 2, the MPP-core VP9 `show_existing_frame`
   reference-buffer refcount bug (not fixed).** The direct-RKMPP assertions
   (invalid ref counts, buffer-slot asserts, leaked buffers) point at MPP's VP9
   `show_existing_frame`/superframe buffer ownership mishandling the shared
   reference slot — the decode-side root cause. Likely in `librockchip_mpp`
   VP9 (`vp9d`) buffer/slot management rather than the kernel. **Leg 1** (the
   `rockchip-vaapi` stride under-allocation → segfault) is a *separate*
   userspace defect and is already fixed in that repo — see the three-leg
   table above; it is not this decode-side root cause.

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
  confirm the leg-3 crash site (and that `0053`/`0054` catch it).
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

## VERIFIED FIXED on Pd222-C4ad2 (2026-07-22)

Booted the KASAN debug build `Pd222-C4ad2` (`0058` compiled in; vmlinuz md5
matched the deb) with `panic_on_oops=0`. Ran the deterministic reproducer
`mpp-clientless-release-fd-uaf.c` (open `/dev/mpp_service`, skip
`INIT_CLIENT_TYPE`, one `MPP_CMD_RELEASE_FD`):

- ioctl returned `-1`/`EINVAL` (was: hard NULL deref at `mpp_dma_release_fd+0x38`,
  the `0x1b18` = `offsetof(struct mpp_dma_session, dev)` fault).
- Kernel logged the new guard: `rk_vcodec: mpp_process_request:1580: pid <n>
  release fd on session 0 with no dma`.
- Board stayed up; KASAN silent.

Regression: `kasan-mpp-suite.sh` 12/12 pass, `flagged_kernel_lines=0 clean=1` —
the guard does not perturb normal client sessions (which hold a valid
`session->dma` from `INIT_CLIENT_TYPE`). **Distribution blocker cleared.**
