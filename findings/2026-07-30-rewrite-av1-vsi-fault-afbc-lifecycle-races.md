# Rewrite AV1/VSI audit closes fault-admission and teardown races; AFBC retirement proof remains a hardware gate

> Scope: kernel-drivers — clean-room `mpp-rewrite` AV1 backend, VSI IOMMU
> provider, ROCK 5B AV1 reset wiring, and their KUnit/build gates
> Source: `~/Code/rock-5b/kernel/linux-6.18-rkvenc`
> `rk3588-rewrite-6.18@9771d14cfa109`, mirrored to
> `~/Code/rock-5b/kernel/linux`
> `rk3588-rewrite-mainline@5bfb81f90f05b`; BSP comparison against the local
> Rockchip AV1 decoder implementation
> Date: 2026-07-30
> Trust: SOURCE-INSPECTED, ROOT-CAUSED, SOURCE-CONFIRMED,
> FIX-COMPILE-VERIFIED, PARTIAL — no booted kernel or AV1 hardware run

## Result

A full AV1-side review found that the original `CORE_WORK`/`CORE_IDLE`
ownership class had several siblings across the consumer/provider boundary:
software could observe "no active job" while a provider fault still owned
recovery, could unregister a callback without draining process-context replay,
or could release an active job after a stop attempt supplied no DMA-quiescence
proof. The AV1 auxiliary block added its own mask/status/START race and teardown
MMIO hazards.

The fixes make DMA admission, fault delivery, active-job publication, recovery,
system PM, remove, and shutdown one fail-closed ownership protocol. The two
rewrite trees carry the same MPP implementation; VSI differs only where the
kernel IOMMU API differs.

## Confirmed defects and disposition

| Severity | Defect | Disposition |
|----------|--------|-------------|
| High | VSI's last "no fault" check and AV1 START were separate transactions. A fault could be captured between them while MPP admitted a new generation. | Added provider `prepare`, final `reserve`, and exactly-once `release` APIs. Successful reserve holds the admission mutex, PM reference, and disabled/drained provider IRQ through active-job publication and START. Release captures once more before restoring the IRQ and can dispatch while the job is still owned. |
| High | A provider fault arriving while the consumer looked idle could be discarded or replayed without an owning generation. | VSI retains address/status/domain and uses a single delivery claim. MPP keeps `iommu_fault_pending` as an admission blocker and assigns the marker to the generation once ownership is restored. |
| High | `synchronize_irq()` did not drain handler calls made by registration/replay or the reservation path. Teardown could free the old callback token while such a call still ran. | Provider callback in-flight accounting now surrounds every invocation. `set handler NULL -> sync` excludes new callbacks and waits for IRQ and process-context origins. |
| High | A retained pending fault stored a raw paging-domain pointer across detach/release. Later replay could dereference a freed domain. | Paging-domain replacement and device release serialize against DMA admission, mask/disable the provider while powered, retire the fault record, and wait for callbacks before the old domain can disappear. |
| High | Failed stop proof restored the active job but left the core advertised. The timeout was gone, the provider source remained claimed/masked, and queued work could accumulate forever. | Recovery now restores ownership first, then quarantines the core/coordinator and fails queued work. Active DMA-visible resources remain pinned for fail-stop teardown retries. |
| High | AV1 AFBC UPDATE/status and VCD START were not one auxiliary IRQ-safe transaction; stale status could be mistaken for the new generation. | A raw auxiliary lock now covers mask/status/generation/START/unmask. The dedicated level IRQ is exclusive and hard-only. START requires stale status to deassert. |
| High | Failure to deassert AFBC status before START took ordinary submit cleanup even though AFBC was already programmed and in an unknown state. A later non-AFBC job could bypass that check. | The stale-status path now resets and terminally isolates AV1 before releasing ownership. If isolation cannot be proved, the active job and buffers remain owned. |
| High | AV1 error bits were acknowledged but could still complete with success. | Hardware error status now returns `-EIO` and enters the same stop/isolation policy. |
| High | AV1 abnormal reset had no documented idle handshake proving VCD/AFBC DMA retirement. | Reset success alone no longer permits reuse; abnormal AV1 recovery requires terminal isolation. The ROCK 5B node again supplies all four VCD/AFBC/BIU resets, and the binding accepts exactly the documented two-reset or four-reset forms. |
| High | System suspend/remove/shutdown could cross callback teardown, fault work, IRQ, or powered auxiliary MMIO boundaries in the wrong order. Partial unregister failure could restore an online core with the provider handler already NULL. | Suspend performs two idle snapshots around provider synchronization, unregisters the handler before force-suspend, and rolls back in reverse order. Unregister failure quarantines instead of restoring online. Remove/shutdown retain ownership and retry stop/unregister indefinitely when safety cannot be proved. |
| Medium | Suspend treated one `prepare_dma() == -EBUSY` as cleared after merely flushing work. | It now retries provider preparation and proceeds only when the provider itself reports no retained fault. |

## AFBC boundary that is deliberately not overclaimed

The BSP enables/programs AFBC before VCD START, completes from the VCD
interrupt, and only opportunistically acknowledges AFBC status in its thread.
That corroborates the rewrite's operational sequence, but it is not an
architectural statement that VCD completion retires every downstream AFBC DMA
write. AFBC acknowledge bit 0 is therefore **observational only** and never
finishes a job.

The remaining risk is measured with debugfs/proc state:

- `av1_afbc_prestart_status_count` and
  `av1_afbc_stale_status_timeout_count`;
- first software observation before/after the VCD hard-IRQ timestamp;
- observed/not-observed when the VCD thread samples the generation;
- observed/not-observed after the final powered mask-and-ack at quiesce;
- maximum VCD-to-late-AFBC-observation delta;
- `av1_reset_idle_unproven_count`, which records the reset-success branch that
  still required terminal isolation because no idle proof exists.

These counters describe software observation order, not hardware arrival time
or DMA completion. The final-quiesce "not observed" delta is the most useful
field signal for the unresolved retirement contract.

## Validation performed

- `vsi-iommu.o` and `mpp_rewrite.o` compile warning-free in both trees. The
  clean-archive gate exposed a pre-existing 6,704-byte soft-CCU KUnit frame;
  that fixture now heap-allocates its three large state objects.
- `rockchip/rk3588-rock-5b.dtb` builds in both trees.
- MPP is byte-identical across 6.18 and mainline.
- Strict `checkpatch.pl` is clean for source changes; the combined 6.18 diff
  reports only the expected "DT binding should be a separate patch" warning,
  and the commits are split accordingly.
- KUnit source audit: 326 known fixture signals, zero new, zero absent.
- Exact suite manifest: 90 MPP cases,
  `a9320a8d3903075e89efe9c9692ddacb0ed5fa40e84cdb5e3d1819aaa6ed3175`;
  RGA remains 148 cases.
- The clean-archive build gate now explicitly enables and builds
  `CONFIG_VSI_IOMMU` / `drivers/iommu/vsi-iommu.o`.
- The warning-fatal clean-archive `normal` profile passes for both committed
  tips, building both IOMMU providers, both rewrite objects, and the ROCK 5B
  DTB. This is a focused gate, not a full `Image`/modules/package build.
- `dt_binding_check` was unavailable because this host lacks `dtschema`; no
  schema result is claimed.

## Hardware gate

Before promotion, boot a successor debug kernel and require:

1. exact 90+148 KTAP, fatal-free outer interval, live lockdep, and clean aged
   kmemleak;
2. isolated AFBC-off and AFBC-on AV1 decode, recording all counter deltas;
3. zero stale-status timeout and reset-idle-unproven deltas in normal work;
4. fault injection across pre-admission, reserved/pre-START, active, VCD IRQ,
   system suspend, remove, and shutdown boundaries;
5. a vendor or hardware-derived retirement proof if normal VCD completion is
   ever to be promoted from BSP-compatible practice to an explicit AFBC DMA
   safety guarantee.
