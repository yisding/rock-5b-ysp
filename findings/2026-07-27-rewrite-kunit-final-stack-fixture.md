# Final capped RGA KUnit stack fixture warning is fixed in both rewrite trees

> Scope: clean-room RGA rewrite KUnit suite on the ROCK 5B
> Source: booted `6.18.40-video-rewrite-kasan-rockchip64` build `#6`; `dmesg`; `rk_rga_timeout_target_replacement_kunit()`; 6.18 `3b41eca277c7` and mainline `52d4dfa16825`
> Date: 2026-07-27
> Trust: MEASURED / SOURCE-INSPECTED / ROOT-CAUSED / FIX-COMPILE-VERIFIED / PARTIAL

## Result

The next rewrite boot passes the complete current KUnit plans:

| Suite | Results | Failed | Skipped |
|-------|---------|--------|---------|
| `rk_mpp_rewrite` | 85/85 | 0 | 0 |
| `rockchip-rga-rewrite` | 148/148 | 0 | 0 |

It also proves the shared-IRQ repair reaches its intended hardware result:
RGA2 registers on IRQ 35 and both RGA3 cores register on their shared IRQs 48
and 49.

The interval is still not warning-clean. Debug Objects emits two reports in the
passing `rk_rga_timeout_target_replacement_kunit` case:

```text
ODEBUG: object (...) is on stack (...), but NOT annotated.
WARNING: ... lib/debugobjects.c:672 ...
 rk_rga_timeout_target_replacement_kunit+0x148/0xb98

ODEBUG: object (...) is on stack (...), but NOT annotated.
WARNING: ... lib/debugobjects.c:672 ...
 rk_rga_timeout_target_replacement_kunit+0x1a4/0xb98
```

The fixture embeds `struct delayed_work timeout_work` in a stack
`struct rk_rga_hw` and initializes it with ordinary `INIT_DELAYED_WORK()`.
That produces one report for the embedded `work_struct` and one for its
`timer_list`. The test still returns `ok 99`, so this is fixture lifetime
misannotation rather than a failed timeout-generation contract or evidence of
a production object being queued from a stack frame.

This corrects the preceding finding's accounting. Before its three recorded
fixtures were repaired, the RGA suite contained eight affected debug objects
across four fixtures, not six across three. `debug_object_is_on_stack()` returns
after five mismatches per boot. The earlier five printed reports consumed that
budget, hiding the sixth object already inferred there and both objects in this
later case. Fixing the first six reset visibility on the next boot and exposed
the final pair.

No KASAN, KCSAN, UBSAN, KFENCE, Oops, use-after-free, or bounds report appears
in the full dmesg scan. The independent DWC PCIe PMU same-class notifier report
still occurs before KUnit and disables lockdep for the rest of the boot.

## Fix

Both maintained trees now allocate the fixture's `rk_rga_hw` owner with
`kunit_kzalloc()` and retain the ordinary production `INIT_DELAYED_WORK()`
initializer:

| Tree | Commit |
|------|--------|
| `rk3588-rewrite-6.18` | `3b41eca277c7bd3209dda7853054e84eb57a8469` |
| `rk3588-rewrite-mainline` | `52d4dfa168253a479edae0d2ef44b55e499f1dd9` |

The driver files remain byte-identical. `git diff --check`, checkpatch, and a
focused KUnit-enabled 6.18 `rga_rewrite.o` build pass. The clean-archive normal
profile also passes at both exact commits, warning-free, building the Rockchip
IOMMU provider, both KUnit-enabled rewrite objects, and the ROCK 5B DTB. The
subsequent byte-identical KUnit/live-service isolation descendants,
6.18 `dbc36621b301` and mainline `948db1b44c63`, pass the same gate.

## Boundary

The source fix is compile-verified, not boot-verified. The running build
predates these two commits, so its two warnings are expected evidence of the
old fixture. The DWC PCIe PMU report still prevents a lockdep-qualified
interval even after this KUnit repair. No ABI or media ioctl was exercised as
part of this inspection.

## Next gate

Package and boot current 6.18 tip `dbc36621b301` (which contains the fixture
fix), disable the optional DWC PCIe PMU for the qualification experiment, and
require:

1. 85/85 MPP plus 148/148 RGA results;
2. no Debug Objects or other fatal dmesg signature;
3. lockdep still enabled after KUnit;
4. RGA2 and both RGA3 cores bound; and
5. an isolated ABI replay with clean dmesg and readable rewrite debugfs.
