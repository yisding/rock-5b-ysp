# Third GRD oops under live MPP tracing: one buffer import, an immediate fatal sync, and the fingerprint holds 3/3

> Scope: ROCK 5B kernel forward-port; the GNOME Remote Desktop RKMPP
> login-screen path. Executes the pre-registered test in
> [`2026-07-27-grd-sg-corruption-reproduced-and-ioctl-capture-plan.md`](2026-07-27-grd-sg-corruption-reproduced-and-ioctl-capture-plan.md).
>
> Source: booted production `6.18.40-ysp-rockchip64`
> (`6.18.40+rk3588av1fwport20260725-0ubuntu1~rk1`), boot of 2026-07-27
> 20:06:37, oops at 20:11:26; live-armed `mpp_dev_debug=0x18` trace; capture
> bundle `~/Code/tmp/sg-oops-repro/hit-20260727-201153/` (kernel.log, full.log,
> pstore, versions); sub-command names from
> `packaging/ppa/out/work/linux-rockchip64-ysp-6.18.40+rk3588av1fwport20260725/include/uapi/linux/rk-mpp.h`.
>
> Date: 2026-07-27
>
> Trust: **MEASURED** / **SOURCE-INSPECTED** / **INFERRED**

## Result

### It reproduces under tracing, 3/3, and tracing changes nothing

Third production boot, third RDP login, third oops — again the first login of
the boot, this time with `mpp_dev_debug=0x18` (`DEBUG_IOCTL` + `DEBUG_IOMMU`)
armed before the connection. The prior finding's timing-sensitivity caveat is
retired: the trace does not mask the failure.

| | 16:36:07 (boot −2) | 19:38:08 (boot −1) | 20:11:26 (this run) | |
|---|---|---|---|---|
| failing entry index (`x23`) | 1 | 1 | 1 | **same** |
| entry length (`x1 − x0`) | 1 MiB | 1 MiB | 1 MiB | **same** |
| `orig_nents` (`x21`) | 24 | 24 | 24 | **same** |
| direction (`x22`) | 0 (`DMA_BIDIRECTIONAL`) | 0 | 0 | **same** |
| ESR | `0x96000145` | same | same | **same** |
| UID / comm | 60579 / `mpp_h264e_4425` | 60579 | 60579 / `mpp_h264e_6365` | **same** |
| geometry / strides | 2064×1296, 2112×1344→2112×1296 | same | same | **same** |
| `vmemmap` (`x20`) | `fffffdffc0000000` | same | same | **same** |
| CPU | 7 | 7 | **3** | **differs** |
| fault PFN | `0x1e0c1fc` | `0x1dbe8fc` | `0x1de02fc` | differs |
| recovered `page_link` | `0xfffffe0038307f00` | `0xfffffe0036fa3f00` | `0xfffffe003780bf00` | differs |
| `sgl` base (`x19`) | `ffff0001c3e59400` | `ffff000227370000` | `ffff0001e60f0800` | differs (all 1024-aligned) |

CPU 7 is no longer an invariant: this oops ran on CPU 3. The failure signature
in userspace is unchanged — `Initialized FFmpeg/rkmpp encode backend` logged,
`Created h264_rkmpp encode session` never logged, taint 0 → 128 (`DIE`).

### The pre-registered outcome is the first one: the window is [import, first sync-end], with nothing in it

The complete `/dev/mpp_service` sub-command sequence for the failing process
(handover daemon PID 6365), decoded against `rk-mpp.h`:

```text
20:11:24  cmd 0    MPP_CMD_QUERY_HW_SUPPORT      -> hw_support 00010210
20:11:24  cmd 2    MPP_CMD_QUERY_CMD_SUPPORT     x5
20:11:24  cmd 100  MPP_CMD_INIT_CLIENT_TYPE      client 4   -> cmd 1 QUERY_HW_ID: hw_id 80019000
20:11:24  cmd 100  MPP_CMD_INIT_CLIENT_TYPE      client 9   -> cmd 1 QUERY_HW_ID: hw_id 53813f05
20:11:24  cmd 100  MPP_CMD_INIT_CLIENT_TYPE      client 16  -> cmd 1 QUERY_HW_ID: hw_id 50603312
          (2 s gap: backend init logged, AVC420 caps, virtual monitor added,
           mpp_enc prep cfg 2064x1296 with the 1344 -> 1296 vstride reconfigure)
20:11:26  cmd 100  MPP_CMD_INIT_CLIENT_TYPE      client 16  (the encoder session)
20:11:26  cmd 401  MPP_CMD_TRANS_FD_TO_IOVA      flags 00000002
20:11:26  fd 161 => iova ffc00000
20:11:26  Unable to handle kernel paging request at ffff001de02fc000
```

The `fd 161 => iova ffc00000` line and the oops are **adjacent kernel lines in
the same second**. Between the successful import — whose own
noncoherent-device map path synced the same 24 entries without faulting — and
the fatal `DMA_BUF_IOCTL_SYNC(END|RW)`, the trace shows **no** kernel-side MPP
activity: no `MPP_CMD_INIT_TRANS_TABLE`, no `MPP_CMD_SET_REG_WRITE`, no poll,
no second import. This is exactly the first pre-registered reading: the
inferred chain (import → libmpp software-header writes on the CPU →
`mpp_enc_hal_start()` → `mpp_buffer_sync_partial_end()` → full sync) is
confirmed as far as the kernel can see it, and the corruption window is pinned
between a map-time sync that walked the entries cleanly and the first
CPU-access-end sync a moment later.

Newly measured constants for the victim buffer: encoder client type **16**
(the third of the three types the backend probes at init), import flags
`0x2`, and iova `0xffc00000` — the 2,678,784-byte buffer thus ends at
`0xffe8e000`, just under the 4 GiB IOVA ceiling.

### The fingerprint held: three for three

```text
page_link = vmemmap + PFN * 64      (vmemmap = 0xfffffdffc0000000)

16:36  PFN 0x1e0c1fc  ->  0xfffffe0038307f00   & 0x3fff = 0x3f00
19:38  PFN 0x1dbe8fc  ->  0xfffffe0036fa3f00   & 0x3fff = 0x3f00
20:11  PFN 0x1de02fc  ->  0xfffffe003780bf00   & 0x3fff = 0x3f00

all three: PFN & 0xff == 0xfc (4 pages below a 256-page / 1 MiB boundary)
```

The prior finding pre-registered this exact test: a third corrupt value
satisfying `page_link & 0x3fff == 0x3f00` makes the −256-byte reading
near-certain rather than a two-sample coincidence (~1-in-16384 per sample if
random). It does. The stored value is a well-formed `struct page` pointer
sitting exactly 4 `struct page`s (256 bytes) below a correctly 1 MiB-aligned
page pointer whose base PFN is far outside RAM. The hardware-watchpoint
prediction stands sharpened: whatever the watchpoint catches must be storing a
value 256 bytes below a 16 KiB boundary.

Two secondary observations on the three values, both **INFERRED** readings of
the same bits rather than new measurements. The corrupt PFNs sit in a narrow
band (aligned bases `0x1dbe900` / `0x1de0300` / `0x1e0c200`, a ±0.7% spread,
deltas `0x21a00` and `0x2bf00` pages), so the bad input varies per boot but is
tightly clustered — shaped like an address-derived quantity, not a counter or
constant. Equivalently, read as a byte offset from `vmemmap`
(`page_link − vmemmap` = `0x76fa3f00` / `0x7780bf00` / `0x78307f00`), all
three land at 1.99–2.02 GiB, which unlike the 119–120 GiB "physical address"
reading is *inside* this board's RAM — so `vmemmap + (byte offset ≈ 2 GiB)` and
`vmemmap + 64 × (bogus PFN ≈ 119 GiB)` are both live candidate shapes for the
arithmetic. A watchpoint stack will discriminate them.

## Boundary

- The writer is still unidentified. This finding closes the ioctl-sequence gap
  and the tracing-masks-it question; it does not attribute the write.
- `mpp_dev_debug` observes only `/dev/mpp_service`. The fatal
  `DMA_BUF_IOCTL_SYNC` — and any dma-buf `SYNC_START` libmpp may have issued
  before writing headers — is invisible here, as pre-registered. Only the
  guard patch or ftrace shows both sides in one timeline.
- The trace is n=1: the sub-command sequence has been measured on one failing
  login. Its invariance across boots is assumed from the deterministic
  userspace signature, not measured.
- Client-type numbers (4, 9, 16) are read from the trace; they were not
  resolved to enum names in this pass.
- 3/3 still says nothing about a second login in the same boot, or about rate
  under sustained use.
- The narrow-band and 2 GiB byte-offset readings are interpretations of three
  samples; neither is attribution evidence on its own.

## Evidence and reproduction

- **Identity:** ROCK 5B, production `6.18.40-ysp-rockchip64`
  (`6.18.40+rk3588av1fwport20260725-0ubuntu1~rk1`), boot 2026-07-27 20:06:37,
  taint 0 at arm time; GRD `50.2+rkmpp+git20260721.13.cf60b4d`, libmpp
  `1.5.0+git20260529.1375813c`, librga `2.2.0+git20260725.26a50ef` — all
  version-matched to both prior failing boots.
- **Exercise:** armed
  `echo 0x18 > /sys/module/rk_vcodec/parameters/mpp_dev_debug` (root), then
  one macOS RDP login at the standard client geometry; encoder configured
  2064×1296 with the 2112×1344 → 2112×1296 stride reconfigure, matching both
  prior runs.
- **Pass/fail signal:** `/proc/sys/kernel/tainted` 0 → 128 at 20:11:26;
  backend-initialized line present, session-created line absent; one
  `Unable to handle kernel paging request` in the boot's kernel journal.
- **Artifacts:** `~/Code/tmp/sg-oops-repro/hit-20260727-201153/`
  (`kernel.log`, `full.log`, `pstore/`, `versions`, `uname`, `tainted`,
  `mpp_dev_debug`) — board-local capture, not committed.

## Verification gate

The guarded non-KASAN forward-port build was resumed 2026-07-27 after this
capture (`KERNEL_TREE=~/Code/tmp/fwport-sgguard bash
kernel-drivers/scripts/build-kernel.sh forward-port`, 76 userpatches, patch
hash `P37e0`). Then, per the
[escalation path](../kernel-drivers/docs/grd-sg-corruption-repro-plan.md#if-it-oopses-again-the-escalation-path):

1. Boot it with `system_heap.sg_guard=0` and take one login — validates the
   local build reproduces like the PPA kernel before trusting guard silence.
2. Re-enable the guard (runtime parameter) — names the owning device of the
   damaged table and brackets the window with `SGGUARD:` checkpoint reports.
3. Arm the hardware watchpoint on the victim entry's `page_link` — the caught
   store must match the 3/3 fingerprint (value 256 bytes below a 16 KiB
   boundary); a silent watchpoint alongside a fresh corruption indicts device
   DMA instead.

## Why it matters / follow-up

This closes the plan's open capture step with its best-case outcome: the
window is measured rather than inferred, it contains no kernel-side MPP work
at all, and the fingerprint test passed its pre-registered third trial. The
remaining unknown is a single writer identity, and the instrument that names
it is already building.
