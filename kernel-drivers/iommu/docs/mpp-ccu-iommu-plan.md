# MPP CCU IOMMU/MMU plan

This is the design note for the net-new MMU work needed after the 6.18
forward-port. The current forward-port keeps the BSP's multicore CCU idea mostly
intact, but its IOMMU implementation is still too implicit: secondary cores borrow
the main core's domain by rewriting per-core `mpp_iommu_info` fields. That mirrors
the BSP, but it is not a clean ownership model for mainline IOMMU semantics.

The goal is to keep the useful part of the BSP design while making the address
space explicit and auditable.

## Correct model

The upstream RK3588 rkvdec multicore discussion clarifies the intended shape:

- each hardware core has its own Rockchip IOMMU block;
- the multicore cluster uses one shared IOVA address space;
- the shared address space is the first/main core's default DMA domain;
- every participating core's IOMMU device is attached to that domain;
- map/unmap/TLB flush operations then reach all IOMMU blocks attached to the
  domain through the Rockchip provider's per-domain IOMMU list.

That is not "one independent address space per core". It is:

```text
decoder cluster:
  decoder core0 IOMMU \
  decoder core1 IOMMU  -> one decoder domain / one decoder IOVA space

encoder cluster:
  encoder core0 IOMMU \
  encoder core1 IOMMU  -> one encoder domain / one encoder IOVA space
```

The encoder and decoder clusters must not share a domain with each other. Their
internal fixed IOVA windows may collide, they have separate schedulers, and they
are separate hardware fault/recovery domains.

The correctness invariant is simple:

> Every DMA/IOVA value programmed into a core must be valid in the domain attached
> to that core's IOMMU at the time the core runs.

For CCU scheduling, one task may be dispatched to either core, so all participating
cores need the same task-visible mappings. A cluster-wide shared domain satisfies
that invariant without remapping buffers per dispatch.

## Why the first core's default domain

The first/main core's default DMA domain is not arbitrary. MPP sessions and
dma-buf imports use the DMA API. In the V4L2 upstream discussion, VB2 allocates
and maps through the device's DMA domain, so the shared cluster domain must be the
domain the DMA API is already populating. RKMPP has the same practical constraint:
`mpp_dma_session_create()` stores the device used for later `dma_buf_attach()` and
`dma_buf_map_attachment()` calls.

Current CCU registration already lines up with this:

- RKVDEC2 CCU registers only core 0 with the MPP service.
- RKVENC2 CCU registers the selected `main_core` with the MPP service.
- User sessions therefore allocate/import DMA buffers through the service-visible
  main core device.

The MMU work should preserve that. If a future change allows userspace sessions to
originate from a secondary core, session DMA creation must be redirected to the
cluster's main/global device, or the IOVAs may be allocated in the wrong default
domain before the core is attached to the shared domain.

## Current forward-port state

The current 6.18 forward-port now uses the intended model: mainline's Rockchip
IOMMU provider plus a small MPP/CCU shared-domain shim, not a wholesale BSP IOMMU
forward-port.

Implemented forward-port fixes:

- `mpp_iommu_shared_domain` is the explicit cluster-owned object for the borrowed
  domain and shared `rw_sem`.
- RKVDEC2 and RKVENC2 CCU attach bind secondary cores through the helper instead
  of open-coding `domain` / `rw_sem` field swaps.
- Shared-domain bind failure rolls the secondary back to its default domain.
- CCU detach restores secondary cores to their default domains, and owner detach
  frees secondary fixed RCB mappings before tearing down the shared domain.
- Fixed RCB/SRAM IOVA windows are tracked per cluster and overlapping windows are
  rejected before reserving the generic IOVA allocator range. The tracking table
  is locked, ranges are checked for 32-bit wrap/overflow, and table exhaustion is
  a hard `-ENOSPC` failure instead of silently losing the record.
- RCB/SRAM allocation errors unwind maps, pages, IOVA reservations, and fixed
  window records through the same free path used by remove.
- MPP and RGA dma-buf imports now require the DMA API to return one nonzero,
  non-wrapping 32-bit IOVA segment; unsafe mappings are rejected with a log
  instead of passing a truncated first segment to hardware.
- MPP fault-handler activation now fails the task/power-on path instead of
  running hardware without the intended provider fault hook.
- RKVENC2 fault handling routes by the faulting IOMMU device while holding RCU
  over the CCU core list.
- RKVDEC2 CCU power-on failure paths unwind runtime PM, clocks, IOMMU activation,
  idle-core state, prepared link tables, and power latches.
- AV1 AFBC's sideband IRQ no longer touches AFBC registers unless the AV1 clocks
  are known live; clock-off clears the active flag and synchronizes the IRQ before
  disabling clocks.
- Rockchip and VSI provider hooks now honor media fault-handler return values,
  preserving generic `report_iommu_fault()` fallback when a handler declines the
  fault.

Provider (`drivers/iommu/rockchip-iommu.c`):

- the mainline Rockchip provider already has `struct rk_iommu_domain::iommus`;
- attach adds the hardware IOMMU to that domain list;
- `flush_iotlb_all()` and range zaps iterate the domain's IOMMU list;
- media-facing provider helpers are wrapped so they do not touch suspended IOMMU
  registers.
- Rockchip and VSI clients advertise a 32-bit max DMA segment so dma-buf mappings
  can be merged into the single IOVA span expected by the vendor media drivers.
  Provider-created `dma_parms` storage is devm-owned by the consumer device.

### Inherited or legacy debt not fixed here

These are intentionally documented instead of changed in this forward-port fix
set because they are BSP-inherited or require a separate design decision:

- `rockchip,iommu-shared-mask` / `driver_managed_dma` remains the old arm32
  service-mask path. RK3588 CCU sharing does not rely on it; the forward port
  shares the owner core's normal DMA domain because MPP still uses the DMA API
  and dma-buf attachment mapping.
- The generic `iommu_set_fault_handler()` fallback has no public clear API, so
  the forward port uses provider hooks on RK3588 and keeps the generic fallback
  as best-effort only.
- RGA hot-unbind cleanup is still mostly global-driver cleanup, matching the BSP
  shape. That is hotplug robustness debt, not the current RGA3 MMU interrupt root
  cause.
- RGA platform-device remove remains hot-unplug-light; module/global cleanup
  unwinds the IOMMU binding, but per-device remove does not try to make the
  driver fully hotplug robust.
- Legacy `queue->last_iommu_info` is still present for the old arm32
  `CONFIG_ARM_DMA_USE_IOMMU` shared-IOMMU path. RK3588 arm64 does not exercise it
  because the forward port uses explicit shared domains instead.
- The generic non-Rockchip RGA fault-handler fallback still has one handler token
  per domain. The RK3588 Rockchip provider path uses per-device provider hooks,
  so this is not a blocker for this branch.
- The RKVDEC2/RKVENC2 RCB free path still has BSP-style ordering debt around
  freeing backing pages versus unmapping the fixed IOVA. The forward-port fixes
  made this path unwindable and auditable, but a full ordering cleanup belongs in
  the BSP-cleanup series unless testing shows a new 6.18 regression.
- RGA and MPP cache-sync/import behavior that predates the 6.18 port should be
  handled as separate BSP cleanup unless hardware testing shows a new forward
  regression.

## Proposed implementation layout

### 1. Add an explicit shared-domain helper in MPP

Add a small helper layer around `struct mpp_iommu_info` instead of letting codec
drivers open-code field swaps.

Expected shape:

```c
struct mpp_iommu_shared_domain {
        struct mpp_iommu_info *owner;
        struct iommu_domain *domain;
        struct rw_semaphore *rw_sem;
};
```

The helper should provide operations along these lines:

- initialize from the main core's `mpp_iommu_info`;
- bind a secondary `mpp_iommu_info` to the shared domain;
- attach the secondary's IOMMU group/device to the shared domain;
- roll back the local binding if attach fails;
- expose a single place for future assertions/logging.

The helper should set both `domain` and `rw_sem`. Decoder needs to be brought up
to the encoder's serialization level.

### 2. Give each CCU explicit domain state

Add domain state to the CCU structs, not to arbitrary secondary-core fields.

Decoder:

```c
struct rkvdec2_ccu {
        ...
        struct mpp_iommu_shared_domain iommu;
};
```

Encoder:

```c
struct rkvenc_ccu {
        ...
        struct mpp_dev *main_core;
        struct mpp_iommu_shared_domain iommu;
};
```

For RKVDEC2 the owner should be core 0, because the service registration already
requires `core_id == 0`. For RKVENC2 the owner should be `ccu->main_core`, because
that is the service-visible core.

### 3. Convert decoder attach

`rkvdec2_attach_ccu()` should become:

1. find the CCU;
2. read `rockchip,core-mask`;
3. if this is core 0, initialize the CCU shared-domain object from core 0;
4. if this is a secondary core, wait for the shared-domain owner and bind through
   the helper;
5. attach the secondary IOMMU to the shared domain;
6. only publish `dec->ccu` after all IOMMU work succeeds.

This removes the local domain pointer swap from the codec driver and makes the
failure path uniform.

### 4. Convert encoder attach

`rkvenc_attach_ccu()` should follow the same pattern:

1. first attached core becomes `ccu->main_core` and initializes the shared-domain
   object;
2. secondary cores bind through the helper;
3. message capacity bookkeeping happens only after IOMMU attach succeeds;
4. detach/unwind uses a matching helper path.

The encoder currently gets closer than decoder because it already shares `rw_sem`.
The conversion should preserve that behavior while making the domain owner
explicit.

### 5. Make RCB/SRAM mappings intentionally cluster-domain mappings

Both RKVDEC2 and RKVENC2 map fixed RCB/SRAM windows with `iommu_map()` after CCU
attach. That is correct only if those maps are made in the shared cluster domain.

Implementation requirements:

- keep mapping RCB/SRAM after the core is bound to the CCU domain;
- reject or warn loudly on overlapping fixed IOVA windows inside one cluster;
- keep decoder and encoder fixed windows in separate domains;
- unmap from the same domain used for map;
- document the Rock 5B layout: decoder uses distinct `0xFFF00000` and
  `0xFFE00000` windows.

Do not try to solve per-core SRAM by giving each core a separate task-visible
IOVA space. The task register programming assumes the selected core can consume
the same IOVA namespace as the rest of the CCU-visible task.

### 6. Make reset/refresh paths domain-explicit

The dangerous failure mode is a secondary core returning to its own default domain
after reset, detach, identity attach, or empty-domain restore. The restore path
must always end in the CCU shared domain for CCU cores.

Work items:

- audit `mpp_iommu_attach()`, `mpp_iommu_refresh()`, `mpp_dev_reset()`, and the
  RKVDEC2 link/CCU reset paths;
- add assertions or warnings when a CCU-bound core's current domain is not the
  CCU domain;
- avoid relying on `iommu_get_domain_for_dev(dev)` as proof that the attached
  domain is correct for secondary CCU cores;
- keep the provider-local Rockchip refresh helpers, because MPP needs to disable,
  re-enable, and flush the hardware IOMMU without assuming BSP-private APIs.

### 7. Keep fault handling per hardware core

Once a cluster shares one domain, the domain alone no longer identifies the
faulting core. Fault handlers must route by `iommu_dev` or provider token.

RKVDEC2 already has CCU fault matching by IOMMU device. Preserve that pattern and
ensure encoder diagnostics also report the concrete core that faulted.

Expected behavior on fault:

- mask the faulting IOMMU IRQ;
- dump the task and the selected/faulting core;
- let the task timeout/reset path recover;
- refresh/re-attach the shared domain before accepting more work.

### 8. Keep AV1/VSI separate

The RKMPP AV1 path is not part of the RKVDEC2/RKVENC2 Rockchip-IOMMU CCU cluster.
AV1 uses the VSI/AV1D IOMMU provider and needs its own refresh/fault hooks. Do not
mix VSI devices into the encoder or RKVDEC2 shared domains.

## Patch plan

A reviewable series should be split roughly like this:

1. **Docs/assertions only:** add comments and debug prints naming the current BSP
   borrowed-domain behavior; no functional change.
2. **MPP helper:** add `mpp_iommu_shared_domain` helpers and unit-level error
   handling; convert no codecs yet.
3. **RKVDEC2 conversion:** move decoder CCU attach to the helper and share
   `rw_sem`; keep behavior otherwise unchanged.
4. **RKVENC2 conversion:** move encoder CCU attach/detach to the helper; preserve
   `msgs_cap` behavior.
5. **RCB/SRAM hardening:** validate fixed IOVA windows and ensure map/unmap always
   use the cluster domain.
6. **Reset/fault hardening:** add domain assertions around reset/refresh and improve
   fault-core attribution.
7. **Validation docs:** record build, DTB, boot, parallel workload, and fault-inject
   results.

This keeps each step bisectable. The helper can land before codec conversion, and
each codec conversion should leave single-core behavior unchanged.

## Validation matrix

Minimum pre-merge checks:

| Check | Expected result |
|-------|-----------------|
| Focused arm64 build | `drivers/iommu/rockchip-iommu.o` and `drivers/video/rockchip/mpp/` build cleanly. |
| `git diff --check` | no whitespace errors. |
| DTB build | Rock 5B DTB still builds with encoder/decoder CCU, IOMMU, aliases, and RCB windows. |
| Boot probe log | encoder and decoder cores attach to their CCU domains; only service-visible main cores register `/dev/mpp_service`. |
| Parallel decode | two independent H.264/H.265 decode jobs can run without IOMMU faults. |
| Parallel encode | two independent encode jobs can run without IOMMU faults. |
| Fault injection | bad/unmapped IOVA faults report the faulting core and recover or fail the task cleanly. |
| Reset stress | forced timeout/reset does not leave secondary cores attached to their private default domains. |
| Suspend/runtime PM smoke | if exercised, resume re-enables the shared domain on all participating IOMMUs. |

Nice-to-have checks after the minimum matrix:

- HARD CCU opt-in decode stress;
- repeated open/close while secondary cores probe/defer;
- remove/unbind of a secondary core after the cluster has accepted sessions;
- kmemleak or lockdep runs around attach/detach and reset paths.

## Non-goals

- Do not forward-port the BSP Rockchip IOMMU provider wholesale.
- Do not create one domain shared by encoder, decoder, RGA, and AV1.
- Do not change the userspace ABI or expose one userspace device per hardware
  core.
- Do not use HARD CCU as part of this MMU fix; HARD remains a separate scheduling
  validation problem.
