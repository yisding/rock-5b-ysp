# MPP `INIT_CLIENT_TYPE` double-call corrupts the workqueue session list

> Scope: kernel forward-port MPP driver (`rk_vcodec`), C4ad2 debug build; BSP-shared core code
> Source: `linux-6.18-rkvenc-av1-fwport` @ `bsp-high-port-20260722`, `drivers/video/rockchip/mpp/mpp_common.c` — `mpp_session_attach_workqueue()` `:492`, called from the `MPP_CMD_INIT_CLIENT_TYPE` case `:1448`
> Date: 2026-07-22
> Trust: board-observed + deterministically reproduced, KASAN/lockdep/DEBUG_LIST build; ROOT-CAUSED

## Result — root cause (confirmed)

Issuing **`MPP_CMD_INIT_CLIENT_TYPE` twice on the same `/dev/mpp_service`
session** double-adds `session->session_link` and corrupts the taskqueue's
`session_attach` list. Unprivileged; `CONFIG_DEBUG_LIST` catches it as a
`WARNING` ("list_add double add"); the board survives.

Exact mechanism:

- `session->session_link` is `INIT_LIST_HEAD`'d once at session creation
  (`mpp_session_init()`, `:424`).
- The `MPP_CMD_INIT_CLIENT_TYPE` handler (`:1409`–`:1448`) is **unguarded
  against re-init**: it re-runs `session->device_type = …`,
  `session->dma = mpp_dma_session_create(…)`, `session->mpp = mpp`, rebinds the
  dev-ops callbacks, and calls `mpp_session_attach_workqueue()` **every time**
  it is invoked.
- `mpp_session_attach_workqueue()` (`:487`) does an unconditional
  `list_add_tail(&session->session_link, &queue->session_attach)`.
- First call: clean add. Second call: `session_link` is already linked in
  `session_attach`, so `list_add_tail` re-adds an already-linked node →
  `__list_add_valid_or_report` fires (`new == prev`, the classic
  double-add-at-tail signature).

The compiler inlines `mpp_session_attach_workqueue` → `list_add_tail` →
`__list_add` into `mpp_process_request`, which is why the trace frame reads
`mpp_process_request+0x11a8` (resolved with `addr2line` against the matching
`vmlinux`: `list.h:191` → `mpp_common.c:492` → `mpp_common.c:1448`).

**Two distinct harms from the second call:**
1. **List corruption** — `session_attach` gets a self-referential/duplicate
   node. On this DEBUG_LIST build it is a WARN; on a **production kernel the
   corruption is silent**, and the taskqueue worker (`mpp_taskqueue_*`,
   `mpp_session_detach_workqueue` doing `list_del_init` + move to
   `session_detach`) later walks a broken list → possible NULL/again-add fault
   or hang.
2. **Resource leak** — the second `mpp_dma_session_create()` overwrites
   `session->dma` without destroying the first, leaking the prior DMA session.

**Not a `0059`–`0069` regression — pre-existing BSP bug (confirmed by direct
comparison, not just inference).** The Rockchip 6.1 BSP donor
(`rockchip-kernel/drivers/video/rockchip/mpp/mpp_common.c`) carries the
byte-identical unguarded sequence: `session->device_type = …;
session->dma = mpp_dma_session_create(…); … mpp_session_attach_workqueue(…)`
with no re-init guard. No `0059`–`0069` patch touches this path. It was never
hit before only because prior gates drove one `INIT_CLIENT_TYPE` per session;
the ioctl fuzz was the first workload to send it twice.

## Evidence and reproduction

- **Identity:** ROCK 5B / RK3588, boot `Pabd5-C4ad2` (KASAN+lockdep+DEBUG_LIST),
  `/boot/vmlinuz-6.18.38-current-rockchip64` md5 `d058837408638134c0e63639f9be5c98`,
  booted 2026-07-22 17:21 PDT.
- **First surfaced by:** `PROFILE=forward-port bash kernel-drivers/tests/ioctl-fuzz-smoke.sh`
  (32 flagged WARN lines, `Comm: ioctl-fuzz-smok`, `mpp_process_request+0x11a8`).
- **Deterministic reproducer:** [`kernel-drivers/tests/mpp-double-init-repro.c`](../kernel-drivers/tests/mpp-double-init-repro.c)
  — opens `/dev/mpp_service`, picks a supported client_type from
  `QUERY_HW_SUPPORT`, sends `INIT_CLIENT_TYPE` twice. Both ioctls return `0`
  (the driver does **not** reject the second); the second prints and produces:
  ```
  list_add double add: new=ffff00012420b198, prev=ffff00012420b198, next=ffff0001118a01a8.
  WARNING: CPU: 1 PID: 59172 at lib/list_debug.c:35 __list_add_valid_or_report+0x184/0x1d0
   mpp_process_request+0x11a8/0x20a8
  ```
  Same call site as the fuzz-surfaced WARN. Unprivileged (run as UID 1000).
- **Symbol resolution:** `mpp_process_request` at `ffff8000817817d8` in both the
  build `vmlinux` and the running `/boot/System.map` (identical), `+0x11a8`
  → `mpp_session_attach_workqueue` `:492`, `mpp_process_request` `:1448`.

## Proposed fix

Reject re-init instead of silently re-binding. At the top of the
`MPP_CMD_INIT_CLIENT_TYPE` case, before any mutation:

```c
if (session->mpp)          /* already bound by a prior INIT_CLIENT_TYPE */
    return -EBUSY;
```

This closes both harms at once: no second `list_add_tail`, and no leaked
`session->dma`. (An idempotent alternative — guard the attach with
`if (list_empty(&session->session_link))` and skip the re-create when
`session->dma` is set — is more code and preserves the surprising
re-bind semantics; a hard reject is the least-surprise fix and matches how a
one-shot bind ioctl should behave.) Fold into both the forward-port tail and
the BSP backport set in
[`patch-catalog.md`](../kernel-drivers/docs/patch-catalog.md).

## Severity escalation — it is a use-after-free, not just a WARN (2026-07-22)

Building the OOB reproducers surfaced the real impact. After the deterministic
double-init reproducer corrupted `queue->session_attach` at 20:00, a **later,
single, ordinary `INIT_CLIENT_TYPE`** (from an unrelated PoC at 20:29) tripped a
**KASAN slab-use-after-free** at the same `list_add` site:

```
BUG: KASAN: slab-use-after-free in __list_add_valid_or_report … by task mpp-reg-offset-/131080 (UID 1000)
  mpp_process_request+0x11a8  (mpp_session_attach_workqueue list_add_tail)
The buggy address belongs to the object … kmalloc-1k … pointer offset 408
Freed by task 55846:  kfree … mpp_process_request+0x11a8 …
```

The freed object is a **`struct mpp_session`** (kmalloc-1k, `session_link` at
offset 408) freed on session close. Because the earlier double-add left the
freed session's `session_link` still linked into `queue->session_attach`, a new
session's `list_add_tail` reads the freed node. So the double-init defect is not
a self-contained WARN: it **persistently corrupts a kernel-wide list**, and the
use-after-free is then reachable by **any subsequent unprivileged
`INIT_CLIENT_TYPE`** on `/dev/mpp_service`, reading (and on the next add,
writing through) freed slab memory. That is a genuine UAF write/read primitive,
not merely a DEBUG_LIST diagnostic. On a production kernel without DEBUG_LIST the
corruption is silent until the freed-node access faults.

This moves the bug into the same **memory-corruption submit-now tier** as
`0055`/`0060`/`0052`/`0057` in the
[upstream-submission-priority finding](2026-07-22-bsp-bug-upstream-submission-priority.md).

> The currently booted `Pabd5-C4ad2` lacks the `0070` fix, so its
> `session_attach` list is corrupted for the rest of this boot; reboot onto the
> `0070` build before further MPP testing.

## Fix applied

The `-EBUSY` guard is committed to the forward-port branch
`bsp-high-port-20260722` as patch **`0070`**
(`video: rockchip: mpp: reject re-init of an already-bound session`,
`fa8c80ceccc5e`), checkpatch-clean, and staged into the tracked series at
[`patches/forward-port-rk3588-av1/…-0070-…`](../kernel-drivers/patches/forward-port-rk3588-av1).
The KASAN/lockdep debug build carrying `0070` completed 2026-07-22 as
**`P29f4-C9fc5`** (image sha256 `5cc3abe29a3f…`); its `.config` is byte-identical
to the booted `Pabd5-C4ad2` (the `C9fc5` vs `C4ad2` hash differs only because
Armbian hashes the config *input* re-seeded from the now-running kernel — the
resolved config matches, md5 `d8fad6fb…`, full debug class intact). **Not yet
installed/booted.** Gate: install `P29f4-C9fc5`, reboot, run
`mpp-double-init-repro` (second `INIT_CLIENT_TYPE` must return `-EBUSY`, no WARN,
clean `session_attach`), then re-run the five memory-corruption PoCs on the
unpoisoned list plus the codec/RGA regression sweep.

## Boundary

Until that build is installed and gated, the fix is compile-staged only — the
`-EBUSY` behavior and the absence of the WARN are not yet confirmed on hardware. Not confirmed on a non-DEBUG_LIST production build (the
double-add is silent there; the downstream fault from the corrupted
`session_attach` list is inferred, not observed). Legitimate userspace calls
`INIT_CLIENT_TYPE` once, so normal decode/encode is unaffected; the exposure is
a hostile or buggy client on an otherwise ordinary unprivileged `/dev/mpp_service`
fd (`video` group).

## Why it matters / follow-up

Unprivileged, deterministic kernel-list corruption from a legal device node is
a real memory-safety weakness even though DEBUG_LIST demotes it to a WARN here.
Follow-up: apply the `-EBUSY` guard, gate the reproducer, and carry the fix to
Rockchip in the BSP backport set. Tracked as `status.md` watchlist **W19**.
