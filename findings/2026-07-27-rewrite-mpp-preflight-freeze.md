# MPP conformance froze in pre-workload state capture after KUnit poisoned the service

> Scope: ROCK 5B clean-room rewrite qualification kernels and conformance
> runner
> Source: user-observed freeze after the `mpp: official test suite` banner;
> captured kernel logs; runner and driver source inspection
> Repaired source: 6.18 `f6ebe28a3f668`, mainline `394d80552960f`
> Date: 2026-07-27
> Trust: USER-OBSERVED / LOG-INSPECTED / SOURCE-INSPECTED /
> FIX-COMPILE-VERIFIED / PACKAGE-VERIFIED / NOT-BOOT-VERIFIED

## Result

The official MPP workloads did not cause the observed freeze. The runner prints
`mpp: official test suite` before entering `mpp-suite.sh`; that wrapper then
captures MPP procfs/debugfs state before its first `run_case`. The blocked task
was reading `/sys/kernel/debug/rk_mpp_rewrite/state`, whose show function waited
on `rk_mpp_srv.hw_lock`.

That mutex had already been left locked by an earlier kernel fault during the
same conformance run. A failed boot-time KUnit fixture had corrupted production
service state, then ABI replay oopsed while holding `hw_lock`. The recursive
pre-workload snapshot was therefore the first reader to wait on the abandoned
lock. It entered uninterruptible `D` state, so killing the shell could not
recover the system.

The later refusal to reach userspace on the affected rewrite kernel was a
separate boot-lifecycle defect, not persistent damage caused by the MPP
workload. Boot KUnit runs after all initcalls; that package's suite initializer
cleared an already-probed production singleton. The lifecycle repair at
6.18 `db8251eec71a` and mainline `fac707773158` unregisters the runtime before
using its singleton as fixture storage and restores it before initramfs.

## Remaining defect found in the successor boot

The lifecycle and earlier fixture repairs were necessary but not the end of
the compound gate. `rk_mpp_session_abort_hw_active_kunit()` constructed a
zeroed local `struct rk_mpp_service`, initialized `sched_lock`, and then reached
`rk_mpp_rkvenc2_dchs_release()` through the production abort path without
initializing `rkvenc_dchs_lock`. Lock debugging reported an invalid spinlock
and disabled lockdep even though the KTAP case itself reported `ok`.

The repaired tips initialize that fixture lock:

- 6.18 `f6ebe28a3f668` on `rk3588-rewrite-6.18`;
- mainline `394d80552960f` on `rk3588-rewrite-mainline`.

The rewrite source is byte-identical between those commits.

## Driver containment

The same commits make only the debugfs `state` show function nonblocking:

```c
if (!mutex_trylock(&srv->hw_lock))
	return -EBUSY;
```

The queue section applies the same rule to `sched_lock`. This does **not**
change ioctl, submit, dequeue, scheduling, completion, or recovery locking.
A diagnostic snapshot taken during a legitimate short update can now return
`EBUSY`; the workload continues unchanged. Ad-hoc diagnostics may retry after
a short delay. Conformance preflight deliberately fails closed because a busy
service before the first workload is itself evidence that the boot is not a
clean qualification environment.

Do not restore an unbounded debugfs wait. If a future use case requires a
guaranteed snapshot while workloads are active, replace this behavior with a
bounded retry or copy the protected state into temporary storage under the
lock and format it after unlocking.

## Harness containment

Three harness changes prevent KTAP-green but warning-corrupted boots from
advancing:

1. `rewrite-kunit-log-check.sh` now extracts the complete boot KUnit interval,
   scans it with the shared `SUITE_DMESG_FATAL_RE`, and requires
   `/proc/sys/kernel/debug_locks` to remain `1`.
2. With `KUNIT_REPORT=<run>-kunit.tsv`, it also persists
   `<run>-kunit-journal.txt`, `<run>-kunit-fatal.txt`, and
   `<run>-kunit-dmesg-scan.tsv`. `rewrite-evidence-audit.sh` requires the
   run-correlated scan to be complete, clean, and lockdep-live.
3. `mpp-suite.sh` no longer recursively reads every generated file below the
   MPP procfs/debugfs trees. It reads an explicit compatibility/state/event
   allowlist once and treats a failed read as a fast preflight failure.

The KUnit compound gate runs before system information, ABI replay, and the MPP
banner. A warning like either fixture defect now stops the run before
production state can be exercised.

## Validation

Completed:

- KUnit log-check self-test, including fatal-interval, incomplete-interval, and
  disabled-lockdep rejection;
- evidence-audit self-test, including fatal and disabled-lockdep evidence;
- Bash syntax checks for all changed runners;
- clean-archive 6.18 normal, KASAN/fault-injection, and KCSAN/lockdep object +
  DTB profiles (the user stopped the mainline matrix);
- strict kernel `checkpatch.pl` with zero findings;
- `git diff --check` in both kernel trees; and
- byte comparison of the two maintained rewrite sources.

## Current KASAN package

The current 6.18 tip built successfully as:

```text
6.18.40-S221f-D3dd5-P91d6-Cad24-H9acc-HK01ba-Vc222-Bfe95-R448a
PHASH=P91d6-Cad24
```

Build UUID `1adc4587-6b24-419e-9c6d-e177f6dd5d39` applied 330 rewrite patches
to exact stable base `221fc2f4d0eda59d02af2e751a9282fa013a8e97`. The final
patch is `f6ebe28a3f668` and its staged SHA-256 is
`259e86b9f0fc49ae657ad836775daf1dc7ecaa3a7988199814d0f758ff006402`.
The compile/install phase took 1,689 seconds, packaging took 91 seconds, and
the Docker run completed in 31:33 with 14,035 ccache hits and 409 misses.

| Artifact | Bytes | SHA-256 |
|----------|------:|---------|
| image deb | 648,806,592 | `2fb257bec37015c72a158d2bf1685aa86766156f40a3d613ed41ae639737c28e` |
| DTB deb | 30,116,032 | `58451abfafa95574d51b9e1f0300bf6d4162fcde294eb00d1fc47c7104df258d` |
| headers deb | 112,885,952 | `7d3d73468007567275538b9f6533da4b05e68b1f8845fd990f6996369f805962` |
| libc-dev deb | 7,884,992 | `57b0a573cfdf639b7a1c7273c5d21b063f0944be06a62d56bcf11d717d234367` |
| packaged `vmlinuz` | 118,704,640 | `44bad068708c54e568462858c08adf47e7818887e78d2485b9e48a29ff8dc392` |
| packaged config | 272,137 | `692216a4b48d2cf5fdd19e4fb27bbf21a0728efe6e70d8daa078a9acf3525c88` |
| packaged `System.map` | 6,279,446 | `fa0d88782724feaf203655f3366c5554e16311d2177c8da593d4af3a82c3cbbe` |
| packaged ROCK 5B DTB | 195,348 | `2961225a7738b16f4517ddf4a0452329b2d4792bcca1c7a748bab65a641c7849` |

Payload checks confirm both 85/148-case suites, both rewrite drivers, KASAN,
UBSAN, lockdep, Debug Objects, kmemleak, DMA API debug, and IOMMU debugfs are
built in. Vendor MPP, multi-RGA, V4L2 RGA, and DWC PCIe PMU are disabled.
`System.map` contains both runtime and suite init/exit symbols plus
`rk_mpp_session_abort_hw_active_kunit` and `rk_mpp_debug_state_show`. The
applied Armbian worktree contains all three final source changes. The packaged
DTB retains ramoops and disjoint `0x200` RGA3 core windows.

The image header reserves 138,215,424 bytes (131.8 MiB), which exceeds the
stock 127 MiB load gap. The existing managed U-Boot map was read-only checked:
its `fdt_addr_r=0x0c000000` provides a 188 MiB gap and about 56.2 MiB headroom.

The package is not installed or boot-verified. It must pass all 85 MPP and 148
RGA cases, the complete fatal-signature scan, live lockdep, an aged clean
kmemleak scan, restored production devices/cores, ABI replay, and only then the
official MPP and remaining media suites.
