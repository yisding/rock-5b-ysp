# MPP ioctl surface and batch mode

How `librockchip_mpp` talks to `/dev/mpp_service`: the single `MPP_IOC_CFG_V1`
ioctl, the `MppReqV1` message format, the `MULTI_MSG`/`LAST_MSG` chaining that
packs many sub-commands into one syscall, and the cross-session **batch server**
— which is fully implemented but **dormant** (no live caller).

Complements [`mpp-library-architecture.md`](mpp-library-architecture.md) (see its
"Kernel Device Boundary" section for the higher-level `MppDev` picture) and the
kernel ABI notes in
[`../../../kernel-drivers/docs/dev-uapis.md`](../../../kernel-drivers/docs/dev-uapis.md).

Sources studied:

| Source | Notes |
|--------|-------|
| `mpp-rockchip` at `1375813cbbae5ad6861b166475dd8fb672183220` | Current HEAD; all `(~:NNN)` anchors below are against this tree. |
| `osal/inc/mpp_service.h` | ioctl number, flags, `MppReqV1`, command enum. |
| `osal/driver/mpp_service.c` | Request assembly, flag stamping, the actual `ioctl()` sites. |
| `osal/driver/mpp_server.c` | The cross-session batch server (dormant). |
| `osal/driver/mpp_device.c` | `MppDev` dispatch (`MPP_DEV_BATCH_ON`, `MPP_DEV_DELIMIT`, `MPP_DEV_CMD_SEND`). |
| Commits `16ce9d1f`, `ecf7531c`, `e66e69d3` | The rise-and-removal history of batch mode (git-verified). |

> **Trust:** the code facts are read-from-source at the pin above and the history
> is git-verified (**MEASURED** in that sense). Two claims are reasoned, not
> confirmed, and tagged **HYPOTHESIS** inline: (a) the exact kernel-side
> buffer-walking loop (kernel driver is out of this tree), and (b) that "fast
> mode" deliberately superseded batch mode.

## One ioctl number, many logical commands

The kernel driver exposes essentially a single ioctl:

```c
/* osal/inc/mpp_service.h */
#define MPP_IOC_MAGIC     'v'
#define MPP_IOC_CFG_V1    _IOW(MPP_IOC_MAGIC, 1, unsigned int)   /* :14 */
```

Every userspace→kernel interaction — probe, init, register write/read, fd→IOVA
translation, poll — goes through `MPP_IOC_CFG_V1`. The *real* command lives inside
the payload, not in the ioctl number. This keeps the kernel ABI stable while
Rockchip adds sub-commands over time and negotiates support at runtime.

### The wire format: `MppReqV1`

```c
/* osal/inc/mpp_service.h:86 */
typedef struct mppReqV1_t {
    RK_U32 cmd;       /* MppServiceCmdType — the real command */
    RK_U32 flag;      /* MPP_FLAGS_* — MULTI_MSG / LAST_MSG / ... */
    RK_U32 size;      /* byte size of *data_ptr */
    RK_U32 offset;
    RK_U64 data_ptr;  /* pointer to command-specific payload */
} MppReqV1;
```

`cmd` draws from `MppServiceCmdType` (`mpp_service.h:48`), grouped into ranges:
`QUERY` (0x0), `INIT` (0x100), `SEND` (0x200), `POLL` (0x300), `CONTROL` (0x400).
Runtime capability probing (`check_mpp_service_cap()`, `mpp_service.c:99`) reads
`/proc/mpp_service/support[s]-cmd` and per-range `QUERY_CMD_SUPPORT` so newer
commands degrade gracefully on older kernels.

### The flags

```c
/* osal/inc/mpp_service.h:23 */
#define MPP_FLAGS_MULTI_MSG         (0x00000001)  /* more MppReqV1 follow in the buffer */
#define MPP_FLAGS_LAST_MSG          (0x00000002)  /* end of the current task — commit it */
#define MPP_FLAGS_REG_FD_NO_TRANS   (0x00000004)
#define MPP_FLAGS_SCL_FD_NO_TRANS   (0x00000008)
#define MPP_FLAGS_REG_OFFSET_ALONE  (0x00000010)
#define MPP_FLAGS_POLL_NON_BLOCK    (0x00000020)
#define MPP_FLAGS_SECURE_MODE       (0x00010000)
```

The two that matter here are orthogonal:

- **`MULTI_MSG`** = "there is another `MppReqV1` immediately after this one in the
  buffer — keep reading."
- **`LAST_MSG`** = "this is the last message of the *current task* — commit /
  dispatch it now."

## Two ioctl entry points

```c
/* osal/driver/mpp_service.c */
RK_S32 mpp_service_ioctl(RK_S32 fd, RK_U32 cmd, RK_U32 size, void *param); /* :58 */
RK_S32 mpp_service_ioctl_request(RK_S32 fd, MppReqV1 *req);                /* :73 */
```

- `mpp_service_ioctl()` builds one stack `MppReqV1` and fires one ioctl — for
  simple one-shots (probe, `INIT_CLIENT_TYPE`, `QUERY_HW_ID`).
- `mpp_service_ioctl_request()` takes a pre-built `MppReqV1` (or the head of an
  array) — this is the multi-message path. Both end at
  `ioctl(fd, MPP_IOC_CFG_V1, req)`.

## Assembling and flushing a task (single session)

The service context (`MppDevMppService *p`) owns a growable `reqs[]` array plus
`req_cnt`. HAL code never ioctls directly; it calls `mpp_dev_ioctl(dev,
MPP_DEV_REG_WR, ...)` etc., routed by `mpp_device.c` (`:98`) to builders that
**append** one `MppReqV1` each — no syscall yet:

- `mpp_service_reg_wr()` / `mpp_service_reg_rd()` (`mpp_service.c:491` / `:505`)
- `mpp_service_next_req()` (`:181`) hands out the next slot, doubling the buffer
  when full.

The flush is `mpp_service_cmd_send()` (`:719`). Its core is the flag stamping:

```c
/* osal/driver/mpp_service.c:770 */
if (p->req_cnt > 1) {
    for (i = 0; i < p->req_cnt; i++)
        p->reqs[i].flag |= MPP_FLAGS_MULTI_MSG;                 /* all: "more follow" */
}
p->reqs[p->req_cnt - 1].flag |= MPP_FLAGS_LAST_MSG | MPP_FLAGS_REG_OFFSET_ALONE; /* last only */
...
ret = mpp_service_ioctl_request(p->server, &p->reqs[0]);        /* :784 — ONE ioctl, whole array */
```

So a normal decode/encode submission is: N `SET_REG_WRITE` / `SET_REG_READ` /
`SET_REG_ADDR_OFFSET` / `SET_RCB_INFO` messages accumulated in `reqs[]`, then a
single ioctl on the session's own fd, where the kernel walks all N because each
carries `MULTI_MSG`, stopping at `LAST_MSG`. Completion is collected by
`mpp_service_cmd_poll()` (`:801`) with a single `POLL_HW_FINISH`/`POLL_HW_IRQ`.

> **Corollary — exactly one `LAST_MSG` per normal submission.** One `cmd_send`
> stamps `LAST_MSG` on only the final request, so a single-session flush can never
> produce two.

## Can one ioctl carry multiple `LAST_MSG`s?

Yes, but only via the batch server (below). Two things that look related but are
**not** the same:

### `MPP_DEV_DELIMIT` — within-session multi-task packing (this IS used)

`mpp_service_delimit()` (`:441`) appends a `MPP_CMD_SET_SESSION_FD` marker
(flag `MULTI_MSG`) into the current request list to separate multiple sub-tasks of
**one frame in one session**. Live callers:

- `mpp/hal/rkenc/h265e/hal_h265e_vepu580.c` (`~:2991`) — between H.265 **tiles**
- `mpp/hal/vpu/jpege/hal_jpege_vepu2_v2.c` (`~:721`) — between JPEG **partitions**

The whole list still flushes as one direct ioctl on the session's own fd with a
single terminating `LAST_MSG`; the buffer looks like
`[tile0 regs][SESSION_FD][tile1 regs][SESSION_FD]…[LAST_MSG]`. So delimit produces
multiple `SESSION_FD` markers but still only **one** `LAST_MSG`. It does not touch
`mpp_server.c`.

### The cross-session batch server — multiple `LAST_MSG`s (this is DORMANT)

`osal/driver/mpp_server.c` aggregates *different sessions'* tasks into one buffer
and fires one ioctl on a dedicated per-client-type server fd
(`server_fd = open(...)`, `:578`). Each session first runs its own `cmd_send`
(stamping `LAST_MSG` on its last req), then the server copies those reqs verbatim
and prepends a `SET_SESSION_FD` header per task (`try_proc_pending_task`,
`:434`–`:463`). Result — one ioctl (`batch_send`, `:246`) carrying:

```text
[SET_SESSION_FD  client=A   MULTI_MSG]        <- header for task A
[reg_wr          MULTI_MSG]
[reg_rd          MULTI_MSG | LAST_MSG]        <- LAST_MSG #1  (end of task A)
[SET_SESSION_FD  client=B   MULTI_MSG]        <- header for task B
[reg_wr          MULTI_MSG]
[reg_rd          MULTI_MSG | LAST_MSG]        <- LAST_MSG #2  (end of task B)
...
```

The matching wait buffer holds one `POLL_HW_FINISH` per task, each with
`POLL_NON_BLOCK | MULTI_MSG | LAST_MSG`, submitted in one ioctl (`process_task`,
`:283`). Here `LAST_MSG` delimits a per-session task while `MULTI_MSG` (still set
on that same entry) keeps the kernel reading into the next task group.

> **Kernel cross-check:** the BSP `mpp_service` collector still treats
> `LAST_MSG` as the terminator for the whole ioctl, including the
> `SET_SESSION_FD` path. It does not expose a general multi-`LAST_MSG`
> continuation ABI for normal submissions. The rewrite therefore recognizes the
> dormant batch-server wait-array shape and rejects it with `-EOPNOTSUPP` rather
> than preserving a userspace-only layout that current libmpp no longer wires.

## Why the batch server is dormant

Batch mode turns on only through:

```text
mpp_dev_ioctl(dev, MPP_DEV_BATCH_ON)           <- the trigger
  -> api->attach == mpp_service_attach          (mpp_device.c:114)
    -> mpp_server_attach                         (mpp_service.c:421)
      -> server_attach -> ctx->batch_io = 1      (mpp_server.c:731)
```

`MPP_DEV_BATCH_ON` / `MPP_DEV_BATCH_OFF` have **zero callers** in the tree — only
the enum declaration (`mpp_device.h:22`) and the switch handler
(`mpp_device.c:114`). Consistent with that, `serv_ctx` is only ever set to `NULL`
and `batch_io` is only set to 1 inside the unreachable `server_attach`. Every real
submission takes the direct-ioctl branch (`mpp_service.c:784`); the server thread,
10 ms batch timer, and aggregation never run.

### History: live for ~11 months, then dropped

| Date | Commit | What happened |
|------|--------|---------------|
| 2021-05-08 | `16ce9d1f` | `mpp_server.c` added — *"Add mpp_server module for batch mode"*; rationale: *"reduce the ioctl overhead on ultra multi-instance case."* |
| 2021-06-03 | `ecf7531c` | **Trigger wired up.** Added `batch_mode` to `MppDecBaseCfg` and real callers in `mpp/codec/mpp_dec.cpp`: `mpp_dec_update_cfg` did `if (batch_mode) MPP_DEV_BATCH_ON else BATCH_OFF`; `mpp_dec_deinit` did `BATCH_OFF`. |
| 2022-05-12 | `e66e69d3` | **Trigger removed.** The commit *"Diable fast mode when hal not support"* deleted `MppDecImpl.batch_mode` and both `BATCH_ON/OFF` calls, replacing that region of `mpp_dec_update_cfg` with `parser_fast_mode`/`fast_parse` logic. |
| since | — | `git log -S MPP_DEV_BATCH_ON --all` shows no re-addition. Dead ~3 years. |

Two notes:

- **HYPOTHESIS — fast mode superseded it.** The removal commit never mentions
  batch mode; it's about HAL `support_fast_mode`. But the batch block occupied the
  exact spot fast mode took over, and nothing restored it, so fast mode
  (per-frame pipelining) appears to be the throughput mechanism that replaced it.
  See [`mpp-fast-mode.md`](mpp-fast-mode.md) for how fast mode works.
- **Never wired into encoders** — batch mode only ever had a decoder caller.
  Encoders use `MPP_DEV_DELIMIT` (above), which is unrelated and still active.

### Still maintained despite being dead

The module is kept compiling: `ed3995dc` (2025-03-19) rewrote it C++→C, and later
commits touched it for a mem-pool refactor and a MISRA macro rename. So it is
carried intentionally, not rotting — but no caller reconnects it.

### Vestige: the `batch_mode` config knob

The public field outlived its consumer — `mpp/inc/mpp_dec_cfg.h` (`~:42`) and the
config table in `mpp/base/mpp_dec_cfg.c` (`~:31`) still expose `base:batch_mode`,
so an app can set it, but the internal reader was deleted in 2022. **Setting it
today is a silent no-op.**

## Reactivation sketch (if ever needed)

Re-add a `mpp_dev_ioctl(dev, MPP_DEV_BATCH_ON, NULL)` (gated on `batch_mode`) in
`mpp/codec/mpp_dec.c` around config update, with the matching `BATCH_OFF` on
deinit — roughly reverting the `ecf7531c` codec-side hunk onto the current C tree.
Before doing so, understand why fast mode replaced it (that is where the
multi-instance performance work went) and design a fresh kernel contract for
batch-server submit/wait arrays; the current rewrite intentionally rejects that
dormant path.
