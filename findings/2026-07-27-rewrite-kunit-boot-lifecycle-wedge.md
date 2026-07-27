# Rewrite KUnit boot wedge was live-singleton destruction after initcalls

> Scope: ROCK 5B clean-room rewrite qualification kernel
> Source: failed 6.18 package source `835b19f81d2b41d7ab5269e61a7b022d901a6928`
> and linked `vmlinux`; repaired 6.18 `db8251eec71a9d3d0ae3f578bca78cd0bb656414`
> and mainline `fac7077731585`; Linux 6.18 `init/main.c`
> `kernel_init_freeable()` and `lib/kunit/test.c` `kunit_run_tests()`
> Repaired Armbian build UUID `f1e64434-55a1-4fe9-bd1d-369b430624d3`
> Date: 2026-07-27
> Trust: SOURCE-INSPECTED / BINARY-INSPECTED / ROOT-CAUSED /
> FIX-COMPILE-VERIFIED / PACKAGE-VERIFIED / FIX-RUNTIME-VERIFIED

## Result

The KUnit isolation change in package `P259b-Cad24` could not provide the
ordering its comments assumed. It moved both rewrite drivers from
`module_init()` to `late_initcall_sync()` on the premise that the built-in
suites ran from KUnit's late initcall first. In Linux 6.18, `kunit_init()`
only prepares KUnit infrastructure. `kernel_init_freeable()` calls
`do_basic_setup()` to run **all** initcalls, then calls
`kunit_run_all_tests()`, and only then waits for initramfs.

Both rewrite drivers therefore registered and probed their hardware before
their suite initializer ran. Each initializer then called its state-init
helper, whose first operation cleared the live global service singleton with
`memset()`. That discarded list, lock, workqueue, debug, and registration state
while the platform devices and userspace-facing service remained registered.
The exact source ordering and the linked failed-package `vmlinux` both contain
this path. The failed boot did not reach userspace far enough to create a
journal entry, so the final blocked operation was not captured; destroying the
active singleton is nevertheless a complete, source-pinned boot-corruption
mechanism and not merely a timing hypothesis.

## Repair

The repair is 6.18 commit `db8251eec71a9` and byte-identical mainline commit
`fac7077731585`:

- restore the ordinary `module_init()` device-initcall path;
- split production registration and unregistration from the `__init` and
  `__exit` wrappers, with explicit registered-state tracking;
- in suite initialization, require boot's `SYSTEM_SCHEDULING` state and a
  registered runtime, then cleanly unregister the misc/proc/debugfs service and
  platform driver before clearing the singleton for fixtures;
- in suite teardown, restore the production driver before initramfs and turn a
  restore error into a failed KUnit suite outcome; and
- reject post-boot debugfs reruns with `-EBUSY` before they can disturb live
  sessions or hardware.

If KUnit autorun is disabled, the suite is filtered out, or the test symbols
are absent, no suite callback runs and the normal driver remains registered.

## Validation

The repaired source passes:

- focused 6.18 KUnit-enabled builds of both rewrite objects;
- `git diff --check` and strict `checkpatch.pl` with zero findings;
- clean `git archive` builds for 6.18 and mainline under all six combinations
  of the `normal`, KASAN/fault-injection `memory`, and KCSAN/lockdep `race`
  profiles; each profile also builds the Rockchip IOMMU provider and ROCK 5B
  DTB; and
- a source audit of every rewrite initcall plus every work scheduling,
  cancellation, flush, and blocking-wait site. No second source-level
  boot-order wedge candidate was found.

The 6.18 KUnit executor was inspected directly as part of this gate:
`system_state` is still `SYSTEM_SCHEDULING` during boot autorun, `suite_exit`
runs before the suite-end verdict is printed, and `suite_init_err` participates
in that verdict. Those facts make the isolation window and restore-failure
reporting explicit rather than relying on initcall folklore.

## Repaired package inspection

The exact 6.18 repair built successfully in 14:11 as:

```text
6.18.40-S221f-D3dd5-P3138-Cad24-H9acc-HK01ba-Vc222-Bfe95-R448a
```

Final source patch `328/328` is commit `db8251eec71a9`. The packaged
`System.map` contains the runtime-registration and both suite init/exit paths
and places `rk_mpp_init` plus `rk_rga_init` in device-initcall level `6`; it
contains no rewrite `late_initcall_sync` entries. The config hash is unchanged
from the preceding instrumentation build and resolves both rewrite drivers and
suites, KUnit autorun/debugfs, KASAN, UBSAN, lockdep, DMA API debug, Debug
Objects, kmemleak, and IOMMU debugfs to `y`. Vendor MPP/RGA and optional DWC
PCIe PMU remain unset.

| Artifact | SHA-256 |
|----------|---------|
| image package | `cb30ff5ce1e1253bafde2ed54a6f0e125d93e19c56ecf08ac87f5ea114b33ff9` |
| DTB package | `f80e8d8196515543907f119170dd015286b561a2d665021a8032622341abaa76` |
| headers package | `54cd02cb6ab974d5a23be83c3c14413fa89d39ccf784d5450c85dc694acd33d1` |
| libc-dev package | `9bed426475402fa9928d7a7e5f14a554482a8a8c43a3a9f481f9c8184b25a9aa` |
| packaged `vmlinuz` | `c1e5a5c2692087e91c5f8c90b9c5b26a3a3573b3bc1964dfb1e03786985ef798` |
| packaged config | `692216a4b48d2cf5fdd19e4fb27bbf21a0728efe6e70d8daa078a9acf3525c88` |
| packaged ROCK 5B DTB | `2961225a7738b16f4517ddf4a0452329b2d4792bcca1c7a748bab65a641c7849` |

The DTB preserves ramoops at `0x118000`/`0xd0000` and disjoint RGA3 core
windows `0xfdb60000`/`0x200` on SPI 114 and
`0xfdb70000`/`0x200` on SPI 115. The build has no compiler errors and retains
the same 31 known KASAN-inflated KUnit frame-size diagnostics as the prior
package; the lifecycle repair adds none.

The arm64 image header reports a 138,215,424-byte (131.812 MiB) text+BSS
footprint. The active `boot.cmd` and executable `boot.scr` agree on the raised
`fdt_addr_r=0x0c000000`; with the installer fallback
`kernel_addr_r=0x00400000`, that is 188 MiB of headroom and about 56 MiB spare.
The earlier silent pre-console BSS/FDT overlap is therefore not a second wedge
candidate for this package.

## Boundary

The later `P3138-Cad24` boot completed exact 85/85 MPP plus 148/148 RGA KTAP,
restored both services, and bound every expected MPP/RGA core. That verifies
the unregister → fixtures → restore lifecycle repair itself. The same boot was
not a compound KUnit pass: one MPP fixture disabled lockdep through an
uninitialized mutex and another left a 2,048-byte nested allocation to
kmemleak. Those independent defects and their successor commits are recorded
in the
[final fixture finding](./2026-07-27-rewrite-kunit-lockdep-kmemleak-fixtures.md).

## Next gate

Boot a new package from successor `6b55e022ce491`, persist its KUnit interval
and running image fingerprint, and require exact KTAP, a fatal-signature-free
interval, live lockdep, and a clean aged kmemleak scan before media evidence.
