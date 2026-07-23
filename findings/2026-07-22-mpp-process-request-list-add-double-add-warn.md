# MPP `mpp_process_request` list_add double-add WARN from unprivileged ioctl fuzz

> Scope: kernel forward-port MPP driver (`rk_vcodec`), C4ad2 debug build; BSP-shared core code
> Source: `linux-6.18-rkvenc-av1-fwport` @ `bsp-high-port-20260722`, `drivers/video/rockchip/mpp/mpp_common.c` `mpp_process_request()` (task-submit path near `mpp_session_clear_pending`, ~:1356–1620)
> Date: 2026-07-22
> Trust: board-observed, KASAN/lockdep/DEBUG_LIST build

## Result

Fuzzing `/dev/mpp_service` with malformed non-submit ioctls as an unprivileged
user (UID 1000) trips `CONFIG_DEBUG_LIST`'s **"list_add double add"** check
(`lib/list_debug.c:32`, `__list_add_valid_or_report`) inside
`mpp_process_request()`. The kernel logs a `WARNING` and taints `G W`; the board
survives (WARN, not Oops). Reached during the `ioctl-fuzz-smoke` gate on the
booted `Pabd5-C4ad2` kernel — 18 hits at `list_debug.c:35` and 14 at `:32` in a
single fuzz window, all from `Comm: ioctl-fuzz-smok` on the same
`mpp_process_request+0x11a8 → mpp_dev_ioctl_common → mpp_dev_ioctl → sys_ioctl`
path.

**This is not a `0059`–`0069` regression.** No patch in the `0059`–`0069` HIGH
subset modifies `mpp_process_request` or the SET_REG/task-submit list handling,
and `mpp_common.c` is byte-identical to the Rockchip 6.1 BSP (per the
[lifetime audit](2026-07-21-forward-port-lifetime-resource-ownership-audit.md)).
The defect is therefore **latent in the pristine BSP** and was simply never hit
before because prior gates drove only well-formed request sequences. It belongs
in the BSP backport/fix queue alongside the audit HIGHs, not against the fixes
under test.

The surrounding driver logs show the fuzzer's malformed inputs being rejected
correctly elsewhere in the same window (`client_type must less than 30` →
`-22`; `unknown ioctl cmd`; `can not find <fd> buffer in list` →
`release fd failed`), so most of `mpp_process_request`'s validation is
fail-closed. The list_add path is the one that mutates a list before/without
the guard that would keep a task or session link from being added twice.

## Evidence and reproduction

- **Identity:** ROCK 5B / RK3588, boot path `Pabd5-C4ad2` (KASAN+lockdep+DEBUG_LIST),
  `/boot/vmlinuz-6.18.38-current-rockchip64` md5 `d058837408638134c0e63639f9be5c98`,
  booted 2026-07-22 17:21 PDT.
- **Exercise:** `PROFILE=forward-port bash kernel-drivers/tests/ioctl-fuzz-smoke.sh`
  (no `fail-nth` fault injection — that mode self-sudoes and was not run).
- **Pass/fail signal:** the fuzz smoke itself exits `PASS`
  (`mpp calls=256 ok=149 errors=107`, `rga calls=294 ok=223 errors=71`) — it
  scores ioctl survival, not journal cleanliness. The defect is the
  `WARNING: CPU … __list_add_valid_or_report` in the kernel journal during the
  fuzz window; the whole-session fatal scan flagged 32 such lines.
- **Trace anchor:** `mpp_process_request+0x11a8`; PID 52372; `pstate` clean;
  `end trace` single WARN, no follow-on Oops.
- **Artifacts:** `scratchpad/ioctl-fuzz.out` (this session, not committed);
  journal via `journalctl -k --since "2026-07-22 19:34:10"`.

## Boundary

Not root-caused to the exact list or the exact malformed cmd sequence — the
WARN and the `client_type`/`unknown cmd` rejections interleave across many fuzz
iterations, so the offending ioctl is not yet isolated to one case. Not
confirmed on a non-DEBUG_LIST build (the double-add is silent without
`CONFIG_DEBUG_LIST`, but the list still ends up corrupt, so a production kernel
could see a later NULL/again-add fault). Not yet reproduced on the `Pd222`
baseline to timestamp it as pre-existing by observation — the byte-identity
argument is source-level, not a paired run. No security claim beyond
"unprivileged-reachable list corruption, WARN-level here."

## Why it matters / follow-up

A malformed unprivileged ioctl corrupting a kernel list is a real
memory-safety weakness even when `DEBUG_LIST` demotes it to a WARN on this
build. Follow-up: isolate the single fuzz cmd (bisect the fuzzer's op list or
add a per-iteration journal-cursor check), identify the list and the missing
`list_empty()`/`list_del_init()` guard, and fold the fix into both the
forward-port tail and the BSP backport set in
[`patch-catalog.md`](../kernel-drivers/docs/patch-catalog.md). Add to the
`status.md` watchlist until isolated.
