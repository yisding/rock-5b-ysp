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
> **OPEN** (harness mitigated; kernel and MPP not hardened).

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

## Verification gate

- Re-run the bounded `split_arg=4` reproducer after both sides are hardened.
- Require bounded termination with either a complete stream or one explicit
  overflow error; repeated `EIO` polling is a failure.
- Confirm the next encoder job succeeds, proving pending-task cleanup and
  scheduler recovery.
- Re-run the ordinary `split_arg=120` H.264/H.265 suite and require every frame,
  a decodable artifact, and a clean KASAN/fatal-signature scan.
