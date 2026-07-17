# RGA raw-physical import crash and hardening

## Result

The 2026-07-16 forward-port test crash was caused by the BSP-derived RGA3
`RGA_IOC_IMPORT_BUFFER` physical-address path, not by an RGA hardware job. The
ABI probe supplied physical address `0x1000`; the driver converted it to a
`struct page`, built a scatterlist, and let `dma_map_sg()` perform cache
maintenance through the bogus arm64 direct-map alias `ffff000000001000`.

Forward-port commit `1c9a110129fe` hardens this path. It is represented by
patch `0039` in [`patches/forward-port-rk3588-av1`](../patches/forward-port-rk3588-av1/README.md).
The kernel installed before this commit remains vulnerable until a rebuilt
package is installed and booted.

## Crash evidence

The previous-boot journal records the ABI probe process faulting in this call
chain:

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

The first fault was an arm64 kernel paging request at
`ffff000000001000`. Secondary allocator/process faults followed roughly 34
seconds later, then the machine rebooted without an orderly shutdown. The
trigger was the probe in `tests/abi-probe.c`, which used raw physical address
`0x1000`, size `4096`, and type `RGA_PHYSICAL_ADDRESS` without submitting an
RGA job.

## Root cause

The imported helper checked only the first PFN:

```c
if (WARN_ON_ONCE(!pfn_valid(PHYS_PFN(phys_addr))))
	return -EINVAL;
```

It then called `phys_to_page()` for every page without validating the rest of
the range. `pfn_valid()` means that a `struct page` exists; it does not promise
that the PFN is mapped, usable System RAM. Sparse-memory holes and reserved
`no-map` regions can therefore pass that test. On arm64, DMA cache maintenance
later dereferences the direct-map alias derived from the scatterlist page and
can fault before the IOMMU mapping is established.

This behavior came from Rockchip's later BSP change that replaced
`dma_map_resource()` with `dma_map_sg()`. Restoring `dma_map_resource()` is not
a valid fix: the DMA API reserves it for MMIO resources and forbids using it to
map normal RAM.

## Kernel fix

The hardening patch:

1. rejects a byte range whose inclusive end overflows `phys_addr_t`;
2. validates every page before constructing the scatterlist;
3. uses `virt_addr_valid(phys_to_virt(addr))`, which on arm64 reaches
   `pfn_is_map_memory()` and rejects holes/`no-map` ranges;
4. detects overflow while advancing through pages; and
5. removes the user-triggerable `WARN_ON_ONCE()`.

Valid mapped System RAM, including ordinary CMA-backed memory, keeps the BSP
physical-import ABI. Invalid addresses now fail before `dma_map_sg()` and its
cache synchronization. The patch deliberately does not add a `CAP_SYS_RAWIO`
check because that would change the BSP ABI. Consequently, access to `/dev/rga`
remains a security boundary: a caller that knows a valid System-RAM physical
range can still request the legacy import.

## Test-harness containment

Raw physical-address generation is disabled by default, even though these
probes do not submit hardware work:

| Harness | Explicit opt-in |
|---------|-----------------|
| `abi-probe.sh` | `ABI_PROBE_ENABLE_RGA_PHYSICAL=1` |
| `librga-smoke.sh` | `LIBRGA_SMOKE_ENABLE_PHYSICAL_PROBE=1` |
| `ioctl-fuzz-smoke.sh` | `IOCTL_FUZZ_ENABLE_RGA_PHYSICAL=1` |
| syzkaller draft | separate `ioctl$rga_import_physical`, marked `disabled, no_generate` |

The `PROFILE=*rewrite*` ABI replay and librga suite explicitly enable their
physical probe and require `-EOPNOTSUPP`, preserving the rewrite's negative ABI
gate. Setting either `*_EXPECT_*_PHYSICAL_REJECT=1` also enables the matching
probe for backward compatibility. The syzlang ABI-marker check now uses
`ABI_PROBE_ABI_ONLY=1`, so its advertised device-free mode emits compile-time
constants without opening either device node.

Do not enable raw physical probes on the published
`6.18.38+rk3588av1fwport20260716` kernel. Re-enable them only after booting a
kernel containing `1c9a110129fe`, preferably with ramoops and readable dmesg.

## Runtime gate for the rebuilt kernel

After packaging, installation, and reboot, confirm the running build contains
the patch, capture a before-dmesg/ramoops baseline, and run only the targeted
negative probe first:

```bash
ABI_PROBE_ENABLE_RGA_PHYSICAL=1 bash kernel-drivers/tests/abi-probe.sh
```

For the forward port, the `0x1000` import should return an error (normally
`EINVAL`) without a warning, oops, reboot, or new RGA/IOMMU fault. The rewrite
profile continues to require `EOPNOTSUPP`. Only after this targeted gate and a
clean dmesg should the wider ABI, librga, fuzz, decode, encode, and transcode
suites run.
