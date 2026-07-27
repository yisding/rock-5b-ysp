# Reset/import KUnit fixture missed the DCHS spinlock initialized in its sibling

> Scope: ROCK 5B clean-room rewrite qualification kernel; MPP and RGA KUnit fixture audit
> Source: booted `P91d6-Cad24` / Linux `6.18.40-video-rewrite-kasan-rockchip64` build `#11`; `rk_mpp_reset_session_hw_active_import_kunit()` and `rk_mpp_rkvenc2_dchs_release()` in 6.18 `f6ebe28a3f668`
> Date: 2026-07-27
> Trust: MEASURED / SOURCE-INSPECTED / ROOT-CAUSED / FIX-COMPILE-VERIFIED / PARTIAL

## Result

The first boot of `P91d6-Cad24` disproved the package's final-fixture claim.
Both suites printed green totals — 85/85 MPP and 148/148 RGA — but MPP case 83,
`rk_mpp_reset_session_hw_active_import_kunit()`, acquired a zeroed local
service's uninitialized `rkvenc_dchs_lock`. Lockdep reported a non-static key
and disabled the locking correctness validator for the remainder of the boot.
The compound KUnit gate is red, and no later locking-cleanliness claim can use
this boot.

This is a fixture construction defect, not evidence that the production
service leaves the lock uninitialized. `rk_mpp_service_state_init()` initializes
`rkvenc_dchs_lock`; the failing case bypassed that production initializer while
constructing a local `struct rk_mpp_service`.

## Evidence

The running image, config, and symbol map matched the documented package
payload exactly:

```text
vmlinuz    44bad068708c54e568462858c08adf47e7818887e78d2485b9e48a29ff8dc392
config     692216a4b48d2cf5fdd19e4fb27bbf21a0728efe6e70d8daa078a9acf3525c88
System.map fa0d88782724feaf203655f3366c5554e16311d2177c8da593d4af3a82c3cbbe
```

At 8.627 seconds the boot log reported:

```text
INFO: trying to register non-static key.
turning off the locking correctness validator.
...
rk_mpp_rkvenc2_dchs_release
rk_mpp_session_abort_jobs
rk_mpp_process_request
rk_mpp_reset_session_hw_active_import_kunit
```

The suite summaries followed:

```text
# rk_mpp_rewrite: pass:85 fail:0 skip:0 total:85
ok 1 rk_mpp_rewrite
# rockchip-rga-rewrite: pass:148 fail:0 skip:0 total:148
ok 2 rockchip-rga-rewrite
```

No separate KASAN, Oops, or kernel BUG signature appeared in the captured
`dmesg`, but lockdep was blind after the report.

## Root cause and fix

The preceding case, `rk_mpp_session_abort_hw_active_kunit()`, received
`spin_lock_init(&srv.rkvenc_dchs_lock)` in 6.18 `f6ebe28a3f668` and mainline
`394d80552960f`. The structurally similar reset/import case was left with only
`sched_lock` initialized, even though its hardware-active reset path reaches
the same production DCHS release helper.

The repair adds the missing initialization to that second fixture:

- 6.18 `rk3588-rewrite-6.18@9af4a8816f259`;
- mainline `rk3588-rewrite-mainline@fb5040f08d833`.

The rewrite source remains byte-identical between the two commits.

## Similar-fixture audit

The source audit used the warning point as the trust boundary: MPP cases 1–82
ran while lockdep was live, while cases 84–85 and the complete RGA suite ran
after it was disabled. The two later MPP cases initialize every lock they
reach. The RGA audit covered every local lock-bearing service, session, import,
and hardware fixture against the production helper called by the case:

- full session/job paths use `rk_rga_session_init()`;
- mapped imports use `rk_rga_import_init()` directly or through
  `rk_rga_kunit_import()`;
- queue, abort, dispatch, timeout, and fault paths initialize `job_lock` and
  `run_lock`; and
- partial hardware/session objects only reach topology, parsing, format, or
  fail-fast branches that do not acquire the omitted locks.

No second reachable uninitialized lock was found. This is static
source-inspection evidence, not a substitute for rerunning the suites with
lockdep live.

The boot also exposed a fatal-scan gap: this lockdep failure printed neither
`WARNING:` nor the literal word `lockdep`. The shared scan and standalone root
gate now explicitly match `DEBUG_LOCKS`, `trying to register non-static key`,
and `turning off the locking correctness validator`; the KUnit log-check
self-test and repository scan regression pin the observed signature.

## Boundary and verification gate

The repair is compile-verified but not boot-verified. Build success cannot
prove that no later fixture warning exists. A successor package must repeat the
exact 233-case boot with a complete fatal-signature-free interval and live
lockdep through the end of the RGA suite, then pass the aged kmemleak,
restored-runtime/core, ABI, and media gates.
