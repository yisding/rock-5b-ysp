# Rewrite Phase 3C: activation-owned selected hardware

Date: 2026-08-09

## Result

The retained MPP selected-core reference now has one storage owner:
`rk_mpp_activation::selected_hw`. The duplicate `rk_mpp_job::hw` member is
gone at the byte-identical maintained tips:

- 6.18 `rk3588-rewrite-6.18@a72abb9809fc`
- mainline `rk3588-rewrite-mainline@2ea836184b5f`

This is a representation and ownership checkpoint. It does not change core
selection, hardware reference counts, queueing, MMIO, retry, completion,
abort, or final destruction order.

## Ownership contract

`rk_mpp_job_select_hw()` still obtains exactly one retained hardware reference
before translation and admission. `rk_mpp_job_get_hw()` still takes a temporary
reference while holding `session->lock`; `rk_mpp_job_drop_hw()` still exchanges
the retained pointer with `NULL` under that lock and puts it after unlock.
Normal completion still releases DCHS and CCU/link ownership before dropping
the selected core and releasing the session-dispatch owner. Jobs that do not
reach normal completion retain the same final-destructor fallback put after
CCU/link cleanup.

Activation install now warns if the selected hardware differs from the active
core. In-place hard-CCU retry changes generation/deadline state but preserves
the selected pointer and its reference.

The adjacent `rk_mpp_job::rkvdec_ccu` pointer was deliberately not moved. Its
lifetime is coupled to the coordinator list node, descriptor/link storage,
coordinator power, cluster power lease, and retry/relink state. Moving only
that pointer would split one participation object between activation and job.

## Mechanical guard

The source audit now enforces:

- exactly one `struct rk_mpp_hw *selected_hw` member in
  `rk_mpp_activation`;
- no legacy `struct rk_mpp_hw *hw` member in `rk_mpp_job`;
- 72 selected-hardware access statements and four writes, with hard
  function-specific allowlists;
- exactly one still job-owned `rkvdec_ccu` member, 27 access statements, and
  four writes, also behind hard allowlists;
- aggregate activation writes cannot erase the selected reference through
  assignment, publisher macros, `memset()`, or copy operations; and
- schema drift, wrong readers/writers, KUnit/production confusion, cross-tree
  divergence, and `--update-baseline` attempts cannot bless violations.

The complete source-pinned inventory is 1,406 signals per tree with zero new
or absent entries. Aggregate activation coverage is 88 accesses and 13 writes.
The KUnit-debt audit remains 306 signals per tree.

## Focused tests

Existing cases were strengthened without changing the exact manifest:

- `rk_mpp_job_hw_pin_kunit` proves activation-owned pin/drop balance and the
  final `NULL` state;
- `rk_mpp_explicit_iova_affinity_kunit` uses the production drop owner between
  selected-core bindings;
- `rk_mpp_hw_prepare_active_retry_kunit` proves rejected and successful
  in-place retry preserve the exact selected pointer; and
- active-install/timeout fixtures bind the selected core before publishing an
  activation.

The manifest remains exactly 102 MPP plus 152 RGA cases.

## Verification

- MPP sources are byte-identical between both maintained tips.
- Strict patch checkpatch: zero errors, warnings, and checks on both tips.
- Production ownership audit: 1,406 signals per tree, zero new/absent.
- KUnit source-debt audit: 306 signals per tree, zero new/absent.
- Exact manifest: 102 MPP plus 152 RGA.
- Warning-fatal clean-archive builds: `normal`, `test-disabled`,
  KASAN/fault-injection `memory`, and KCSAN/lockdep `race` pass on both trees.
- Repository consistency, source-audit unit tests, shell checks, links, and
  whitespace pass through `bash scripts/check-repo.sh`.

These are source and compile results. No Phase 2 or Phase 3 kernel has been
packaged, installed, booted, or exercised by runtime KUnit/hardware tests.

## Boundary and next gate

The active and timeout slots remain retained job pointers. Hard-CCU retry still
rewrites the same embedded activation storage in place. CCU/link/descriptor,
coordinator and member-power leases, DCHS ownership, async reason snapshots,
and terminal arbitration remain job/hardware state.

The next coherent source step must either move the complete CCU participation
object or introduce an activation-typed retained retirement boundary; it must
not relocate a lone coordinator pointer. Runtime qualification still requires
an exact Phase 3C package/boot, all 254 KUnit cases with a fatal-free lockdep
interval, same-session H.26x replay, reset-contention/recovery, solo RGA3 vpp,
and the overlay chain.
