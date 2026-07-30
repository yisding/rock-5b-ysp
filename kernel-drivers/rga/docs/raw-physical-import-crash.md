# RGA raw physical-address import crash

> **Corrected 2026-07-29** (source record kept in the private
> `rock-5b-security` repository).
> **The kernel that actually ships on a Rock 5B does not have this bug.** The
> three-branch analysis below covers `rockchip-linux/kernel`
> `develop-5.10`/`develop-6.1`/`develop-6.6` and never checked `radxa/kernel`
> `linux-6.1-stan-rkr5.1`, which is the branch Radxa's images are built from.
> That branch is **NOT AFFECTED** — see the fourth table row.

> **Evidence class (recorded 2026-07-29).** Two honesty notes that belong in
> any write-up of this document:
>
> - The oops trace quoted below is **hand-transcribed**: a bare list of frame
>   names with no timestamps, no `uname`, no PC/LR, and no source log committed
>   anywhere. Trust: **MEASURED** that a crash occurred, **UNVERIFIED** as a
>   verbatim trace.
> - The crash was observed on **this project's own 6.18 forward port**, never
>   on a vendor kernel. No vendor-kernel reproduction exists. The claim that
>   `develop-5.10`/`develop-6.1` carry the same defect is **CODE-INSPECTED**
>   against the pinned tips in the table, not measured.
> - The raw physical-import probe is **disabled in every recorded ABI run** on
>   this box: `physical_import_probe          disabled` appears in all 26
>   `norm`/`raw` logs across the 13 distinct `tests/logs/abi-replay/` runs, and
>   the probe never appears enabled in any of them. Those logs are gitignored,
>   so this is not independently checkable from a clone.

## Scope and conclusion

The 2026-07-16 forward-port crash is inherited from Rockchip's vendor RGA3
driver. It is not a Linux 6.18 porting regression.

Rockchip's `develop-5.10` and `develop-6.1` branches both contain the same
unsafe `dma_map_sg()` physical-import implementation. Neither branch contains a
later validation fix. Rockchip's `develop-6.6` branch does not contain this
exact import-time crash path because it retained the older
`dma_map_resource()` implementation, but that implementation is not a proper
fix: it still accepts an unvalidated userspace-supplied physical address and
uses the wrong DMA API for normal RAM.

`radxa/kernel` `linux-6.1-stan-rkr5.1` — the shipping Rock 5B branch — is
**not affected at all**: it predates the `dma_map_sg()` conversion and still
uses `rga_mm_map_phys_addr()` → `rga_iommu_map()` with
`rga_mm_check_range_phys_addr()`. "The BSP has this bug" is therefore true of
`rockchip-linux` and false of what Radxa ships; name the tree.

Here, **Rockchip BSP** means Rockchip's out-of-tree vendor `rga3` driver. It does
not mean the smaller RGA driver in mainline Linux.

Forward-port commit `1c9a110129fe` now implements the minimal crash fix. It is
represented by patch `0039` in
[`patches/forward-port-rk3588`](../../patches/forward-port-rk3588/README.md).
The published `6.18.38+rk3588av1fwport20260716` package predates that commit
and remains vulnerable until a rebuilt package is installed and booted.
Hardened version
`6.18.38+rk3588av1fwport20260716.1-0ubuntu1~rk1` passed both a full Armbian
integration build and a full binary build from the exact exported PPA source.
Launchpad accepted its signed source as pending publication `18624583` and
started arm64 build `33407863`; do not treat the fix as live until Launchpad
publishes that version and the board boots it.

## Observed failure

The ABI probe submitted a no-job buffer import with:

```text
ioctl:       RGA_IOC_IMPORT_BUFFER
type:        RGA_PHYSICAL_ADDRESS
memory:      0x1000
size:        4096
```

The forward-port kernel accepted PFN 1 as structurally present, constructed an
sg-table for it, and passed that table to the DMA/IOMMU layer. ARM64 cache
maintenance then dereferenced the direct-map address corresponding to physical
address `0x1000` and oopsed:

```text
dcache_clean_poc
iommu_dma_sync_sg_for_device
iommu_dma_map_sg
__dma_map_sg_attrs
dma_map_sg_attrs
rga_dma_map_sgt
rga_mm_map_buffer
rga_mm_import_buffer
rga_ioctl
```

The crash is reachable from an import ioctl; no RGA job submission is needed.
Secondary allocator/process oopses followed before the machine rebooted.

That frame list is **hand-transcribed** — no timestamps, no `uname`, no
register state, and no committed source log — and it was taken on this
project's own 6.18 forward port, not on a vendor kernel. See the evidence-class
note at the top of this page before quoting it in a report.

## Root cause

The Rockchip helper validates only the first PFN:

```c
if (WARN_ON_ONCE(!pfn_valid(PHYS_PFN(phys_addr))))
	return -EINVAL;

for (i = 0; i < page_count; i++) {
	pages[i] = phys_to_page(addr);
	addr += PAGE_SIZE;
}
```

That check is insufficient for three reasons:

1. `pfn_valid()` means that the PFN has an associated `struct page`; it does not
   establish that the PFN is usable System RAM or safely accessible through the
   kernel linear mapping.
2. Only the first page is checked. A range can begin on a valid page and cross
   into a sparse-memory hole, reserved/no-map region, or wrapped address.
3. The range arithmetic is not overflow-checked. The nearby 32-bit-range test
   also uses unchecked `paddr + size` arithmetic.

The subsequent `dma_map_sg()` performs cache synchronization for what it
believes are ordinary RAM pages. With `0x1000`, that reaches the invalid ARM64
linear-map address `ffff000000001000`, producing the observed oops.

The `WARN_ON_ONCE()` makes a userspace validation failure look like a kernel
warning as well. Invalid ioctl input should be rejected with an errno without a
warning or stack dump.

## Rockchip branch history

The first three rows were inspected in the official Rockchip kernel repository
on 2026-07-16. The fourth row — `radxa/kernel`, the tree that actually ships on
a Rock 5B — was added 2026-07-29 after the original analysis was found to have
never covered it.

| Branch | Checked tip | Physical import implementation | Result |
|---|---|---|---|
| `develop-5.10` | `bfa51d2ab081` (2026-06-08) | Commit [`8d8595c96b10`](https://github.com/rockchip-linux/kernel/commit/8d8595c96b10f30a0a95ca500a6e64c206269bd0) replaces `dma_map_resource()` with a page array, sg-table, and `dma_map_sg()`, guarded only by the first-page `pfn_valid()` check. | Same import-time crash remains possible. Later 5.10 RGA work through April/June 2026 did not harden this helper. |
| `develop-6.1` | `b4ef083dc0c3` (2025-12-26) | Equivalent commit [`6e89da27bef6`](https://github.com/rockchip-linux/kernel/commit/6e89da27bef6c787175330d809d6f8ec9438a17d) adds the same helper and mapping path. | Same bug; this is the implementation inherited by the forward port. |
| `develop-6.6` | `1ba51b059f25` (2025-09-01) | Still calls `dma_map_resource(map_dev, phys_addr, size, ...)`; it never received the August 2025 `dma_map_sg()` conversion. | It avoids this specific import-time cache-sync oops, but it does not validate that the address names usable RAM and may accept a bogus address. It is an older unsafe path, not a fix. |
| `radxa/kernel` `linux-6.1-stan-rkr5.1` **(the shipping Rock 5B branch)** | `567401fe1718` (2026-04-21) | Predates the conversion entirely: `rga_mm_map_phys_addr()` (`rga_mm.c:678`) range-checks via `rga_mm_check_range_phys_addr()` (`:341`, called at `:711`) and maps with `rga_iommu_map()` (`:727`). No page array, no sg-table, no `dma_map_sg()` on this path. | **NOT AFFECTED.** Grepping every file under `drivers/video/rockchip/rga3/` on this branch for `pfn_valid\|phys_to_page` returns **zero hits** (verified 2026-07-29). Patch `0039` has nothing to fix here; a `radxa/kernel` PR would target a branch without the bug. |

A history search across the available Rockchip refs found the two commits above
adding `WARN_ON_ONCE(!pfn_valid(...))`, and no later commit removing or
strengthening it with `pfn_is_map_memory()`, `virt_addr_valid()`, checked range
arithmetic, or an equivalent validation predicate.

### Why the 6.6 path should not be restored

The kernel DMA API documents `dma_map_resource()` for MMIO resources; normal
RAM must use the page/sg mapping APIs. Restoring the 6.6 implementation would
avoid the immediate cache-maintenance dereference, but would retain unchecked
raw-address DMA and could move the failure to later IOMMU or device access.

The 6.6 helper also does this:

```c
ret = dma_mapping_error(map_dev, addr);
if (ret < 0)
	return ret;
```

`dma_mapping_error()` returns a boolean result, so testing it for `< 0` cannot
detect failure. That is a separate reason not to treat 6.6 as the corrected
implementation.

### Why the 2023 "sync cache causing crash" commit is unrelated

Rockchip commit
[`af706ad8bf10`](https://github.com/rockchip-linux/kernel/commit/af706ad8bf10478817df6a8824d7b3d653668100)
is titled `fix iommu device sync cache causing crash`, but it predates the
August 2025 `dma_map_sg()` physical-import conversion. It changes cache
synchronization for an already mapped buffer; it cannot prevent the initial
`dma_map_sg()` call from trying to synchronize a bogus page during import.

## Implemented forward-port hardening

The forward port keeps the page/sg mapping model and now rejects unsafe input
before the sg-table reaches the DMA layer:

1. Check physical-address and size arithmetic for overflow.
2. Validate every page in the complete byte range, not only the first page.
3. On ARM64, require each page to be normal linear-map System RAM, using
   `virt_addr_valid(phys_to_virt(addr))` or the underlying
   `pfn_is_map_memory()` predicate.
4. Return `-EINVAL` for an unusable page and an overflow errno for wrapped
   ranges; do not emit `WARN_ON_ONCE()` for userspace input.
5. Preserve the existing import ABI for valid BSP users while keeping the
   rewrite driver's deliberate `-EOPNOTSUPP` rejection of raw physical imports.

This validation prevents the observed crash, but raw physical-address import
remains a privileged and fragile ABI design: unlike dma-buf import, it provides
no ownership object that proves the caller is entitled to DMA to that memory.
Any future expansion should separately consider an authorization policy such
as `CAP_SYS_RAWIO`; that would be an ABI/policy change rather than part of the
minimal crash fix.

## Test containment

Raw physical-address generation is now opt-in — and it has never actually been
opted into. Every recorded ABI-replay run on this box prints
`physical_import_probe          disabled` (26 `norm`/`raw` logs across 13
distinct runs under the gitignored `kernel-drivers/tests/logs/abi-replay/`);
the probe appears enabled in none of them. The containment below is therefore
effective, but it also means no post-fix runtime evidence for this path exists.

| Harness | Explicit opt-in |
|---------|-----------------|
| `abi-probe.sh` | `ABI_PROBE_ENABLE_RGA_PHYSICAL=1` |
| `librga-smoke.sh` | `LIBRGA_SMOKE_ENABLE_PHYSICAL_PROBE=1` |
| `ioctl-fuzz-smoke.sh` | `IOCTL_FUZZ_ENABLE_RGA_PHYSICAL=1` |

The `PROFILE=*rewrite*` ABI replay and librga suite explicitly enable their
physical probe and require `-EOPNOTSUPP`, preserving the rewrite negative gate.
Setting either `*_EXPECT_*_PHYSICAL_REJECT=1` also enables the matching probe
for backward compatibility.

Do not enable raw physical probes on the published 20260716 forward kernel.
After the `.1` package containing `1c9a110129fe` is published, installed, and
booted,
capture a dmesg/ramoops baseline and run the targeted negative probe first:

```bash
ABI_PROBE_ENABLE_RGA_PHYSICAL=1 bash kernel-drivers/tests/abi-probe.sh
```

For the forward port, `0x1000` should return an error (normally `EINVAL`)
without a warning, oops, reboot, or new RGA/IOMMU fault. The rewrite profile
continues to require `EOPNOTSUPP`. Run the wider ABI, librga, fuzz, decode,
encode, and transcode suites only after that targeted gate and a clean dmesg.
A known-valid physical allocation should be tested only if a real compatibility
consumer requires that legacy ABI.
