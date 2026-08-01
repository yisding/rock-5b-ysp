# RK3588 video hardware: behaviour learned by debugging

What the silicon actually does, as established by driving it — not a TRM
substitute. Every claim here cost a debugging session, and several cost a
wedged board and a walk to the power switch. The point of writing it down is
that most of it is **not in any public document**, and the expensive parts were
each learned twice before anyone recognised the pattern.

Scope is the video pipeline on RK3588 as seen from a ROCK 5B: the rkvdec2
decoder cores and their CCU, the AV1 block, RGA2/RGA3, and the recovery
infrastructure around them. IOMMU silicon has its own treatment in
[`../iommu/docs/02-rk3588-iommu-hardware.md`](../iommu/docs/02-rk3588-iommu-hardware.md)
and is only cross-referenced here.

**How to read the trust tags.** `MEASURED` means observed on hardware with
artifacts on disk. `INFERRED` means the best model consistent with the
measurements, not independently proven — usually because the TRM does not
document the register or the mechanism. `SOURCE-CONFIRMED` means the vendor BSP
states it and both BSP branches agree. Where a mechanism is inferred, the
discriminating prediction that held is named, because that is what separates a
model from a story.

---

## 1. The defining hazard: MMIO to a gated or in-reset block stalls the whole SoC

**This is the single most important fact on this list.** A CPU store or load to
a video block whose register file is clock-gated, power-gated, or held in reset
does not fault, does not time out, and does not return. The AXI/AHB transaction
stalls forever, and the machine stops — not the thread, the *machine*.

`MEASURED`, four independent events:

| Date | Trigger | Recovery |
|---|---|---|
| 2026-07-29 | `mpi_dec_mt_h264`, dual-core, three times | hardware watchdog |
| 2026-07-30 | `mpi_dec_mt_h264` → `mpi_dec_h265` first submit | systemd `RuntimeWatchdogSec` |
| 2026-08-01 11:21 | reset-contention harness, 300 s config | hardware watchdog |
| 2026-08-01 11:32 | reset-contention harness, error streams only | hardware watchdog |

What makes it distinctive, and what to recognise it by:

- **No oops, no panic, no KASAN report, no stall report.** The journal simply
  stops mid-line.
- **`/sys/fs/pstore/` is empty afterwards.** Ramoops only captures an oops or
  panic path; a stall reaches neither, so there is nothing to record. An empty
  pstore after a silent hang is *not* a retention failure and should not be
  investigated as one.
- **Armed panic-on-hang sysctls never fire.** On 2026-08-01 the second wedge
  ran with `hung_task_panic=1`, `hung_task_timeout_secs=30`,
  `softlockup_panic=1` and `panic_on_rcu_stall=1` set 48 seconds beforehand.
  None produced anything. The 2026-07-29 event held the same sysctls armed
  across ~7 wedged minutes with the same result. Those detectors need a CPU
  that still executes; here none does.
- **Only the hardware watchdog recovers it** (§9).

The discriminating prediction that established the class: **single-core
immunity**. With rkvdec2 core 1 unbound, the 2026-07-29 killer case passed in
0.774 s, having wedged the board on every prior attempt. The mechanism requires
a second core to do the gating.

`INFERRED`: that the stalling access is specifically a coordinator or CPU poke
at a *gated* register file. The full-SoC stall is measured; the identity of the
stalling transaction has never been caught in the act, because catching it
would require the machine to survive it.

**Operational consequence.** On this SoC an entire class of driver bug produces
zero diagnostic output by construction. Budget for that: it means bisection by
configuration, not by log reading, and it means a serial console on `ttyS2` is
the only instrument with any chance of seeing the last gasp — journald, pstore,
and every in-kernel detector are downstream of a running CPU.

## 2. Core clock gating belongs to the CCU, not to the core

On `rockchip,ccu-mode = <1>` (soft CCU, which is what a ROCK 5B runs), the
coordinator owns per-core clock gating. A core registered in `CORE_WORK` can be
re-gated by the coordinator in response to a *sibling's* completion, without
the software that armed it being involved.

`INFERRED` from the BSP contract plus the measured dual-core requirement. The
BSP's `rkvdec2_soft_ccu_enqueue()` runs the entire arm → cache-config →
task-registers → `CORE_STA` → START sequence on a single taskqueue worker, and
runs every CCU/core power transition on that same worker — so in the vendor
design a gating event can never interleave with an arm or a start. That
single-worker serialization is load-bearing, and it is invisible unless you
look for why it exists.

Two consequences that were each learned the hard way:

- **Splitting the arm/start sequence is fatal**, not merely racy. Writing the
  task registers with the coordinator lock dropped leaves a window where a
  sibling completion re-gates the armed core; the next write stalls the
  interconnect (§1). Fixed 2026-07-29 by restoring BSP order, and again
  2026-07-30 when the critical section turned out to still be split in the
  middle.
- **Autosuspend is part of the gating surface.** Cores power off via
  `pm_runtime_put_autosuspend` with a 200 ms delay. After a multi-threaded
  session closes, its cores remain registered in `CORE_WORK` and their
  autosuspends expire ~200 ms later — *inside the next session's first-frame
  window*. That cross-session overlap is why `mpi_dec_h265` wedged only when
  `mpi_dec_mt_h264` ran first, and passed in 0.340 s on a fresh boot. The
  minimal reproducer was two cases, not one.

`MEASURED` discriminator for the second point: solo `mpi_dec_h265` passes; the
pair `mpi_dec_mt_h264 mpi_dec_h265` wedges at h265's first submit, on the same
boot image.

## 3. Reset controller semantics (rkvdec2)

- **Each core takes five reset lines, and no line is shared between cores.**
  `reset-names` on both `video-codec@fdc38000` and `video-codec@fdc40000` is
  `video_a video_h video_core video_cabac video_hevc_cabac`. Verified against
  the live device tree by comparing the raw `resets` phandle/index pairs: both
  cores use the same controller but disjoint indices — core0 `{323, 322, 328,
  326, 327}`, core1 `{330, 329, 335, 333, 334}`. `CONFIG-INSPECTED`.

  Cores therefore do **not** share a reset line, so the only cross-core writer
  of a core's reset is software that reaches across — which the driver does, via
  the group power-on. (Earlier notes described this as two lines,
  `SRST_A`/`SRST_H`; that undercounts. It does not change the conclusion, since
  the reset control is acquired as an array and asserted as a unit.)
- **The platform device name is not the device-tree unit address.** The node is
  `video-codec@fdc38000` but the bound device — and therefore the token you
  echo into `bind`/`unbind` — is `fdc38100.video-codec`, because the device name
  derives from the first `reg` entry rather than the unit address. Core 1 is
  `video-codec@fdc40000` / `fdc40100.video-codec`. Getting this wrong makes an
  unbind silently do nothing, which reads exactly like "single-core immunity did
  not hold".
- **The controls are exclusive**
  (`devm_reset_control_array_get_optional_exclusive`), so
  `reset_control_deassert()` always drives the hardware. There is no shared
  refcount to make a redundant deassert a no-op. `SOURCE-CONFIRMED`.
- **The recovery pulse is ~10 µs** (`assert` / `udelay(10)` / `deassert`) and is
  **truncatable by any other deassert of the same line**. A sibling core's
  power-on ends the pulse early; the pulsing core's own deassert then no-ops and
  recovery reports success without having reset anything.

  `MEASURED` 2026-08-01: `reset_deassert_contended_count` moved by 2 in each of
  two 60 s runs, against a modelled expectation of ~3.0 per run — 4 hits against
  a combined λ of 5.96, P(X=4) ≈ 0.14. See
  [the race finding](../../findings/2026-07-31-rkvdec-sibling-reset-deassert-race.md).
  This is the failure mode worth fearing: *recovery that reports success while
  leaving the core unrecovered*, so the damage surfaces later as corrupt output
  or a stalled core with nothing in the log tying it back.
- **Power-off never asserts reset.** So the pulse is the only thing a stray
  deassert can corrupt.

## 4. Interrupts and the error path

- **The practical reset source is the decode error interrupt**, not the abort
  path and not the watchdog. `MEASURED`: a provocation built on killing
  decoders mid-decode produced **zero** resets over a full run — a victim
  spends only ~12 ms of its ~300 ms life on hardware, and only an in-flight job
  reaches the abort reset path. Switching the provocation to damaged slice
  payloads produced **5092 resets in 61 s** on the same workload shape.
- **Error status is `irq_status & 0xf0`.** The soft-CCU IRQ thread resets the
  core whenever any bit in that mask is set, and a stream with corrupt slice
  data reaches it a few times per decode.
- **The hard IRQ handler performs core MMIO outside all CCU serialization** —
  an `INT_STA` read and an ack write under only the per-core spinlock. This is
  structural, not incidental: the handler is not sleepable and cannot take the
  coordinator mutex. It remains the leading unresolved candidate for the
  wedges that survived both 2026-07-30 fixes.
- **Corrupting a stream to reach the error path is easy to get wrong.** Damage
  the slice *header* and userspace rejects the slice without ever submitting
  it, so the hardware never sees anything. Damage must land in the payload,
  past the header, with parameter sets and NAL framing intact — see
  `../tests/rewrite-corrupt-stream.py`, which forces every written byte
  non-zero with bit 6 set so no `00 00 01` can be synthesised.

## 5. Job dispatch topology: one stream is not one core

A single decoder session's jobs alternate across **both** rkvdec2 cores of the
group. `MEASURED` 2026-08-01, one decoder, 60 s:
`dispatched_rkvdec_core0_count` 1877 against `core1` 1876.

Resets, by contrast, land only on the core that owned the erroring job — the
same run reset core0 936 times and core1 **zero** times.

This matters for experiment design and it invalidated an isolation matrix on
the day: "run one stream" does *not* give you a single-core configuration. If
you need one core, unbind the other:

```
echo fdc40100.video-codec > /sys/bus/platform/drivers/rk-mpp-rewrite-hw/unbind
```

## 6. AV1: the block with no idle proof

The AV1 decoder exposes **no documented idle handshake** that proves its reset
pulse has retired every outstanding VCD/AFBC DMA transaction. There is no
register to read that answers "is it safe now".

The practical consequence is that abnormal recovery on AV1 cannot be proven
correct from the hardware side, only assumed. The rewrite driver therefore
keeps AV1 recovery fail-closed — it counts the unproven case
(`av1_reset_idle_unproven_count`) and terminally isolates the block rather than
returning it to service. That is a deliberate capability sacrifice standing in
for hardware evidence that does not exist; if a TRM ever supplies the
handshake, that is the code to revisit.

AV1 also has its own auxiliary AFBC block whose mask/status/START sequence is a
separate IRQ-safe transaction from the VCD START, and a dedicated level IRQ
that is exclusive and hard-only. See
[`../av1/docs/av1-rk3588.md`](../av1/docs/av1-rk3588.md).

## 7. RGA3 format and memory contracts

- **10-bit `vir_w` is a byte stride in every uncompressed mode — RASTER and
  TILE alike.** There is no pixel convention for 10-bit outside the compressed
  modes. The `* 8` in the BSP's TILE stride expression is the
  eight-lines-per-tile-block factor, not a pixel-depth scale; the BSP comment
  says so directly. `SOURCE-CONFIRMED`, both `develop-5.10` and `develop-6.1`
  identical. Misreading that one expression propagated a wrong stride into two
  independent codebases that then agreed with each other and diverged from the
  hardware.
- **RGA3 AFBC NV15→P010 intermittently returns success without writing the
  destination, and the rate depends on picture size.** `MEASURED`, 1248
  hash-compared frames:

  | Geometry | Runs affected | Frames wrong |
  |---|---:|---:|
  | 416×240 | 6/10 | 24/480 (5.00%) |
  | 320×240 | 3/8 | 5/384 (1.30%) |
  | 1280×720 | **0/8** | 0/384 |

  Silent at every layer — MPP reports no `errinfo`, librga reports no error,
  and the driver's own audit counts the expected number of conversions. A
  recycled destination buffer comes back bit-exact to its previous contents; a
  fresh one comes back entirely zero. Mechanism **not closed**; see
  [the finding](../../findings/2026-07-31-rga3-afbc-p010-dropped-destination-write.md).
- **Multi-segment memory contracts differ by kernel generation.** The BSP
  relies on 5.10/6.1 IOMMU coalescing behaviour that newer kernels do not
  reproduce; drivers on 6.18 must validate or remap rather than assume. See
  [`../rga/docs/userptr-iommu.md`](../rga/docs/userptr-iommu.md).

## 8. RCB and SRAM

RKVENC RCB is **ABI-plumbed but not SRAM-backed in the device tree** on this
board — the interface exists, the memory does not. Encoder RCB allocation must
stay best-effort, exactly as the BSP has it, and decoder SRAM must not be
borrowed for it without TRM evidence. `CONFIG-INSPECTED` +
`SOURCE-CONFIRMED`; full treatment in
[`../mpp/docs/rcb-sram.md`](../mpp/docs/rcb-sram.md).

## 9. Recovery infrastructure: what actually saves the board

- **Hardware watchdog: Synopsys DesignWare, ~89 s (1 min 29 s)**, opened by
  systemd as `/dev/watchdog0`. `MEASURED` repeatedly — it is the *only* thing
  that recovers an interconnect stall, and the gap between the last journal
  line and the next boot has matched it every time.
- **`RuntimeWatchdogSec=60s` in systemd** proved itself independently on
  2026-07-30 and is worth keeping armed during any wedge hunting.
- **A hard reset discards the last ~5–30 s of ext4 writes.** Test artifacts
  that were written but not synced are simply gone, so *absence of an artifact
  localizes nothing* — this cost two runs' worth of misattribution in July when
  missing output directories were read as "died at startup". Per-case `sync`
  in the suite runner is what made the 2026-07-29 artifacts survive to be
  useful.
- **journald syncs every 5 minutes by default**, so a wedge silently discards
  up to five minutes of log tail; the first 2026-08-01 wedge lost 13 minutes
  and made the crash look far earlier than it was. `SyncIntervalSec=1s` is the
  cheap fix while hunting.
- **Warm reset may not fully clear a stalled video-codec domain.** After the
  2026-07-30 wedge the next two boots died mid-early-boot at ~15–25 s uptime
  before the third survived. `MEASURED` but not isolated — manual resets in
  that window are not excluded.

## 10. Debug-kernel interactions worth knowing

- **`CONFIG_PROVE_RAW_LOCK_NESTING` cannot be disabled by config on arm64.**
  `ARCH_SUPPORTS_RT` hides the prompt and forces `default y` whenever
  `PROVE_LOCKING=y`, so the debug flavor carries a one-line Kconfig patch to
  make the prompt unconditional. Without it, the first decode IRQ trips an
  invalid-wait-context report, **lockdep disables itself for the rest of the
  boot**, and every subsequent deadlock goes uncovered — which is the entire
  reason the debug kernel exists.
- **Lockdep reports once and then goes blind.** This masked a real hard-IRQ
  wait-context defect for weeks: on earlier kernels the soft-CCU submit
  recursion always killed lockdep first, so the IRQ report never surfaced until
  the recursion was fixed. If lockdep is silent, check `debug_locks` before
  concluding anything.

## 11. What we still do not know

Honest gaps, so nobody re-derives them as if they were settled:

- **The gating mechanism is inferred, not TRM-proven.** No register
  documentation supports the model in §1–2; it rests on the BSP contract plus
  the single-core immunity prediction holding.
- **Which transaction stalls.** Two candidates remain live for the 2026-08-01
  wedges — a reset pulse overlapping a sibling's power-on deassert, and the
  hard-IRQ `INT_STA` access to a core in reset. The pending reset-domain lock
  discriminates them: it closes the first and cannot touch the second.
- **Whether the RGA3 AFBC dropped-write defect is silicon or driver.** The
  size dependence is suggestive of the former; it has never been bisected
  against an older kernel.
- **Whether AV1 has any idle proof at all**, or whether fail-closed recovery is
  permanent.

## Sources

Findings are dated and evidence-bearing; each carries its own artifact paths.

- [2026-07-29 dual-core wedge, arm/start split](../../findings/2026-07-29-rewrite-soft-ccu-dual-core-wedge.md)
- [2026-07-30 split critical section, h265 wedge](../../findings/2026-07-30-rewrite-soft-ccu-split-critical-section-h265-wedge.md)
- [2026-07-31 sibling reset-deassert race](../../findings/2026-07-31-rkvdec-sibling-reset-deassert-race.md)
- [2026-08-01 cross-core reset wedge](../../findings/2026-08-01-rewrite-soft-ccu-cross-core-reset-wedge.md)
- [2026-07-31 RGA3 AFBC P010 dropped destination write](../../findings/2026-07-31-rga3-afbc-p010-dropped-destination-write.md)
- [2026-07-24 10-bit tile byte stride](../../findings/2026-07-24-rga-10bit-tile-byte-stride-and-fbc-exception.md)
- [2026-07-30 AV1/VSI fault and AFBC lifecycle races](../../findings/2026-07-30-rewrite-av1-vsi-fault-afbc-lifecycle-races.md)
- [RK3588 IOMMU hardware structure](../iommu/docs/02-rk3588-iommu-hardware.md)
- [RCB and SRAM](../mpp/docs/rcb-sram.md)
- [Multi-core decode scheduling, CCU hard/soft modes](../mpp/docs/multicore-scheduling.md)
