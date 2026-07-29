# rk3588-rewrite-av1-6.18 forked before 19 hardening commits; KUnit isolation and the ISR fault-handler panic fix are absent

> Scope: kernel-drivers (clean-room rewrite track); branches `rk3588-rewrite-av1-6.18` and `rk3588-rewrite-6.18` in the shared `linux-rock5b` repo
> Source: `~/Code/kernel/linux-6.18-rk-av1-rewrite` @ `e58c57e50d0a0` vs `~/Code/kernel/linux-6.18-rkvenc` @ `e5867fa31ed2b`; merge-base `c5faabf9d00b0`
> Date: 2026-07-29
> Trust: SOURCE-INSPECTED; backport section PARTIAL until the staging branch builds and is fast-forwarded

## Result

The AV1 rewrite branch is a four-commit feature spur (see
[the backend design finding](2026-07-29-av1-rewrite-backend-design-source-audit.md))
that forked from `c5faabf9d00b0` before the hardening work that landed on
`rk3588-rewrite-6.18`. As of today the AV1 branch lacks these 19 commits
(oldest first):

| # | Commit | Subject |
|---|--------|---------|
| 1 | `2241255f4cb24` | finish rewrite KUnit fixture repairs |
| 2 | `0cc483d3ee20f` | arm64: dts: separate RK3588 RGA3 core resources |
| 3 | `bc420aca1300e` | rga-rewrite: share external IOMMU IRQs |
| 4 | `eb64bc7de3270` | rga-rewrite: model shared IRQ wiring |
| 5 | `4273266a990ef` | rga-rewrite: keep work fixtures off stack |
| 6 | `6edc44f79a4d2` | reconcile rewrite ABI ledgers |
| 7 | `3b41eca277c7b` | rga-rewrite: fix final stack work fixture |
| 8 | `dbc36621b3016` | isolate rewrite KUnit from live services |
| 9 | `835b19f81d2b4` | mpp-rewrite: move batch fixture off stack |
| 10 | `db8251eec71a9` | isolate rewrite KUnit at runtime |
| 11 | `6b55e022ce491` | fix final rewrite KUnit fixture leaks |
| 12 | `f6ebe28a3f668` | harden rewrite KUnit preflight |
| 13 | `9af4a8816f259` | initialize reset fixture DCHS lock |
| 14 | `0a2d7b9414f58` | make rewrite KUnit suites opt-in |
| 15 | `669697f23d3df` | drop duplicate MPP ABI KUnit case |
| 16 | `51ea9d1ca537b` | isolate rewrite KUnit fixtures |
| 17 | `cd71f985a784c` | fix rewrite review findings |
| 18 | `35eb735d21dd8` | iommu: rockchip: split fault-handler teardown sync out of the setter |
| 19 | `e5867fa31ed2b` | fix rewrite KUnit fixture crashes and hardening gaps |

Two of the gaps are not cosmetic:

- **KUnit is unisolated on the AV1 branch.** Its Kconfig still says
  `default KUNIT_ALL_TESTS` on a tristate parent, there is no
  `suite_init` boot-phase gate, and the mpp test block references the live
  `rk_mpp_srv` singleton 18 times — re-initializing its locks and splicing
  fixture cores onto the live `hw_list`. This is exactly the runtime-poisoning
  class recorded in
  [the KUnit-poisons-runtime finding](2026-07-26-rewrite-kunit-poisons-runtime-and-rga3-probe-fails.md);
  the isolation series (commits 8, 10, 14, 16 above) is the fix the AV1 branch
  never received.
- **The ISR fault-handler panic fix is absent.** The branch carries the
  sleeping `set_fault_handler(…, NULL, NULL)` teardown in both IOMMU providers
  and the in-tree BSP caller `mpp_iommu_clear_fault_handler()` that triggers it
  from atomic context — the "scheduling while atomic → idle task" panic
  root-caused in
  [the ISR-panic finding](2026-07-29-mpp-isr-fault-handler-clear-sleeps-panics-idle-task.md).
  Fix is commit 18 (`35eb735d21dd8`), not an ancestor of the AV1 branch.

## Boundary

The gap list is a git-topology fact plus targeted source checks (Kconfig
defaults, `rk_mpp_srv` references inside the test block, absence of
`rockchip_iommu_sync_fault_handler` on the AV1 branch). Whether each of the 19
commits applies cleanly on top of the AV1 spur — and whether any is already
superseded by the spur's own hardening (`e58c57e` overlaps conceptually with
parts of the recovery work) — is being established by the backport below, not
assumed here.

## Backport record (in progress)

- Backup ref: `ysp-backup/rk3588-rewrite-av1-6.18-before-hardening-20260729`
  (= `e58c57e50d0a0`).
- Staging branch: `rk3588-rewrite-av1-6.18-hardening` in worktree
  `~/Code/tmp/av1-hardening-20260729/wt`, cherry-picking the 19 commits in
  order; commits that are already present in equivalent form or no longer make
  sense on the AV1 spur are skipped with rationale.
- Compile gate: `mpp_rewrite.o`, `rga_rewrite.o`, and the RK3588 DTBs built
  from the staging branch with the KUnit configs enabled (build dir seeded from
  `~/Code/kernel/build-rk-av1-rewrite/.config`).
- Per-commit outcomes: recorded here when the run completes.

## Why it matters / follow-up

Anyone booting the AV1 spur inherits a known panic class and a KUnit
configuration that can poison a live service. After the backport lands, the
AV1 branch should be treated as "rewrite-6.18 + AV1", not as a diverged
lineage; keep future hardening on `rk3588-rewrite-6.18` and rebase or
fast-forward the spur, rather than letting the two drift again.
