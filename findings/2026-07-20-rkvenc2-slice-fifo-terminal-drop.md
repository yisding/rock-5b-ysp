# RKVENC2 silently drops the terminal slice when its per-task FIFO fills

> Scope: RK3588 VEPU580/RKVENC2 on the forward-port
> `6.18.38-current-rockchip64 #1` KASAN kernel; Rockchip MPP
> `c2c1ee502b3a`; H.264 low-delay CTU split at 1280x720.
>
> Source: bounded official-MPP hardware runs plus the exact booted-kernel and
> pinned MPP source worktrees under `/home/yi/Code/`.
>
> Date: 2026-07-20
>
> Evidence: `/home/yi/Code/rockchip-conformance/logs/forward-port/`
> `20260720-h264-slice-mt-6.log` and `.h264`; corrected controls
> `20260720-h264-slice-mt-6-ctu120.*` and
> `20260720-h265-slice-mt-6-ctu120.*`.
>
> Trust: **MEASURED** (bounded hardware reproduction) /
> **CODE-INSPECTED** (unchecked FIFO insertion and MPP retry loop) /
> **IMPLEMENTED 2026-07-25** (kernel `0075`, MPP `0002`/`0003`; compile-verified
> only — the [verification gate](#verification-gate) below is still owed).

## Result

The official multi-thread encoder with `split_mode=2`, `split_out=1`, and
`split_arg=4` generates roughly 900 H.264 slices for each 1280x720 frame. The
bounded six-frame run emitted only three decodable frames. After the kernel
lost the terminal record, the MPP process continuously logged:

```text
mpp_service_cmd_poll ioctl MPP_IOC_CFG_V1 failed ret -1 errno 5 Input/output error
```

The driver defines a 256-entry FIFO:

```c
#define RKVENC_MAX_SLICE_FIFO_LEN 256
DECLARE_KFIFO(slice_info, union rkvenc2_slice_len_info,
	      RKVENC_MAX_SLICE_FIFO_LEN);
```

but both ordinary and synthetic terminal insertions ignore `kfifo_in()`'s
return value. `slice_wr_cnt` is incremented even when no record was stored:

```c
kfifo_in(&task->slice_info, &slice_info, 1);
task->slice_wr_cnt++;
```

If the FIFO is full when the last record arrives, userspace can drain all
stored slices without ever observing `slice_info.last`. Task completion then
pops the pending task; its next poll sees an empty pending list and returns
`-EIO`.

The MPP VEPU580 H.264 HAL amplifies the kernel failure. It leaves `slice_last`
uninitialized, does not act on the poll return value, and loops only on
`slice_last`:

```c
RK_U32 slice_last;
...
ret = mpp_dev_ioctl(ctx->dev, MPP_DEV_CMD_POLL, poll_cfg);
...
} while (!slice_last);
```

Once polling returns `EIO` with `count_ret == 0`, no slice updates
`slice_last`; the userspace loop can therefore spin indefinitely.

## Harness correction and control

This reproduction used an unnecessarily aggressive split for the conformance
goal. The tracked suite now:

- uses `mpi_enc_mt_test` so its output thread drains low-delay callbacks while
  encoding is active;
- defaults `MPP_ENC_SPLIT_ARG=120`, producing multiple slices without nearing
  the 256-entry kernel FIFO; and
- defaults the slice cases to one channel.

With those settings, six-frame H.264 and H.265 controls each produced all six
decodable frames. The corrected 120-frame KASAN run
`20260720-213128-kasan-mpp-suite` passed both slice cases with an empty kernel
fatal-signature scan. This validates the ordinary polling path; it does not
make silent FIFO overflow acceptable.

## Fix direction

The kernel must never silently discard the state transition that terminates a
polling protocol. A robust change should check every `kfifo_in()` result,
remember overflow independently of FIFO contents, wake the waiter, and return
one deterministic terminal/error result before releasing the pending task.
Growing the FIFO alone only moves the threshold.

MPP should independently initialize `slice_last`, stop on a nonzero poll
result, and propagate a hardware/poll error instead of retrying forever. The
equivalent HEVC VEPU580 loop should receive the same audit even though the
bounded failure above was captured with H.264.

## What was implemented (2026-07-25)

Both sides are written and compile-verified. **Nothing has been booted or run on
hardware**, so every runtime claim below is reasoned from source, and the
verification gate that follows is entirely unmet.

### Kernel — `0075` (`12a7da02bea8`, branch `rk3588-video-6.18`)

Both `kfifo_in()` sites now go through `rkvenc2_push_slice_len()`, which
**reserves the last free slot for the terminal record**: an ordinary record is
only stored while `kfifo_avail() > 1`, so the record carrying
`slice_info.last` is always guaranteed a slot. The helper owns
`last_slice_found` and demotes a duplicate terminal record rather than letting
it consume the reservation. A dropped record's length is carried into the next
stored record, so the byte offsets userspace accumulates stay exact.

The consequence that drove the design: an overflowing frame is still **complete
and decodable** — the stream always terminates and the lengths still sum to the
frame. Only the reported slice boundaries are coarser than requested, two
adjacent slices arriving merged into one record. The condition is therefore
counted per task and reported as a ratelimited `dev_warn` from both producer and
consumer, and is deliberately **not** an error return.

> An earlier draft of this patch returned `-EOVERFLOW` from
> `rkvenc2_wait_result()` on any merge. That was wrong and was removed before
> the patch was finalised: under the very reproducer this fix targets, records
> merge on essentially every frame, so it would have failed every frame of a
> stream it had just made correct — trading a hang for total frame loss. The
> wait predicate is likewise left alone; firing it on the merge count would
> abandon the drain before the reserved terminal record reached userspace, which
> is the property that lets an already-installed userspace terminate against
> this kernel.

`W=1` builds with zero warnings; `checkpatch --strict` reports zero.

### MPP userspace — two commits on `ysp/main`

Originally landed as quilt patches `0002`/`0003` under
`packaging/ppa/mpp/debian/patches/`. MPP was converted to the fork-branch model
on 2026-07-25, so they are now the second and third commits on branch
`ysp/main` of `yisding/mpp` (tip `7c4fcda2`), still based on the `1375813c`
= `1.0.12` packaging baseline. The `0002`/`0003` names below refer to the
original patches; see [`packaging/userspace-patches.md`](../packaging/userspace-patches.md).

- **`0002`** hardens all eight vepu5xx split-output poll loops. They assigned
  the `MPP_DEV_CMD_POLL` return value but never tested it and terminated only on
  a last flag, and the four h264e HALs left that flag uninitialised — so an
  error with `count_ret == 0` spun forever. Each loop now consumes the returned
  records first (a poll delivering the terminal record *and* an error still
  completes the frame), then fails, and bounds consecutive empty-but-successful
  polls. `hal_h265e_vepu580.c` ends on a tile count rather than `slice_last`, so
  it tracks terminal delivery in a per-frame `finish_sent` flag — it must not
  test `ctx->output_cb->cmd`, which lives on the encoder-wide `MppCbCtx` and
  persists across frames, because a stale `ENC_OUTPUT_FINISH` would suppress the
  callback and reinstate this very hang.
- **`0003`** sizes the h264e poll cfg allocation from `sizeof(MppDevPollCfg)`
  rather than `sizeof(p->poll_cfgs)` (the pointer, 8 vs 16), which had left 40
  bytes per config where `mpp_service_cmd_poll()` declares 48 to the kernel. It
  also stops `hal_h264e_vepu511a.c` indexing its **single**-config allocation by
  `task->flags.reg_idx` — copied from the multi-task vepu580 HAL, latent because
  that HAL is single-task and `reg_idx` is always 0, but an out-of-bounds read
  and write for any non-zero `reg_idx`, and the size correction above would have
  widened the window from 40 to 48 bytes rather than closing it.

No ABI or struct change on either side; `poll_type` and `poll_ret` stay unused.

### Known remaining, deliberately not fixed

The hardened loops `break` on **any** non-zero poll return. Two of
`rkvenc2_wait_result()`'s error returns do not pop the task off
`session->pending_list`: `-ERESTARTSYS` from a signal interrupting
`wait_event_interruptible()`, and `-EINVAL` from a failed `copy_from_user()` of
the poll cfg. On either, userspace abandons a task the kernel still holds, so
the next frame's poll would drain the previous frame's task and desynchronise
the session by one.

This is not addressed here. It is strictly better than the pre-fix behaviour
(an unbounded spin), the correct handling for `-ERESTARTSYS` is to retry rather
than fail — which needs the errno actually preserved through `mpp_dev_ioctl()`,
not yet traced — and neither path is known to be reachable in the MPP encoder
threads. It is recorded so the next person does not rediscover it as a new
defect. The empty-poll bound (`HAL_ENC_SLICE_POLL_EMPTY_MAX`) means no variant
of this can hang.

### Object-lifetime review (2026-07-25) — clean

Given this driver's history
([wait-result UAF](./2026-07-18-rkvenc2-wait-result-task-uaf-kasan.md),
[lifetime audit](./2026-07-21-forward-port-lifetime-resource-ownership-audit.md)),
`0075` was put through a dedicated lifetime and concurrency review. **No blocking
findings.** The four load-bearing results, each re-verified against the source:

- **The new fields cannot carry stale state.** `rkvenc_alloc_task()` is a plain
  `kzalloc()` per submission (`mpp_rkvenc2.c:1179`) with `kfree()` on release and
  no `kmem_cache`, `mempool` or free-list anywhere in the file, so
  `slice_drop_cnt`/`slice_drop_len` start at zero every frame. The worry that
  motivated the review — a recycled task carrying `slice_drop_len` into the next
  frame's first slice length — is unreachable. The explicit `INIT_KFIFO` that
  suggested recycling is a red herring: it sets `esize` and `data`, which
  `kzalloc` leaves as 0/NULL, so it is *mandatory* on freshly zeroed memory.
- **Producer/consumer ordering is sound by construction, not by luck.**
  `try_process_running_task()` brackets `dev_ops->isr` in
  `disable_irq()`/`enable_irq()` (`mpp_common.c:976,993,994`), and `rkvenc_isr()`
  clears `mpp->cur_task` *inside* that bracket before `mpp_task_finish()` sets
  `TASK_STATE_DONE`. Since `mpp->cur_task` is the hard IRQ's only handle on the
  task, this both flushes any in-flight producer (`disable_irq` implies
  `synchronize_irq`) and permanently severs the IRQ from the task. A plain
  `set_bit` would *not* have sufficed.
- **The post-free warn is safe.** `merged` and `task_id` are pre-sampled locals;
  `mpp` is `devm`-allocated with the platform device; `session` is pinned by the
  fd for the duration of the ioctl. Nothing added by the patch touches `task` or
  `enc_task` after `rkvenc2_task_default_process()`, preserving `0043`'s
  read-before-pop discipline. The patch adds zero pops and zero refcount
  operations, and the removed `-EOVERFLOW` draft left no orphaned early exit.
- **The reservation invariant is proven, not merely plausible.** `kfifo_avail()`
  reaches 0 only immediately after a successful terminal store, and that store is
  precisely what sets `last_slice_found`, which demotes any later terminal record
  to ordinary. So a terminal record arriving with `last_slice_found == 0` always
  sees `avail >= 1`, and `kfifo_in()` with `avail >= 1` always succeeds. Also
  checked: `union rkvenc2_slice_len_info` is `slice_len : 31 / last : 1`, so an
  accumulated carry-forward length truncates within its own field and cannot
  clobber the terminal bit — the invariant does not depend on the length being
  small.

Two **pre-existing** hazards were re-confirmed as neither created nor worsened by
this patch: audit item F2 (two result waiters on one fd can double-pop a task and
break the fifo's single-consumer assumption) and F3 (timeout-work ownership).
F2 has a direct bearing on scoring the gate — see below.

This is a static review. It lowers the risk of the KASAN run; it does not replace
it.

### Known remaining, deliberately not fixed

### Conformance fixture

The conformance MPP checkout is pinned to a **different** base
(`c2c1ee502b3a`, per `MANIFEST.tsv`) than the packaging baseline, so the quilt
patches do not apply to it. The same changes are carried as a repo-owned
bootstrap patch at
[`kernel-drivers/tests/conformance/patches/rockchip-mpp/0001-harden-encoder-slice-poll-loops.patch`](../kernel-drivers/tests/conformance/patches/rockchip-mpp/0001-harden-encoder-slice-poll-loops.patch),
applied automatically by `scripts/bootstrap-sources.sh`. This matters for
scoring the gate below: **without the userspace half, the official MPP binaries
hang instead of terminating**, so a gate run against unpatched userspace would
misreport the kernel fix as a failure.

## Verification gate

**Unmet as of 2026-07-25.** Requires a rebuilt kernel carrying `0075` and MPP
binaries carrying the userspace half (see the conformance-fixture note above).

- Re-run the bounded `split_arg=4` reproducer:

  ```bash
  MPP_ENC_SPLIT_MODE=2 MPP_ENC_SPLIT_ARG=4 MPP_ENC_SPLIT_OUT=1 \
  MPP_ENC_FRAMES=6 MPP_ENC_SLICE_INSTANCES=1 MPP_TIMEOUT=120 \
  MPP_REQUIRED_CASES="mpi_enc_h264_slice mpi_enc_h265_slice" \
    bash kernel-drivers/tests/mpp-suite.sh forward-port
  ```

- Require **bounded termination with a complete stream**: all six frames out,
  decodable. Repeated `EIO` polling is a failure, and so is any frame *lost* —
  the implemented design merges slice boundaries but never fails a frame, so a
  frame-level error here means the fix regressed.
- Require the merge to be *visible*: `dmesg` should carry the ratelimited
  `slice fifo full (256), merged N record(s)` producer warning and the matching
  `session … merged N slice record(s)` consumer warning. Silence at
  `split_arg=4` means the reservation is not being exercised and the run proves
  nothing.
- Confirm the next encoder job succeeds, proving pending-task cleanup and
  scheduler recovery.
- Re-run the ordinary `split_arg=120` H.264/H.265 suite and require every frame,
  a decodable artifact, and a clean KASAN/fatal-signature scan:

  ```bash
  MPP_ENC_SPLIT_ARG=120 MPP_ENC_FRAMES=120 \
    bash kernel-drivers/tests/kasan-mpp-suite.sh
  ```

- Because `hal_h265e_vepu580.c`'s `finish_sent` fix only bites with
  `tile_parall_en` and low-delay split output, add an H.265 tile-parallel
  low-delay case, or record explicitly that the path stayed unexercised.
- Configure the run with **one result consumer per fd**. Pre-existing audit item
  F2 (two result waiters on a single fd can double-pop a task and violate the
  fifo's single-consumer assumption) is independent of this fix but would produce
  KASAN noise that is easy to misattribute to the merge path.
