# The KASAN kernel does not reproduce the GRD system-heap oops, and is likely unable to

> Scope: ROCK 5B kernel forward-port; the GNOME Remote Desktop RKMPP
> login-screen path traced in
> [`2026-07-27-grd-rkmpp-system-heap-sg-corruption-oops.md`](2026-07-27-grd-rkmpp-system-heap-sg-corruption-oops.md).
>
> Source: booted `6.18.40-video-port-kasan-rockchip-rk3588` (`P47b9-Cc271`
> config) and the retained persistent journal for the production
> `6.18.40-ysp-rockchip64` boot; production source at
> `packaging/ppa/out/work/linux-rockchip64-ysp-6.18.40+rk3588av1fwport20260725`;
> `drivers/dma-buf/heaps/system_heap.c`, `include/linux/scatterlist.h`,
> `drivers/iommu/dma-iommu.c`.
>
> Date: 2026-07-27
>
> Trust: **MEASURED** / **SOURCE-INSPECTED** / **INFERRED**

> **Confounded 2026-07-27 by**
> [`2026-07-27-kasan-vs-production-build-provenance-confound.md`](2026-07-27-kasan-vs-production-build-provenance-confound.md).
> The two kernels compared here differ by **two major GCC releases**, not only by
> KASAN: production is a Launchpad buildd binary (gcc 15.2.0, binutils 2.46) and
> this debug kernel is a local Armbian Docker build (gcc 13.3.0, binutils 2.42).
> Memory-layout config, vendor driver source, and Armbian-derivation were all
> checked and are *not* confounded — the toolchain is. "KASAN masks it" and "the
> gcc-13 build does not have it" are both still sufficient explanations of the
> table below, and nothing measured so far separates them.

> **Updated 2026-07-27 by**
> [`2026-07-27-grd-sg-corruption-reproduced-and-ioctl-capture-plan.md`](2026-07-27-grd-sg-corruption-reproduced-and-ioctl-capture-plan.md).
> The *production evidence is n=1* section below is superseded: a second
> production boot reproduced the oops on its first login, 2/2, with an identical
> failing entry index, entry length, `orig_nents`, direction, CPU and UID. The
> open question this finding framed — deterministic-and-masked versus rare — is
> settled in favour of deterministic on production and masked under KASAN. The
> KASAN measurements and the blindness argument here are unaffected.

## Result

The prior finding's verification gate — boot the existing KASAN/`DEBUG_SG` image
and repeat one login — was run and came back clean. More importantly, the gate
is mis-specified: KASAN is probably structurally incapable of reporting this
write.

### The KASAN kernel does not reproduce it

| Kernel | RDP handovers | `h264_rkmpp` sessions created | Oopses |
|---|---|---|---|
| `6.18.40-ysp-rockchip64` (production, boot -1) | **1** | 0 | **1** |
| `6.18.40-video-port-kasan-rockchip-rk3588` (boot 0) | 9 | 9 | 0 |
| same, direct `mpi_enc_test` (400 iters × 4 instances) | — | 1600 | 0 |

Session *connection* is not the discriminator: on the failing production boot
the client authenticated, handed over to GDM, started greeter session `c2` and
negotiated AVC420 before the oops. The discriminator is whether
`Created h264_rkmpp encode session` appears. On the KASAN kernel it appears every
time, including through the greeter handover path (`sessionc8`, uid `60585` —
the same dynamic gdm-greeter range as the failing thread's uid `60579`).

### The production evidence is n=1

The production kernel has been booted with GRD exactly once, took exactly one
handover, and oopsed on it. There is no measurement of determinism. "KASAN masks
it" and "the single production attempt was unlucky" are both still open.

### The corrupt `page_link` is a well-formed `struct page` pointer

This is the load-bearing result. The oops register block gives
`x20 = fffffdffc0000000`, which is the `vmemmap` base held live across
`iommu_dma_sync_sg_for_device()`'s loop. Since
`page_to_pfn(p) = (p - vmemmap) / sizeof(struct page)`, the stored value is
recoverable — which the prior finding could not do:

```text
page_link  = x20 + PFN * 64
valid window (PFN 0 .. 0x4fffff):  0xfffffdffc0000000 .. 0xfffffdffd4000000
observed PFN 0x1e0c1fc          ->  page_link ~ 0xfffffe0038307f00
                                    (~1.68 GiB past the top of the window)
```

A PFN that small places the stored value in the first ~0.1% of the 2 TiB vmemmap
region. Slab poison (`0x6b`/`0x5a`), a SLUB freelist pointer (a linear-map
address), ASCII, or zero would each decode to an astronomically larger PFN and a
correspondingly wild fault address — not the clean `__va(0x1e0c1fc000)` that was
logged, whose page-table walk resolved cleanly to `pud=0` at level 1.

So the writer **computed a page pointer** — `phys_to_page()`, `pfn_to_page()`,
or page arithmetic — from a bad but bounded input, and stored it. This is not a
generic wild memory overwrite.

### Why KASAN is likely blind to it

If that store was in-bounds on a live scatterlist array, then:

- **KASAN cannot report it.** KASAN detects out-of-bounds and use-after-free,
  not correct-shape stores of wrong values into valid objects.
- **`DEBUG_SG` cannot report it.** This kernel's `struct scatterlist` carries no
  magic field (`include/linux/scatterlist.h`); nothing validates `page_link`.
- **A device-side DMA scribble is invisible to KASAN regardless**, since KASAN
  instruments CPU accesses only.

That makes the clean KASAN result weak evidence of absence, and it means the
prior finding's "existing KASAN discriminator" is not the right instrument.

### Two corrections to the prior finding

1. **`x19` is the scatterlist array base, not the failing entry.**
   `sizeof(struct scatterlist)` is exactly 32 here (`CONFIG_NEED_SG_DMA_LENGTH=y`
   and `CONFIG_NEED_SG_DMA_FLAGS=y`), so a 24-entry table is
   `kmalloc_array(24, 32)` = 768 B, living in **kmalloc-1024** and therefore
   1024-byte aligned. `x19 = ffff0001c3e59400` is 1024-aligned; the failing
   entry 1 is at `…9420`. Read as the failing entry, the base would land at
   `…93e0`, which no kmalloc-1024 object can occupy.
2. **`end_cpu_access()` syncs the per-attachment *duplicate*, not
   `buffer->sg_table`,** and walks **every** mapped attachment
   (`system_heap_dma_buf_end_cpu_access()` iterates `buffer->attachments` and
   syncs `&a->table`). The buffer identification by size and entry count stands,
   but the *owning device of the damaged table* is not established — it need not
   be the encoder's attachment.

## Boundary

This does not identify the writer, and does not disprove the production oops.

- The KASAN result is a non-reproduction, not a refutation: the production trace
  stands on its own evidence.
- The direct `mpi_enc_test` harness generates its own frames, so it imports no
  external dma-buf and never involves the GPU or RGA. GRD's path does both
  (`panthor`, `rockchipdrm` and the RGA driver were live in the failing boot's
  module set). Multiple attachments per buffer is a shape the direct harness
  cannot produce, so its 1600 clean sessions do not cover the full GRD path.
- The "KASAN is blind" argument is **INFERRED** from the shape of the stored
  value. It holds only if the write was in-bounds on a live object; an
  out-of-bounds write that happened to land on `page_link` would still be
  KASAN-visible.
- `sizeof(struct page) = 64` is assumed in the `page_link` recovery. The
  qualitative conclusion (a vmemmap-region pointer, not garbage) does not depend
  on it; the exact recovered value does.
- No bisection was attempted between the production PPA kernel and the local
  forward-port series.

## Evidence and reproduction

- **Identity:** ROCK 5B, `6.18.40-video-port-kasan-rockchip-rk3588` (KASAN
  generic inline, `DEBUG_SG`, `DEBUG_PAGEALLOC`, DMA-API debug, `PROVE_LOCKING`
  all confirmed set); GRD `50.2+rkmpp+git20260721.13.cf60b4d`; libmpp
  `1.5.0+git20260529.1375813c`; librga `2.2.0+git20260725.26a50ef`.
- **Exercise:** `kernel-drivers/tests/grd-sg-oops-repro.sh` — drives
  `mpi_enc_test` at the finding's exact geometry (`2064x1296`, hstride 2112,
  alternating vstride 1344/1296 to mirror GRD's reconfigure), churning process
  starts so each iteration allocates a fresh buffer and scatterlist.
- **Pass/fail signal:** the script exits non-zero the moment
  `/proc/sys/kernel/tainted` moves or a kernel report appears. 400 iterations ×
  4 instances completed with `taint=0`.
- **Artifacts:** none committed; journal is persistent on the board.

### Setup defect found

`CONFIG_PAGE_OWNER=y` on the KASAN kernel, but `page_owner=on` is absent from
`/proc/cmdline`, so the journal reports `page_owner is disabled`. One of the four
discriminators the prior gate depends on was never armed. `CONFIG_PAGE_OWNER` is
not set at all on the production kernel. Its value here is limited regardless:
the bogus PFN is outside RAM, so no `struct page` exists to carry owner data.

### Ruled out by source inspection

- `drivers/iommu/dma-iommu.c` never writes `page_link` on the map/sync path;
  `__finalise_sg()` touches only `dma_address`/`dma_len`/`offset`/`length`. Its
  one `sg_set_page()` is in an allocation path building its own table. A
  snapshot of `page_link` therefore stays valid across map and unmap.
- The forward-port's only change to `dma-iommu.c` is an additive accessor
  (`iommu_dma_get_iova_domain`); core DMA-IOMMU scatterlist logic is stock.
- The `sg_set_page(dst, phys_to_page(start), len, 0)` sites in
  `rga3/rga_dma_buf.c` (`rga_dma_alloc_aligned_sgt()`) and the rewrite
  equivalent write only a locally allocated `aligned_sgt`, bounded to
  `orig_nents`, freed before return.
- `drivers/video/rockchip/mpp/mpp_iommu.c` reads `sg_dma_address`/`sg_dma_len`
  but never writes `page_link`.

## Verification gate

Establish the production base rate before building anything further:
[`kernel-drivers/docs/grd-sg-corruption-repro-plan.md`](../kernel-drivers/docs/grd-sg-corruption-repro-plan.md).
That plan also carries the post-oops escalation path.

## Why it matters / follow-up

The prior finding's gate sends effort to the wrong kernel. The instrument that
can see this class of write is
[`kernel-drivers/patches/system-heap-sg-guard/`](../kernel-drivers/patches/system-heap-sg-guard/README.md)
— a `page_link` snapshot-and-compare across every point the heap touches an
attachment's table, reporting the owning device and skipping the corrupted sync
so the machine survives. It builds clean against both the production and KASAN
configs and applies clean to all three kernel trees. It belongs on the kernel
where the bug reproduces, which on current evidence is production, not KASAN.

Because the guard reports at checkpoints it brackets rather than catches the
writer. The escalation is a hardware watchpoint on the failing entry's
`page_link` (`CONFIG_HAVE_HW_BREAKPOINT=y` on both kernels), which also
discriminates CPU writer from device DMA: a silent watchpoint alongside a
confirmed corruption would be strong evidence for a DMA scribble that no
CPU-side tool can observe.
