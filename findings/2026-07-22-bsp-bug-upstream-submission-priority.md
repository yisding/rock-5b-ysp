# Which patched BSP bugs are critical enough to report upstream immediately

> Scope: forward-port MPP/RGA fixes vs the shipping Rockchip 6.1 BSP; security-severity triage for upstream submission
> Source: [`patch-catalog.md`](../kernel-drivers/docs/patch-catalog.md), the `0038`-`0070` patch commit messages, [`bsp-audit.md`](../kernel-drivers/docs/bsp-audit.md), and the lifetime/UAF findings cited per row
> Date: 2026-07-22
> Trust: SOURCE-INSPECTED (patch messages + donor comparison); the reproduced rows also MEASURED (KASAN on hardware)

## Result

A subset of the `BSP-BUG`-class fixes clears the bar for **reporting to
Rockchip/Armbian now** rather than in a batched correctness series: the
unprivileged, attacker-reachable **memory-corruption** bugs. Two of them
(`0055`, `0060`) are arguably CVE-worthy. The correctness/hardening/environment
fixes are real but not attacker-reachable memory corruption and can ride a
follow-up submission.

### Venue — not mainline

`rk_vcodec` / `multi_rga` are **out-of-tree Rockchip BSP drivers**; mainline
Linux uses the V4L2 `rkvdec` stack and does not carry this code. "Upstream" for
these fixes therefore means the **Rockchip BSP tree** (`rockchip-linux/kernel`,
`develop-6.1`) and **Armbian**, plus — for the memory-corruption tier — the
**CVE process / `linux-distros`**. Every submit-now patch message states the BSP
donor carries the identical defect, so these apply to shipping vendor kernels on
essentially every RK3588 board.

### Reachability model (why these rate high, not medium)

`/dev/mpp_service` and `/dev/rga` are `crw-rw----` **group `video`**. On a
Rockchip/Armbian desktop the logged-in user and GUI processes are in `video`
(that is how HW decode is granted). The realistic attacker is therefore **a
local or sandboxed process holding video access — a browser tab doing hardware
decode, a flatpak media app** — escalating to the kernel. Not a
root-only/appliance-only surface.

### Submit-now tier (ranked)

| Fix | Bug | Why report-now | Reproduction |
|-----|-----|----------------|--------------|
| **0055** | Two unprivileged **OOB kernel writes** into `mpp_task`'s fixed 80-entry translation array, clobbering adjacent `state`/`abort_request`/**`delayed_work`** during task assembly | Deterministic trigger (repeat one valid dma-buf fd across 81 attachment slots; or a non-multiple `req->size`); corrupting a `work_struct`/pointer is a classic **LPE write primitive** | Audit AV1-R1/R8; code-confirmed, **no standalone PoC yet** |
| **0060** | `MPP_CMD_SET_SESSION_FD` **type confusion** — the guard compared `private_data` to itself, so *any* fd passes and the foreign file's `private_data` is used as a `struct mpp_session` | Attacker-controlled object treated as a kernel struct → controlled deref; most exploitable class here | Foreign-fd gate returns `-EBADF` on the fixed kernel; **no standalone PoC yet** |
| **0058** | Clientless `MPP_CMD_RELEASE_FD` NULL-deref (`session->dma == NULL`) | **10-line deterministic reproducer**, unprivileged, synchronous crash → trivial local DoS; low-complexity/high-certainty ideal for a first submission | [`tests/mpp-clientless-release-fd-uaf.c`](../kernel-drivers/tests/mpp-clientless-release-fd-uaf.c) ✓ |
| **0052 / 0057** | RGA request / job vs `/dev/rga`-close **use-after-free** (+ refcount underflow) | KASAN-proven UAFs, unprivileged; UAF → LPE potential | [`tests/rga-session-uaf.c`](../kernel-drivers/tests/rga-session-uaf.c) `cross` ✓ (64k async submits clean on the fixed build) |
| **0042** | MPP `RESET_SESSION` **double-free** | Deterministic KASAN double-free, unprivileged | [`tests/kasan-narrowed-repro.sh`](../kernel-drivers/tests/kasan-narrowed-repro.sh) ✓ |
| **0070** | `INIT_CLIENT_TYPE` double-init → persistent `session_attach` list corruption → **KASAN slab-use-after-free of a freed `struct mpp_session`**, reachable by any *later* unprivileged `INIT_CLIENT_TYPE` | Deterministic; escalated from WARN to UAF while building these PoCs (see [finding](2026-07-22-mpp-process-request-list-add-double-add-warn.md)) | [`tests/mpp-double-init-repro.c`](../kernel-drivers/tests/mpp-double-init-repro.c) ✓ |

**Pick to file first:** `0055` (deterministic OOB write over a `work_struct`),
`0060` (type confusion), and `0070` (double-init UAF of a freed session) — the
CVE-class set. Bundle `0058` as the undeniable, low-risk DoS opener.

**PoCs written and fix-validated on the booted kernel (2026-07-22):**

- `0060` — [`tests/mpp-foreign-session-fd-repro.c`](../kernel-drivers/tests/mpp-foreign-session-fd-repro.c):
  a foreign eventfd and `/dev/null` passed to `SET_SESSION_FD` both return
  `-EBADF` on the fixed kernel (no dereference). Standalone, unprivileged.
- `0055` — [`tests/mpp-reg-offset-oob-repro.c`](../kernel-drivers/tests/mpp-reg-offset-oob-repro.c):
  `SET_REG_ADDR_OFFSET` with `size=647` makes the fixed extractor log
  `invalid reg offset size 647` and copy nothing — the guard fires, no OOB.
  (This run also incidentally tripped the `0070` UAF via its bind, since the
  boot's `session_attach` was already poisoned — see that finding.)
- `0070` — [`tests/mpp-double-init-repro.c`](../kernel-drivers/tests/mpp-double-init-repro.c):
  two `INIT_CLIENT_TYPE` on one session; the second trips the list_add and, as
  shown above, leaves a UAF for later sessions.

Each PoC is attachable to the upstream report and doubles as a runtime gate:
on a fixed kernel it fails closed; on a vulnerable kernel it produces the KASAN
report / crash to cite.

### Second priority (same batch)

- **0056** — unmap-after-free leaving a stale IOMMU mapping onto freed/reused
  pages (DMA reachability to freed memory).
- **0053 / 0054** — device-less-task NULL-deref **hard lockup** = full-board DoS.
- **0061 / 0063** — more unprivileged OOB writes (RKVDEC2 RCB index, RKVENC2
  request fan-out), same class as `0055`, no isolated repro yet.

(`0070` was promoted from here into the submit-now tier above once building the
PoCs showed it is a UAF, not a WARN.)

### Not urgent (batched follow-up)

Correctness/hardening/environment fixes are real and worth upstreaming but are
not attacker-reachable memory corruption: `0039` physical-import validation,
`0047` under-4G diagnostics, `0048`/`0049` 10-bit P010, `0064`/`0065`/`0066`/
`0067`/`0068`/`0069` RGA lifetime/policy. Ride a follow-up series.

## Boundary

Severity here is reasoned from the patch mechanics and the `video`-group
reachability, not from a demonstrated end-to-end exploit: none of these has been
driven to a controlled read/write or code-exec primitive. `0055`, `0060`, and
`0070` now have standalone unprivileged PoCs (above) that reach the vulnerable
path and validate the fix on hardware; `0061`/`0063` remain code-confirmed and
fuzz-reachable without an isolated repro. The reproduced rows (`0042`, `0052`,
`0055`, `0057`, `0058`, `0060`, `0070`) are submission-ready as memory-safety
reports today.

## Why it matters / follow-up

This is the concrete answer to the [audit's upstreaming note](../kernel-drivers/docs/bsp-audit.md)
("submission target awaiting an owner decision"): report the memory-corruption
tier to Rockchip + Armbian now, request CVEs for `0055` and `0060`, and keep the
correctness fixes for a batched follow-up. Next actions: (1) draft standalone
PoCs for `0055`/`0060`; (2) write the report bundle for the submit-now tier;
(3) record the submission decision and any CVE IDs. Tracked in the
[`status.md`](../status.md) watchlist alongside the BSP-audit upstreaming item.
