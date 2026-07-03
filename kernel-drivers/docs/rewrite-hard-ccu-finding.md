# Finding: RK3588 CCU mode is now honored; HARD remains unvalidated

**Date:** 2026-07-03 · **Track:** clean-room rewrite (`mpp-rewrite`) · **Status:** code mismatch fixed, needs hardware.

The rewrite MPP driver originally drove the RK3588 dual-core decoder in **HARD
CCU** mode on the actual rock-5b device tree, even though the BSP-validated
configuration is **SOFT CCU**. The current rewrite now reads
`rockchip,ccu-mode`, defaults invalid/missing values to BSP-compatible SOFT, and
only enables HARD link-table scheduling when the DT explicitly selects
`rockchip,ccu-mode = <2>`. This page records the fixed divergence, the remaining
hardware-validation gap, and how to earn confidence in HARD.

Read [multicore-scheduling.md § 7](./multicore-scheduling.md#7-the-ccu-and-its-hardsoft-modes)
first — it establishes what SOFT/HARD are ("who owns the scheduling loop": CPU vs
the CCU) and notes that even Rockchip defaults to SOFT. This page is the
rewrite-specific consequence of that, plus a validation plan.

> **Anchors & provenance.** `file:line` for the rewrite resolve against
> `linux-6.18-rkvenc`, branch `rk3588-rewrite-6.18` (tip `ee279b88cfa8`, this is
> the same tree as track 4 in [status.md](../../status.md)). Vendor `file:line`
> resolve against the forward-ported `drivers/video/rockchip/mpp/`. DT lines are in
> that same tree's `arch/arm64/boot/dts/rockchip/`. The "HARD is unreliable" claim
> is **secondary/web-sourced** (see § 7 of the multicore doc) — treat as a
> hypothesis to disprove, not a measured fact.

---

## 1. The divergence

| | BSP forward-port (vendor) | Clean-room rewrite |
|---|---|---|
| Modes implemented | SOFT **and** HARD (`mpp_rkvdec2_link.c`) | SOFT default + HARD opt-in |
| Reads `rockchip,ccu-mode`? | Yes (`mpp_rkvdec2.c:1759`) | Yes |
| Default when unset/invalid | SOFT (`mpp_rkvdec2.c:1753`) | SOFT |
| What rock-5b DT requests | SOFT (`rockchip,ccu-mode = <1>`) | honored |
| What should run on the board | **SOFT** | **SOFT** |

**The device tree explicitly asks for SOFT:**

```
rk3588-base.dtsi:1548   /* 1: soft ccu  2: hw ccu */
rk3588-base.dtsi:1549   rockchip,ccu-mode = <1>;
rk3588-rock-5b.dtsi:141 &rkvdec_ccu { status = "okay"; };   # enables, no mode override
```

**The rewrite now gates the two paths from the same DT property:**

- `rk_mpp_hw_read_rkvdec_ccu_mode` reads `rockchip,ccu-mode` from the CCU node
  and normalizes invalid/missing values to SOFT.
- `rk_mpp_rkvdec2_prepare_soft_ccu` programs the SOFT coordination registers and
  starts the selected core directly, matching the BSP "CPU owns dispatch" model.
- `rk_mpp_rkvdec2_stage_link_table` / `_start_ccu_job` remain available only
  when the normalized mode is HARD.

**The fixed risk boundary:** HARD is still implemented, but it is no longer live
on the Rock 5B DT merely because the `"link"` reg window exists. Link tables are
allocated only when the DT selects HARD. On rock-5b the relevant core still has
both a CCU phandle and link MMIO:

```
rk3588-rock-5b.dtsi   &vdec0 { reg-names = "regs", "link"; rockchip,ccu = <&rkvdec_ccu>; ... }
```

but the explicit `rockchip,ccu-mode = <1>` now keeps the rewrite on SOFT.

**Net:** the shipped board DT no longer silently selects a multi-core mode the
BSP deliberately avoids. The remaining question is runtime equivalence and
performance on hardware.

---

## 2. Why the tests don't catch it

The HARD path has ~16 KUnit cases (`_fill_link_table`, `_link_table_ownership`,
`_link_table_ccu_ref`, `_ccu_running_list`, `_ccu_job_done`, `_ccu_power_transfer`,
`_release_power_transfer`, `_ccu_relink_unfinished`, `_ccu_collect_unfinished`,
`_ccu_descriptor`, `_ccu_descriptor_core_mask`, `_fixed_rcb_link`,
`_hw_abort_ccu_dependents`, plus link-info / irq-decode / timeout helpers).

They are **logic-level only**: descriptors are built in `kunit_kcalloc` buffers
with fake IOVAs (`0x12345000`), and assertions check link-table **byte layout**
(which register word lands where, next-pointer, readback/segment offsets) and the
job-list / ownership / power-transfer **state machines**. The new SOFT coverage
checks mode normalization and the register programming shape, but still does not
touch real MMIO, DMA, reset timing, or real hardware.

So the suite would catch a regression in *which path is selected* and *how the
driver assembles link tables / programs SOFT coordination registers*, but says
nothing about whether RK3588 silicon executes either mode correctly under load.

---

## 3. Where instability would live (code-grounded suspects)

`rk_mpp_rkvdec2_start_ccu_job` (`mpp_rewrite.c:6123`) is carefully written — it has
an explicit `wmb()` before the `CFG_DONE` doorbell ("Ensure CCU descriptor writes
land before CFG_DONE starts the job", `~:6205`), runs under `ccu->run_lock`, and
checks cancellation. So a crude missing-barrier bug is unlikely. The risk is in
concurrent state transitions unit tests can't reach, in likelihood order:

1. **ADD-mode append race.** When `add_mode` is true the code appends to a
   *running* list: the previous tail's next-pointer is linked in
   `stage_link_table` (`prev_table[...] = job->rkvdec_link_iova`), then this
   function rings `CFG_DONE` in ADD mode. Classic failure: the HW latches the old
   tail's `next = NULL` and halts the walk in the window around the CPU publishing
   the new node → the appended job is orphaned → timeout. **Whether the CCU's "add"
   semantics close that window is the single most important thing to prove.**
2. **`add_mode` decision vs. completion IRQ.** `ccu_en = readl(CCU_WORK)` +
   `ccu_has_jobs()` decide append-vs-fresh-start; if a completion IRQ empties the
   CCU between that read and the doorbell, the code can append to a CCU that just
   stopped. Confirm the IRQ/completion path takes `ccu->run_lock`.
3. **Timeout / reset recovery.** `restart_ccu_job` +
   `relink_unfinished`/`collect_unfinished` re-drive after a reset; reset-during-
   append and IRQ-during-reset are textbook instability, and this is the least
   exercised path.

---

## 4. Validation / debug / fuzz plan

**Goal reframe.** You cannot *prove* a hardware linked-list walker correct by
testing (unbounded interleaving space). Achievable goals: (a) drive the failure
rate below a soak threshold, and (b) guarantee **safe degradation** on failure.

**Prerequisite — make the mode selectable + safe by default.**
- Done in code: the rewrite reads `rockchip,ccu-mode`, defaults to the
  BSP-validated SOFT/per-core path, and makes HARD opt-in.
- Still needed: add **fallback-on-fault**. On a HARD timeout/reset, demote that
  `hw` to
  per-core/SOFT and log. Turns a user-visible decode hang into degraded-but-working
  + telemetry — the thing that lets you ship while chasing the tail.
- This also gives you the A/B oracle below on one kernel.

**Layer 1 — observability (can't debug an invisible hang).**
- Use the per-core HW timing counters already landed in the rewrite.
- ftrace tracepoints at `reserve`/`stage`/`prepare`/`start`/`add`/`complete`/
  `timeout`/`reset` with `{job id, core mask, link index, add_mode, cfg_addr}`.
- On every timeout/reset, snapshot to a ring buffer: full descriptor bytes, link
  status word, CCU `WORK`/`CORE_WORK`/`CORE_STA` regs, IOMMU fault record. That
  snapshot is what turns "it hung" into a root cause.

**Layer 2 — correctness oracle (differential testing).** Strongest tool. Decode the
same conformance bitstream three ways — HARD CCU, rewrite per-core, vendor SOFT —
and hash output frames (H.264/H.265/VP9 conformance suites w/ golden MD5s). Any
HARD-vs-reference divergence = bug; HARD-only hang = stability bug. Without this, a
fuzzer that produces *wrong pixels* (not a crash) is invisible. Extend the existing
[`kernel-drivers/tests/mpp-suite-compare.sh`](../tests/mpp-suite-compare.sh) /
`gstreamer-suite-compare.sh` comparators to add the HARD-vs-SOFT axis.

**Layer 3 — concurrency/fault fuzzing (the real target).** Fuzz the *orchestration*,
not just ioctl bytes:
- Randomize {session count, core mask, job sizes, submit interleaving, append
  timing}; deliberately hit the append window (submit N+1 as N is expected to
  finish).
- Fault injection: jam the timeout threshold to the floor (driver has 20/50/100 ms
  tiers — force recovery constantly), inject IOMMU faults via map/unmap races,
  cancel / close-fd mid-decode, reset during append.
- Ring boundaries: `task-capacity = 16` link ring — wraparound, full-ring,
  `rkvdec_link_used` index reuse.
- Build under **KCSAN** (for CPU-appends-while-HW-walks and IRQ-vs-`run_lock` data
  races — most likely to name the actual bug), **KASAN**, lockdep, `DMA_API_DEBUG`.

**Layer 4 — reproduce & minimize.** Seed the RNG + record the exact schedule so
every hang is replayable; delta-debug the schedule to the minimal failing
interleaving; run as a multi-hour soak with the Layer-2 oracle. **Decisive
experiment:** if the identical soak passes on SOFT and fails on HARD, the
instability is isolated to the HARD orchestration — corroborating the upstream
reports and pointing at § 3 suspects.

**ABI/parser surface** (malformed `MPP_IOC_CFG_V1` batches, bad session fds,
out-of-range register requests): **syzkaller + a custom syzlang description of the
MPP UAPI**, under KASAN. Catches driver memory-safety, **not** the HW linked-list
instability (that needs Layers 2–4). Pairs with the existing
[`kernel-drivers/tests/abi-replay.sh`](../tests/abi-replay.sh).

---

## 5. Bottom line

Ship SOFT as the default, keep HARD opt-in with automatic fallback-on-timeout,
and earn confidence in HARD via **differential soak testing under KCSAN**, with
the append-race, IRQ-vs-lock, and reset-recovery paths as the named targets.
Everything beyond the code-selection fix needs RK3588 hardware, so it lands on
the same critical path as the outstanding bring-up (track 4,
[status.md](../../status.md)).

**Cross-refs:** [multicore-scheduling.md § 7](./multicore-scheduling.md#7-the-ccu-and-its-hardsoft-modes)
· [rewrite-drivers.md](./rewrite-drivers.md) · [debug-kernel.md](./debug-kernel.md)
· source finding also recorded in the rewrite tree at
`drivers/video/rockchip/mpp-rewrite/ABI.rst` § Findings.
