# Failed rewrite KUnit poisoned MPP runtime while overlapping resources disabled RGA3

> Scope: clean-room MPP/RGA rewrite drivers on the ROCK 5B
> Source: booted `linux-6.18-rkvenc@c5faabf9d00b` in `6.18.40-video-rewrite-kasan-rockchip64`; run `20260726-165709`; `mpp_rewrite.c` `rk_mpp_hw_abort_ccu_dependents_kunit()`, `rk_mpp_get_hw_id()`, and `rk_mpp_debug_state_show()`; `rk3588-base.dtsi` RGA3 resources
> Date: 2026-07-26
> Trust: MEASURED / CODE-INSPECTED / ROOT-CAUSED / BOOT-VERIFIED / KASAN-UAF / FIX-COMPILE-VERIFIED / PACKAGE-INSPECTED / PARTIAL

> **Follow-up 2026-07-26:** the [next rewrite boot's standalone KUnit
> gate](./2026-07-26-rewrite-kunit-gate-passes.md) reports 85/85 MPP and
> 147/147 RGA cases passing with zero skips. The failure chain below remains
> the record of the earlier `P3b08-Cad24` boot; package fingerprint, warning
> scan, core binding, and userspace gates remain to be captured for the
> follow-up boot.

## Result

The `20260726-165709` rewrite run did not hang in an MPP media test. It never
started one. A boot-time MPP KUnit failure had already corrupted the live global
MPP service; ABI replay then oopsed while holding that service's hardware-list
mutex, and the MPP suite's initial debugfs snapshot blocked uninterruptibly on
the orphaned mutex.

The boot disproved the claimed closure at `c5faabf9d00b`:

| Gate | Result |
|------|--------|
| MPP KUnit | 84/85, one failure, zero skips |
| RGA KUnit | 139/147, eight failures, zero skips |
| ABI replay | `abi-probe.sh` segfaulted after its MPP ioctl triggered kernel Oops `#2` |
| Official MPP suite | no case started; `summary.tsv` and `artifacts.tsv` contain headers only |
| RGA runtime | not reached |
| RGA hardware discovery | only RGA2 bound; both RGA3 cores failed probe with `-EBUSY` |

The board must be rebooted before more rewrite testing. The MPP service's
`hw_lock` is permanently held on this boot, and the process reading
`/sys/kernel/debug/rk_mpp_rewrite/state` was observed in `D+` state for more
than 12 minutes.

## Failure chain

The logs and the matching unstripped `vmlinux` reduce the apparent KUnit,
userspace-segfault, KASAN-UAF, and hang symptoms to one causal chain:

1. At boot, `rk_mpp_hw_abort_ccu_dependents_kunit` replaced the production
   `rk_mpp_srv.hw_list` with KUnit-allocated fake CCU/core objects. At
   `c5faabf9d00b` those objects had no `match` pointers.
2. The recovery path called `rk_mpp_debug_record_values()`, which dereferenced
   `hw->match->name`. The test generated a null-pointer KASAN report and Oops
   `#1`, then aborted before restoring the global list.
3. KUnit freed the failed test's allocations, leaving freed fake hardware
   objects linked from the production service.
4. ABI replay sent `QUERY_HW_ID`. Symbolization maps
   `rk_mpp_process_request+0x374` through `rk_mpp_get_hw_id()` to the inlined
   `rk_mpp_hw_usable()` hardware-list walk. It dereferenced the poisoned entry,
   causing KASAN null dereference at `0x590` and Oops `#2` in PID 80209.
5. That task died while holding `rk_mpp_srv.hw_lock`. The next reader, PID
   80520 (`cat /sys/kernel/debug/rk_mpp_rewrite/state`), entered
   `rk_mpp_debug_state_show()`. Mutex owner spinning then read the freed
   `task_struct` of the dead ABI task, producing a slab use-after-free report,
   after which the reader remained blocked on the mutex.

This also explains why the runner stopped after printing
`mpp: official test suite`: `mpp-suite.sh` captures debugfs state before
launching its first media case. The partial file ends exactly at:

```text
-- /sys/kernel/debug/rk_mpp_rewrite/state --
```

The counters captured before that final read are KUnit-polluted rather than
hardware-workload evidence: `ioctl_count=8`, `queued_job_count=1`,
`completed_job_count=1`, `failed_job_count=1`, but zero started, scheduled,
dispatched, IRQ, and hardware-time counters.

## Residual KUnit failures

The one MPP and eight RGA failures are remaining fixture defects, not evidence
that the affected production operations were exercised successfully:

| Suite/cases | Observed mismatch | Source-only repair after this boot |
|-------------|-------------------|------------------------------------|
| MPP `rk_mpp_hw_abort_ccu_dependents_kunit` | fake hardware omitted identity/match data and poisoned the live service when its Oops bypassed cleanup | initialize fake-device names and `match` pointers |
| RGA config/reconfig handles, direct-physical reject, resources, and Gaussian | zero-initialized acquire-fence fields made fd 0 look valid, so setup returned `-EINVAL` before the intended assertion | initialize unused acquire fds to `-1` |
| RGA config-ioctl acquire | the test measured a fence reference while its own lookup still held another reference | hold/release the intended test reference explicitly |
| RGA pending-acquire release and last-HW removal | fake hardware identity/core masks were incomplete, leading to `-ENODEV` and incorrect import/fence states | initialize the fake hardware type and core mask |
| RGA legacy synchronous wait | incomplete setup returned `-EINVAL`; ordinary work initializers on stack objects also emitted debug-object warnings | complete the fixture and use matching on-stack work initialization/destruction |

These changes are committed as
`linux-6.18-rkvenc@2241255f4cb2` and byte-identical mainline replay
`linux@edba1c58a726`. The 6.18 repair is included in final package
`Pf1f5-Cad24`; the mainline replay was rebased onto `v7.2-rc5` but, by explicit
request, was not built after that rebase. Neither repair has been installed or
verified on a booted kernel. The fixture changes alone do not repair the RGA3
probe failure below.

## Independent RGA3 probe failure

Both RGA3 cores failed before KUnit:

```text
rockchip-rga-rewrite fdb60000.rga: error -EBUSY: can't request region for resource [mem 0xfdb60000-0xfdb60fff]
rockchip-rga-rewrite fdb70000.rga: error -EBUSY: can't request region for resource [mem 0xfdb70000-0xfdb70fff]
```

The installed DTB and pinned source contain overlapping resources:

| Device | Core resource | IOMMU resource | Overlap |
|--------|---------------|----------------|---------|
| RGA3 core 0 | `0xfdb60000 + 0x1000` | `0xfdb60f00 + 0x100` | final `0x100` bytes |
| RGA3 core 1 | `0xfdb70000 + 0x1000` | `0xfdb70f00 + 0x100` | final `0x100` bytes |

The cross-tree comparison explains both the origin of the bad size and why it
did not break the vendor stack:

| Source | RGA3 core size | RGA mapping API | Outcome |
|--------|----------------|-----------------|---------|
| BSP `develop-6.1@b4ef083dc0c3` | `0x1000` | `devm_ioremap()` | overlap tolerated |
| Forward port `rk3588-video-6.18@12a7da02bea83` | `0x1000` | `devm_ioremap()` | overlap tolerated |
| Upstream `v7.2-rc3@a13c140cc289` | `0x200` | `devm_platform_ioremap_resource()` | disjoint |
| Maxline public `f12fb0acf7bb` and WIP `74b24e96da62` | `0x200` | inherits mainline | disjoint |
| Rewrite failed boot | inherited `0x1000` | `devm_ioremap_resource()` | both RGA3 probes fail |

`devm_ioremap()` maps MMIO without claiming its physical byte range.
`devm_ioremap_resource()` first reserves that range, then maps it. The BSP
therefore works by convention: its RGA mapping covers the IOMMU subrange, but
RGA accesses only the low core registers while the IOMMU driver accesses
`+0xf00..+0xfff`. Reservation is software ownership bookkeeping rather than a
hardware-access requirement; without it, a real same-register collision would
race rather than being arbitrated.

The IOMMU and rewrite both reserve their resources. On this boot the IOMMUs
claimed the overlapping subranges first, so both RGA3 core probes returned
`-EBUSY`, leaving only `fdb80000.rga2` bound. The stable ownership explanation,
exact intervals, and risks of the BSP convention are in the
[device-tree guide](../kernel-drivers/docs/device-tree.md#rga3-coreiommu-resource-ownership).

The published 6.18 rewrite tip now uses `0x200` for both RGA3 core windows,
matching the mainline RK3588 DT rather than inventing a new boundary. This
comfortably contains the rewrite's highest register, `RK_RGA3_CMD_STATE` at
`0x040` (minimum mapped size `0x044`), and ends at `+0x1ff`, well before the
IOMMU at `+0xf00`.

The focused DTB build passed:

```bash
make -C /home/yi/Code/rock-5b/kernel/linux-6.18-rkvenc \
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j4 \
    rockchip/rk3588-rock-5b.dtb
```

`fdtget` confirmed the compiled resource cells:

```text
/rga@fdb60000    0 fdb60000 0 200
/iommu@fdb60f00  0 fdb60f00 0 100
/rga@fdb70000    0 fdb70000 0 200
/iommu@fdb70f00  0 fdb70f00 0 100
```

The resulting DTB SHA-256 is
`44f86e6fb9d1ef288b4956c8992326aaed3d1e4cc8df9f282e46b9386835d674`.
The correction is committed and published as
`linux-6.18-rkvenc@0cc483d3ee20`. KASAN/lockdep package `Pf1f5-Cad24` was built
from that exact tip. Its packaged ROCK 5B DTB has SHA-256
`2961225a7738b16f4517ddf4a0452329b2d4792bcca1c7a748bab65a641c7849`
and reports the same four disjoint resource cells. The packaged config contains
both rewrite drivers, both KUnit suites, KUnit, KASAN, lockdep, and work/timer
debug objects. This remains package evidence only; the new artifact is not
boot-verified.

## Evidence

The runner command was:

```bash
sudo env \
    TMPDIR=/home/yi/Code/rock-5b/build/scratch \
    PROFILE=rewrite \
    RUN_COUNTER_CHECKS=1 \
    RUN_CONTINUE_ON_FAIL=1 \
    bash kernel-drivers/tests/rewrite-conformance-run.sh
```

The raw captures remain outside git under
`/home/yi/Code/rock-5b/build/rockchip-conformance/logs/rewrite/`:

| Artifact | SHA-256 |
|----------|---------|
| `20260726-165709-kunit.tsv` | `bd443624ffd29a47daba4e2594390c6e2f0a363725ee4d9a9b96d38f2ebab7ee` |
| `20260726-165709-system/system.txt` | `dc71a81a627dbb5a01acdf4c06d8020d0de0b84d50fdb47aa34c563ec6b1c9e` |
| `20260726-165709-mpp-suite/dmesg-before.txt` | `7aba46a8834b41053d7faa1dbb2e787b480f4af0afbcc4dc924826c7f5a2d833` |
| `20260726-165709-mpp-suite/mpp-state-before.txt` | `1885ea4c55cb097ef6a00d2272fdab1fdda432a3b860bd34a98c7d513ec6b13a` |
| `20260726-165709-mpp-suite/summary.tsv` | `8f0bb64b9a14398a01d4bfed51eca5e4cb6415d54d6b369f3a79c922dc3ac172` |

The four ABI replay logs are zero bytes: the probe crashed while its output was
buffered through `tee`, so they are not negative evidence. The kernel Oops is
preserved in the MPP suite's pre-run dmesg capture. The PID tree, `D+` state,
and subsequent mutex-owner slab-UAF were inspected from the live post-wedge
system; they are recorded here but were not copied into a separate raw
artifact.

Two runner details are secondary harness findings:

- `RUN_CONTINUE_ON_FAIL=1` continued into live ioctls after a booted KUnit
  failure. For in-driver KUnit suites that mutate global production state, a
  red KUnit result must be fatal even when aggregate reporting is requested.
- The system collector tried to `cat /proc/mpp_service`, which is a directory.
  That diagnostic error did not cause the driver failure.

## Verification gate

Do not resume this run on the wedged boot. The next meaningful gate is:

1. install and boot `Pf1f5-Cad24`, which packages the post-run fixture repair
   plus the committed `0x200` RGA3 DT resource correction under KASAN/lockdep;
2. before any userspace MPP/RGA ioctl, require exactly 85/85 MPP and 147/147
   RGA KUnit cases, zero skips, and no Oops, KASAN, refcount, debug-object,
   IRQ, or preemption warning over the full suite interval;
3. require all intended MPP cores and all three RGA cores to be bound;
4. run ABI replay alone and verify a clean exit, clean kernel log, and
   unwedged debugfs state before starting full rewrite conformance; and
5. only then run the official MPP and RGA workloads with counter deltas and
   per-case kernel-log scans.

## Boundary

No real MPP media case or RGA workload ran in this attempt. The result proves
KUnit isolation, probe, and harness-safety failures; it says nothing positive or
negative about codec output correctness, RGA pixel correctness, performance,
or concurrency on the rewrite drivers. The post-run fixture and RGA3 DT
corrections are committed, published, compile-verified, and package-inspected
in `Pf1f5-Cad24`, but remain uninstalled and unbooted.
