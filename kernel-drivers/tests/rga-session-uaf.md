# rga-session-uaf — RGA session-close force-free reproducer

Targeted reproducer for the `/dev/rga` session-close hazard analysed in
[`findings/2026-07-17-rga-session-close-uaf.md`](../../findings/2026-07-17-rga-session-close-uaf.md).
It exercises the driver **cleanup** path only (it does not validate blit output)
and exists to convert the crash from *plausible-by-inspection* to *proven under
KASAN*.

> ⚠️ **Destructive by design.** Mode `cross` provokes a kernel use-after-free on
> a vulnerable kernel and can crash or corrupt the machine. Run it only on a
> disposable test board, ideally a **KASAN** debug build. Access to `/dev/rga`
> and a `dma_heap` node is a security boundary; treat this as a kernel exploit
> harness, not a conformance test.

## Why two modes

The audit (see the finding) narrowed the hazard precisely:

- The force-free (`rga_mm_force_releaser_buffer()`) only becomes a
  use-after-free when a **direct pointer** to the freed `internal_buffer`
  survives the free. Userspace handle access always goes through `idr_find()`,
  which fails safe once the entry is removed.
- The only direct-pointer holder is an **in-flight job** (`rga_mm_get_buffer()`
  takes the kref at submit time and holds it to completion).
- A closing session's *own* in-flight jobs are drained first by
  `rga_request_session_destroy_abort()`. So the reachable UAF is specifically a
  job from **another** session referencing a buffer whose nominal owner closes —
  reachable because imports de-dup across sessions while `->session` records only
  the first importer.

The two modes map onto that:

| Mode | What it drives | Determinism | Purpose |
|------|----------------|-------------|---------|
| `leak` (default) | one session imports a dma-buf, leaks the handle, closes → refcount-1 force-free | deterministic | Reproduce the **reported** conditions. Clean by inspection, so a **quiet KASAN run here is evidence the reported Oops was not this path in isolation**. |
| `cross` | session B holds outstanding async jobs on buffers **owned by** session A, then A closes | probabilistic (job window) | Trip the **reachable cross-session UAF** the driver fix targets. |

## Build

```sh
kernel-drivers/tests/rga-session-uaf.sh leak      # or: cross
```

The script mirrors `abi-probe.sh` include paths (`rga_ioctl.h` from the librga
fork, kernel uAPI). Override `KERNEL_UAPI` / `LIBRGA_ROOT` etc. as for
`abi-probe.sh`. Build only (to copy the binary to the board):

```sh
CC=aarch64-linux-gnu-gcc BUILD_DIR=./out kernel-drivers/tests/rga-session-uaf.sh --help
```

## Run under a KASAN kernel

Boot a debug kernel built with `CONFIG_KASAN=y` (and, ideally,
`CONFIG_KASAN_INLINE`, `CONFIG_DEBUG_KMEMLEAK` off to reduce noise). Also make
the crash *persist* across the hard reset so the trace is not lost the way the
original was — configure `ramoops`/`pstore` (or `crashkernel=`/kdump) so the
Oops survives:

```sh
# Reported conditions (deterministic). Expect: no KASAN report on any kernel.
kernel-drivers/tests/rga-session-uaf.sh leak
RGA_UAF_FORK=1 kernel-drivers/tests/rga-session-uaf.sh leak   # process-exit variant

# Reachable cross-session UAF (loops until it hits the window).
RGA_UAF_ITERS=5000 RGA_UAF_BURST=64 kernel-drivers/tests/rga-session-uaf.sh cross
```

### Expected outcomes

| Kernel | `leak` | `cross` |
|--------|--------|---------|
| Unpatched fwport (`force_releaser`) | quiet (path is clean at refcount 1) | **KASAN use-after-free** in the RGA job-completion / `kref_put` path — the proof |
| Patched (`bc086cbe03d7`, "release session buffers by reference on close") | quiet | quiet; `dmesg` shows the new `handle[..] still referenced at exit (refcount=..)` line instead of a crash |

`cross` prints a summary each run:

```
cross: iters=5000 rounds=5000 dedup_shared=5000 async_submits=NNNNN submit_fail=0 burst=64
```

- `dedup_shared` > 0 confirms the cross-session sharing precondition (B got A's
  handles). If it is 0, imports are **not** de-duplicating across sessions on
  this kernel and the UAF is not reachable this way — investigate before trusting
  a quiet run.
- `async_submits` > 0 confirms real jobs entered the window. **If
  `async_submits` is 0** the blit params were rejected on this target and the
  cross-session job window never opened — a quiet run then proves nothing; tune
  the blit (format/size/handles in `rga_submit_async_blit()`) until submits land.

## Interpreting a quiet cross run

A quiet `cross` run is only meaningful if `dedup_shared > 0` **and**
`async_submits > 0`. Widen the window with larger `RGA_UAF_BURST` and more
`RGA_UAF_ITERS` before concluding the fix holds; the job-completion window is
short for a 16×16 blit.

## Relationship to the fix

- Driver fix: `linux-6.18-rkvenc-av1-fwport@bc086cbe03d7`.
- Trigger fix (stops the leak that first exposed the path):
  [`abi-probe.c`](./abi-probe.c) `probe_rga_dmabuf_import_release()`.
