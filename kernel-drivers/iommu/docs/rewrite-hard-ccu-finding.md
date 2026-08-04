# Finding: RK3588 CCU mode is now honored; HARD remains unvalidated

**Date:** 2026-07-03 · **Updated:** 2026-07-24 · **Track:** clean-room rewrite (`mpp-rewrite`) · **Status:** code/topology mismatch fixed, needs hardware.

The rewrite MPP driver originally drove the RK3588 dual-core decoder in **HARD
CCU** mode on the actual rock-5b device tree, even though the BSP-validated
configuration is **SOFT CCU**. The current rewrite now reads
`rockchip,ccu-mode`, defaults invalid/missing values to BSP-compatible SOFT, and
only enables HARD link-table scheduling when the DT explicitly selects
`rockchip,ccu-mode = <2>`. This page records the fixed divergence, the remaining
hardware-validation gap, and how to earn confidence in HARD.

> **Current-source update (2026-08-04):** maintained tips are 6.18
> `33c30ec6989e` and mainline `9e503f6b16df`. The SOFT-default/HARD-opt-in
> model remains in source and the current normal focused build passes, but HARD
> still has no current-tip hardware result. The older `file:line` anchors below
> retain historical provenance; use the named symbols when reading the current
> translation unit.

Read [multicore-scheduling.md § 7](../../mpp/docs/multicore-scheduling.md#7-the-ccu-and-its-hardsoft-modes)
first — it establishes what SOFT/HARD are ("who owns the scheduling loop": CPU vs
the CCU) and notes that even Rockchip defaults to SOFT. This page is the
rewrite-specific consequence of that, plus a validation plan.

> **Anchors & provenance.** `file:line` for the rewrite resolve against
> `linux-6.18-rkvenc`, branch `rk3588-rewrite-6.18` (historical inspection tip
> `bb32bc4f999f`; maintained pin recorded above — see [rewrite-drivers.md § 6](../../docs/rewrite-drivers.md#6-status--citable-location)
> and [source-trees § 8](../../../docs/source-trees.md); this is the same tree as
> track 4 in [status.md](../../../status.md)). Vendor `file:line`
> resolve against the forward-ported `drivers/video/rockchip/mpp/`. DT lines are in
> that same tree's `arch/arm64/boot/dts/rockchip/`. The "HARD is unreliable" claim
> was originally **secondary/web-sourced** (see § 7 of the multicore doc); the
> [vendor BSP git history](#vendor-bsp-history--was-hard-ever-on-primary-evidence)
> section below now backs it with **primary evidence** (default-SOFT since HARD's
> birth, a ~5.5× maintenance asymmetry, and a real HARD-only reset bug) — still
> short of a measured "HARD is broken on current silicon" proof, but no longer a
> bare hypothesis.

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

### Shared-IOMMU prerequisite

HARD can dispatch a link table and its imported-buffer IOVAs to either decoder
core, so both cores must use one DMA domain. The rewrite now has both halves of
that safety contract:

- Rock 5B's `vdec1_mmu` names `vdec0_mmu` with
  `rockchip,shared-domain-owner`. The Rockchip provider returns the owner's
  singleton group, letting IOMMU core create and attach one normal default DMA
  domain and install ordinary DMA ops for both decoder masters.
- MPP compares the public domain identity of every online peer before
  advertising HARD support and again while building the descriptor mask. A
  mixed cluster is not advertised and staging fails with `-EXDEV`.

This removes the prior address-space blocker without making HARD the shipped
default. The board still selects SOFT, and HARD still needs the stress and
differential evidence below.

---

<a id="vendor-bsp-history--was-hard-ever-on-primary-evidence"></a>

## Vendor BSP history — was HARD ever on? (primary evidence)

Traced 2026-07-24 against `rockchip-kernel` branch `develop-6.1` (Rockchip's
official 6.1 BSP). **Conclusion: HARD was never the default, and the HARD path
was chronically under-maintained and hit a real recovery bug.** That upgrades the
former web-sourced "HARD is unreliable" hypothesis to git-grounded evidence,
though it stops short of proving HARD is broken on *current* silicon.

- **SOFT was the default from the moment HARD existed — there is no "flip to
  SOFT" event.** `c2f143006f0c` (2021-12-28) adds soft-ccu; the very commit that
  adds HARD, `e9490005011e` (2022-01-26, "rkvdec2: Add hard-ccu mode"), sets the
  probe default to `RKVDEC2_CCU_TASK_SOFT` (`mpp_rkvdec2.c:1747-1757`, comment
  "use task-level soft ccu default"), overridden only by an explicit *valid*
  `rockchip,ccu-mode`; an invalid value also normalizes back to SOFT.
- **The device tree never requested HARD.** The `rkvdec-ccu@fdc30000` node was
  introduced already carrying `rockchip,ccu-mode = <1>` (`0eead2352fed`,
  2022-09-08, "rkvdec add hw ccu mode for rk3588" — the title means it added the
  *node/capability*, not that it enabled HARD). No `develop-6.1` DT ever set
  `<2>`.
- **HARD received a fraction of SOFT's maintenance.** Commits touching the worker
  bodies over the tree's life: `rkvdec2_soft_ccu_worker` = **11**,
  `rkvdec2_hard_ccu_irq` = **2**. SOFT got dedicated reset hardening HARD never
  did — `db7cef2b18d8` (2022-01-14, "Disable irq when soft ccu reset"),
  `a8e9b2055a4e` (2022-02-21, "sip reset for soft-ccu") — and `8b15ae280af3`
  (2023-11-16, "optimize iommu faul handle for ccu flow") *adds* IOMMU-fault
  handling for the SOFT flow while only "optimizing" it for HARD.
- **The one HARD-specific bug is in exactly the fragile part — reset recovery.**
  `900dde95ad88` (2023-08-22, "fix task re-add running_list issue"): in the hard
  ccu worker, tasks resent to hardware on decoder reset could be **re-added to
  `running_list`** (list corruption). The fix moves
  `mpp_taskqueue_pending_to_run()` out of `rkvdec2_hard_ccu_enqueue()` — which is
  reused on the resend-after-reset path — into the worker's initial enqueue only.
  That is precisely the "if one core errors, wait for dual-core idle, reset both
  cores + CCU, re-run unfinished tasks" flow the add-commit described, and it
  maps directly onto the § 3 reset-recovery suspect below.

**Caveats.** The search covered `develop-6.1` only (the cross-branch `--all`
history search times out on this tree). No commit states outright "default SOFT
because HARD is unreliable" — the intent is inferred from the default-from-birth
choice, the maintenance asymmetry, and the reset bug, not stated. After the 2023
fix HARD may well work; this evidence shows it was experimental and never
production-validated, which justifies keeping it opt-in and still gating it
behind the § 4 differential-soak plan.

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

### 4.0 Sequencing — HARD is gated behind SOFT bring-up

This is the governing constraint. As of this writing **no rewrite kernel has
booted at all** (track 4), and HARD cannot be meaningfully tested before the
rewrite boots in SOFT and passes conformance, for three reasons:

1. **SOFT is the correctness oracle.** The only way to catch a HARD bug that
   emits *wrong pixels* rather than a hang is to diff HARD output against a
   known-good decode — rewrite-SOFT and vendor-SOFT. No SOFT baseline, no oracle.
2. **SOFT is the fallback target.** The safety net that lets you soak HARD
   without power-cycling on every bug is demote-to-SOFT-on-fault (§4.1); that
   path must work first.
3. **A HARD-only failure is only diagnostic if SOFT passes the identical run.**
   The decisive experiment below ("same soak passes SOFT, fails HARD") requires a
   trustworthy SOFT baseline.

So the pipeline is: **SOFT bring-up (gate 2) → HARD prerequisites (§4.1) → HARD
functional bring-up (§4.2) → stress/oracle/soak (§4.3, Layers 1–4)**. Most of the
leverage *available today* is the off-hardware and instrumentation prep that
makes HARD testable the moment SOFT lands.

### 4.0a Phase 0 — off-hardware, doable now (no board)

- **Turn the vendor's reset bug into a directed regression test.** The vendor hit
  exactly one HARD-specific defect — `900dde95ad88`, a task re-added to
  `running_list` when resent to hardware during decoder reset (see the Vendor BSP
  history section). Drive the rewrite's HARD reset-recovery state machine
  (`restart_ccu_job` / `relink_unfinished` / `collect_unfinished`) through
  reset-during-resend and assert no task is double-linked. The rewrite *claims*
  structural immunity here ("idempotent IDR retire, un-refcounted requests") —
  this test **verifies that claim** instead of trusting it, and it targets the
  one path the vendor is known to have gotten wrong.
- **Model the ADD-mode append window with a fake walker.** Build a device-free
  "CCU" that walks a descriptor chain on a separate thread with controllable
  next-pointer latch timing, run the driver's append logic against it under
  KCSAN, and prove the *software* side of the handshake (ordering, `wmb()`,
  `run_lock` coverage) is race-free. It cannot prove the silicon closes the
  window (that needs the board) but removes the software-side variable.
- **Lockdep / ordering audit by inspection.** Enumerate `ccu->run_lock`,
  `ccu_recovery_lock`, and the manager lock, and confirm the completion IRQ, the
  append decision (`readl(CCU_WORK)` + `ccu_has_jobs()`), and reset all serialize
  — resolving § 3 suspect #2 before spending board time.

### 4.1 Phase 1 — board prerequisites (build alongside SOFT bring-up)

- **A HARD device-tree variant.** A dtbo overlay or separate dtb setting
  `rockchip,ccu-mode = <2>` on `rkvdec-ccu@fdc30000`, keeping the shared-IOMMU
  wiring (`vdec1_mmu` → `rockchip,shared-domain-owner`) intact — HARD requires
  both cores in one DMA domain, and the driver refuses to advertise HARD
  (`-EXDEV`) for a mixed cluster.
- **Fallback-on-fault — implement this first.** On a HARD timeout/reset, demote
  that `hw` to per-core/SOFT, log, and bump a counter. Converts a user-visible
  decode hang into degraded-but-working + telemetry; it is the difference between
  a ~20-minute (power-cycle) and a ~2-minute iteration loop.
- **A runtime mode switch (debugfs), not only DT.** A guarded drain-then-switch
  `ccu_mode` knob lets you flip HARD↔SOFT without rebooting or re-flashing a DT,
  giving the differential A/B oracle on a **single boot** and collapsing the
  iteration cost of the whole plan. Without it, every HARD-vs-SOFT comparison is
  a reboot.

### 4.2 Phase 2 — HARD functional bring-up

- **Probe-time proof:** both cores enumerate, shared domain attached, HARD
  advertised, link tables allocated, debugfs `ccu_mode` reads `hard`.
- **Both-cores-actually-used proof (conformance-gap gate #5):** a multi-instance
  decode must increment *both* decoder-core start counters. SOFT can pass while
  only ever touching one core, so this counter check is what proves HW
  arbitration is real — and it is why HARD genuinely cannot be validated by any
  SOFT run. A single stream in HARD exercises the link-table/doorbell path but
  not dual-core arbitration, peer IRQ, or coordinator-wide recovery; those need
  multi-stream load.
- **Differential correctness:** conformance bitstreams with golden MD5s decoded
  HARD vs SOFT vs vendor-SOFT, byte-exact (Layer 2 below).

### 4.3 Phase 3–4 — the on-hardware toolkit

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
[`kernel-drivers/tests/mpp-suite-compare.sh`](../../tests/mpp-suite-compare.sh) /
`gstreamer-suite-compare.sh` comparators to add the HARD-vs-SOFT axis (the §4.1
runtime switch makes this a single-boot comparison).

**Layer 3 — concurrency/fault fuzzing (the real target).** Fuzz the *orchestration*,
not just ioctl bytes:
- Randomize {session count, core mask, job sizes, submit interleaving, append
  timing}; deliberately hit the append window (submit N+1 as N is expected to
  finish). Keep the CCU continuously busy (multi-session/multi-instance) so
  *append*, not fresh-start, is the hot path.
- Fault injection: jam the timeout threshold to the floor (driver has 20/50/100 ms
  tiers — force recovery constantly), inject IOMMU faults via map/unmap races,
  cancel / close-fd mid-decode, reset during append.
- Ring boundaries: `task-capacity = 16` link ring — wraparound, full-ring,
  `rkvdec_link_used` index reuse.
- Build under **KCSAN** (for CPU-appends-while-HW-walks and IRQ-vs-`run_lock` data
  races — most likely to name the actual bug), **KASAN**, lockdep, `DMA_API_DEBUG`.
  Reuse `rewrite-recovery-stress.sh` and `iommu-machinery-fuzz.sh` for orchestration.

**Layer 4 — reproduce & minimize.** Seed the RNG + record the exact schedule so
every hang is replayable; delta-debug the schedule to the minimal failing
interleaving; run as a multi-hour soak with the Layer-2 oracle. **Decisive
experiment:** if the identical soak passes on SOFT and fails on HARD, the
instability is isolated to the HARD orchestration — corroborating the vendor BSP
history and pointing at § 3 suspects.

**ABI/parser surface** (malformed `MPP_IOC_CFG_V1` batches, bad session fds,
out-of-range register requests): **syzkaller + a custom syzlang description of the
MPP UAPI**, under KASAN. Catches driver memory-safety, **not** the HW linked-list
instability (that needs Layers 2–4). Pairs with the existing
[`kernel-drivers/tests/abi-replay.sh`](../../tests/abi-replay.sh).

### 4.4 Two gates worth setting explicitly

- **"Should we even ship HARD?" — a perf go/no-go gate.** HARD's only reason to
  exist is throughput. Before investing in the full soak, measure HARD vs SOFT on
  the workloads that matter (4K, multi-stream). If HARD is not materially faster
  than SOFT per-core dispatch for real workloads, the tail-risk is not worth
  chasing: HARD stays a documented, tested-to-degrade-safely opt-in rather than a
  target, and the effort shrinks to Phase 0 + fallback. Cheap to answer early.
- **Board-safety gate (before Phase 2).** HARD *will* hang during bring-up, and
  this board's ramoops does not persist across warm reset (see
  [the boot-firmware retention guide](../../../boot-firmware/docs/ramoops-retention.md)).
  Serial/netconsole capture is mandatory, or every crash you are trying to
  root-cause is lost.

Because the driver source is byte-identical on the 6.18 and mainline rewrite
tips, all HARD work can be done on the 6.18 KASAN rewrite build and applies to
both. Note the currently built KASAN rewrite image is SOFT-only (its DT selects
`ccu-mode = <1>`), so HARD needs a fresh build carrying the §4.1 DT variant,
fallback, and debugfs switch.

---

## 5. Bottom line

Ship SOFT as the default, keep HARD opt-in with automatic fallback-on-timeout,
and earn confidence in HARD via **differential soak testing under KCSAN**, with
the append-race, IRQ-vs-lock, and reset-recovery paths as the named targets.
**Sequence it behind SOFT bring-up** (§4.0): SOFT is both the correctness oracle
and the fallback target, so HARD testing cannot start until the rewrite boots
SOFT and passes conformance. Do the Phase 0 off-hardware work now (the
vendor-reset-bug regression test, the fake-walker append model), and answer the
perf go/no-go gate (§4.4) early — if HARD is not materially faster than SOFT for
real workloads, it stays a tested-to-degrade-safely opt-in rather than a target.
Everything past Phase 0 needs RK3588 hardware, so it lands on the same critical
path as the outstanding bring-up (track 4, [status.md](../../../status.md)).

**Cross-refs:** [multicore-scheduling.md § 7](../../mpp/docs/multicore-scheduling.md#7-the-ccu-and-its-hardsoft-modes)
· [rewrite-drivers.md](../../docs/rewrite-drivers.md) · [debug-kernel.md](../../docs/debug-kernel.md)
· source finding also recorded in the rewrite tree at
`drivers/video/rockchip/mpp-rewrite/ABI.rst` § Findings.
