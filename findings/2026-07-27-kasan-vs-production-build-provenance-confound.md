# The KASAN non-reproduction is confounded by toolchain: production is a Launchpad gcc-15.2 build, the KASAN kernel is a local gcc-13.3 build

> Scope: ROCK 5B kernel forward-port. Tests whether the production-vs-KASAN
> split behind
> [`2026-07-27-grd-sg-corruption-kasan-non-reproduction.md`](2026-07-27-grd-sg-corruption-kasan-non-reproduction.md)
> is attributable to KASAN at all, or to how the two kernels were built.
>
> Source: the running board — `/proc/version`, `dpkg -s linux-image-ysp-rockchip64`,
> `apt-cache policy`, `/boot/config-6.18.40-ysp-rockchip64` versus
> `/boot/config-6.18.40-video-port-kasan-rockchip-rk3588`; source trees
> `packaging/ppa/out/work/linux-rockchip64-ysp-6.18.40+rk3588av1fwport20260725`
> and `~/Code/tmp/fwport-sgguard`; the Armbian build tree's patch archive at
> `~/Code/rock-5b/build/kernel/rock5b-kernel-build/armbian-build`.
>
> Date: 2026-07-27
>
> Trust: **MEASURED** (all identity/config/source comparisons) / **INFERRED**
> (the significance of the toolchain gap) / **FALSIFIED-AS-SOLE-CAUSE**.

> **Corrected 2026-07-28 by**
> [`2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md`](2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md).
> **The toolchain is not the discriminator.** The KASAN non-reproduction is
> explained by `CONFIG_DMABUF_DEBUG`: production sets it, both KASAN kernels do
> not, and it is the option that gates the `mangle_sg_table()` writer. Compiler
> version is irrelevant to this failure.
>
> The specific error is in *What is not confounded* item 1 below. That sweep
> enumerated the memory-layout-relevant config deltas and concluded "the only
> differences on that axis are the five intended debug options: `KASAN`,
> `DEBUG_SG`, `DEBUG_PAGEALLOC`, `PAGE_POISONING`, `PROVE_LOCKING`". It checked
> `DMA_API_DEBUG` — which does match — but **missed `CONFIG_DMABUF_DEBUG`**, a
> distinct symbol that differs and is the actual cause. The sixth debug option
> was the one that mattered.
>
> The escalation this finding recommended is void. Building the guarded source
> through the PPA to control for gcc was answering a question that was never
> open; the `linux-rockchip64-ysp-sgguard` package should not be uploaded. The
> identity, provenance, and source-comparison facts recorded below were measured
> and remain accurate — keep them as the record of what was ruled out.

## Result

The two kernels differ by **two major GCC releases**, not only by KASAN. The
conclusion "KASAN masks the bug" was drawn from a comparison that never
controlled for the compiler, and the control run about to be performed does not
control for it either.

| | production `6.18.40-ysp-rockchip64` | debug `6.18.40-video-port-kasan-rockchip-rk3588` |
|---|---|---|
| built by | **Launchpad buildd** (`build@launchpad`) | local Armbian Docker container |
| origin | PPA `yi-ding/ubuntu-rock-5b`, `6.18.40+rk3588av1fwport20260725-0ubuntu1~rk1` | `output/debs/`, never published |
| compiler | **gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0** | **aarch64-linux-gnu-gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0** |
| binutils | **2.46** (`CONFIG_LD_VERSION=24600`) | **2.42** (`CONFIG_LD_VERSION=24200`) |
| host distro | Ubuntu resolute (26.04) | Ubuntu noble (24.04) container |
| reproduces the oops | **3/3** | 0/9 logins, 0/1600 encoder sessions |

`/proc/version` on the failing kernel reads in full:

```text
Linux version 6.18.40-ysp-rockchip64 (build@launchpad)
  (gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0, GNU ld (GNU Binutils for Ubuntu) 2.46)
  #1 SMP PREEMPT Thu, 09 Jul 2026 12:00:00 -0700
```

### What is *not* confounded

Three candidate explanations were tested and eliminated, which is what makes the
toolchain the live one:

1. **Memory-layout config is clean.** 202 config options differ in total, but on
   every axis that could move the victim allocation or change slab behaviour the
   two agree: `ARM64_4K_PAGES`, `SPARSEMEM_VMEMMAP`, `NEED_SG_DMA_LENGTH`,
   `NEED_SG_DMA_FLAGS`, `SLUB_DEBUG`, `SLUB_DEBUG_ON`, `SLAB_FREELIST_RANDOM`,
   `SLAB_FREELIST_HARDENED`, `RANDOM_KMALLOC_CACHES`, `SLAB_MERGE_DEFAULT`,
   `MEMCG`, `INIT_ON_ALLOC/FREE_DEFAULT_ON`, `SHUFFLE_PAGE_ALLOCATOR`,
   `DMA_API_DEBUG`. The only differences on that axis are the five intended debug
   options: `KASAN`, `DEBUG_SG`, `DEBUG_PAGEALLOC`, `PAGE_POISONING`,
   `PROVE_LOCKING`. The remaining ~197 are debug/hung-task/UBSAN/DRM_PANIC noise.
2. **The vendor driver source is identical.** `diff -rq` over
   `drivers/video/rockchip/` between the PPA source package tree and the local
   patch worktree reports only `Kconfig` and `Makefile` — because the PPA tree
   additionally *ships* (but does not build) `mpp-rewrite/` and `rga-rewrite/`.
   Every `mpp/` and `rga3/` source file matches. In `drivers/dma-buf/`,
   `system_heap.c` differs only by the local worktree's `DIAG` guard commit.
3. **Both trees are Armbian-derived.** The local build applies Armbian's
   177-patch `rockchip64-6.18` archive plus our 76 userpatches; the PPA source
   package carries Armbian patches too — the Armbian-only symbol
   `rk3399_pcie_ignore_serror_enabled` (from
   `HACK-Ignore-SError-to-enable-rk3399-PCIe-bus-enumera.patch`) appears four
   times in the PPA tree's `arch/arm64/kernel/traps.c`. So this is not
   "Armbian vs vanilla". (Whether the two Armbian archives are the same
   *vintage* was not established.)

The apparent base-version gap is an artifact worth writing down so it is not
re-discovered as alarming: `~/Code/tmp/fwport-sgguard/Makefile` says
`SUBLEVEL = 0` because that worktree is a **patch carrier** based on `v6.18`
(`BASE_TAG=v6.18`, series regenerated as `v6.18..HEAD`). The kernel actually
built from it is Armbian's 6.18.40 tree with those 76 patches applied, so the
built kernels are both 6.18.40.

### Why the toolchain gap is not merely cosmetic

GCC 13 → 15 is two major releases, and the configs show it changing generated-code
*semantics*, not just optimization:

- `CONFIG_CC_HAS_COUNTED_BY=y` on production, **absent** on the KASAN kernel
  (gcc 13 lacks the attribute). `CONFIG_FORTIFY_SOURCE=y` on both, so
  `__builtin_dynamic_object_size` resolves differently between the two builds for
  every `__counted_by`-annotated struct in the tree. No such annotation exists in
  `scatterlist.h` or `drivers/dma-buf/`, so this does not touch the victim
  directly — but it is proof that the two builds are not the same program.
- `CONFIG_CC_HAS_MIN_FUNCTION_ALIGNMENT=y` and
  `CONFIG_CC_HAS_SANE_FUNCTION_ALIGNMENT=y` on production only — different
  function alignment, hence different code and cache layout, hence different
  timing on a bug whose window is sub-millisecond.
- Inlining and register allocation differ across two major releases regardless,
  and vendor BSP code of this vintage is not UB-clean.

This does **not** promote "gcc 15 miscompiles something" to a leading theory.
The source sweep found no scatterlist writer in the vendor drivers for a
compiler to miscompile, and a codegen difference is a mechanism of last resort.
It does mean the observed split has at least two sufficient explanations —
KASAN's layout/quarantine changes, and the toolchain — and nothing measured so
far distinguishes them.

## Boundary

- This does not weaken the production evidence at all. Three oopses on the
  shipped kernel are three oopses; what is weakened is the *inference* that
  KASAN is what suppresses them.
- No miscompilation has been demonstrated. No disassembly comparison of the
  relevant paths was made between the two builds.
- The Armbian patch-archive vintage used for the PPA build was not recovered, so
  "both are Armbian-derived" is established but "both carry the same Armbian
  patches" is not.
- Timing effects are argued from first principles, not measured.

## Why it matters — the pending control run is also confounded

The guarded build now compiling is another **local Armbian Docker build, and so
another gcc 13.3.0 build**. The escalation plan's step 1 — boot it with
`system_heap.sg_guard=0` and take one login — was designed to control for the
guard, the local build, and the patch delta. It does not control for the
compiler. So its outcomes read:

| `sg_guard=0` result | What it licenses |
|---|---|
| **oopses** | Decisive and good: a gcc-13 local build reproduces, so toolchain is not the discriminator and KASAN masking is confirmed. The guard is immediately useful. |
| **clean** | Ambiguous *three* ways, not one: KASAN's layout change, the toolchain, or the Armbian-archive vintage. Do not record this as "the guard build does not reproduce". |

That second row is the case worth preparing for, because the cheapest way out of
it is already available:

1. **gcc 15.2.0 is installed natively on this board** — `/usr/bin/gcc-15`,
   `gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0`, the exact version Launchpad used. A
   local build with the production compiler removes the variable, if the Armbian
   Docker toolchain can be overridden or a native build path is used.
2. **Better: move the debug config into the PPA lineage.** `build-kernel.sh`
   already has a `ppa-forward-port` flavor. A KASAN-or-guard variant built *by
   Launchpad* from the same source package leaves **config as the only
   variable** — the experiment the current comparison was always meant to be. It
   costs an upload and a build-farm wait rather than local CPU.

## Verification gate

Take the `sg_guard=0` login as planned. If it oopses, this finding is closed as
a ruled-out confound and the investigation proceeds on the local build. If it
comes back clean, do **not** conclude anything about KASAN: build the same
guarded source through the PPA lineage so Launchpad's gcc 15.2 compiles it, and
compare that against production with config as the sole difference.
