# RGA session-close force-free ignores refcounts; a leaked test handle exposed it as a kernel Oops

> Scope: RK3588 RGA (`/dev/rga`) on the forward-port kernel
> `linux-6.18-rkvenc-av1-fwport`, driven by the repo ABI probe
> (`kernel-drivers/tests/abi-probe.c`)
> Source: driver — `linux-6.18-rkvenc-av1-fwport@1c9a110129fe`,
> `drivers/video/rockchip/rga3/rga_mm.c` `rga_mm_session_release_buffer()` /
> `rga_mm_force_releaser_buffer()`; test — `kernel-drivers/tests/abi-probe.c`
> `probe_rga_dmabuf_import_release()` (~:838). Fixes:
> `linux-6.18-rkvenc-av1-fwport@bc086cbe03d7` (driver) and this repo (test).
> Date: 2026-07-17
> Trust: MEASURED (the Oops) / CODE-INSPECTED (both paths) / INFERRED (the exact
> faulting function was not captured)

## Result

Two defects chained into a kernel crash while running the ABI probe:

1. **Test leak (proven).** `RGA_IOC_IMPORT_BUFFER` returns the *positive* buffer
   handle as its ioctl return value — `rga_ioctl_import_buffer()` returns
   `rga_mm_import_buffer()`'s handle (`rga_drv.c:705,715,729`;
   `rga_mm.c:2706-2708,2737,2786`). The dma-buf probe released the handle only
   under `if (!ret)`, i.e. only when the handle was 0, so every real import
   (e.g. handle 2) was never released. The va and physical probes already used
   the correct `ret >= 0` form. Fixed here to `if (ret >= 0)`; the probe now
   compiles clean (`-Wall -Wextra`) and releases the handle.

2. **Driver hazard (inspected).** On `/dev/rga` close,
   `rga_mm_session_release_buffer()` called `rga_mm_force_releaser_buffer()` for
   every buffer owned by the session, which `idr_remove`s + unmaps + `kfree`s
   the buffer **ignoring its kref refcount**. Imports are de-duplicated across
   the whole `memory_idr` (`rga_mm_lookup_external()` has no per-session filter)
   while `internal_buffer->session` records only the first importer, and a
   running job also holds a reference (`rga_mm_get_buffer()`,
   `kref_get` at `rga_mm.c:1829`). So a buffer owned by the exiting session can
   still be referenced by another session or an in-flight job; force-freeing it
   leaves a dangling pointer, and a later put/use faults on the freed object —
   consistent with the observed random-address Oops.

The driver fix (commit `bc086cbe03d7`) drops only the exiting session's
reference through the normal `kref_put(..., rga_mm_kref_release_buffer)` path, so
a buffer is unmapped/freed only when its last reference is gone; when a reference
survives it detaches `->session` (owner is gone; the field is only ever
pointer-compared, `rga_mm.c:2848`) and logs the leftover refcount so a recurrence
names the stage. `rga_mm_force_releaser_buffer()` is retained for the
driver-remove path (`rga_mm_buffer_destroy_for_idr()`), where all sessions are
already gone.

## Evidence and reproduction

- **Identity:** ROCK 5B, forward-port kernel `linux-6.18-rkvenc-av1-fwport`
  (`@1c9a110129fe` at crash time), `/dev/rga` (RGA3/RGA2 `multi_rga`).
- **Detection:** journal timeline from the crashing boot — abi-probe issued the
  expected negative MPP/RGA ABI probes; RGA logged that test process 17464
  exited with handle 2 still allocated (the
  `"[tgid:%d] Destroy handle[%d] when the user exits"` line from
  `rga_mm_session_release_buffer()`); 6.59 s later the kernel dereferenced
  `5db09466707b56d2` and Oopsed; the board was then hard-reset.
- **Exercise:** `kernel-drivers/tests/abi-probe.sh` (dma-buf import/release
  probe). Physical probing stays disabled by default for the forward-port
  profile (`ABI_PROBE_ENABLE_RGA_PHYSICAL`).
- **Pass/fail signal:** before — handle leaked on probe exit, force-free on close,
  later Oops. After the test fix — the handle is released before exit so
  session-close has nothing to reclaim. After the driver fix — session-close
  respects refcounts and cannot free a still-referenced buffer.
- **Artifacts:** none committed (raw machine captures are not stored per repo
  policy). `rga_mm.o` rebuilds clean with the change
  (`make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- drivers/video/rockchip/rga3/rga_mm.o`).

## Boundary

- The **exact faulting function is not proven.** The journal stopped before PC/LR
  and the call trace were saved and pstore was empty, so attribution of *this*
  Oops to the force-free path is INFERRED from the timeline plus code inspection,
  not from a captured trace. The refcount hazard itself is established by
  inspection (cross-session dedup + job references + unconditional free).
- This run did **not** reproduce the earlier signature, which faulted immediately
  in `dcache_clean_poc()` importing physical `0x1000` — a different bug already
  addressed by `@1c9a110129fe` "validate physical import pages".
- The MPP "unknown ioctl" and RGA "unknown ioctl cmd" lines are intentional
  negative ABI probes, not the crash.
- The driver fix is compile-verified only; it has **not** been re-exercised on
  hardware. In a pathological same-session multi-import-without-release case it
  favors a bounded leak over a force-free UAF, which is the safer trade.

## Why it matters / follow-up

- The probe is safe to rerun now: with the test fix it no longer leaks handle 2,
  and with the driver fix a leaked handle would be reclaimed by reference rather
  than force-freed. (The prior guidance "do not rerun this probe unchanged" is
  satisfied — the probe is changed.)
- The driver fix lives as a fwport-tree commit (`bc086cbe03d7`), like its sibling
  crash fix `@1c9a110129fe`. The repo's base patch
  (`kernel-drivers/patches/rk3588-rkvenc2-01-vcodec-rga-drivers.patch`) is a
  frozen vendor snapshot and still carries the force-free path; fold both commits
  in at the next base-patch regeneration / resync
  ([resyncing guide](../kernel-drivers/docs/resyncing.md)). Tracked as watchlist
  **W15**.
- Next on-hardware pass: re-run the RGA smoke/ABI suite on a kernel carrying
  `bc086cbe03d7` and confirm the new
  `"handle[%d] still referenced at exit (refcount=%u)"` line does **not** appear
  in normal operation.
