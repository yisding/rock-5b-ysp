# Finding: the rewrite runs HARD CCU where the BSP runs SOFT

**Date:** 2026-07-03 · **Track:** clean-room rewrite (`mpp-rewrite`) · **Status:** open, needs hardware.

The rewrite MPP driver drives the RK3588 dual-core decoder in **HARD CCU** mode on
the actual rock-5b device tree, even though the BSP-validated configuration is
**SOFT CCU**. Upstream/secondary sources report HARD as unreliable. This page
records the divergence, why the existing tests don't cover it, and how to earn
confidence in (or design around) HARD.

Read [multicore-scheduling.md § 7](./multicore-scheduling.md#7-the-ccu-and-its-hardsoft-modes)
first — it establishes what SOFT/HARD are ("who owns the scheduling loop": CPU vs
the CCU) and notes that even Rockchip defaults to SOFT. This page is the
rewrite-specific consequence of that, plus a validation plan.

> **Anchors & provenance.** `file:line` for the rewrite resolve against
> `linux-6.18-rkvenc`, branch `rk3588-rewrite-6.18` (tip `b7053000e792`, this is
> the same tree as track 4 in [status.md](../../status.md)). Vendor `file:line`
> resolve against the forward-ported `drivers/video/rockchip/mpp/`. DT lines are in
> that same tree's `arch/arm64/boot/dts/rockchip/`. The "HARD is unreliable" claim
> is **secondary/web-sourced** (see § 7 of the multicore doc) — treat as a
> hypothesis to disprove, not a measured fact.

---

## 1. The divergence

| | BSP forward-port (vendor) | Clean-room rewrite |
|---|---|---|
| Modes implemented | SOFT **and** HARD (`mpp_rkvdec2_link.c`) | **HARD only** |
| Reads `rockchip,ccu-mode`? | Yes (`mpp_rkvdec2.c:1759`) | **No — property ignored** |
| Default when unset | SOFT (`mpp_rkvdec2.c:1753`) | n/a (always HARD if link MMIO present) |
| What rock-5b DT requests | SOFT (`rockchip,ccu-mode = <1>`) | (ignored) |
| What actually runs on the board | **SOFT** | **HARD** |

**The device tree explicitly asks for SOFT:**

```
rk3588-base.dtsi:1548   /* 1: soft ccu  2: hw ccu */
rk3588-base.dtsi:1549   rockchip,ccu-mode = <1>;
rk3588-rock-5b.dtsi:141 &rkvdec_ccu { status = "okay"; };   # enables, no mode override
```

**The rewrite implements only the HARD linked-list path** and never consults the
property:

- `rk_mpp_rkvdec2_reserve_link_table` / `_fill_ccu_descriptor` /
  `_prepare_ccu_descriptor` / `_start_ccu_job` — all HARD-CCU (in-memory
  descriptor list handed to the CCU, `CCU_CFG_ADDR` / `LINK_MODE` / `CFG_DONE`).
- No SOFT-CCU equivalent (no software per-core round-robin dispatch loop).
- `grep ccu-mode mpp_rewrite.c` → nothing.

**And the HARD path is live on this DT, not the `-EOPNOTSUPP` fallback.** The link
table is provisioned whenever a `ccu_node` and the `"link"` reg window are present
(`rk_mpp_rkvdec2_setup_link`, `mpp_rewrite.c:8192`). On rock-5b both are true:

```
rk3588-rock-5b.dtsi   &vdec0 { reg-names = "regs", "link"; rockchip,ccu = <&rkvdec_ccu>; ... }
```

so `hw->rkvdec_link_vaddr` is allocated and `reserve_link_table` succeeds. The
`-EOPNOTSUPP` degrade-to-per-core path is reached **only** when the `"link"` MMIO
is absent — which it is not here.

**Net:** on the shipped board DT, the rewrite silently selects a multi-core mode
the BSP deliberately avoids.

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
job-list / ownership / power-transfer **state machines**. No test touches MMIO, the
CCU register block, DMA, or real hardware. **SOFT has zero coverage** because it is
unimplemented.

So the suite would catch a regression in *how the driver assembles link tables and
juggles jobs*, but says nothing about whether RK3588 silicon actually **executes**
them — which is precisely where "HARD is unreliable" would live.

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
- Wire the rewrite to read `rockchip,ccu-mode` (today it ignores it). Default to
  the BSP-validated SOFT/per-core path; make HARD opt-in.
- Add **fallback-on-fault**: on a HARD timeout/reset, demote that `hw` to
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

Ship SOFT as the default, gate HARD behind a flag with automatic
fallback-on-timeout, and earn confidence in HARD via **differential soak testing
under KCSAN**, with the append-race, IRQ-vs-lock, and reset-recovery paths as the
named targets. Everything here needs RK3588 hardware, so it lands on the same
critical path as the outstanding bring-up (track 4, [status.md](../../status.md)).

**Cross-refs:** [multicore-scheduling.md § 7](./multicore-scheduling.md#7-the-ccu-and-its-hardsoft-modes)
· [rewrite-drivers.md](./rewrite-drivers.md) · [debug-kernel.md](./debug-kernel.md)
· source finding also recorded in the rewrite tree at
`drivers/video/rockchip/mpp-rewrite/ABI.rst` § Findings.
