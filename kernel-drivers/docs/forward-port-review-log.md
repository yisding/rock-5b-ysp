# Forward-port review log

This records adversarial review findings that are about our Linux 6.18
forward-port/integration work, not latent bugs in the Rockchip BSP itself. BSP
defects stay in [bsp-audit.md](./bsp-audit.md) and the AV1-specific BSP defects
stay in [av1-bsp-audit.md](./av1-bsp-audit.md).

## 2026-07-03 pass: all forward ports

Scope reviewed:

- `../linux-6.18-rkvenc`: RKVENC2, RKVDEC2, RGA, Rockchip IOMMU provider hook path.
- `../linux-6.18-rkvenc-av1-fwport`: all of the above plus RKMPP AV1 and VSI IOMMU.

### Fixed in the worktrees

| Area | Origin | Fix |
|------|--------|-----|
| Probe unwinds after `mpp_dev_probe()` | forward-port error path | RKVDEC2/RKVENC2 now unwind late probe failures through RCB/link cleanup and `mpp_dev_remove()` instead of leaking runtime-PM, wakeup, workqueue, and IOMMU state on CCU attach or IRQ failures. |
| Encoder CCU bookkeeping | forward-port error/remove path | Added a shared detach helper so late probe failure and remove update the CCU core list, `main_core`, and borrowed message capacity consistently. |
| Reset error propagation | forward-port recovery path | `mpp_task_finish()` now returns finish/reset errors and marks the task aborted when reset recovery fails; link/CCU workers no longer resend work after failed IOMMU refresh. |
| CCU reset coverage | forward-port recovery path | RKVDEC2 soft/hard CCU reset now attempts every enabled core and returns the first refresh error instead of breaking after the first failed core. |
| `MPP_FLAGS_POLL_NON_BLOCK` | forward-port UAPI semantics | Generic MPP waits and RKVENC2 slice waits now return `-EAGAIN` instead of blocking when the task has not completed. `mpp_dev_ioctl_common()` now returns wait errors instead of only logging them. |
| Kconfig dependencies | forward-port config hygiene | MPP/RGA vendor drivers now depend on `ROCKCHIP_IOMMU` where they call provider-specific IOMMU helpers directly. |
| AV1 probe ordering | AV1 forward-port | `mpp_av1dec.c` initializes `dec->hw_info` immediately after `mpp_dev_probe()` succeeds, before the IRQ can run. |
| VSI fault handling | AV1/VSI integration | VSI IRQ handling now masks faults, drops the provider spinlock before calling client/generic fault handlers, reports generic fault flags instead of raw VSI status bits, and tolerates missing/identity domains. |
| VSI provider lookup | AV1/VSI integration | `vsi_iommu_probe_device()` now handles missing fwspec/provider/driver-data with `ERR_PTR()` returns and holds the provider device reference through `device_link_add()`. |
| MPP fault masking for VSI | AV1/VSI integration | The MPP fault path now masks VSI faults as well as Rockchip IOMMU faults, preventing repeated page-fault IRQ storms while the task times out. |

### Verification run

- `../linux-6.18-rkvenc`: focused arm64 build passed for `drivers/video/rockchip/mpp/` and `drivers/video/rockchip/rga3/`.
- `../linux-6.18-rkvenc-av1-fwport`: focused arm64 build passed for `drivers/iommu/rockchip-iommu.o`, `drivers/iommu/vsi-iommu.o`, `drivers/video/rockchip/mpp/`, and `drivers/video/rockchip/rga3/`.
- Both worktrees passed `git diff --check`.

The AV1 `O=/tmp/...` build needed `HOSTCFLAGS=-Wno-error=discarded-qualifiers`
because the host `tools/bpf/resolve_btfids` libbpf build trips GCC's
discarded-qualifier warning as an error before reaching the kernel objects. That
is a host-tool build issue, not a media-driver failure.

### Still open

- The shared-domain CCU design remains the major IOMMU correctness risk. The
  current work keeps mainline's Rockchip IOMMU provider and adds narrow media
  hooks; it does not wholesale-forward-port the BSP IOMMU code. Cross-core shared
  domains need an explicit design that respects 6.18 IOMMU groups/domains. The
  chosen direction is now tracked in [mpp-ccu-iommu-plan.md](./mpp-ccu-iommu-plan.md):
  one shared domain per encoder/decoder CCU cluster, owned explicitly by the CCU
  and attached to each per-core Rockchip IOMMU, instead of leaving the BSP-style
  domain-pointer borrow as local codec-driver state.
- Runtime validation is still pending for the newly hardened reset/fault paths,
  especially actual IOMMU fault recovery and AV1/VSI page faults.

## 2026-07-03 commit + branch provenance

The AV1 forward-port worktree (`../linux-6.18-rkvenc-av1-fwport`, branch
`rkvenc-fwport-6.18`) was **entirely uncommitted on top of the two base commits**
until now. It is committed as a 7-commit series (`5614909..92e08bc`), dependency
ordered:

| Commit | Content |
|--------|---------|
| `07742fd` | route MPP iommu fault handling through the Rockchip/VSI provider hooks |
| `648daa4` | add `mpp_iommu_shared_domain` CCU helper (init/bind/verify) — plan §1/§2 |
| `72ad822` | VSI IOMMU provider + Rockchip provider media hooks + soc headers |
| `23ff47e` | MPP core + rkvdec2/rkvenc2 forward-port; **decoder CCU attach converted onto the shared-domain helper** (plan §3 — decoder now shares the owner `rw_sem`) |
| `538d695` | RKMPP AV1 decoder (`mpp_av1dec.c`) |
| `71bcd51` | RGA `ROCKCHIP_IOMMU` dep + version-string `sizeof` fix |
| `92e08bc` | RK3588 DTS: decoder/AV1 IOMMUs, SRAM windows, node wiring |

This advances the [mpp-ccu-iommu-plan](./mpp-ccu-iommu-plan.md): helper (§2) and
decoder conversion (§3) are done; **encoder conversion (§4) and RCB/reset
hardening (§5–§7) are still open**. The `verify()` audit hook exists but is not
wired into reset/refresh yet.

### The rewrite lineage carries a *stale* copy of the forward-port — do not sync back from it

`rk3588-rewrite-6.18` (worktree `../linux-6.18-rkvenc`) forks from the same base
`5614909` and carries the clean-room rewrite drivers **plus an older copy of the
vendor forward-port**, squashed as `710642eb` *"harden rk3588 forward-port
recovery"*. Despite the name, **`rkvenc-fwport-6.18` is strictly more hardened
than `710642eb`** — verified by direct comparison:

- **Recovery paths (my branch has, `710642eb` lacks):** reset-return checking +
  `TASK_STATE_ABORT` + `reset_request` re-arm across `rkvdec2_link_try_dequeue`/
  `_worker`, `soft_ccu_worker`, `hard_ccu_worker`, and `mpp_task_finish`; plus
  `MPP_FLAGS_POLL_NON_BLOCK` and the iommu-required probe check. (`710642eb`'s
  `mpp_rkvdec2_link.c` has the `"link reset failed"` abort in **0** places; this
  branch has it in **2**. These are the same fixes already listed above under
  "Reset error propagation" / "CCU reset coverage" / "POLL_NON_BLOCK".)
- **IOMMU recovery machinery is identical** on both (zap_cache/zap_lines/
  force_reset/zap_iova/pagefault_done/`iommu_enabled`; `rk_iommu_disable()` is
  byte-for-byte identical), so there is nothing to gain there either.
- The rewrite lineage **never carried this hardening forward**: the vendor
  recovery files (`mpp_common.c`, `mpp_rkvdec2_link.c`, `mpp_rkvenc2.c`,
  `rockchip-iommu.c`, `mpp_iommu.c`) have a **0-line delta** between `710642eb`
  and the rewrite tip `bb32bc4`.

**Guidance:** the canonical forward-port source is `rkvenc-fwport-6.18`.
`710642eb`/`rk3588-rewrite-6.18` is only interesting for its `mpp-rewrite/` +
`rga-rewrite/` drivers; cherry-picking or checking out its vendor-driver copy
onto this branch would **regress** recovery, `POLL_NON_BLOCK`, the iommu-required
probe, and the shared-domain rework. (Note: `rewrite-drivers.md` §6 cites
`710642eb58e3` only as the rewrite **build-gate** tip for `../linux-6.18-rkvenc`,
not as a forward-port source.)
