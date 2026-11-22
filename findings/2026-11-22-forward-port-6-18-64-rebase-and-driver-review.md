# Forward-port rebased to Linux 6.18.64 with ten driver-review fixes

> Scope: forward-port kernel (`rk3588-video-6.18`), its MPP, RGA and IOMMU
> driver code, and the `linux-rockchip64-ysp` PPA package
> Source: Linux `v6.18.64@fd7cfd39c8859`; series tip
> `rk3588-video-6.18@9fb65e963624` (was `e7ff978398825` on `v6.18`); Armbian
> `build@eb97c8d0` (was `2a53f158`)
> Date: 2026-11-22
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, MEASURED (package artifacts). No
> boot or hardware result for anything new here.

## Result

Linux 6.18.64 is the current longterm release (2026-11-17). The forward-port
series moved onto it and grew from `0001`–`0097` to `0001`–`0107`.

**Rebase.** Earlier re-cuts let Armbian apply the unchanged `v6.18`-based series
to its rolling stable branch. That no longer works at 6.18.64: stable now
carries two things the series used to supply or depend on, so the branch itself
was rebased with `git rebase --onto v6.18.64 v6.18`. 96 of 97 patches replayed
unchanged. Patch `0005` (VSI IOMMU provider and Rockchip provider hooks) needed
two adjustments:

- Stable backported upstream `8d4346ecd495` ("iommu/rockchip: disable fetch dte
  time limit") into `rk_iommu_enable()`. It performs the same
  `RK_MMU_AUTO_GATING |= DISABLE_FETCH_DTE_TIME_LIMIT` write that `0005` added,
  so `0005` drops its hunk and its duplicate `#define`.
- 6.18.57 backported upstream `fd714986e4e4` ("iommu: Pass in old domain to
  attach_dev callback functions"). `rockchip-iommu.c` came with it, but our
  `vsi-iommu.c` is a new file in `0005`. Both of its attach callbacks now take
  the third `struct iommu_domain *old` argument and ignore it, as mainline's
  copy does. A plain rebase does not catch this; only the compile does.

The prior tip is preserved at
`ysp-backup/rk3588-video-6.18-before-6.18.64-20261119`, locally and on the
`linux-rock5b` fork, whose `rk3588-video-6.18` branch was force-updated to the
rebased tip.

A plain `git rebase v6.18.64` (no `--onto`) tried to replay all of history
from `Linux-2.6.12-rc2`. The shared kernel object store under
`../rock-5b/kernel/linux` is a shallow repository, so git found no merge base
between the series and the newly fetched `v6.18.64`. Always pass
`--onto v6.18.64 v6.18` there.

Both resync hazards the [resync guide](../kernel-drivers/docs/resyncing.md)
ranks highest are clear at 6.18.64: `struct iommu_dma_cookie` is byte-for-byte
the 6.18.51 layout with `iovad` first, and `IOMMU_COOKIE_NONE` still exists.
The review also found that hazard #1's private cookie shadow no longer exists
in the maintained series, which reaches `iovad` through its own exported
`iommu_dma_get_iova_domain()`. The shadow survives only in tracked patch 01
(DKMS and the anchor tree). The guide now says so. No
`compat/` shim header is shadowed by a new upstream header, and upstream
`pm_domains.h` still lacks the QoS and idle-request helpers. Stable also added
"iommu/rockchip: Clear stale page faults before enabling stall"
(`b10d5920cafa`), which applies cleanly underneath the series.

**Armbian.** `build` moved from `2a53f158` to `eb97c8d0`, which includes
"rockchip64-6.18: rewrite against 6.18.60" and drops a CAN patch that 6.18.64
now carries. In the 6.18 patch layer, only `media-0001` (`751e0ceacf38`),
`media-0003`, and `media-0007` (`b11a1cde993c`) overlap files the series
touches. `media-0001` and `media-0007` stay disabled in the forward-port lane.
Armbian also now ships `general-pm-runtime-02-make-barrier-return-void`; no
vendor driver uses `pm_runtime_barrier()`.

The new Armbian revision also changed its build-host image from Ubuntu Noble to
Debian Trixie (`docker-armbian-build:armbian-debian-trixie-latest`), and the
first build with it left only the Trixie image locally.
`kernel-drivers/scripts/docker-clean-armbian-state.sh` hardcoded the Noble tag,
so the second `build-kernel.sh ppa-forward-port` run died before staging, when
it went to discard the previous lane:
`local Armbian Docker image not found`. The cleaner now uses the first of the
known build images that exists locally, unless `--image` or
`ARMBIAN_DOCKER_IMAGE` names one. The trap only fires on the second run after an
Armbian bump, which makes it easy to misattribute.

## Driver review

Six independent reviewers read the entire forward-port driver surface in full:
MPP core and service, RKVDEC2 and link/CCU, RKVENC2 and IEP2, AV1, RGA
memory/job/fence, RGA register generation and policy, and the IOMMU layer.
They found no high-severity kernel memory-safety defect reachable from an
unprivileged `/dev/mpp_service` or `/dev/rga` user. Eight confirmed defects
were fixed:

| Patch | Commit | Defect | Reach |
| --- | --- | --- | --- |
| `0098` | `d24a9417a709` | The forward-port's compat ioctl path parsed a 20-byte request record. libmpp's `MppReqV1` has a `RK_U64 data_ptr` on every ABI, so 32-bit callers send 24-byte records and every multi-message submit was misparsed from record 2 on. The BSP used the native handler for compat. | 32-bit userspace |
| `0099` | `e8347c3d5ab4` | `mpp->irq_status` was never cleared, so a timed-out task inherited the last latched status, usually the previous frame's success. Affects AV1, RKVENC2, IEP2 and non-link RKVDEC2. | any user whose task times out |
| `0100` | `b0b4a83553db` | After `mpp_task_run()` failed, the default worker stopped draining. `rkvenc2_prepare()`'s `core_idle` claim was never returned, so each failure took an encoder core out of dispatch until reboot. | error path |
| `0101` | `53360159f99c` | RKVDEC2, RKVENC2 and AV1 could be sysfs-unbound under live sessions, leaving `sub_devices[]` and `session->mpp` pointing at freed memory. IEP2 and the service already suppressed bind attributes. | root only |
| `0102` | `a3d8ad5ad95a` | `rkvenc_alloc_task()` leaked every class register buffer when the request had no PIC-class format. | unprivileged, unbounded |
| `0103` | `f47b1f0fe562` | `/dev/mpp_service` was registered before `session_lock` and `session_list` were initialised. | open racing boot probe |
| `0104` | `ee5c04a5dd55` | RGA2 `COLOR_PALETTE_MODE` shifted by `3 - palette_mode` with no range check; values ≥ 4 are undefined behaviour and program a bogus stride. RGA2 MMU-bounded. | unprivileged |
| `0105` | `61f14842809f` | `RGA_IOC_GET_HW_VERSION` copied a partially uninitialised stack struct. Hidden by `CONFIG_INIT_STACK_ALL_ZERO=y`, but the `= {0}` that [BSP audit](../kernel-drivers/docs/bsp-audit.md) records as applied was missing. | unprivileged, latent |

Provenance, checked against `rockchip-kernel@b4ef083dc0c3`: only `0098` is a
forward-port regression. `0099`, `0100` and `0102`–`0105` are the same defect in
pristine BSP code, and so are backport candidates. `0101` is hardening. The
[patch catalog](../kernel-drivers/docs/patch-catalog.md) carries the per-patch
verdicts.

All eight pass `checkpatch.pl --strict` with zero errors, warnings or checks.
The production-config `W=1` build of `drivers/iommu/` and
`drivers/video/rockchip/` on 6.18.64 is warning-free; each changed object was
rebuilt.

### Reported but not changed

These are recorded so the next pass does not re-derive them. None is a kernel
memory-safety defect.

- **Encoder input cache maintenance.** The leading new hypothesis for the open
  [RKVENC corruption finding](2026-08-16-forward-port-rkvenc-intermittent-encode-corruption.md#candidate-mechanism-unsynced-cached-input-frames-2026-11-22)
  is documented there, together with the evidence against it and three cheap
  tests. A kernel cache-behaviour change was not shipped on an untested
  hypothesis.
- **Shared IOMMU domain and raw addresses.** All sessions of a codec share one
  IOMMU domain, `MPP_FLAGS_REG_FD_NO_TRANS` passes raw IOVAs, and translated
  offsets are not bounded to the imported buffer (IEP2 excepted). A video-group
  user can therefore point codec DMA at another session's mapped buffers. DMA
  stays inside mapped dma-bufs, so this is a vendor-ABI isolation property, not
  host memory corruption. Changing it needs a libmpp compatibility check first.
- **RGA offset admission.** No `x_offset + act_w <= vir_w` check per channel.
  Overruns are bounded by the RGA IOMMU or the RGA2 soft MMU (vendor behaviour).
- **Unbounded per-session task and message allocation** (vendor). Memory is
  reclaimed on close.
- **Legacy RGA2 MMU ring.** The non-handle RGA2 page-table path still carves
  from one global ring without per-job ownership (vendor, load-dependent).
- **RKVDEC2 secondary-core probe window.** Core 1 is dispatchable before its
  probe finishes. This is only reachable if core 1 probes after decoding starts.
- **RKVENC2 IRQ requested before `hw_info` is set**, and IEP2's hard IRQ
  clearing all status bits before checking relevance. Both are plausible, not
  traced to a trigger on this board.
- **`MPP_CMD_RESET_SESSION` is one-way**, and `task_count` underflows on
  freed pending tasks. Both are latent or cosmetic.

### IOMMU layer

One plausible, high-impact defect was fixed as two further patches, taking
the series to `0001`–`0107`:

| Patch | Commit | Change |
| --- | --- | --- |
| `0106` | `c93484104ac8` | Exports `rockchip_iommu_translation_lost()`, which is true when the MMU's domain is a paging domain but `iommu_enabled` is false |
| `0107` | `9fb65e963624` | `mpp_iommu_ensure_translating()` retries enable once and fails the task with `-EIO`. It runs at default-path admission (`mpp_iommu_dev_prepare_task()`) and before each soft-CCU RKVDEC2 enqueue |

The defect: `mpp_iommu_refresh()` disables and then re-enables the MMU after a
reset. If the re-enable times out on stall or paging, the MMU is left in bypass
(or paging with a null directory) while still recorded as attached. Every
caller (`mpp_common.c` and three sites in `mpp_rkvdec2_link.c`) logs the error
and carries on. The next task would then DMA to physical addresses equal to its
IOVAs, including the fixed RCB window, which means kernel memory writes. The
RKVDEC and RKVENC MMUs set `rockchip,disable-mmu-reset`, so a force-reset cannot
recover a stuck bank. The likeliest trigger, a stall that never asserts
because of a stale page fault, is separately mitigated by stable's
`b10d5920cafa`, which clears stale faults inside `rk_iommu_enable_stall()`.
Trust: SOURCE-INSPECTED, PLAUSIBLE — not reproduced. Both new commits are
strict-checkpatch and W=1 clean.

Settled, not a defect: the exported mask, unmask, prepare and IRQ-delivery
hooks touch MMU registers without `clk_bulk_enable()`. On the live DT each
MMU's clocks are a subset of its master's, and every call site runs either in
the IOMMU IRQ handler (which enables the clocks), inside the task power window,
or in IEP2 work cancelled before power-off. A DT where the MMU had a clock its
master does not enable would break that.

The reviewer also confirmed that MPP and RGA implement no `attach_dev`
callbacks of their own, so the three-argument change touched only
`vsi-iommu.c`. Mainline's `rk_iommu_identity_attach()` and
`rk_iommu_attach_device()` came with stable.

## Packaging

Version `6.18.64+rk3588av1fwport20261122-0ubuntu1~rk1`, built through
`kernel-drivers/scripts/build-kernel.sh ppa-forward-port` from the dedicated
Armbian PPA lane. Upload and Launchpad state are recorded in the
[package record](../packaging/ppa/kernel-forward-port/README.md) and
[W05](../status.md#watch-w05).

## Correction: 6.18.51 / `0097` is installed and booted

`status.md`, W16 and the package record said the 6.18.51 package (and so
`0097`) had never been installed. That has been stale since 2026-11-03: that
day `linux-image-ysp-rockchip64`
`6.18.51+rk3588av1fwport20260913-0ubuntu1~rk1` was installed, and
`/boot/Image` and `/boot/dtb` were pointed at it. On 2026-11-22 the board was
running `6.18.51-ysp-rockchip64` (booted 2026-11-19). This is boot evidence
only; no conformance, gray256 or USERPTR result has been recorded for it.

## Boundary

- Nothing in `0098`–`0107`, and nothing on the 6.18.64 base, has been
  installed or booted. The compat fix needs a 32-bit libmpp client to exercise
  it, and the timeout fix needs a hung task.
- The review was code reading only. PLAUSIBLE items were not reproduced, and
  "no high-severity finding" covers what six readers traced, not a proof.
- The local gate compiled only `drivers/iommu/` and `drivers/video/rockchip/`
  on the plain branch. The full-tree compile on Armbian's patched tree is the
  Launchpad build.
