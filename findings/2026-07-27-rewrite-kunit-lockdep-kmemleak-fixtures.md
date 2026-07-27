# Final rewrite KUnit boot blockers were one uninitialized mutex and one nested allocation

> Scope: ROCK 5B clean-room rewrite qualification kernel
> `6.18.40-video-rewrite-kasan-rockchip64` build `#9`
> Source: booted 6.18 `db8251eec71a9d3d0ae3f578bca78cd0bb656414`;
> repaired 6.18 `6b55e022ce491` and byte-identical mainline
> `9aa6ef7e97b23`
> Date: 2026-07-27
> Trust: MEASURED / SOURCE-INSPECTED / ROOT-CAUSED /
> FIX-COMPILE-VERIFIED / PACKAGE-VERIFIED / PARTIAL

## Result

The first boot of the lifecycle-repaired rewrite package completed both KUnit
suites and restored both production runtimes. All **85 MPP + 148 RGA** cases
reported `ok`, `/dev/mpp_service` and `/dev/rga` were present, both RKVDEC2
cores, both RKVENC2 cores, RGA2, and both RGA3 cores bound. The earlier
live-singleton destruction boot wedge is therefore fixed at runtime.

The compound KUnit gate is nevertheless **not green**. MPP case 9 locked an
uninitialized fixture mutex and disabled lock debugging for the remainder of
the boot. The ten-minute automatic kmemleak scan then found a separate
2,048-byte object allocated by MPP case 28. Both cases still reported `ok`
because neither defect violated a KUnit expectation. The kernel-log and
kmemleak halves of the qualification contract caught what KTAP alone could not.

## Evidence

The boot interval reported the exact suite totals:

```text
# rk_mpp_rewrite: pass:85 fail:0 skip:0 total:85
ok 1 rk_mpp_rewrite
# rockchip-rga-rewrite: pass:148 fail:0 skip:0 total:148
ok 2 rockchip-rga-rewrite
```

At 7.609 seconds, `rk_mpp_set_err_ref_hack_kunit()` emitted:

```text
DEBUG_LOCKS_WARN_ON(lock->magic != lock)
WARNING: CPU: 1 PID: 150 at kernel/locking/mutex.c:577 __mutex_lock
...
rk_mpp_set_err_ref_hack_kunit
kunit_try_run_case
```

`DEBUG_LOCKS_WARN_ON()` calls `debug_locks_off()` before printing the warning.
The later MPP cases and the entire RGA suite therefore ran without live
lockdep, even though every assertion passed.

At 685.166 seconds, the default automatic kmemleak scan reported one new
suspect. An explicit scan and read of `/sys/kernel/debug/kmemleak` attributed
it unambiguously:

```text
unreferenced object 0xffff00012991f000 (size 2048):
  comm "kunit_try_catch", pid 188, jiffies 4294894211
  backtrace:
    kmemleak_alloc
    __kmalloc_cache_noprof
    rk_mpp_job_translate_reg
    rk_mpp_job_translate_reg_image
    rk_mpp_rkvdec2_vp9_translate_validate_kunit
    kunit_try_run_case
```

The object dump began with two `struct rk_mpp_reg_binding` records:
register `160` (`0xa0`) at embedded offset `4`, then register `162` (`0xa2`)
at offset `8`, both pointing at the fixture import. This matches the VP9
fixture exactly.

## Root causes

### `SET_ERR_REF_HACK` fixture locked a zeroed mutex

`rk_mpp_set_err_ref_hack_kunit()` constructed:

```c
struct rk_mpp_session session = {};
```

It then called `rk_mpp_process_request()`. The production
`MPP_CMD_SET_ERR_REF_HACK` path calls `rk_mpp_session_initialized()`, which
locks `session->lock`. Unlike the other initialized-session fixtures, this one
never called `mutex_init(&session.lock)`. Zero-filled storage is not a valid
debug mutex. The production command behavior was correct; the fixture failed
to establish the production invariant it exercised.

### VP9 fixture lost the production binding table

`rk_mpp_rkvdec2_vp9_translate_validate_kunit()` intentionally reaches the
production lazy allocation in `rk_mpp_job_translate_reg()`:

```c
image->bindings = kcalloc(RK_MPP_MAX_REG_TRANS_NUM,
                          sizeof(*image->bindings), GFP_KERNEL);
```

The requested 80-entry table is 1,280 bytes and occupies the 2,048-byte slab
object kmemleak reported. Normal jobs release it from `rk_mpp_job_release()`.
The fixture instead allocated the outer `struct rk_mpp_job` with
`kunit_kzalloc()` and manually released only its imports. KUnit freed the
outer job but knew nothing about the nested production allocation.

## Repair

The repair is 6.18 commit `6b55e022ce491` and byte-identical mainline commit
`9aa6ef7e97b23`:

- initialize the `SET_ERR_REF_HACK` session mutex before the first production
  request;
- preserve coverage of the production binding-table allocation rather than
  replacing it with a KUnit allocation;
- immediately register the resulting table with
  `kunit_add_action_or_reset()` through a CFI-safe
  `KUNIT_DEFINE_ACTION_WRAPPER()`; and
- make successful translation and the expected allocation fatal assertions
  only after cleanup ownership has transferred to KUnit.

The deferred action is important. A bare `kfree()` at the bottom of the case
would fix this observed execution but leak again if a future fatal assertion
returned early.

A focused audit covered every raw `kmalloc`/`kzalloc`/`kcalloc` in both
rewrite KUnit regions and every MPP session fixture that reaches a locked
production helper. The remaining raw allocations either transfer into
production refcount/release paths or have explicit fixture teardown. The
boot's single kmemleak object agrees with that ownership accounting.

## Diagnostic smoke and harness correction

The broken-lockdep boot was used only for a non-qualifying smoke diagnostic.
The restored MPP/RGA devices and debugfs counters were readable and the MPP
control/import ABI probes passed. The smoke initially stopped because its RGA
request-config probe zeroed both acquire-fence fields. File descriptor zero is
an actual descriptor, not the ABI's “no fence” value; the rewrite correctly
rejected it when it was not a sync file and mapped the internal configuration
error to the public `EFAULT` contract.

`abi-probe.c` now sets both the per-task and request-wide acquire fences to
`-1`. `rewrite-smoke.sh` also now honors `CONFORMANCE_ROOT`, accepts the
installed MPP `bin/` + `lib/` layout, and defaults to the maintained
`ffmpeg-rockchip` binaries plus the existing generated 1080p H.264 asset.
These are harness corrections, not additional driver fixes.

## Validation

Completed:

- focused KUnit-enabled 6.18 `mpp_rewrite.o` build;
- strict `checkpatch.pl` with zero findings;
- `git diff --check` in both kernel trees;
- byte identity between the maintained 6.18 and mainline rewrite sources; and
- compile-only ABI-probe, Bash syntax, and ShellCheck gates for the harness
  corrections.

Clean-archive builds passed the 6.18 `normal`, KASAN/fault-injection `memory`,
and KCSAN/lockdep `race` profiles at `6b55e022ce49`, plus mainline `normal` and
`memory` at `9aa6ef7e97b2`. The redundant mainline `race` profile was stopped
at the user's direction; no separate KCSAN package is required. The new board
test artifact is instead a 6.18.40 `rewrite-debug` package built with the
existing KASAN/UBSAN/lockdep/kmemleak configuration and pinned to stable base
`221fc2f4d0ed` so the source delta is limited to the fixture repair.

## Repaired KASAN package

The pinned 6.18.40 `rewrite-debug` build completed successfully as:

```text
6.18.40-S221f-D3dd5-Pe8c5-Cad24-H9acc-HK01ba-Vc222-Bfe95-R448a
PHASH=Pe8c5-Cad24
```

Build UUID `e07c63c7-c175-4b28-a820-9160768319e6` applied all 329 rewrite
patches, with `6b55e022ce491` as patch 329, against exact stable commit
`221fc2f4d0eda59d02af2e751a9282fa013a8e97` (`Linux 6.18.40`). The compiler
phase took 2,382 seconds, packaging took 159 seconds, and the Docker wrapper
completed in 47:14. Ccache reported 14,035 hits and 77 misses (99%).

| Artifact | Bytes | SHA-256 |
|----------|------:|---------|
| image package | 648,806,592 | `82e7ec5c3d9fa5f43b69a8fb299475b20457394606ba55123f993aa64a6d080c` |
| DTB package | 30,116,032 | `ec8f13a5e882e539774c775936d8d4588470acca9b548c61d5a04dac507a49bc` |
| headers package | 112,885,952 | `fe2a254003671a4fe0f7940dd83794fee940022f9761b5b1a70d28da1aea8f94` |
| libc-dev package | 7,884,992 | `6ae7892b7cd7d8faab512ec6e099829ab3f108d75bdb12a8dd8950e11b453c26` |
| packaged `vmlinuz` | 118,704,640 | `a98ed98b00b817b1462be5be4baf4f26a69ef86b2917f041837e7d0194f69c44` |
| packaged config | 272,137 | `692216a4b48d2cf5fdd19e4fb27bbf21a0728efe6e70d8daa078a9acf3525c88` |
| packaged `System.map` | 6,279,461 | `d607976f496687b2447ca917d9468b90251df9843f44e51cd5c940dae8d50da3` |
| packaged ROCK 5B DTB | 195,348 | `2961225a7738b16f4517ddf4a0452329b2d4792bcca1c7a748bab65a641c7849` |

Payload inspection confirms both rewrite drivers and both 85/148-case suites
are built in; KASAN generic, UBSAN, lockdep, DMA API debug, Debug Objects,
kmemleak automatic scan, and IOMMU debugfs are enabled. Vendor MPP service,
multi-RGA, upstream V4L2 RGA, and the optional DWC PCIe PMU are disabled. The
packaged symbol map contains `rk_mpp_kunit_kfree`, both repaired test cases,
and both runtime init functions at device-initcall level 6. The DTB retains
ramoops at `0x118000`/`0xd0000`, both `0x200` RGA3 register windows, and the
expected three RGA plus four MPP cores.

## Boundary and next gate

The fixes are source- and compile-verified, not boot-verified. The next kernel
must repeat the full boot contract:

1. exact 85/85 MPP plus 148/148 RGA KTAP, with no skips;
2. no fatal signature in the entire KUnit interval;
3. no `debug_locks_off()` trigger and live lockdep after both suites;
4. explicit kmemleak scan after the automatic-scan age threshold, with no
   KUnit-owned orphan;
5. both production runtimes and all expected cores restored; and
6. only then, the isolated ABI replay and full media conformance set.
