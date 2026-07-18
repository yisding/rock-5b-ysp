# MPP procfs session dump races private teardown and NULL-dereferences

> Scope: RK3588 Rockchip MPP forward-port kernel, `/proc/mpp_service/sessions-summary`
> read concurrently with rapid RKVENC session close/open
> Source: `linux-6.18-rkvenc-av1-fwport@bc086cbe03d7`, primarily
> `drivers/video/rockchip/mpp/mpp_service.c`, `mpp_common.c`, and
> `mpp_rkvenc2.c`. Fix: `linux-6.18-rkvenc-av1-fwport@df0d7037213c` and YSP
> forward-port patches `0040`/`0041`.
> Date: 2026-07-17
> Trust: MEASURED (complete Oops and trigger) / CODE-INSPECTED (race and fix) /
> COMPILE-VERIFIED (three affected objects) / HARDWARE-RETEST PENDING

## Result

The first version of the RKMPP lifecycle experiment sampled
`/proc/mpp_service/sessions-summary` every 50 ms while its encoder worker
rapidly opened and closed sessions. On the 547th no-forced-IDR churn lifecycle,
the sampler's `cat` raced RKVENC session teardown and produced this exact Oops:

```text
Unable to handle kernel NULL pointer dereference at virtual address 0000000000000000
Internal error: Oops: 0000000096000004 [#1] SMP
CPU: 0 UID: 1000 PID: 30423 Comm: cat Not tainted 6.18.38-ysp-rockchip64 #1 PREEMPT
pc : rwsem_read_trylock+0xc/0xe8
lr : down_read+0x4c/0xc0
x19: 0000000000000000 x0 : 0000000000000000
Call trace:
 rwsem_read_trylock+0xc/0xe8
 rkvenc_dump_session+0x48/0x1e0
 mpp_show_session_summary+0x290/0x338
 seq_read_iter+0x11c/0x4c0
 proc_reg_read_iter+0x78/0xe0
 copy_splice_read+0x190/0x340
 do_splice_read+0x64/0xc0
 splice_file_to_pipe+0x8c/0x100
 do_splice+0x598/0x830
 __arm64_sys_splice+0xe8/0x368
note: cat[30423] exited with preempt_count 1
```

The encoder, proc reader, and MPP worker subsequently remained in
uninterruptible sleep. The MPP subsystem was no longer safe to exercise and
requires a reboot; no reboot was performed as part of this investigation.

## Root cause

`mpp_show_session_summary()` correctly holds `srv->session_lock` while walking
`srv->session_list`. Under that lock it checks `session->priv`, dumps
`session->dma`, and calls the device-specific `dump_session()` callback.
Teardown, however, did not use the same lifetime boundary:

1. `mpp_session_deinit()` invoked the device/default deinit callback while the
   session was still linked into `srv->session_list`.
2. The default path called `rkvenc_free_session()`, which `kfree()`d
   `session->priv` and assigned NULL. It could also destroy `session->dma`.
3. Only after freeing those objects did the default callback acquire
   `srv->session_lock` and unlink the service-list entry. The custom rkvdec2-link
   callback used the same unsafe order.

A proc reader can therefore acquire the lock, observe a non-NULL private
pointer, and enter the dump path while teardown concurrently frees it without
the lock. In the captured interleaving, `rkvenc_dump_session()` reloaded NULL
into its local `priv` and passed `&priv->rw_sem` (address zero) to `down_read()`,
matching `x0 = 0`, `x19 = 0`, and the fault in `rwsem_read_trylock`. If its
reload happens earlier, the same race permits a use-after-free instead. The
generic DMA dump has the analogous lifetime problem.

This Oops is separate from the FFmpeg/libmpp forced-IDR control/input race. The
no-forced-IDR worker completed 546 iterations; the instrumentation itself then
crashed the driver during the next open/close. It is not evidence of a second
FFmpeg stall mechanism.

## Fix

Commit `df0d7037213c` moves service-list removal into the common
`mpp_session_deinit()` entry point, before any device-specific callback can free
private or DMA state. Taking `srv->session_lock` there has both required effects:

- it waits for an already-running procfs dump to finish before teardown; and
- after unlink, no new procfs traversal can find the session.

The patch removes the now-redundant late unlink from both the default teardown
and `rkvdec2_link_session_deinit()`. It also makes `rkvenc_dump_session()` return
when `session->priv` is NULL as a defensive guard; the guard alone would not
fix the possible private-state UAF or the DMA-session race.

Validation completed without touching the wedged runtime device:

- `git diff --check`: pass;
- `scripts/checkpatch.pl --strict --no-tree --show-types`: 0 errors/warnings for
  the MPP patch; and
- arm64 cross-build: `mpp_common.o`, `mpp_rkvenc2.o`, and
  `mpp_rkvdec2_link.o` all compile successfully against the forward-port config.

The fix is exported as
`kernel-drivers/patches/forward-port-rk3588-av1/rk3588-av1-fwport-0041-*`.
The preceding `0040` folds the already-reviewed RGA session-refcount fix into
the same canonical series through sequence number `0041` (`0012` is omitted
because the base already carries it).

## Experiment safety change

`apps/gnome-remote-desktop/bench/rkmpp_lifecycle_experiment.sh` no longer reads
any file under `/proc/mpp_service`. It retains IRQ deltas, userspace wait
channels/stacks, package identity, and kernel-journal capture. Its parent
watchdog also uses a bounded reap after sending `SIGKILL`, because a child
already stuck in kernel D state cannot be killed until the kernel wait returns.

Do not use `/proc/mpp_service/sessions-summary` as a high-frequency lifecycle
sampler on an older kernel. A one-off read is not guaranteed safe either; high
frequency only makes the teardown window easier to hit.

## Boundary and next gate

- The NULL variant is proven by the full call trace and registers. The possible
  UAF variant is code-inspected, not separately observed.
- Compile/style verification is complete, but the fix has not been booted.
- After installing a kernel that contains `df0d7037213c`, reboot, confirm the
  stuck processes are gone, run a deliberate procfs/churn concurrency test,
  and then repeat the no-forced-IDR 1,000-iteration control without live RDP.
- Until that reboot, do not run additional hardware RKMPP experiments on this
  boot. The userspace-only `--self-test-stall` watchdog test remains safe.
