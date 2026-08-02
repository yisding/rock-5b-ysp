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

### What the TRM does settle `TRM-CONFIRMED`

TRM Part 1 §5.6.5 "VDPU381 CCU configuration flow" (p. 676) documents the
link-table/hard-CCU path, and its register block is the one our soft path also
writes. Every offset in our driver matches:

| Our constant | Offset | TRM register |
|---|---|---|
| `CCU_CORE_WORK_BASE` | `0x0044` | `SWREG17_CCU_CORE_WORK_MODE` |
| `CCU_CORE_STA_BASE` | `0x0048` | `SWREG18_CCU_CORE_WORK_STA` |
| `CCU_CORE_IDLE_BASE` | `0x004c` | `SWREG19_CCU_CORE_FORCE_IDLE_E` |
| — *(unused)* | `0x0050` | `SWREG20_CCU_CORE_REQ_TIMEOUT_E` |
| `CCU_CORE_ERR_BASE` | `0x0054` | `SWREG21_CCU_CORE_ERR_STA` |
| `CCU_CORE_RW_MASK` | `GENMASK(17,16)` | the per-core write-enable bits |

Three things it tells us that were previously guesswork:

- **Resetting a CCU-controlled core has a documented precondition.** On
  `SWREG19`: *"When core should be reset, should config this bit to 1, force
  ccu core0 controller on idle status."* Our
  `rk_mpp_rkvdec2_reset_soft_ccu_job()` does exactly this — it writes
  `hw->core_mask` (`0x00010001`, value bit plus write-enable) to force idle
  before `stop_active()`, then writes write-enable alone afterwards to clear
  it. That sequence was arrived at from the BSP and is now confirmed correct
  against the TRM.
- **A failing core takes itself out of service.** On the error path: *"If any
  error found by hardware core, the error hardware core will disable itself,
  and if all selection hardware core error, ccu stop decoder."* The flow
  diagram adds that hardware *"will stop decoder and auto disable
  ccu_work_en"*. So core removal on error is a hardware action, not only a
  driver one.
- **There is an unused hardware safety net.** `SWREG20_CCU_CORE_REQ_TIMEOUT_E`
  — *"When ccu start core to work, but too long to fetch ack, it will unload
  such core"* — defaults to 0, "can't timeout", and **we never program it**.
  Whether enabling it would blunt the wedge class in §1 is untested, but it is
  the only documented mechanism by which the CCU gives up on an unresponsive
  core.

What the TRM does **not** contain: any warning about accessing a gated or
in-reset block, or any description of the soft-CCU mode the BSP implements.
§1 remains undocumented by the vendor.

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

## 3a. The hardware resets *itself* — a third reset actor `TRM-CONFIRMED`

The decoder performs its own soft reset on most error conditions, without the
driver asking and without the driver being told in advance. This was missed
entirely until 2026-08-01 and it changes how the whole error path should be
read.

`RKVDEC_SWREG224_STA_INT` — TRM Part 1 p. 518, at **offset 0x0380**, which is
byte-for-byte our `RK_MPP_RKVDEC_INT_STA_BASE`:

| Bit | Name | Self-resets the hardware? |
|---:|---|---|
| 9 | `sw_softreset_rdy` | — *"When it is 1'b1, it says that softreset has been done."* |
| 8 | `sw_cabu_end_sta` | no |
| 7 | `sw_colmv_ref_error_sta` | **yes** (HEVC/VP9; H.264 only when `sw_h264_error_mode` is 0) |
| 6 | `sw_buf_empty_sta` | no |
| 5 | `sw_dec_timeout_sta` | **yes** (valid only when `sw_dec_timeout_e` is 1) |
| 4 | `sw_dec_error_sta` | **yes** (HEVC/VP9; H.264 conditional as above) |
| 3 | `sw_dec_bus_sta` | **yes** — *"there is error on the axi bus"* |
| 2 | `sw_dec_rdy_sta` | no (picture decoded) |
| 1 | `sw_dec_irq_raw` | no |
| 0 | `sw_dec_irq` | no |

Three consequences, all of which the driver should be read against:

- **By the time the IRQ thread runs, the core has usually already reset
  itself.** Our `err_mask` of `0xf0` covers bits 4–7, and bits 4, 5 and 7 are
  all documented self-reset conditions. The driver's own reset pulse is
  therefore landing on a core that has already been reset by hardware.
- **Bit 9 is the completion signal for that self-reset**, and we never read it.
  Mainline does, and uses it to trigger IOMMU recovery.
- **The self-reset clears the decoder's embedded IOMMU programming.** The
  IOMMU sits inside the decoder, so resetting one resets the other. Mainline's
  `rkvdec` recovers by attaching and detaching an empty domain to force a
  reprogram, because the IOMMU framework has no restore call.

The same register documents the `sw_dec_bus_sta` AXI-error bit as self-
resetting — **and it is outside our `0xf0` mask**, so a bus error currently
completes the job as successful. See
[the 2026-08-01 gap finding](../../findings/2026-08-01-rkvdec-self-reset-and-iommu-restore-gaps.md)
for the staged disposition; the short version is that the BSP and mainline
both use `0xf0` as well, so this gets measured before it gets changed.

**All of these bits are observable without a kernel change.** The rewrite
driver records every interrupt into its debug event ring with the raw
`irq_status`, and `/sys/kernel/debug/rk_mpp_rewrite/events` prints that word in
hex as field 11. Set `trace_mask` to `2` (`TRACE_IRQ`), provoke briefly, read
the ring, set it back to `0`. The ring is 64 entries, so under a heavy
provocation it samples rather than counts — enough to answer "does this ever
happen", which is the question that decides whether dedicated counters are
worth their frame-size cost.

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
- **The rewrite RGA3 AFBC NV15→P010 path intermittently returns success without
  writing the destination; the production forward-port/vendor driver does
  not reproduce it under substantially wider coverage.** The original rewrite
  build `#23` result is `MEASURED`, 1,248 hash-compared frames:

  | Geometry | Runs affected | Frames wrong |
  |---|---:|---:|
  | 416×240 | 6/10 | 24/480 (5.00%) |
  | 320×240 | 3/8 | 5/384 (1.30%) |
  | 1280×720 | **0/8** | 0/384 |

  Silent at every layer — MPP reports no `errinfo`, librga reports no error,
  and the driver's own audit counts the expected number of conversions. A
  recycled destination buffer comes back bit-exact to its previous contents; a
  fresh one comes back entirely zero. On 2026-08-02 the production
  forward-port/vendor driver passed 90/90 runs and 4,320/4,320 exact frames at
  each affected geometry, plus explicit exercise of both RGA3 cores. That is a
  hardware counterexample and scopes the known failure to the rewrite track;
  it does not prove which rewrite defect causes it. See the
  [original failure](../../findings/2026-07-31-rga3-afbc-p010-dropped-destination-write.md)
  and the
  [forward-port discriminator](../../findings/2026-08-02-rga3-forward-port-small-geometry-discriminator.md).
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

- **The gating mechanism is still inferred.** The TRM documents the CCU
  register block and the hard-CCU flow (§2), which confirms our register map
  and the force-idle-before-reset protocol — but it says nothing about what
  happens when the CPU touches a gated core, and nothing about soft-CCU mode
  at all. The §1 model still rests on the BSP contract plus the single-core
  immunity prediction holding.
- **Whether `SWREG20_CCU_CORE_REQ_TIMEOUT_E` would blunt the wedge.** It is the
  one documented mechanism for the CCU to unload an unresponsive core, and it
  is currently left disabled. Untested.
- **Whether the hardware self-reset (§3a) races the driver's reset pulse.** The
  driver issues `reset_control` assert/deassert on cores that have usually
  already self-reset, and never reads the `sw_softreset_rdy` completion bit.
  This is a newly discovered third reset actor and it has not been modelled or
  measured.
- **Which transaction stalls.** Two candidates remain live for the 2026-08-01
  wedges — a reset pulse overlapping a sibling's power-on deassert, and the
  hard-IRQ `INT_STA` access to a core in reset. The pending reset-domain lock
  discriminates them: it closes the first and cannot touch the second.
- **Whether the corrected rewrite power/map ordering cures the RGA3 AFBC
  dropped write.** The production forward-port/vendor driver is clean under
  repeated dual-core evidence, so this is no longer an open silicon-versus-
  driver question. The corrected rewrite has not been boot-tested, and the
  cross-track comparison is not a strict single-variable bisection.
- **Whether AV1 has any idle proof at all**, or whether fail-closed recovery is
  permanent.

## Sources

### Primary

- **RK3588 TRM Part 1, v1.0** — §5.6.5 "VDPU381 CCU configuration flow"
  (p. 676); `RKVDEC_CCU_SWREG17`–`SWREG21` (pp. 535–536);
  `RKVDEC_SWREG224_STA_INT` (p. 518); `VDPU_SWREG1` (p. 395). Mirrored at
  `scs.stanford.edu/~zyedidia/docs/rockchip/rk3588_part1.pdf` (54 MB, 2287
  pages — too large for most fetch tools; download and `pdftotext -layout`,
  then grep). Page numbers above are the printed ones.

### Upstream, for comparison

- [`media: rkvdec: Restore iommu addresses on errors`](https://patchew.org/linux/20250508-rkvdec-iommu-reset-v1-1-c46b6efa6e9b@collabora.com/)
  — the self-reset/`SOFTRESET_RDY`/IOMMU-restore behaviour, from the mainline side.
- [`media: rkvdec: Disable multicore support`](http://www.mail-archive.com/linuxtv-commits@linuxtv.org/msg48496.html)
  — mainline deliberately does not expose the second core, so nothing upstream
  exercises the dual-core paths in §1–2.
- [Collabora: RK3588/RK3576 decoders merged upstream](https://www.collabora.com/news-and-blog/news-and-events/rk3588-and-rk3576-video-decoders-support-merged-in-the-upstream-linux-kernel.html)
  — confirms the IOMMU is embedded in the decoder and is reset with it.

### Our findings

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
