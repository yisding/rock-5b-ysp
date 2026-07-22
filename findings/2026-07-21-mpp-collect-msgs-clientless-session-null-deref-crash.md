# MPP `mpp_collect_msgs` on a client-less session: fatal near-NULL deref that hard-crashed the board

> Scope: RK3588 MPP (`/dev/mpp_service`, `rk_vcodec`) on the forward-port
> kernel, KASAN debug build `P7589-C4ad2` (`#7`).
> Source: journal of the crashed boot (`boot -1`, 14:44:07 → 15:12:27 crash),
> `rk_vcodec` `mpp_process_request()` / `mpp_collect_msgs()` /
> `mpp_dev_ioctl_common()`.
> Date: 2026-07-21
> Trust: **MEASURED** (the oops line + the driver error trail preceding it) /
> **INFERRED** (the exact faulting deref and call path — no call trace was
> preserved; see Boundary).

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
fault — so the oops is **not** at :1550/:1727. The near-NULL deref is a
separate access on the same torn-down session, most plausibly on the MPP
**service/worker thread** (`session->srv`) or a task-processing path that
touches `session->mpp`/`session->srv`/a task struct **without** the NULL-client
guard the ioctl path has, racing the teardown that nulled the client. The
`0x1b18`-ish offset is consistent with a field deep inside the `mpp_dev` /
`mpp_taskqueue` / task struct reached through the NULL client pointer.

## What ran / how it was reached

The crashing workload was MPP **decode** — `mpp[63274]`/`mpp[63353]` logged
`mpp_dec: can not enable fast parse while hal not support` at 15:11:39–40,
then the client-less collect loop and crash at 15:12:27. The launching
process was not a tracked systemd unit (no suite "Starting" line), so the
exact command is unconfirmed — plausibly the repo's own MPP decode path or the
background auto-commit/exerciser agent. The `not find client 0` condition
appeared **only** at the crash instant, with no precursor warnings earlier in
the boot.

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

## Boundary / how to get the trace next time

- **No call trace was captured**, so the faulting function and the precise
  client-less access are INFERRED from the driver error strings + the
  near-NULL KASAN-shadow fault address, not proven.
- **Serial console is the best capture path:** the kernel cmdline carries
  `console=ttyS2,1500000`. If a UART is attached, the full oops went out the
  serial port even though it never reached the journal or the (power-cycled)
  ramoops. Capture ttyS2 on the P9c12 boot.
- **ramoops will not help** (superseded understanding): even a clean warm
  `panic=10` reboot does not preserve the region on this board, so don't wait
  on pstore — go straight to serial/netconsole. Still prefer letting the board
  self-reboot over power-cycling, but only so the next boot comes up clean, not
  for ramoops.
- **Reproduce under KASAN:** run MPP decode concurrently with session
  reset/close (an `mpp_dec` loop racing `MPP_CMD_RESET_SESSION` /
  fd close) on the P9c12 KASAN kernel; a KASAN report on the client-less
  access would name the exact field and path. This is the next step before it
  can be fixed.

## Why it matters

A **fatal, unprivileged-reachable kernel crash** in the core decode path (any
process that can open `/dev/mpp_service` and drive a session into the
client-less collect state) is a **distribution blocker on par with — and more
severe in impact than — the RGA UAF**: it hard-locks the machine rather than
being caught by KASAN. It must be root-caused (with a trace) and fixed before
the forward-port kernel ships broadly. Tracked alongside the
[RGA request UAF finding](./2026-07-21-rga-request-completion-vs-session-close-uaf-kasan.md).
