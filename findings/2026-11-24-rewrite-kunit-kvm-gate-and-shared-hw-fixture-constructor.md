# Rewrite KUnit suites run under KVM in the build gate, and MPP hardware fixtures share probe's constructor

> Scope: the MPP rewrite driver's KUnit fixtures on both rewrite kernel lines,
> `kernel-drivers/tests/rewrite-kunit-qemu.sh`, and
> `kernel-drivers/tests/rewrite-build-gate.sh`
> Source: `rk3588-rewrite-6.18@c7aab336874b` (was `94b3d97d6a12`) on
> `v6.18.64` and `rk3588-rewrite-mainline@8dd8071bbab6` (was `1bcfb8514376`)
> on `v7.4-rc3`; `drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c`,
> `rk_mpp_hw_state_init()` and `rk_mpp_kunit_alloc_hw()`
> Date: 2026-11-24
> Trust: MEASURED in a KVM guest on the board (arm64 `virt` machine),
> SOURCE-INSPECTED, FIX-RUNTIME-VERIFIED in that guest only, PARTIAL. No
> rewrite kernel was booted on the board itself, no package exists for these
> tips, and no hardware path ran.

## Result

Two preparations for the
[minimal hard-IRQ plan](../kernel-drivers/docs/rewrite-minimal-hard-irq-plan.md)
are done. Neither changes driver behaviour.

1. **The suites run under KVM as a default profile of the build gate.** The
   guest takes under two seconds to run all 263 cases; a warm end-to-end
   script run takes about 17 seconds.
2. **Every MPP hardware fixture is built by the function probe uses.** The
   suite's cases created 94 `struct rk_mpp_hw` objects by hand. They now come
   from one constructor, so a member probe starts initialising is initialised
   in every fixture.

The second change found two more defective fixtures on its first run, which
is the reason it was worth doing before the locking work.

### KVM instead of emulation

The [2026-11-23 run](2026-11-23-rewrite-kunit-first-execution-fixture-repair-and-case-audit.md)
used QEMU's software emulation on one or two virtual CPUs. With the user in
the `kvm` group, the same guest runs on the real cores:

- four guest CPUs, pinned to the board's four Cortex-A76 cores (host CPUs
  4–7, the ones with the largest `cpu_capacity`). KVM does not support a
  guest CPU migrating between unlike cores, so the pin is not optional on
  this SoC;
- the guest reports the host's MIDR (`0x414fd0b0`) and
  `KVM: hypervisor services detected`, and the script fails if that line is
  missing, because `kunit.py` lists KVM first and falls back silently; and
- suite time in the guest: 0.6 s with lockdep and debug objects, 1.3 s with
  generic KASAN added.

It is still a `virt` machine. No RK3588 device, interrupt or IOMMU exists in
it, so KVM improves speed and the realism of concurrency and nothing else.

### What `rewrite-kunit-qemu.sh` does now

- **Runs the committed tip.** It exports `HEAD` into a persistent scratch
  tree with a private index, so the checkout is never touched, uncommitted
  changes cannot leak in, and an unchanged file keeps its timestamp for an
  incremental rebuild. This also removes the need to export by hand a
  checkout that holds in-tree build output.
- **Builds the way the debug kernel does by default.** It applies the same
  locknest prompt patch and turns `PROVE_RAW_LOCK_NESTING` off, so lockdep
  stays alive for the whole run and a pass means lockdep saw every case.
  `KUNIT_QEMU_RAW_NESTING=1` leaves the checker on, which is the mode the
  hard-IRQ plan's exit gates use.
- **Pins only the guest.** The kernel builds on all eight cores.
- **Distinguishes four outcomes:** 0 clean; `kunit.py`'s status when a case
  fails; 3 when every case passes but the console holds a kernel report; 4
  when lockdep was turned off during the run.
- **Installs its own QEMU without root.** `--install-qemu` downloads the
  distribution packages and unpacks them under
  `../rock-5b/build/qemu-userland`, which the script uses when
  `qemu-system-aarch64` is not on `PATH`.

`rewrite-build-gate.sh` gains a `kunit-run` profile that calls the script,
and its default profile set is now `normal kunit-run`. A fixture that has
fallen behind the driver therefore fails the gate at the commit that broke
it.

### The shared constructor

Probe initialised a hardware object's reference count, completion, mutexes,
spinlocks, lists and work items inline. That block is now
`rk_mpp_hw_state_init(hw, coordinator)`, called by probe with the same
statements in the same order. `rk_mpp_kunit_alloc_hw()` and
`rk_mpp_kunit_hw_init()` call it for fixtures and register cancellation of
the object's work items. Cases keep only what their scenario sets:
back-pointers, register windows, match data, and reference counts other than
probe's.

Well over a hundred hand-written initialisation lines went away. Six objects
that lived on the stack moved to KUnit-managed memory, because they now carry
initialised work items and debug objects rejects those on a stack.

The constructor does not set `hw->srv`, `hw->match` or `hw->dev`. Those
depend on the scenario, and a case that omits one can still dereference NULL.

### Two fixtures with the driver's lock order reversed

Before this change each fixture called `mutex_init()` and `spin_lock_init()`
at its own call site, and lockdep gives every call site its own lock class.
A fixture's locks were therefore unrelated, as far as lockdep could tell, to
any other fixture's and to the driver's ordering rules. With one constructor
all fixture objects share the driver's classes, including the separate
classes probe gives a coordinator.

The first run on shared classes reported
`possible circular locking dependency`:

- `rk_mpp_activation_recovered_terminal_kunit` and
  `rk_mpp_activation_observed_terminal_kunit` took the coordinator's
  `ccu_recovery_lock` while holding a core's `run_lock`.
- The driver takes them the other way round. Its own comment says every
  HARD-CCU owner takes recovery before a core run lock, and
  `rk_mpp_hw_abort_active_recovery_locked()` takes `run_lock` with the
  recovery lock held.

Both cases now take the recovery lock first and hold it across the
`run_lock` section. This was a fixture defect only: the report came from
comparing two test cases. A scan of the six driver functions that take the
recovery lock (`rk_mpp_hw_abort_job`, `rk_mpp_hw_recover_active`,
`rk_mpp_rkvdec2_submit`, `rk_mpp_rkvdec2_hard_ccu_thread`, `rk_mpp_hw_remove`,
`rk_mpp_hw_shutdown_hard_ccu`) found none that takes it with a `run_lock`
already held in the same function. Callers were not traced.

### Results

All runs are in a KVM guest with four CPUs, at the tips in the header.

| Line | Configuration | Result |
| --- | --- | --- |
| 6.18 | lockdep, debug objects, checker off | 111/111 and 152/152, quiet console, lockdep alive at the end, exit 0 |
| 6.18 | the above plus generic KASAN | same, exit 0 |
| 6.18 | checker on (`KUNIT_QEMU_RAW_NESTING=1`) | all pass; the one known `Invalid wait context` report, exit 3 |
| mainline | lockdep, debug objects, checker off | 111/111 and 152/152, quiet console, exit 0 (see [Gate run](#gate-run)) |

The third row is the state the hard-IRQ plan starts from.

### Commits

| Commit | 6.18 | Mainline |
| --- | --- | --- |
| mpp-rewrite: give hardware objects one constructor | `41f6e0eb526f` | `8aeaa7a3f9cf` |
| mpp-rewrite: build KUnit hardware fixtures like probe does | `c7aab336874b` | `8dd8071bbab6` |

The MPP driver file is byte-identical between the two tips, SHA-256
`4131702dbc085f2f9f6a2156c52b8d6e15229330c21e377c10834e593cb9e5c5`. The RGA
file is unchanged from 2026-11-23. The first commit builds warning-free on
its own. These commits are local to the two branches; the `linux-rock5b` fork
still holds the 2026-11-23 tips.

The manifest is unchanged at 111 MPP + 152 RGA = 263. Fixture debt stays at
310 signals/tree, because that audit counts raw allocations, manual list
links and fatal-before-cleanup patterns, none of which this change removes.
The ownership baseline keeps 2,326 signals and the writer inventory 118; both
are re-pinned, and the only content change is six ownership rows whose
owning function is now `rk_mpp_hw_state_init` instead of `rk_mpp_hw_probe`.

## Gate run

`rewrite-build-gate.sh all` with its new default profiles passed on both
lines:

```text
[6.18/normal] PASS: clean rewrite object build at c7aab336874b
[6.18/kunit-run] PASS: both KUnit suites ran clean at c7aab336874b
[mainline/normal] PASS: clean rewrite object build at 8dd8071bbab6
[mainline/kunit-run] PASS: both KUnit suites ran clean at 8dd8071bbab6
```

The mainline guest booted Linux 7.4.0-rc3 on four CPUs under KVM and ran
111/111 and 152/152 with a quiet console. The audits the gate runs first
(ownership, fixture debt, writer inventory, cross-tree identity, manifest)
passed too. The `test-disabled`, `memory` and `race` compile profiles were
not rerun at these tips.

An earlier attempt at this run failed with a shell syntax error because
`rewrite-kunit-qemu.sh` was edited while the gate was executing it. That was
an operator error, not a result; the run above was made with both scripts
left alone.

## Boundary

- A KVM guest is not the board. Nothing here boots a rewrite kernel on the
  RK3588, exercises an interrupt, or touches a codec or RGA core.
- Only the MPP driver got a shared constructor. The RGA fixtures still build
  `struct rk_rga_hw` by hand, and the same hidden-lock-order problem may
  exist there.
- The lock-order result compares fixtures with each other and with the
  driver's `_locked` helpers as the fixtures call them. It is not a proof of
  the driver's own ordering on hardware.
- KASAN and the checker-on run were done on the 6.18 tip only.
- kmemleak was not rerun. The 2026-11-23 verdict came from an untracked
  init, and the script still has no kmemleak mode.
- KCSAN was not run.

## Verification gate

The board gate is unchanged: a package composite for each tip, the 6.18 one
booted under KASAN and lockdep, the 263-case manifest with a fatal-free
interval and lockdep still enabled at the end. Phase 1 of the hard-IRQ plan
has its own gate, a `KUNIT_QEMU_RAW_NESTING=1` run that exits 0 for the MPP
suite.
