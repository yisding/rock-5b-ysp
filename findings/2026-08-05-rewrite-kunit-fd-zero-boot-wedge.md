# A legacy fd-zero fence sentinel wedged the boot inside KUnit

> Scope: clean-room RGA rewrite KUnit suite and the debug-kernel stall policy
> Source: failing tip `rk3588-rewrite-6.18@37ae7459656b`, KASAN package
> `P27bb-Cad24`, fixed tips `rk3588-rewrite-6.18@df22eeef8757` and
> `rk3588-rewrite-mainline@518f59c9f1f8`
> Date: 2026-08-05
> Trust: **MEASURED** / **SOURCE-INSPECTED** / **ROOT-CAUSED** /
> **FIX-COMPILE-VERIFIED** / **PARTIAL**

## Result

The exact-tip KASAN package built from `37ae7459656b` was installed at 16:42 and
did not boot: no HDMI, no serial progress, no journal boot entry, and an empty
`/sys/fs/pstore` on the recovery boot. The board was recovered by pointing the
`/boot` symlinks back at `6.18.42-ysp-rockchip64` at 16:55, and the offending
commit was reverted in `8bec3c8cef46c`.

The cause is the commit's legacy fd-zero fence sentinel, but not through any
path a user can reach. It kills the boot through the driver's own KUnit suite.

## Why a driver change can kill a pre-console boot

`kunit_run_all_tests()` runs from `kernel_init_freeable()` in `init/main.c`
immediately after `do_basic_setup()` and **before `wait_for_initramfs()`**. The
debug config builds both rewrite drivers and both KUnit suites in
(`CONFIG_ROCKCHIP_RGA_REWRITE=y`, `CONFIG_ROCKCHIP_RGA_REWRITE_KUNIT_TEST=y`,
`CONFIG_KUNIT_AUTORUN_ENABLED=y`) but leaves the display driver a module
(`CONFIG_DRM_ROCKCHIP=m`), which is only loaded later from the initramfs.

So every RGA and MPP KUnit case runs before anything can display or log, and a
case that hangs takes the whole boot with it. Because a hang raises no
`kmsg_dump`, ramoops records nothing either — an empty pstore here is the
expected signature of this failure, not a retention regression.

## Root cause

`rk_rga_ioctl_blit()` gained:

```c
if (!task->in_fence_fd)
	task->in_fence_fd = -1;
```

The ABI rule is correct. Rockchip's source of record tests
`request->acquire_fence_fd > 0` before importing a legacy acquire fence, and in
any real process descriptor zero is stdin, never a sync-file a caller meant to
submit.

KUnit is not a real process. Each case runs in a fresh `kthread_create()` thread
whose `files` is a copy of the empty `init_files`; `kunit_attach_mm()` attaches
an mm but never touches `current->files`. The first `get_unused_fd_flags()` in a
case therefore returns **descriptor zero, deterministically**. Three cases
install a live sync-file there and submit it as a real acquire fence, asserting
only `KUNIT_ASSERT_GE(test, acquire_fd, 0)`:

- `rk_rga_release_pending_acquire_job_kunit`
- `rk_rga_last_hw_remove_pending_acquire_kunit`
- `rk_rga_legacy_blit_async_acquire_kunit`

The first two are the fatal ones. Their premise is that the job stays *pending*
on that fence — both assert `dma_fence_get_status(release_fence) == 0` — while a
`kunit_kzalloc()`ed `rk_rga_hw` with no device, no register mapping and no IRQ
sits on `rga->hw_list`. With the fence silently discarded the job is no longer
fence-gated, goes straight to dispatch against that fixture core, and
`rk_rga_release()` blocks forever in

```c
wait_event(session->job_wait, rk_rga_session_dispatches_idle(session));
```

The existing helper already hinted at the hazard: `rk_rga_kunit_track_fd()`
stores `fd + 1` in its cleanup action precisely because descriptor zero is a
valid value here.

## Ruled out

The load-address gate in `install-kernel.sh` STEP 2 produces an identical
symptom — BSS cleared over the FDT, "no HDMI, no serial, no ramoops, no
journal" — and was **not** the cause. The arm64 `image_size` is 138,805,248
(132.4 MiB) against 197,132,288 (188.0 MiB) of headroom
(`fdt_addr_r=0x0c000000`, `boot.cmd` and `boot.scr` agreeing), and it is byte
for byte the same value in `P2178` (which booted), `P27bb` (which did not), and
`P651c`.

## Fix

The fixture was wrong, not the ABI. `rk_rga_kunit_install_fence_fd()` now burns
the lowest descriptor before creating the real fence fd and releases it
immediately after, so every fd a case installs is positive the way a process's
would be. This is the idiom `rk_mpp_kunit_dmabuf_fd()` already uses for the MPP
suite's dma-buf descriptors, whose callers assert `fd > 0`.

`df22eeef8757` reapplies the reverted librga fixes together with that repair, so
no commit in the history wedges the boot; `518f59c9f1f8` carries the fixture
change alone on mainline, which was never reverted. The rewrite sources stay
byte-identical and the 92 + 152 manifest is unchanged.

The debug kernel now also enables `BOOTPARAM_HUNG_TASK_PANIC` and
`BOOTPARAM_SOFTLOCKUP_PANIC`. This deliberately departs from the fragment's
`PANIC_ON_OOPS=n` policy: "stay up and capture it live" needs a userspace that a
pre-initramfs wedge never reaches, so panicking is the only way such a stall
leaves a trace on `ttyS2` and lets `panic=10` reboot into something debuggable.
`HARDLOCKUP` stays reporting-only. Override per boot with
`sysctl.kernel.hung_task_panic=0` / `sysctl.kernel.softlockup_panic=0`.

## Boundary

The fix is compile- and gate-verified only: warning-fatal clean-archive `normal`
builds pass on both tips, the source audit reports 306 signals with zero new and
zero absent, cross-tree byte identity and the KUnit manifest check pass. Nothing
here is runtime-verified. The gate is a boot of the new exact-tip KASAN package
that reaches the ordered 92 + 152 KUnit result with a clean outer interval, which
also re-opens every librga gate listed in
[the librga status finding](2026-08-05-rewrite-rga-librga-swiotlb-fence-status.md).
