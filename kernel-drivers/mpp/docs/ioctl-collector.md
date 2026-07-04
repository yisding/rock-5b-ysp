# The ioctl collector: LAST_MSG and how a batch becomes a task

How one `MPP_IOC_CFG_V1` syscall — a *packed array* of messages — is walked by the
kernel, accumulated into per-session task containers, and turned into hardware
jobs. This is the **kernel-side** companion to the user-facing ABI overview in
[`../../docs/dev-uapis.md § A`](../../docs/dev-uapis.md) (read that first for the
`MppReqV1` envelope and the flag/command tables). Here we trace what the driver
actually does with those messages, and pin down the one detail that trips people
up: **`LAST_MSG` is a whole-syscall terminator, not a per-batch delimiter.**

> **Anchors & provenance.** `~:line` anchors resolve against the **vendor** tree
> (`rockchip-linux/kernel`, `develop-6.1`,
> `drivers/video/rockchip/mpp/mpp_common.c` + `mpp_common.h`; also present in the
> sibling `rockchip-kernel` working tree). Line numbers drift across branches — the
> `~:` is approximate; the function names are exact. The uAPI constants are in
> `include/uapi/linux/rk-mpp.h`.

---

## 1. The one paragraph

Userspace doesn't do one `ioctl()` per register-write or poll. It packs many
sub-messages into a single `MPP_IOC_CFG_V1` call — a register recipe *plus* a poll,
sometimes spanning *several* codec sessions — and the kernel **collects** them into
one or more task containers, submits those to the hardware queue, then blocks for
the results. The collector loop is driven entirely by two flag bits: `MULTI_MSG`
("keep walking") and `LAST_MSG` ("this is the final message — stop"). Everything
else about batching (multi-session submission, the wait array) is layered on top of
that loop by a *third* command, `SET_SESSION_FD`, which acts as an internal batch
separator.

---

## 2. The whole flow, one screen

Every operation on `/dev/mpp_service` funnels through a single ioctl handler
(`mpp_dev_ioctl`, `mpp_common.c` ~:1703):

```
mpp_dev_ioctl()                         // ~:1703
  → mpp_collect_msgs(&msgs_list, ...)   // ~:1507  parse userspace → build task container(s)
  → mpp_msgs_trigger(&msgs_list)        // ~:1636  push tasks onto HW queue, kick the worker
  → mpp_msgs_wait(&msgs_list)           // ~:1681  block on poll, release containers
```

`msgs_list` is an **ioctl-local** list. One syscall can produce **several**
`mpp_task_msgs` on it (one per session batch, see § 5) — that is the whole point of
the multi-session path.

---

## 3. The wire format the collector reads

The `arg` to `MPP_IOC_CFG_V1` is a *packed array* of the fixed on-the-wire header
`struct mpp_msg_v1` (`mpp_common.c` ~:40 — the kernel's private copy of userspace's
`MppReqV1`):

```c
struct mpp_msg_v1 {
    __u32 cmd;        /* which MPP_CMD_*                          */
    __u32 flags;      /* MPP_FLAGS_* — MULTI_MSG / LAST_MSG / ... */
    __u32 size;       /* payload byte size                        */
    __u32 offset;     /* register-patch offset                    */
    __u64 data_ptr;   /* userspace pointer to the payload         */
};
```

The collector copies **only this fixed header** each iteration; the real payload
stays in userspace behind `data_ptr` and is pulled in later, per-command. The
terminator logic (`mpp_msg_is_last`, `mpp_common.c` ~:1194; inlined into the loop
at ~:1536):

```c
if (flags & MPP_FLAGS_MULTI_MSG)
    last = (flags & MPP_FLAGS_LAST_MSG) ? 1 : 0;
else
    last = 1;   /* no MULTI_MSG => a lone message => last by definition */
```

Two modes fall out of this:
- **Legacy single-message** — no `MULTI_MSG` bit → `last = 1`, one pass, done.
- **Batched** — every message carries `MULTI_MSG`; the loop keeps going (`goto next`)
  until it sees the one that *also* carries `LAST_MSG`.

---

## 4. The collector loop — `mpp_collect_msgs()` (mpp_common.c ~:1507)

This is "the kernel collector." It turns the byte stream into one or more
`mpp_task_msgs`. Per iteration:

1. **`copy_from_user` one `mpp_msg_v1`** (~:1523), advance the userspace cursor by
   `sizeof(msg_v1)` (~:1526). *(Rejects anything but `MPP_IOC_CFG_V1` up front,
   ~:1516 — `MPP_IOC_CFG_V2` is reserved/unused.)*
2. **Validate the cmd** — `mpp_check_cmd_v1()` range-checks it against the
   QUERY / INIT / SEND / POLL / CONTROL groups (~:1531).
3. **Compute `last`** from the flags (§ 3).
4. **Grab a container** — `msgs = get_task_msgs(session)` (~:1599).
5. **Record the request** into `msgs->reqs[msgs->req_cnt++]` (~:1613), hard-capped at
   `MPP_MAX_MSG_NUM = 16` (~:1607, `mpp_common.h` ~:32) → overflow returns `-EINVAL`.
6. **Dispatch** via `mpp_process_request()` (~:1620) — the per-command switch (§ 6).
7. **`if (!last) goto next;`** (~:1627) — loop for the next header.
8. **On `last`:** `task_msgs_add(msgs, head)` (~:1630) finalizes the batch onto
   `msgs_list`, then `return 0`.

`task_msgs_add()` (~:1487) is where a container becomes runnable: if it accumulated
any *set* work (`set_cnt`, § 6) it stamps `session->msg_flags = msgs->flags` and
calls `mpp_process_task()` (~:1496) to build the actual `mpp_task`; then it links
the container onto the ioctl's list.

---

## 5. `SET_SESSION_FD` — the real batch delimiter (the load-bearing subtlety)

**This is the part people misread.** A single ioctl can carry work for **multiple
sessions** via `MPP_CMD_SET_SESSION_FD` (~:1542), each pointing at a
`struct mpp_bat_msg { __u64 flag; __u32 fd; __s32 ret; }` (`rk-mpp.h` ~:76). When
the collector hits one it (~:1568):

- **flushes the current container** — if it has requests, `task_msgs_add(msgs, head)`;
  else `put_task_msgs(msgs)` to drop an empty one — then `msgs = NULL`;
- **switches session** — `fdget` the target, `session = f.file->private_data`,
  `msgs = get_task_msgs(session)` for a fresh container (~:1579);
- skips the slot entirely if `bat_msg.flag & MPP_BAT_MSG_DONE` (an already-finished
  slot in a reused wait array).

So the flush happens on the **leading edge of the *next* `SET_SESSION_FD`**, not on a
trailing marker. Each `SET_SESSION_FD` closes the previous batch and opens a new one.

### The gotcha: `LAST_MSG` terminates the *loop*, not a *batch*

Both exit paths `return 0` the instant `last` is true:

```c
/* SET_SESSION_FD path (~:1590) */
session_switch_done:
	if (last)
		return 0;      /* and the guard comment: "session id should NOT be the last message" */
	goto next;

/* normal SET_REG / POLL / ... path (~:1627) */
	if (!last)
		goto next;
	task_msgs_add(msgs, head);   /* flush the FINAL batch */
	msgs = NULL;
	return 0;
```

**Consequence:** the *first* message flagged `LAST_MSG` ends collection for the
entire syscall. There is **exactly one `LAST_MSG` per ioctl**, on its very last
message. If a caller wrongly set `LAST_MSG` on each batch's tail, the collector
would stop after batch #1 and **silently drop every batch after it**. And
`SET_SESSION_FD` must *not* be the last message (~:1591 guard) — it's a separator,
never a terminator.

So a well-formed multi-session batch looks like:

```
SET_SESSION_FD(A)   MULTI                    ← starts batch A
SET_REG_WRITE       MULTI
POLL_HW_FINISH      MULTI
SET_SESSION_FD(B)   MULTI                    ← flushes A onto msgs_list, starts batch B
SET_REG_WRITE       MULTI
POLL_HW_FINISH      MULTI | LAST_MSG         ← flushes B, ends the ioctl
```

Batch boundaries are the `SET_SESSION_FD` markers; the single trailing `LAST_MSG`
flushes the tail and stops the loop. A **single-session** batched ioctl never uses
`SET_SESSION_FD` at all — just a run of `MULTI_MSG` messages ending in `LAST_MSG`.

> **Cross-check.** libmpp's batch server builds its wait array as repeated
> `SET_SESSION_FD` + `POLL_HW_FINISH | POLL_NON_BLOCK | LAST_MSG` pairs — see
> [`../../docs/dev-uapis.md § A`](../../docs/dev-uapis.md). Current libmpp no
> longer wires callers to this server, so the *rewrite* driver recognizes that
> wait-array shape and rejects it with `-EOPNOTSUPP`; generic batches still stop
> at the first `LAST_MSG`.

---

## 6. What `mpp_process_request()` records (mpp_common.c ~:1235)

A big switch on the inner `cmd`. Two categories decide whether a container becomes a
task and/or a wait:

```c
case MPP_CMD_SET_REG_WRITE:
case MPP_CMD_SET_REG_READ:
case MPP_CMD_SET_REG_ADDR_OFFSET:
case MPP_CMD_SET_RCB_INFO:
    msgs->flags |= req->flags;
    msgs->set_cnt++;          /* → this batch will SUBMIT a task   (~:1364) */

case MPP_CMD_POLL_HW_FINISH:
    msgs->flags |= req->flags;
    msgs->poll_cnt++;         /* → this batch will WAIT for a task (~:1368) */
```

- `set_cnt > 0` ⇒ `task_msgs_add` calls `mpp_process_task` (~:1493) to build/queue an
  `mpp_task`.
- `poll_cnt > 0` ⇒ `mpp_msgs_wait` calls `mpp_wait_result` (~:1689) to block for the
  IRQ.
- `POLL_HW_IRQ` (~:1371) is the poll-with-payload variant and stashes a `poll_req`.
- QUERY / INIT / TRANS_FD / RESET / RELEASE commands are handled **inline right here**
  and never become a task (e.g. `INIT_CLIENT_TYPE` routes the session to a driver
  and attaches its workqueue; `RESET_SESSION` drains `task_count` with a 500 ms
  `readx_poll_timeout` then tears down `session->dma`).

---

## 7. The container and its pool — `mpp_task_msgs` (mpp_common.h ~:156)

The accumulator the collector fills:

```c
struct mpp_task_msgs {
    struct list_head list;          /* link into the ioctl's msgs_list          */
    struct list_head list_session;  /* link into the session's idle/busy pool    */
    struct mpp_session *session;
    struct mpp_taskqueue *queue;
    struct mpp_task *task;
    struct mpp_dev *mpp;
    int ext_fd; struct fd f;        /* held fd for the SET_SESSION_FD path        */
    u32 flags;                      /* OR of every sub-message's flags            */
    u32 req_cnt, set_cnt, poll_cnt;
    struct mpp_request reqs[MPP_MAX_MSG_NUM];   /* up to 16 collected requests    */
    struct mpp_request *poll_req;
};
```

These are **not** malloc'd per ioctl. Each session keeps a freelist:
- `get_task_msgs()` (~:234) pops from `session->list_msgs_idle`, or `kzalloc`s a new
  one and bumps `session->msgs_cnt`;
- `put_task_msgs()` (~:265) `fdput`s any held fd, `task_msgs_reset()`s the counters
  (~:210 — zeroes `flags`/`req_cnt`/`set_cnt`/`poll_cnt`), and returns it to
  `list_msgs_idle`;
- `clear_task_msgs()` (~:287) frees the whole pool at session teardown.

This is why the hot submit/poll path does no per-call allocation.

---

## 8. After collection: trigger, then wait

- **`mpp_msgs_trigger()`** (~:1636) — for each container with `set_cnt && queue`, set
  `TASK_STATE_PENDING`, add `task->queue_link` to `queue->pending_list`, and kick
  `mpp_taskqueue_trigger_work()`. It batches the `pending_lock`/trigger **per queue**
  (tracking `queue_prev`) to avoid re-locking across a multi-session submit.
- **`mpp_msgs_wait()`** (~:1681) — for each container with `poll_cnt`, call
  `mpp_wait_result()` to block until the hardware IRQ signals completion, then
  `put_task_msgs()` returns the container to the pool.

For where the task then runs on one/both cores, see
[`multicore-scheduling.md`](multicore-scheduling.md).

---

## 9. Cheat sheet

- **`MULTI_MSG`** = "more messages follow in this syscall — keep walking."
- **`LAST_MSG`** = "final message of the whole syscall — stop the loop." **One per
  ioctl.** Not a per-batch marker; the first one seen ends collection.
- **`SET_SESSION_FD`** = the *batch* delimiter: it flushes the previous container as
  its own `mpp_task_msgs` and opens a fresh one for the next session. May not be the
  last message.
- One ioctl → possibly many `mpp_task_msgs` (one per session batch) → each with
  `set_cnt` submit work and/or `poll_cnt` wait work.
- **The collector** = `mpp_collect_msgs()`: copy header → record into a pooled
  container → dispatch → on `LAST_MSG`, finalize onto the ioctl's list; then
  `trigger` (queue + kick) and `wait` (block on IRQ, recycle container).

## Sources

- Vendor source — `rockchip-linux/kernel` `develop-6.1`,
  `drivers/video/rockchip/mpp/mpp_common.c` (`mpp_collect_msgs`,
  `mpp_process_request`, `mpp_msgs_trigger`/`_wait`, `get`/`put_task_msgs`) and
  `mpp_common.h` (`struct mpp_task_msgs`, `MPP_MAX_MSG_NUM`).
- uAPI — `include/uapi/linux/rk-mpp.h` (`MPP_FLAGS_*`, `struct mpp_request`,
  `struct mpp_bat_msg`, `enum MPP_DEV_COMMAND_TYPE`).
- User-facing ABI companion — [`../../docs/dev-uapis.md § A`](../../docs/dev-uapis.md).
