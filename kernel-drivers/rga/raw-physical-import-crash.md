# RGA raw physical-address import crash

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

Here, **Rockchip BSP** means Rockchip's out-of-tree vendor `rga3` driver. It does
not mean the smaller RGA driver in mainline Linux.

Forward-port commit `1c9a110129fe` now implements the minimal crash fix. It is
represented by patch `0039` in
[`patches/forward-port-rk3588-av1`](../patches/forward-port-rk3588-av1/README.md).
The published `6.18.38+rk3588av1fwport20260716` package predates that commit
and remains vulnerable until a rebuilt package is installed and booted.

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

The branches and commits below were inspected in the official Rockchip kernel
repository on 2026-07-16.

| Branch | Checked tip | Physical import implementation | Result |
|---|---|---|---|
| `develop-5.10` | `bfa51d2ab081` (2026-06-08) | Commit [`8d8595c96b10`](https://github.com/rockchip-linux/kernel/commit/8d8595c96b10f30a0a95ca500a6e64c206269bd0) replaces `dma_map_resource()` with a page array, sg-table, and `dma_map_sg()`, guarded only by the first-page `pfn_valid()` check. | Same import-time crash remains possible. Later 5.10 RGA work through April/June 2026 did not harden this helper. |
| `develop-6.1` | `b4ef083dc0c3` (2025-12-26) | Equivalent commit [`6e89da27bef6`](https://github.com/rockchip-linux/kernel/commit/6e89da27bef6c787175330d809d6f8ec9438a17d) adds the same helper and mapping path. | Same bug; this is the implementation inherited by the forward port. |
| `develop-6.6` | `1ba51b059f25` (2025-09-01) | Still calls `dma_map_resource(map_dev, phys_addr, size, ...)`; it never received the August 2025 `dma_map_sg()` conversion. | It avoids this specific import-time cache-sync oops, but it does not validate that the address names usable RAM and may accept a bogus address. It is an older unsafe path, not a fix. |

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

Raw physical-address generation is now opt-in:

| Harness | Explicit opt-in |
|---------|-----------------|
| `abi-probe.sh` | `ABI_PROBE_ENABLE_RGA_PHYSICAL=1` |
| `librga-smoke.sh` | `LIBRGA_SMOKE_ENABLE_PHYSICAL_PROBE=1` |
| `ioctl-fuzz-smoke.sh` | `IOCTL_FUZZ_ENABLE_RGA_PHYSICAL=1` |
| syzkaller draft | separate `ioctl$rga_import_physical`, marked `disabled, no_generate` |

The `PROFILE=*rewrite*` ABI replay and librga suite explicitly enable their
physical probe and require `-EOPNOTSUPP`, preserving the rewrite negative gate.
Setting either `*_EXPECT_*_PHYSICAL_REJECT=1` also enables the matching probe
for backward compatibility. The syzlang ABI-marker check uses
`ABI_PROBE_ABI_ONLY=1`, so its device-free mode emits compile-time constants
without opening either device node.

Do not enable raw physical probes on the published 20260716 forward kernel.
After a rebuilt package containing `1c9a110129fe` is installed and booted,
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
