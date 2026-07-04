# AV1 BSP audit — forward-port findings

This tracks the BSP defects found while forward-porting Rockchip's RK3588 AV1
MPP backend into the experimental 6.18 worktree. It is the AV1-specific
companion to [the main BSP audit](../../docs/bsp-audit.md), which covers the validated
RKVENC2/RKVDEC2/RGA forward-port.

Port-only issues found after the BSP audit, such as VSI provider lookup,
fault-masking, and reset-unwind bugs introduced by the 6.18 integration, are
tracked separately in [the forward-port review log](../../../kernel-versions/docs/forward-port-review-log.md).

> **Status:** these fixes currently live in the experimental AV1 worktree. They
> are not yet packaged as a YSP split patch series, and they have not had the
> same runtime gate as the validated encoder/decoder work.

## Scope and pins

| Item | Value |
|------|-------|
| Donor BSP | `../rockchip-kernel` |
| Forward-port worktree | `../linux-6.18-rkvenc-av1-fwport` |
| Branch | `rkvenc-fwport-6.18` |
| Primary BSP file | `drivers/video/rockchip/mpp/mpp_av1dec.c` |
| Imported IOMMU provider | `drivers/iommu/vsi-iommu.c` from `../linux`, not the BSP private `rockchip-iommu-av1d.c` path |
| Audit date | 2026-07-03 |

Line numbers below are against the experimental AV1 worktree after the first
forward-port hardening pass. The "donor anchor" column names the original BSP
site when the issue is inherited from Rockchip's `mpp_av1dec.c`.

## Origin summary

| Origin | Count | Notes |
|--------|-------|-------|
| Inherited from BSP `mpp_av1dec.c` | 7 | Register request splitting, bounds, FD translation, and ISR assumptions were already present in the donor driver. |
| Forward-port/API compatibility | 6 | 6.18 callback/config/build issues introduced by moving BSP code into this tree, plus use of local compat wrappers where BSP-only APIs are absent. |
| Hybrid integration hardening | 9 | Issues in the imported upstream-style VSI IOMMU provider and the RKMPP/VSI DT split; not findings against the BSP AV1 MPP driver itself. |
| DT/Kconfig integration | 2 | Base RK3588 Hantro/VSI topology and provider selection must stay complete while ROCK 5B retypes the consumer to RKMPP. |
| Pre-existing branch/packaging dependency | 1 | ROCK 5B DTB still depends on Armbian media labels unrelated to AV1. |

## Findings

| ID | Sev | Origin | Site | Donor anchor | Status |
|----|-----|--------|------|--------------|--------|
| AV1-BSP-001 | high | BSP | `mpp_av1dec.c` `w_reqs[]`/`r_reqs[]` and `av1dec_extract_task_msg()` | donor `mpp_av1dec.c:133-136`, `:331-359` | Fixed in worktree |
| AV1-BSP-002 | high | BSP | `av1dec_extract_task_msg()` copies split writes using the unsplit request offset | donor `mpp_av1dec.c:335-341` | Fixed in worktree |
| AV1-BSP-003 | high | BSP | register request offset/size arithmetic is unchecked | donor `mpp_av1dec.c:234-249`, `:280-298` | Fixed in worktree |
| AV1-BSP-004 | medium | BSP | class bounds check uses `>` instead of `>=` | donor `mpp_av1dec.c:241`, `:287` | Fixed in worktree |
| AV1-BSP-005 | medium | BSP | FD translation loop reuses the outer index and translates by write request instead of valid class | donor `mpp_av1dec.c:417-447` | Fixed in worktree |
| AV1-BSP-006 | medium | BSP | `mpp_extract_reg_offset_info()` return value ignored | donor `mpp_av1dec.c:362-364` | Fixed in worktree |
| AV1-BSP-007 | medium | BSP | ISR derives `task`/`regs` before checking `mpp->cur_task` | donor `mpp_av1dec.c:641-653` | Fixed in worktree |
| AV1-FW-001 | low | forward-port | `platform_driver.remove` must return `void` on 6.18 | donor returns `int` | Fixed in worktree |
| AV1-FW-002 | low | forward-port | procfs guard must match `CONFIG_ROCKCHIP_MPP_PROC_FS`, and that Kconfig must depend on `PROC_FS` | donor uses `CONFIG_PROC_FS` | Fixed in worktree |
| AV1-FW-003 | cleanup | forward-port | forced include path defines `pr_fmt` before imported BSP files | not a donor runtime bug | Fixed in worktree |
| AV1-FW-004 | medium | forward-port | AV1 reset must use `mpp_pmu_idle_request()` instead of calling the missing BSP PMU-idle API directly | `mpp_av1dec.c:922`, `:928` | Fixed in worktree |
| AV1-FW-005 | medium | forward-port | ROCK 5B AV1 reset reaches the PMU-idle no-op unless the node explicitly opts out | `mpp_av1dec.c:922`, `rk3588-rock-5b.dtsi` AV1 override | Fixed in worktree |
| AV1-FW-006 | low | forward-port | RKVENC2 devfreq code was still gated by bare `CONFIG_PM_DEVFREQ` instead of the local tier knob | `mpp_rkvenc2.c` devfreq guards | Fixed in worktree |
| AV1-VSI-001 | medium | hybrid integration | VSI IRQ path must not call sleeping runtime-PM resume from hard IRQ | `vsi-iommu.c:192-220` | Fixed in worktree |
| AV1-VSI-002 | medium | hybrid integration | VSI IRQ fault reporting must tolerate no paging domain / identity domain | `vsi-iommu.c:206-214` | Fixed in worktree |
| AV1-VSI-003 | high | hybrid integration | duplicate map failure must unwind partial PTE writes and return an error, not a bogus partial success | `vsi-iommu.c:347-380` | Fixed in worktree |
| AV1-VSI-004 | medium | hybrid integration | map/unmap need a real `.flush_iotlb_all` implementation without self-deadlocking the domain lock | `vsi-iommu.c:383-419`, `:675-691` | Fixed in worktree |
| AV1-VSI-005 | medium | hybrid integration | identity-domain attach/resume/enable paths must not cast identity domain through `to_vsi_domain()` | `vsi-iommu.c:532-580`, `:783-803` | Fixed in worktree |
| AV1-VSI-006 | high | hybrid integration | two-argument attach adaptation must remove `iommu->node` under the old paging-domain list lock before identity/new-domain attach | `vsi-iommu.c:532-648` | Fixed in worktree |
| AV1-VSI-007 | high | hybrid integration | TLB flush skipped already-active providers when runtime-PM usage count was zero | `vsi-iommu.c:383-405` | Fixed in worktree |
| AV1-VSI-008 | medium | hybrid integration | release-domain identity attach could fail on PM resume even though the 6.18 core ignores that return during release | `vsi-iommu.c:532-576`, `iommu_ops.release_domain` | Fixed in worktree |
| AV1-VSI-009 | medium | hybrid integration | `VSI_IOMMU=m` was allowed without a remove path for `iommu_device_unregister()`/runtime-PM cleanup | `drivers/iommu/Kconfig`, `vsi-iommu.c` platform driver | Fixed by making provider built-in-only |
| AV1-DT-001 | medium | DT/Kconfig integration | shared Hantro `av1d` node must keep `iommus = <&av1d_mmu>` and the base `av1d_mmu` provider must not be left disabled | `rk3588-base.dtsi:1421-1443` | Fixed in worktree |
| AV1-DT-002 | medium | DT/Kconfig integration | Hantro-only Rockchip AV1 configs could leave `CONFIG_VSI_IOMMU=n` even though the base AV1 node references `av1d_mmu` | `drivers/media/platform/verisilicon/Kconfig`, `drivers/iommu/Kconfig` | Fixed in worktree |
| AV1-PKG-001 | low | packaging | `rk3588-rock-5b.dtb` target fails in the plain worktree before AV1 due missing `vdec0/vdec1` labels | `rk3588-rock-5b.dtsi` Armbian media label dependency | Fixed in worktree |

## Details

### AV1-BSP-001 — split request arrays can overflow

The donor task stores one write and one read request array, each sized
`MPP_MAX_MSG_NUM`, but a single userspace register request can overlap multiple
AV1 register classes (`vcd`, `cache`, `afbc`). The extractor appends one split
request per overlapping class without checking the destination count. A valid
`msgs->req_cnt` can therefore expand past the fixed arrays.

The worktree defines `AV1DEC_MAX_REQ_NUM = MPP_MAX_MSG_NUM * AV1DEC_CLASS_BUTT`,
sizes both arrays with that maximum, and checks `task->w_req_cnt` /
`task->r_req_cnt` before taking the next slot.

### AV1-BSP-002 — split write copies from the wrong offset

After `av1dec_update_req()` clamps a request to the current class range, the
donor computes the destination register pointer with the original `req->offset`.
For a request spanning more than one register bank, the later-class copy can
underflow the bank-relative index and write before the class buffer.

The worktree copies using `wreq->offset - base`, where `wreq` is the class
clamped request.

### AV1-BSP-003 — register request arithmetic is unchecked

The donor computes `req->offset + req->size - sizeof(u32)` with no minimum size,
alignment, or overflow guard. Tiny, unaligned, or near-`U32_MAX` requests can make
class-overlap and split-size calculations wrap.

The worktree rejects register requests with `size < sizeof(u32)`, unaligned
offset/size, or overflowing end-offset arithmetic before splitting them.

### AV1-BSP-004 — class bounds are off by one

The donor helper checks `class > hw->reg_class_num`, but valid indexes are
`0..reg_class_num - 1`. `class == reg_class_num` is out of range and must be
rejected. The worktree changes those checks to `>=`.

### AV1-BSP-005 — FD translation loop corrupts its own iterator

The donor code loops over `task->w_req_cnt`, then starts an inner loop that
reuses `i` for `hw->trans_class_num`. That destroys the outer loop state. It also
translates a whole register class once per write request rather than once per
valid class, which can double-apply offsets when multiple writes touch the same
class.

The worktree marks classes valid during write extraction, then translates each
valid class exactly once.

### AV1-BSP-006 — offset-info extraction failure is ignored

`MPP_CMD_SET_REG_ADDR_OFFSET` feeds userspace-provided offset metadata into the
later FD translation path. The donor ignores the return value from
`mpp_extract_reg_offset_info()`, so a malformed request can leave partially
updated or stale offset state. The worktree propagates the error and aborts task
allocation.

### AV1-BSP-007 — threaded ISR dereferences a missing current task

The donor ISR reads `mpp->cur_task`, immediately derives the AV1 task and VCD
register buffer, and only then checks whether `cur_task` was NULL. A spurious or
late threaded IRQ can therefore NULL-deref before the guard. The worktree moves
the NULL guard before `to_av1dec_task()` and register-buffer access.

## Forward-port and integration notes

The `AV1-FW-*` items are not upstream BSP runtime bugs. They are the normal
6.1-to-6.18 compatibility work needed after importing the BSP file: platform
remove callbacks now return `void`, the procfs guard must line up with the local
MPP procfs Kconfig, and this branch's forced compat include reaches `printk.h`
before several BSP files define `pr_fmt`. They also include cases where the BSP
called an API that is absent upstream and must go through this forward-port's
compat wrapper.

The `AV1-VSI-*` items are also not findings against Rockchip's BSP
`mpp_av1dec.c`. They come from the chosen hybrid path: using the standalone
upstream-style Verisilicon IOMMU provider rather than forward-porting the BSP's
private `third_iommu_ops_wrap` / `rockchip-iommu-av1d.c` integration. They are
tracked here because they are required for the AV1 experiment to be supportable
and because a failure there would present as an AV1 decoder bring-up bug.

The second adversarial review also found broader forward-port debt that is not
an original BSP bug. The Rockchip IOMMU item below was fixed after that review
by moving the helper semantics into the mainline Rockchip provider:

- The old compat `rockchip_iommu_*` helpers were no-op/`-ENODEV` shims. They are
  now replaced by a real `include/soc/rockchip/rockchip_iommu.h` plus exported
  wrappers in `drivers/iommu/rockchip-iommu.c`. RKVENC2/RKVDEC2 fault masking,
  reset-refresh recovery, and MPP fault callbacks use the provider; AV1 mapping
  still uses `vsi-iommu` and treats Rockchip-helper `-ENODEV` as a generic flush
  fallback.
- The forced `rockchip_save_qos()`/`rockchip_restore_qos()` compat helpers are
  no-ops, so the RKVDEC2 link reset QoS save/restore behavior is still missing.

Those should be tracked with the broader encoder/decoder forward-port work
rather than counted as donor `mpp_av1dec.c` defects.

### 2026-07-03 adversarial forward-port review fixes

The next review pass was scoped to forward-port bugs only, not original BSP
logic. The fixes now in the worktrees are:

- Rockchip and VSI IOMMU `map_pages`/`unmap_pages` honor the 6.18 `count`
  argument and stop at the current second-level page table boundary.
- Rockchip IOMMU has provider-local `flush_iotlb_all`, fault-handler, refresh,
  IRQ-mask/unmask, and force-reset helpers; the exported force-reset path now
  enables provider clocks while touching MMU registers.
- VSI IOMMU has a provider-local refresh/fault hook for AV1, accepts
  `#iommu-cells = <0>`, propagates probe resource errors, checks DMA mask setup,
  and unwinds prepared clocks on IRQ/DMA-mask failures.
- MPP IOMMU activation tries the Rockchip provider hook first, then VSI, then
  the generic cookie-less fallback; teardown clears both provider hooks.
- The compat ioctl path parses the 32-bit userspace message layout and converts
  the nested data pointer, instead of only converting the top-level ioctl arg.
- RKVENC2/RKVDEC2 secondary-core CCU domain attaches now check
  `mpp_iommu_attach()` and roll back the local shared-domain mutation on error;
  decoder CCU drvdata publication is last.
- The AV1 ROCK 5B DTB is self-contained in the plain worktree: base `vdec0`,
  `vdec1`, their MMU labels, and the needed SRAM pools are present before the
  board override retypes nodes to RKMPP.
- Vendor MPP/RKVENC2/RKVDEC2/RGA schema files now carry explicit dtschema types
  for the non-standard Rockchip properties.
- RGA version-string formatting and staged MPP variant tables are warning-clean
  under the focused `W=1`/object builds used here.

## Verification status

| Method | Status |
|--------|--------|
| Focused MPP object build | PASS: `drivers/video/rockchip/mpp/` builds and includes `mpp_av1dec.o` |
| Focused IOMMU object build | PASS: `drivers/iommu/` builds and includes `vsi-iommu.o` |
| Focused Hantro object build | PASS: `drivers/media/platform/verisilicon/` builds with Rockchip Hantro support |
| Hantro-only Kconfig smoke | PASS: with RKMPP disabled and Hantro Rockchip enabled, `olddefconfig` selects `VSI_IOMMU=y` |
| Shared RK3588 DTS parse smoke | PASS: `rockchip/rk3588s-orangepi-5.dtb` and `rockchip/rk3588-evb1-v10.dtb` build |
| Compiled base AV1 topology | PASS: `rk3588-evb1-v10.dtb` shows `video-codec@fdc70000` with `iommus` pointing at enabled `iommu@fdca0000` |
| AV1 binding check | PASS: targeted `rockchip,av1-decoder.yaml` check runs cleanly with `dtschema` 2026.6 |
| ROCK 5B AV1-enabled DTB | PASS: `make O=/tmp/linux-6.18-rkvenc-av1-build ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- rockchip/rk3588-rock-5b.dtb` |
| Vendor MPP/RGA binding check | PASS: targeted `dt_binding_check` for `rockchip,mpp-service.yaml`, `rockchip,rkvenc2.yaml`, `rockchip,rkvdec2.yaml`, and `rockchip,rga-vendor.yaml` in both worktrees with `dtschema` 2026.6, including yamllint and generated example DTC |
| Focused RGA W=1 build | PASS: `CONFIG_ROCKCHIP_MULTI_RGA=y W=1` directory build for `drivers/video/rockchip/rga3/` in both worktrees |
| Runtime AV1 decode | PENDING: no board boot or `av1_rkmpp` userspace validation yet |

## Open follow-ups

1. Add a runtime gate for `ffmpeg-rockchip` `av1_rkmpp` once the DTB packages.
2. Re-review `av1dec_set_afbc()` arithmetic once runtime traces show which AV1
   profiles and output formats userspace submits.
3. If we decide to upstream any fixes to Rockchip BSP, split `AV1-BSP-*` into
   small mailbox patches independent of the 6.18 compatibility edits.
