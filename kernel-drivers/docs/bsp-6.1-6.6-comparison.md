# Forward port vs Rockchip 6.1 and 6.6 BSP media drivers

Direct source comparison of the RK3588 MPP and RGA driver lineages. This note
answers two separate questions that are easy to conflate:

1. how much the original Linux 6.18 forward port changed its Rockchip donor;
2. whether Rockchip's `develop-6.6` branch contains a materially newer media
   architecture than `develop-6.1`.

> **Result.** The original forward port is a narrowly adapted copy of the 6.1
> BSP implementation, not a redesign. Rockchip's 6.6 MPP/RGA stack has the same
> architecture and the same public ioctl headers. Its MPP implementation differs
> from 6.1 by only 36 edited lines. RGA differs more, but primarily because the
> current 6.1 branch contains later 2025 fixes that never reached the older 6.6
> snapshot. The newer AV1/IOMMU forward-port branch adds significant mapping,
> shared-domain, fault-recovery, and buffer-validation work, while retaining the
> BSP task, scheduler, and register-generation model.

## Compared revisions

The two Rockchip branch tips were verified against the official remote with
`git ls-remote` on 2026-07-16.

| Name | Revision | Role |
|------|----------|------|
| Rockchip 6.1 BSP | `rockchip-linux/kernel develop-6.1@b4ef083dc0c3608e744deabb43dc6b781aadbe6e` | Original MPP/RGA donor and byte-level oracle |
| Rockchip 6.6 BSP | `rockchip-linux/kernel develop-6.6@1ba51b059f25533c5529b7f68186190b47d6a7b3` | Vendor 6.6 comparison snapshot |
| Baseline forward-port import | `linux-rock5b@924f4232546d` | The non-AV1 driver import represented by `patches/rk3588-rkvenc2-01-...patch` |
| Current forward-port superset | `linux-rock5b rkvenc-fwport-6.18@18fae9957686` | AV1, shared-domain IOMMU, recovery, RGA userptr, and RCB hardening series |

The distinction between the last two rows matters. The quantitative
[`vendor-delta.md`](./vendor-delta.md) result belongs to the baseline non-AV1
port. The newer split series is summarized in
[`patches/forward-port-rk3588-av1/`](../patches/forward-port-rk3588-av1/README.md)
and intentionally has a larger delta.

## Measurement method

All counts below are direct Git tree or `--no-index` diffs. "Forward-side lines
differing" means the `+` count when diffing `BSP -> forward-port`: a modified
line is counted once on the forward side, and a new line is counted once. It is
not a net line-count change.

The official branch identities can be rechecked with:

```sh
git ls-remote https://github.com/rockchip-linux/kernel.git \
    refs/heads/develop-6.1 refs/heads/develop-6.6
```

The direct BSP comparison was measured with:

```sh
git diff --numstat b4ef083dc0c3 1ba51b059f25 -- \
    drivers/video/rockchip/mpp drivers/video/rockchip/rga3
git diff b4ef083dc0c3 1ba51b059f25 -- \
    include/uapi/linux/rk-mpp.h drivers/video/rockchip/rga3/include/rga.h
```

The forward-port comparisons used only matching runtime files when reporting
the focused MPP/RGA counts. Deleting an unported BSP block is a scope decision,
not an edit to that block, so legacy VDPU/VEPU, JPEG, IEP, and VDPP files were
not allowed to dominate the like-for-like figures.

## Rockchip 6.1 vs Rockchip 6.6

### Quantitative result

| Subtree | Files changed | 6.6 additions | 6.6 deletions | Total edited lines |
|---------|--------------:|--------------:|--------------:|-------------------:|
| `drivers/video/rockchip/mpp/` | 6 | 14 | 22 | 36 |
| `drivers/video/rockchip/rga3/` | 13 | 258 | 364 | 622 |

The public headers are byte-identical:

| Header | 6.1 blob | 6.6 blob |
|--------|----------|----------|
| `include/uapi/linux/rk-mpp.h` | `9a24407001ec6a15ffce51f0294b26bf3ac41e7d` | same |
| `drivers/video/rockchip/rga3/include/rga.h` | `671867b22371b4931c989fc08c9209c9dfa2b81d` | same |

There is therefore no 6.1-to-6.6 MPP or RGA userspace ABI migration.

### MPP differences

Most of the 36 edited lines are kernel-API adjustments already required by the
forward port:

- `iommu_map()` gains the `GFP_KERNEL` argument;
- `class_create()` loses its `THIS_MODULE` argument.

Only two changes materially affect MPP runtime behavior:

- The current 6.1 code has the later RKVENC2 watchdog fix: VEPU510 uses the
  256-cycle formula while other encoder generations use the 1024-cycle formula.
  The 6.6 snapshot still applies the 256-cycle multiplier to every generation.
- The current 6.1 service clears stale load accounting when the measurement
  interval expires or no sessions remain. That cleanup is absent from 6.6;
  codec execution is unchanged, but procfs load values can remain stale.

The session/taskqueue model, RKVENC2/RKVDEC2 backends, CCU/DCHS model, register
transport, dma-buf ABI, and polling protocol are otherwise the same.

### RGA differences

The RGA delta is real but is not an architectural replacement. It mostly shows
that the live 6.1 branch received media commits after the 6.6 branch stopped.
The two BSP branches share a merge base at `243363ccfdc2` dated 2025-07-30;
`develop-6.6@1ba51b0` is dated 2025-09-01, while the current 6.1 branch contains
RGA fixes through December 2025.

| Area | Current 6.1 / baseline forward port | 6.6 snapshot |
|------|-------------------------------------|--------------|
| Command buffers | Per-scheduler DMA pool, with optional preallocated genpool | One coherent allocation per submitted job |
| Physical-address import behind an IOMMU | Build pages/sg-table and use `dma_map_sg()` | Use `dma_map_resource()` directly |
| 10-bit YUV422 sizing | Correct 20-bit accounting | Shares the 15-bit 420 calculation |
| RGA2 10-bit YUV422 | Includes the later read-path fix | Fix absent |
| RGA3 compact/endian control | Userspace can change raster 10-bit compact/endian mode | Older condition can retain the forced setting |
| Legacy global alpha | Foreground/background assignment typo fixed | Older duplicate-background assignment |
| Kernel MPI 90/270 rotation | Swaps destination active width/height | Older dimensions retained |
| Virtual-buffer physical offset | Includes the page-offset correction | Older base address behavior |
| Driver version | `1.3.11` | `1.3.10` |

These differences can surface in physical-address imports, special 10-bit RGA
profiles, legacy alpha composition, the in-kernel MPI interface, and allocation
pressure. Ordinary dma-buf blits still pass through the same global
`rga_drvdata`, policy scheduler, memory manager, backend vtable, and RGA2/RGA3
register emitters.

## Baseline forward port vs each BSP

The baseline import remains overwhelmingly a 6.1-derived driver. Focused
runtime-file counts are:

| Baseline comparison | Forward-side MPP lines differing | Forward-side RGA lines differing |
|---------------------|---------------------------------:|---------------------------------:|
| Against 6.1 BSP | 141 | 39 |
| Against 6.6 BSP | 151 | 380 |

The larger RGA distance from 6.6 is almost entirely the vendor 6.1-versus-6.6
branch delta above. Against 6.1, the complete baseline accounting remains about
578 local lines out of 34,999 code/build lines: approximately 98% vendor code.

The meaningful baseline changes are integration changes:

- post-6.1 kernel API adaptations;
- compatibility stubs for BSP-only OPP, system-monitor, PMU, DMC, SIP, and QoS
  services;
- fixed-rate clocks instead of the full BSP PVTM/devfreq stack;
- RK3588 CCU probe deferral/publication and compatible matching fixes;
- Kconfig/Makefile wiring for the mainline/Armbian tree;
- deliberate omission of legacy MPP blocks outside the Rock 5B target.

They do not replace the BSP task model, codec backend organization, or RGA
command generators.

## Current AV1/IOMMU forward-port superset

The current `rkvenc-fwport-6.18@18fae9957686` branch should not be described by
the original 1.7% figure without qualification. Against the BSP runtime files:

| Current comparison | Forward-side MPP lines differing | Forward-side RGA lines differing |
|--------------------|---------------------------------:|---------------------------------:|
| Against 6.1 BSP | 1,837 across the selected MPP+AV1 files | 584 |
| Against 6.6 BSP | 1,847 across the selected MPP+AV1 files | 917 |

Those larger counts come from targeted functionality and hardening rather than
a new media-driver architecture:

- RKMPP AV1 plus the Verisilicon IOMMU provider;
- provider-local Rockchip/VSI IOMMU fault callbacks;
- explicit shared IOMMU domains for encoder/decoder CCU clusters;
- RCB fixed-window overlap checks and reset-time domain verification;
- reset-error propagation and recovery containment;
- full dma-buf span and 32-bit IOVA checks;
- restored large DMA-segment support in the Rockchip provider;
- an RGA 32-bit plane-offset wrap guard;
- contiguous IOMMU mapping for scattered RGA userptr buffers;
- optional encoder RCB SRAM.

The current MPP header is also a backward-compatible superset of both BSP
headers. It adds `MPP_CMD_SET_ERR_REF_HACK`, defines
`MPP_FLAGS_REG_OFFSET_ALONE` as the name/alias for bit `0x10`, and adds
`MPP_FLAGS_POLL_NON_BLOCK` (`0x20`). The current forward port implements
nonblocking generic and encoder-slice polling with `-EAGAIN`. It advertises
`SET_ERR_REF_HACK` and accepts it through the codec backend's unknown-command
no-op path; the rewrite is stricter and explicitly validates then discards its
payload.

RGA's public `rga.h` remains byte-identical to both BSP branches, and its RGA2
and RGA3 command emitters remain the 6.1 implementations. The current RGA
changes concentrate in DMA/IOMMU mapping, fault handling, and address safety.

## Significance

| Question | Verdict |
|----------|---------|
| Is the forward port a rewritten MPP/RGA architecture? | **No.** It retains the vendor service, taskqueue, policy, memory-manager, backend, and register-emission design. |
| Is Rockchip 6.6 a newer media architecture than 6.1? | **No.** The ABI and object model are the same. |
| Is 6.6 the better donor merely because its kernel is newer? | **No.** Its media snapshot misses later fixes present on `develop-6.1`. |
| Are there meaningful runtime differences? | **Yes**, in watchdog timing, special RGA formats/imports, command-buffer allocation, IOMMU topology, fault recovery, and AV1 scope. |
| Will ordinary H.264/H.265 and common dma-buf RGA jobs use different codec/image algorithms? | **Generally no.** The userspace register recipes and vendor command generators remain the same lineage. |

For resync work, use the pinned 6.1 tree as the byte-lineage oracle, use 6.6 as
an additional kernel-API/reference snapshot, and review the current
forward-port hardening as a separate local series. Replacing the donor with the
6.6 media subtree wholesale would regress the later 6.1 RGA fixes without
providing a new architecture.
