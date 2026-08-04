# Forward-port conformance preflight Oopsed before the first MPP case

> Scope: ROCK 5B running the 6.18.38 RK3588 MPP/RGA/AV1 forward-port PPA
> kernel, at the start of the paired conformance run
> Source: boot journal plus run `20260717-230531` under
> `/home/yi/Code/rock-5b/build/rockchip-conformance/logs/forward-port/`; kernel package
> `6.18.38+rk3588av1fwport20260717-0ubuntu1~rk1`
> Date: 2026-07-17
> Trust: MEASURED (timeline and Oops) / INFERRED (MPP procfs lifetime is the
> leading attribution; no PC/LR/call trace survived)

## Result

The first conformance pass on the newly booted session-lifetime kernel
`6.18.38-ysp-rockchip64` Oopsed and automatically rebooted at the transition
from ABI replay to the MPP suite. The PPA package contains forward-port fixes
`0040` (RGA session reference lifetime) and `0041` (unlink MPP sessions before
private teardown), so this run was intended to supply their first booted
validation. Instead, it invalidates that validation attempt and blocks the
forward-port baseline needed for comparison with the rewrite kernel.

The previous boot's journal records:

```text
Jul 17 23:06:16 rkvdec2_control:870 unknown mpp ioctl cmd 404
...
Jul 17 23:06:17 Unable to handle kernel paging request at virtual address 002e00d5208367f3
Jul 17 23:06:17 ESR = 0x0000000096000004
Jul 17 23:06:17 EC = 0x25: DABT (current EL), IL = 32 bits
Jul 17 23:06:17 FSC = 0x04: level 0 translation fault
Jul 17 23:06:17 [002e00d5208367f3] address between user and kernel address ranges
Jul 17 23:06:17 Internal error: Oops: 0000000096000004 [#1] SMP
```

The automatic reboot produced a new boot ID. No PC, LR, register dump, or call
trace reached the persistent journal. `/sys/fs/pstore` was empty: the ordinary
kernel had `CONFIG_PSTORE_RAM=m`, no pstore console capture, and the live DT had
no ramoops reserved-memory node.

## Exact sequence

Run `20260717-230531` completed system collection and ABI replay. The raw ABI
log itself survived and reported two contract failures:

1. `RGA2_GET_RESULT` returned `EINVAL`;
2. unsupported `RGA_IOC_REQUEST_CONFIG` returned success instead of `EFAULT`.

All dma-buf handles imported by the corrected probe were released. The next
suite directory,
`20260717-230531-mpp-suite`, contains zero-byte summary, artifact, and
`mpp-state-before.txt` files and no per-case command or log. Therefore no MPP
media test binary began.

`mpp-suite.sh` takes its initial dmesg marker and then recursively reads the
files below `/proc/mpp_service` in `snapshot_mpp_state before`; it launches the
first media binary only after that snapshot and the debugfs counters. The Oops
therefore occurred during the MPP preflight snapshot, immediately after the ABI
probe had created and closed MPP/RGA sessions.

## Attribution boundary

The leading explanation is another MPP procfs/session lifetime race, or an
incomplete variant of the race addressed by patch `0041`: the fault timing is a
recursive `/proc/mpp_service` read after rapid session churn, and the random
non-canonical address is compatible with a use-after-free rather than the
previously captured NULL variant. This is **INFERRED**, not proven. The journal
lacks the faulting function and stack, and delayed RGA teardown after ABI replay
cannot be excluded.

The earlier complete `rkvenc_dump_session()` trace remains independently valid;
see [`2026-07-17-mpp-procfs-session-teardown-oops.md`](2026-07-17-mpp-procfs-session-teardown-oops.md).
This run does not prove patch `0041` ineffective because the recursive snapshot
reads more than `sessions-summary` and the exact fault site is unknown. It also
does not prove the RGA `0040` fix defective; the single-session ABI imports were
released and the prior RGA attribution was already uncertain.

## Resolution (2026-07-18)

The KASAN gate completed and overturned the inference above. The narrowed run
faulted during ABI replay, before the procfs snapshot, and identified a
pre-existing RESET_SESSION double-free of `session->dma`. Forward-port patch
`0042` fixes it; rebuilt run `20260718-093751-kasan-narrowed` exercises the same
sequence with zero flagged kernel lines. A second, distinct RKVENC2 post-free
read was then fixed and KASAN-verified as patch `0043`. Current evidence and
the remaining production/functional gate live in the
[`0042` finding](2026-07-18-mpp-reset-session-dma-double-free-kasan.md) and
[`0043` finding](2026-07-18-rkvenc2-wait-result-task-uaf-kasan.md); do not use
this superseded finding as an active runbook.

> **Workflow correction (2026-07-19):** the former high-DRAM DT overlay did
> not survive RK3588 reset and has been retired. The current debug-kernel
> package adds the BSP-derived low-memory reservation to the base ROCK 5B DTB;
> the enable script verifies that node and configures only boot/sysctl policy.
