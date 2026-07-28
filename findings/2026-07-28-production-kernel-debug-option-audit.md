# Production kernel debug audit: four options above Armbian stock, and a 256 MiB debug allocation arriving from the shared boot environment

> Scope: ROCK 5B production forward-port kernel config and boot environment.
> Follow-on from the `CONFIG_DMABUF_DEBUG` root cause
> ([finding](2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md)) —
> asks whether any *other* debug setting is enabled that should not be.
>
> Source: `packaging/ppa/kernel-forward-port/debian/config/arm64-rockchip64.config`
> versus genuine Armbian stock `linux-image-current-rockchip64` **26.5.1** from
> `apt.armbian.com resolute/main` (`config-6.18.35-current-rockchip64`,
> downloaded and extracted for this audit); `/boot/armbianEnv.txt`;
> `kernel/dma/debug.c` and `arch/arm64/include/asm/cache.h` from the published
> production source; retained journals of production boots -1 and -2.
>
> Date: 2026-07-28
>
> Trust: **CONFIG-INSPECTED** / **SOURCE-INSPECTED** / **MEASURED** (the
> preallocation count, from two production boot journals) / **INFERRED** (the
> byte total and the per-map overhead).

## Result

The config is in good shape. The complete delta against genuine Armbian stock is
only **22** set options, of which **six** are diagnostic, and **zero** stock
diagnostic options are missing from ours.

Those six split into two groups that deserve different treatment. Only the first
group is a real deviation — debug options enabled on code stock also ships:

| option | keep? |
|---|---|
| `CONFIG_DMA_API_DEBUG=y` | **the one worth a decision** — see below |
| `CONFIG_IOMMU_DEBUGFS=y` | fine; debugfs nodes only, used to inspect RGA IOMMU faults |
| `CONFIG_KALLSYMS_ALL=y` | fine; adds data symbols to kallsyms — order of a megabyte or two of kernel memory (not measured), in exchange for better oops decoding, which this project reads constantly |

The second group are debug sub-options of drivers **stock does not ship at
all** — it has no `ROCKCHIP_MPP_*` and no `MULTI_RGA`, only the mainline
`VIDEO_ROCKCHIP_RGA=m`. "Stock doesn't set them" is therefore trivially true and
carries no signal; the real question is whether to enable debug facets of our
own drivers:

| option | note |
|---|---|
| `CONFIG_ROCKCHIP_RGA_DEBUGGER=y` | keep; compiles in `rga_debugger.o`, verbosity ints default 0 |
| `CONFIG_ROCKCHIP_RGA_DEBUG_FS=y` | keep; debugfs nodes for RGA |
| `CONFIG_ROCKCHIP_MPP_PROC_FS=y` | vendor Kconfig `default y` — **inherited, not chosen**. Exposes per-device state under `/proc/mpp_service`. Note this interface has itself produced a crash: [session-teardown oops](2026-07-17-mpp-procfs-session-teardown-oops.md). |

The remaining 16 delta options are not diagnostic: six are the forward-port
drivers themselves (`MPP_SERVICE`, `RKVENC2`, `RKVDEC2`, `AV1DEC`, `MULTI_RGA`,
`RGA_ASYNC` — the point of the project), nine are toolchain-derived and not
choices (`CC_HAS_*`, shadow-call-stack detection, `INIT_STACK_ALL_ZERO`, all
following from gcc 15.2 versus stock's older compiler), and one is the
version-derived `ARM64_ERRATUM_4118414`.

Everything expensive is already off, verified directly rather than by
comparison: `KASAN`, `PROVE_LOCKING`, `LOCKDEP`, `DEBUG_PAGEALLOC`,
`PAGE_POISONING`, `DEBUG_SG`, `SLUB_DEBUG_ON`, `DEBUG_OBJECTS`, `DEBUG_VM`,
`UBSAN`, `DEBUG_KMEMLEAK`, `DEBUG_SPINLOCK`, `DEBUG_MUTEXES`,
`DEBUG_ATOMIC_SLEEP`, `FAULT_INJECTION`.

Options that look alarming but should not change: `SLUB_DEBUG=y` is the
capability only and costs nothing with `SLUB_DEBUG_ON` off; `DEBUG_FS=y` is
required by the Rockchip drivers themselves; `FUNCTION_TRACER=y` pairs with
`CONFIG_DYNAMIC_FTRACE=y`, so call sites are NOPed at boot; `DEBUG_INFO`/
`DEBUG_INFO_BTF` are build-size only; `DMABUF_SELFTESTS=m` is never loaded.

**The largest remaining debug cost is not in the config at all.** It is
`dma_debug_entries=2097152` on the kernel command line, worth ~256 MiB of
permanently allocated kernel memory, and it reaches the production kernel by
accident.

## Methodology correction — the trap that nearly produced a wrong answer

The first pass of this audit compared against
`/boot/config-6.18.38-current-rockchip64` on the assumption that a file named
`current-rockchip64` was Armbian's shipping config. It is not. That package is

```
linux-image-current-rockchip64  26.08.0-trunk  (priority 100, /var/lib/dpkg/status only)
```

— installed locally, absent from `apt.armbian.com` (which offers 26.5.1 /
26.2.1 / 25.11.2), built with the local Docker `gcc 13.3.0`. It is **this
project's own debug kernel**, which by design takes the stock package names:
`debug-kernel/README.md` says "A debug build uses the same
`linux-*-current-rockchip64` package names as the [stock] package."

That config has `KASAN=y`, `PROVE_LOCKING=y`, `UBSAN=y`, `DEBUG_PAGEALLOC=y`,
`DEBUG_KMEMLEAK_AUTO_SCAN=y`. Comparing production against it produced the
comfortable and completely meaningless conclusion that our config is "less
debug-heavy than Armbian stock". The real stock config reverses the direction of
every interesting row — most importantly `DMA_API_DEBUG`, which stock leaves
**off** and we enable.

Anyone auditing config drift on this board must download the real package rather
than read `/boot/config-*-current-rockchip64`:

```bash
apt-get download linux-image-current-rockchip64=26.5.1
dpkg-deb -x linux-image-current-rockchip64_26.5.1_arm64.deb x/
grep DMA_API_DEBUG x/boot/config-6.18.35-current-rockchip64   # -> is not set
```

## `CONFIG_DMA_API_DEBUG` — the one judgment call

It is a deviation from stock, and it is the parent of the oops: Kconfig marks
`DMABUF_DEBUG` `default y if DMA_API_DEBUG`, so enabling this is what silently
armed the scatterlist mangle. That coupling is now broken locally by the
explicit `# CONFIG_DMABUF_DEBUG is not set`, so it cannot re-arm.

Costs, at the currently configured pool size:

- **Memory.** `struct dma_debug_entry` is ~113 bytes, and
  `____cacheline_aligned_in_smp` with arm64's `L1_CACHE_SHIFT = 6` rounds it to
  **128 B**. `DMA_DEBUG_DYNAMIC_ENTRIES = PAGE_SIZE / sizeof(entry)` = 32 per
  page, and `dma_debug_init()` preallocates
  `DIV_ROUND_UP(nr_prealloc_entries, 32)` pages up front.

  | setting | entries | pages | RAM |
  |---|---|---|---|
  | kernel default `PREALLOC_DMA_DEBUG_ENTRIES` | 65,536 | 2,048 | **8 MiB** |
  | our cmdline | 2,097,152 | 65,536 | **256 MiB** |

- **Time.** Every map/unmap/sync takes a hash-bucket lookup under a spinlock
  plus an entry alloc/free. An RKMPP + RGA pipeline performs thousands of these
  per second.

It has earned its keep — it is what surfaced the RGA2 DMA sync on an unmapped
page-table address (`0050`). The call is whether a *production* kernel should
carry it, or whether it belongs only in the debug lineage where the rest of the
instrumentation lives.

## The 256 MiB arrives by accident

`/boot/armbianEnv.txt` line 4:

```
extraargs=cma=256M module_blacklist=snd_soc_hdmi_codec … panic=10 dma_debug_entries=2097152
```

Measured on production boots -1 and -2:

```
DMA-API: preallocated 2097152 debug entries
DMA-API: debugging enabled by kernel config
```

That bump is documented in
[`debug-kernel/README.md`](../kernel-drivers/scripts/debug-kernel/README.md) as
a **debug-kernel** measure — `DMA_API_DEBUG` "silently disables itself under
heavy RGA/MPP DMA traffic", so conformance runs raise the pool "so it stays
active through the whole matrix". But `armbianEnv.txt` holds one `extraargs`
line shared by every installed kernel, so a conformance-run tuning is applied to
every production boot as well.

This is the same structural pattern as the `DMABUF_DEBUG` defect itself: a
setting intended for a debug kernel reaching a kernel nobody intended it for.
There the mechanism was Kconfig's `default y if`; here it is a single-slot boot
environment.

## Boundary

- The 256 MiB is **computed**, not measured. The entry *count* is measured from
  two boot journals; the byte total comes from `sizeof(struct dma_debug_entry)`
  derived from source. No `meminfo` before/after comparison was made.
- Per-map overhead is argued from the code path, not benchmarked. No measurement
  of encode throughput with and without `DMA_API_DEBUG` exists.
- Stock baseline is Armbian 26.5.1 (`6.18.35`) against our `6.18.40`. A five
  point-release skew; adequate for debug-option comparison, not for a full
  config diff.
- Only `arm64-rockchip64.config` was audited. The rewrite/alpha and sgguard
  packaging configs were not.
- **A keyword filter is not an audit.** The first pass matched
  `DEBUG|KASAN|LOCKDEP|PROVE_|UBSAN|…` against the delta and reported *four*
  options, missing `KALLSYMS_ALL` (no matching substring) and
  `ROCKCHIP_MPP_PROC_FS` (likewise) — both diagnostic. The delta is only 22
  options; enumerate and classify all of them rather than grepping. This is the
  second methodology error in this audit, after the wrong baseline.
- The RGA debugger's runtime cost is inferred from its verbosity ints defaulting
  to 0 and its hooks being probe/init-time; no profiling was done.

## Recommended actions

> **Decided and actioned 2026-07-28.** All three genuine deviations were
> switched off in the tracked config and folded into the (still unpublished)
> `~rk2` release, which now carries a four-line config diff against `~rk1`:
> `DMABUF_DEBUG`, `DMA_API_DEBUG`, `IOMMU_DEBUGFS`, `KALLSYMS_ALL`. The RGA and
> MPP debug facets were deliberately kept. Items 1–3 below are superseded and
> retained as the reasoning of record.

1. ~~**Change nothing in the config right now.**~~ Superseded — the one-line
   diff was traded for the full debug cleanup in a single release. Acceptable
   because the attribution rests on the 8/8 arithmetic inversion and the 4/4
   config correlation, not on the package being single-variable, and because
   none of the three added symbols can re-arm the mangle.
2. ~~**Drop `dma_debug_entries=2097152` from `extraargs`.**~~ No longer needed
   as a separate step: with `DMA_API_DEBUG` off the boot argument is inert
   (`Unknown kernel command line parameter`), so the 256 MiB is reclaimed
   without touching the root-owned shared boot environment. Removing the
   argument is still worth doing eventually for tidiness, and remains necessary
   whenever a debug kernel is booted.
3. ~~**Decide `DMA_API_DEBUG` deliberately.**~~ Decided: off in production. It
   belongs in the debug lineage with the rest of the instrumentation, where the
   pool bump lives too.
4. Consider whether the debug kernel should stop borrowing the stock
   `linux-*-current-rockchip64` package names, given it put a debug config at a
   stock-looking path and nearly produced a wrong audit result here.
