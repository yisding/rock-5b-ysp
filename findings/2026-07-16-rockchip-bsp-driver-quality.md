# Rockchip BSP driver quality is feature-strong but below mature mainline robustness

> Scope: Rockchip `develop-6.1` BSP, with detailed inspection of RK3588
> MPP/RGA and representative DRM, clock/pinctrl/IOMMU/PHY, camera, and RKNPU
> samples; compared with mainline `rkvdec` and RGA at Linux `v7.2-rc2`
> Source: `rockchip-kernel@b4ef083dc0c3`,
> `linux-6.18-rkvenc-av1-fwport@1c9a110129fe`, and
> `linux@v7.2-rc2` (`8cdeaa50eae8`)
> Date: 2026-07-16
> Trust: CODE-INSPECTED / SOURCE-INSPECTED / MEASURED / INFERRED for the
> comparative ratings

## Result

The Rockchip BSP is strong hardware-enablement code but its BSP-only
accelerator stacks are below mature mainline-driver quality in hostile-input
validation, resource lifetime handling, kernel-framework integration, public
review traceability, and cross-branch maintenance.

It is appropriate to describe the MPP/RGA stack as usable for a fixed appliance
with trusted userspace, but not as a generally safe unprivileged kernel ABI.
Access to `/dev/mpp_service` and `/dev/rga` is a security boundary. This does
not justify calling every Rockchip driver poor: upstream-derived/framework-led
areas such as DRM are materially closer to normal mainline quality.

The comparative score is therefore deliberately split by dimension:

| Dimension | Assessment |
|---|---|
| Hardware and feature coverage | A- |
| Fixed-board functional reliability | B |
| Kernel-framework integration | C- |
| Maintainability | C- |
| Security and hostile-input robustness | D |
| Upstream readiness | D+ |
| Overall for a trusted appliance | B- |
| Overall against mature mainline drivers | C- |

These grades are reasoned judgments, not measurements. The evidence below is
the durable part of the finding.

## Evidence and reproduction

- **Identity:** Rockchip BSP `develop-6.1@b4ef083dc0c3`, based on the inspected
  upstream-stable `Linux 6.1.141@58485ff1a74f`; current RK3588 forward port
  `1c9a110129fe`; mainline comparison `v7.2-rc2@8cdeaa50eae8`.
- **Detection:** direct inspection of the named source trees, the existing BSP
  audit, current forward-port status, current-kernel `checkpatch.pl`, and Git
  history/trailer counts.
- **Exercise:** inspect the functions and run the source/style/history commands
  recorded below.
- **Pass/fail signal:** the source contains the named unsafe paths; the
  comparison drivers use standard subsystem lifetimes and validate requests
  through framework entry points; commands reproduce the recorded counts.
- **Artifacts:** none beyond the named Git trees and the committed YSP audit,
  comparison, validation, and crash documents.

### Directly confirmed MPP/RGA defects

The current `1c9a110129fe` forward-port source still contains several of the
high-impact BSP audit paths:

1. `mpp_common.c:mpp_collect_msgs()` accepts an arbitrary fd, assigns
   `fd_file(f)->private_data` to a `struct mpp_session *`, and “validates” it by
   comparing that value with itself. There is no `f_op`/device-type check before
   dereferencing the resulting session. This is a device-node-authorized
   type-confusion path.
2. `mpp_rkvdec2.c:mpp_set_rcbbuf()` reads `reg_idx` from a userspace-derived RCB
   descriptor and writes `task->reg[reg_idx]` without bounding the index against
   the register array.
3. `mpp_common.c:mpp_check_req()` handles an overrun by assigning the overflow
   amount (`req_off + req->size - max_size`) rather than the remaining valid
   size. `mpp_extract_reg_offset_info()` also derives an element count by
   division but copies the original byte count, so a non-multiple size can copy
   beyond the accepted element count.
4. `mpp_rkvdec2.c:rkvdec2_ccu_probe()` tests `devm_clk_get()` and
   `devm_reset_control_get()` results as NULL/non-NULL rather than with
   `IS_ERR()`, allowing error pointers to be retained and used.

The full [`BSP audit`](../kernel-drivers/docs/bsp-audit.md) records 89 reviewer
rows across 15 MPP/RGA files. Its own count note says these collapse to roughly
70 distinct `file:line` sites because the three review lenses duplicated some
findings. The reported 16 HIGH rows must therefore not be represented as 16
unique vulnerabilities. The examples above were separately re-read in the
current source and are sufficient to establish that the safety gap is real.

RGA also supplied runtime evidence rather than only static findings. A raw
physical import of address `0x1000` reached DMA cache maintenance through a
bogus arm64 direct-map alias and crashed the kernel. Forward-port commit
`1c9a110129fe` now validates every page with
`virt_addr_valid(phys_to_virt(addr))`, but valid System-RAM physical imports
remain available without `CAP_SYS_RAWIO`; see
[`RGA raw physical-address import crash`](../kernel-drivers/rga/raw-physical-import-crash.md).

### Framework and attack-surface comparison

The quality difference is structural, not primarily formatting:

| Area | BSP MPP/RGA | Mature/mainline comparison |
|---|---|---|
| Userspace ABI | private character-device ioctls | standard V4L2/media/DRM ABIs |
| Scheduling | custom MPP task queues and RGA request/policy scheduler | V4L2 mem2mem/media requests or DRM scheduler/framework ownership |
| Buffer lifetime | custom fd cache, handles, userptr, raw physical paths, dma-buf and private IOMMU glue | vb2/dma-buf/GEM framework lifetimes with narrower import modes |
| Job description | broad register/message ABI or large custom RGA request | typed V4L2 controls, queued buffers, and request validation |
| Probe/unwind | mixed devm and handwritten unwind, with verified leak/error-pointer bugs | predominantly managed resources and conventional subsystem cleanup |
| Feature breadth | broad codec/RGA/product surface | narrower hardware surface, especially mainline RGA |

Mainline `drivers/media/platform/rockchip/rkvdec/rkvdec.c` illustrates the
contrast. `rkvdec_request_validate()` admits exactly one vb2 buffer and then
delegates to `vb2_request_validate()`. Queue ownership is expressed through
`vb2_ops`, V4L2 mem2mem, media requests, and runtime PM. Its probe uses managed
allocation, bulk enabled clocks, managed MMIO mappings, and a managed IRQ.

This narrower standard contract does not prove the mainline driver bug-free,
but it removes large classes of bespoke parser, fd-cache, scheduler, fence, and
buffer-handle lifetime code that the BSP must get right itself.

### Mechanical style sample

The Linux `v7.2-rc2` `scripts/checkpatch.pl` was run with
`--no-tree --terse --show-types -f` on existing C files. This is only a
maintenance/style signal; it is not a correctness or security analyzer.

| Sample | C lines | Errors | Warnings |
|---|---:|---:|---:|
| BSP MPP six-file RK3588 runtime subset | 12,176 | 0 | 8 |
| BSP RGA3, all C files | 15,763 | 0 | 101 |
| BSP RKNPU, all C files | 7,457 | 0 | 68 |
| BSP camera `isp/dev.c` + `cif/dev.c` | 4,702 | 0 | 31 |
| BSP clock/pinctrl/IOMMU/PHY sample | 11,152 | 1 | 24 |
| BSP DRM driver/GEM/VOP2 sample | 21,329 | 0 | 0 |
| Mainline `rkvdec`, all C files | 9,357 | 0 | 0 |
| Mainline Rockchip RGA, all C files | 2,341 | 0 | 0 |

The RGA/RKNPU/camera warnings are dominated by mechanical maintenance issues
such as `LINUX_VERSION_CODE` conditionals, constant comparisons, deprecated
APIs, allocation spelling, and redundant OOM messages. Conversely, MPP's low
warning count alongside serious correctness bugs demonstrates why this result
must not be treated as a safety score. The clean BSP DRM sample demonstrates
that BSP quality is not uniform.

The exact MPP sample was:

```text
mpp_common.c mpp_iommu.c mpp_service.c
mpp_rkvenc2.c mpp_rkvdec2.c mpp_rkvdec2_link.c
```

The DRM sample was `rockchip_drm_drv.c`, `rockchip_drm_gem.c`, and
`rockchip_drm_vop2.c`. The core sample was `clk-rk3588.c`,
`pinctrl-rockchip.c`, `rockchip-iommu.c`, and
`phy-rockchip-snps-pcie3.c`. Its single checkpatch error was spacing in
`rockchip-iommu.c`; most warnings were unspecified `int` bitfield declarations.

### Public review traceability

Git trailer counts provide a process signal, not proof of review quality:

| History range | Commits touching path | `Reviewed-by` | `Tested-by` | `Signed-off-by` |
|---|---:|---:|---:|---:|
| BSP `58485ff1a74f..b4ef083dc0c3`, `drivers/video/rockchip/rga3` | 374 | 0 | 0 | 365 |
| Mainline `v6.18..v7.2-rc2`, `drivers/media/platform/rockchip/rkvdec` | 29 | 27 | 23 | 88 |

These are trailer totals, so a commit can contribute multiple trailers. The BSP
may have internal review and hardware qualification that are not recorded in
Git, but its public history does not make that review independently traceable
the way the mainline history does.

### Maintenance fragmentation

The pinned three-branch comparison shows that Rockchip's 6.6 MPP/RGA tree is
not a newer architecture than 6.1. The public ioctl headers are identical and
MPP differs by only 36 edited lines. Meanwhile, the numerically older 5.10
branch contains later RGA work absent from both 6.1 and 6.6, including
sequential hardware batching, request/fence lifecycle fixes, low-voltage
workarounds, and memory/IOMMU corrections. See
[`forward port vs Rockchip 5.10/6.1/6.6`](../kernel-drivers/docs/bsp-6.1-6.6-comparison.md).

That branch topology makes a kernel-version number a poor proxy for driver
quality and increases the chance that a security or correctness fix exists in
only one product branch.

### Functional strengths

The quality verdict must not erase what the BSP does well:

- it enables substantially more RK3588 functionality than the corresponding
  mainline paths, including multicore codec operation, encoding, the vendor AV1
  path, broad RGA composition/format support, and product-specific memory and
  power integration;
- its code has recognizable service/session/task/backend and
  request/policy/memory/fence layering rather than being an undifferentiated
  hardware dump; and
- the YSP forward port has hardware evidence for multicore H.264/H.265 encode,
  bit-exact H.264/H.265/VP9/AV1 decode, functional RGA, and hardware transcode.
  See [`forward-port status`](../kernel-drivers/docs/forward-port-status.md).

These results establish useful fixed-platform behavior. They do not exercise
every malformed ioctl, allocation failure, concurrency race, removal path, or
IOMMU fault path.

## Boundary

This is not an exhaustive audit of the approximately 5,939 changed files and
3.5 million added lines in the Rockchip BSP. The conclusion is strongest for
MPP/RGA, for which the repository has a detailed audit and direct hardware
evidence. RKNPU, camera, core Rockchip drivers, and DRM were sampled for style
and architecture but were not reviewed with the same path-by-path depth.

The ratings compare against mature in-tree driver expectations, not against a
survey of other vendors' BSP kernels. No claim is made that Rockchip is uniquely
poor among silicon-vendor product kernels.

Checkpatch counts do not measure correctness. Git trailers do not reveal
unrecorded internal review. Existing YSP hardware results were inspected but
not re-run for this finding. Mainline RGA has a much narrower feature contract,
so its smaller and cleaner source cannot be treated as feature parity with the
vendor `/dev/rga` implementation.

The current forward port includes material RGA, IOMMU, AV1, fault-containment,
and buffer-validation hardening beyond the original BSP. It nevertheless
retains the directly confirmed MPP defects above and should not be described as
having absorbed the separate BSP cleanup audit series.

## Why it matters / follow-up

1. Keep `/dev/mpp_service` and `/dev/rga` restricted to trusted workloads; the
   `video` group is a security boundary, not merely a convenience group.
2. Prioritize session-fd type validation, every userspace-derived size/index,
   RGA refcount/fence paths, sleep-in-atomic findings, probe unwind, and raw
   physical imports.
3. Repair the cleanup split series' patch-0024 compile defect, obtain human
   review of refcount/bounds/security edits, then run its still-missing booted
   encode/decode/transcode and targeted-trigger regression gate.
4. Use KASAN/KCSAN, allocation and usercopy fault injection, and syzkaller-style
   ioctl tests before describing the private ABIs as production-safe.
5. Prefer standard V4L2/DRM drivers where their feature coverage is sufficient;
   retain the BSP ABI as a compatibility path for hardware features not yet
   represented by the upstream interfaces.

The cleanup compile/runtime gap is already tracked in `status.md`; this finding
does not add a separate watchlist item.
