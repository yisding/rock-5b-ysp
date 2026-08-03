# IEP2 forward-port safety review

This review records the memory-lifetime, fault-recovery, probe, and userspace
submission audit of the RK3588 IEP2 Linux 6.18 forward port. It complements the
[hardware and driver overview](rk3588-iep2-vdpp.md): that document answers what
IEP2 is and how it is driven, while this one owns the safety findings and the
proof still required before the port is suitable for normal use.

## Outcome and evidence boundary

Three independent source reviews covered task lifetime, userspace ABI and DMA
bounds, and probe/IOMMU-fault/remove behavior. They compared:

| Source | Inspected pin or baseline | Purpose |
|---|---|---|
| Linux 6.18 forward port | `rk3588-video-6.18@7615b69a744af7e79068a7bcc9968783aac62a3b` (IEP2 donor commit `6f5bdf5c0a52c0ed3895842a73dafd585ef3324b`) | Target implementation after the reviewed hardening |
| Rockchip BSP kernel | `develop-6.1@b4ef083dc0c3608e744deabb43dc6b781aadbe6e` | Donor behavior and fault ABI |
| libmpp | `ysp/main@ad32534571564aae2ee5cca26547c3738e3366ed` | Actual IEP2 message and buffer layout |
| Hardened 6.18 rewrite tree | local sibling tree, including fault-handler synchronization commit `876f5583d6575` | Existing teardown precedent |

The audit found real use-after-free, error-pointer dereference, teardown, DMA
validation, and fault-recovery defects. The fixes are committed in the target
tree as `7615b69a744af7e79068a7bcc9968783aac62a3b` and compile together as
`mpp_iep2.o`, the complete MPP built-in archive, and both Rockchip and VSI IOMMU
provider objects. That is source/build evidence only. The fixes have not yet
run on the ROCK 5B, so KASAN runtime, actual I1O1T recovery, invalid-input, and
close-versus-completion stress remain open.

No working memory-corruption reproducer belongs in this public repository.
Such reproducers and disclosure-specific material are owned by the private
`rock-5b-security` repository. This document retains the engineering facts,
fixes, and safe validation contract.

## Confirmed lifetime and Oops paths

### Timeout work could outlive and free its containing task

The common MPP path embedded `timeout_work` in `struct mpp_task`, armed it
without taking a reference, and used asynchronous `cancel_delayed_work()` when
the hardware IRQ won completion. If the callback had started, cancellation
returned false. The completion worker could then remove the running-list
reference while a closing session removed the session-list reference, freeing
the task while the timeout callback was still using or returning through its
embedded work item.

The hard IRQ still performs its atomic-safe asynchronous cancellation, but the
default process-context worker now calls `cancel_delayed_work_sync()` after it
disables the device IRQ and observes the HANDLE bit, but **before** it invokes
the ISR that drops the running reference. IRQ disablement makes completion
ownership stable across the check; a callback that already started can finish
its nested, depth-balanced `disable_irq()`/`enable_irq()` pair and return before
the task is retired. The post-run error path applies the same HANDLE-then-sync
ordering before dropping its reference.

Using synchronous cancellation in hard IRQ was not an option. Sync-cancelling
before IRQ disablement and the HANDLE check also left a race in which the
callback could start immediately afterward. A reviewed alternative that gave generic
`mpp_task_run_begin()` a timer-owned `kref` was also rejected: link/CCU paths
replace the default callback and have several re-arm/cancel sites, so hidden
ownership in the shared arming helper would leak their tasks unless every
custom path were converted together.

### The IOMMU fault callback used a bare current-task pointer

`iep2_run()` published `mpp->cur_task`, the IEP ISR cleared it and completed the
task, and `iep2_iommu_fault_handle()` read it and walked task parameters and the
DMA-region list without a lifetime lock. Completion and session close could
therefore retire the running-list reference while the IOMMU callback retained a
bare task pointer.

The fix uses the taskqueue `running_lock` for all three operations. The fault
callback keeps the lock through its parameter check, memory-region dump, and
workqueue decision; it does not dereference the task after unlocking. This
matches the already-hardened RKVDEC2 fault path. The ROCK 5B maps IEP2 and its
IOMMU to the same interrupt number, which reduces one practical interleaving,
but shared IRQ topology is not a valid object-lifetime contract.

### Provider callbacks could survive IEP2 resource teardown

The Rockchip and VSI IOMMU providers copied their callback and token under a
spinlock, released that lock, and then invoked the callback. Clearing the
registration therefore prevented new callbacks but did not wait for one that
had already copied the old IEP2 pointer. Common removal also called the IEP2
exit hook first, destroying the fault workqueue and freeing its auxiliary page
and ROI before unregistering the provider callback. An overlapping callback
could queue work onto destroyed storage or dereference device-managed memory
after removal.

The fix adds sleepable provider synchronization helpers, separates callback
quiescence from the atomic-safe setter, and calls a common MPP quiesce helper
before the codec exit hook. IEP2 removal also frees and synchronizes the main
shared IRQ before queue and device teardown. Repeating quiescence in common
IOMMU removal is intentional and idempotent.

### Independent hot-unbind remains a broader MPP lifecycle gap

`mpp_dev_register_srv()` publishes a device-managed IEP2 pointer through
`srv->sub_devices[MPP_DEVICE_IEP2]`. The common service has no complete inverse:
lookups are lockless, existing sessions retain `session->mpp`, and removal does
not implement a dying state plus task/session drain. Merely assigning `NULL`
would leave both pre-existing readers and bound sessions unsafe.

The bounded fix suppresses sysfs bind/unbind attributes on both the IEP2 child
and the parent MPP service. The parent matters because unbinding it unregisters
children internally and could otherwise tear down IEP2 beneath open sessions
even when child-only unbind was hidden. This closes the normal manual-unbind
triggers. It does **not** establish safe arbitrary DT-overlay removal, module
unload, or a reusable MPP hot-unplug contract. A complete common fix would need
to:

1. mark the subdevice as removing and reject new init/query/submit operations;
2. serialize service lookup and device publication;
3. abort and drain pending/running tasks and attached sessions;
4. flush device worker work;
5. free/synchronize the main IRQ and quiesce/synchronize IOMMU callbacks; and
6. unpublish only after all readers and retained device references are gone.

That broader lifecycle change is deliberately not represented as solved by
the IEP2-local mitigation.

The common `mpp_dev_probe()` failure label also does not call a hardware exit
hook after a successful hardware init followed by a later hardware-ID/power
failure. That can leak codec-private allocations. IEP2 currently has
`hw_info.reg_id = -1`, so it has no such post-init hardware-ID step, and its own
partial-init labels free ROI/page/workqueue state; this is recorded as common
framework cleanup debt rather than an observed IEP2 UAF or Oops.

## Confirmed probe and recovery defects

### Clock lookup errors became error-pointer dereferences

`mpp_get_clk_info()` stored the result of `devm_clk_get()` but never checked
`IS_ERR()`. IEP2 then logged lookup failures and continued. A deferred or failed
clock lookup could reach `clk_prepare_enable()` as an error pointer. The IEP2
clock-on hook also ignored partial enable failures, allowing MMIO with only a
subset of the required clocks running.

The common helper now returns `dev_err_probe()`, clears the stored pointer, and
preserves probe deferral. IEP2 treats all three clocks as mandatory, checks each
enable, unwinds in reverse order, and disables in `sclk`, `hclk`, `aclk` order.
The reset wrappers reject error pointers and preserve assert/deassert errors;
IEP2 likewise treats its three reset controls as mandatory.

### The BSP fault-status ABI was lost during the provider port

The BSP passed raw `RK_MMU_STATUS` to the IEP2 callback. Its bus ID occupied
bits 10:6, and IEP2 used a nonzero bus ID plus mode and exact end IOVA to
recognize RK3588's intentional I1O1T one-page source read-ahead. The 6.18
provider instead passed generic `IOMMU_FAULT_READ`/`IOMMU_FAULT_WRITE` flags
plus a private bus-error flag. Ordinary read faults therefore appeared to have
bus ID zero, while the private `0x100` bus-error bit accidentally decoded as raw
bus ID 4. The intended auxiliary-page path was skipped, leaving the IRQ masked
until timeout/reset.

The bounded fix no longer decodes nonexistent raw status. It accepts the
workaround only for a normal read with no bus-error flag, the exact imported
source-end IOVA, and `I1O1T` mode. All other faults take the error/reset path.
An alternative provider-wide design would encode the raw bus ID into a
documented noncolliding private field, but no other inspected consumer needed
that larger ABI.

### A no-task fault could permanently mask the IOMMU IRQ

The old IEP2 callback masked the provider IRQ before checking `cur_task`. With
no current task, it incremented `reset_request` and returned success, but no
task completion remained to execute that reset or unmask the source.

The fixed path checks the task under `running_lock` first. With no task it
returns an error without masking, allowing the provider's normal report and
page-fault completion path to clear the source.

### The auxiliary mapping was outside allocator and task lifetime accounting

The I1O1T workaround directly mapped a zeroed page at the fault IOVA but did
not reserve that page in the DMA-IOMMU IOVA allocator. It also left the mapping
until the next fault or device exit. A later DMA import could select the same
apparently free IOVA, and a recovery work item could complete after the task it
was intended to extend.

The fix reserves the page in allocator accounting before `iommu_map()`, unwinds
the reservation on failure, waits/cancels recovery work at task finish, and
unmaps/unreserves the page after the associated hardware task is quiescent.
Device exit performs the same balanced cleanup after callback quiescence.

Reviewing that fix exposed a defect in the pre-existing MPP fixed-IOVA helper:
Linux `reserve_iova()` may return an already-present overlapping node to mean
that the requested range is covered. MPP interpreted every non-null return as a
new reservation it owned; if the subsequent map failed, `free_iova()` could
remove the other DMA allocation's node. The fix adds an exclusive IOVA
reservation primitive that rejects any overlap while holding the allocator
tree lock, and makes MPP use it. This protects both the IEP2 auxiliary page and
the existing encoder/decoder fixed SRAM/RCB window users.

## Confirmed userspace submission and DMA-boundary defects

### Raw IOVA submission bypassed all dma-buf ownership checks

IEP2 honored `MPP_FLAGS_REG_FD_NO_TRANS`, allowing the semantic parameter block
to carry addresses that were written directly to hardware. Installed libmpp's
IEP2 submit path does not require this flag. Because IEP2 sessions share a DMA
domain, a supplied mapped IOVA could address another live mapping; an unmapped
one reached the IOMMU fault/reset path.

Packed fd/offset encoding had a second form of the same problem: a nonzero word
whose low ten fd bits were zero was simply left unchanged and later programmed
as an IOVA.

The fixed IEP2 ABI rejects `MPP_FLAGS_REG_FD_NO_TRANS`, accepts fd zero only
when the entire address word is zero, and clears address slots the selected
format does not use. Every programmed buffer address must now originate from a
successful task-owned dma-buf import.

### Buffer validation bounded only the first byte

The original forward port correctly checked that each offset was inside its
dma-buf and that the translated start fit IEP2's 32-bit address width. It did
not check the span hardware would access. A tiny buffer or an offset near the
end could therefore pass validation while dimensions and strides drove IEP2
past the mapping. An adjacent mapping in the shared domain could be accessed
without producing an IOMMU fault.

The fix derives the programmed width and height from tile counts, converts the
hardware stride units to bytes, checks minimum luma/chroma/output row strides,
and verifies full padded-row plane spans with 64-bit arithmetic. It also checks
the motion-vector tile span and the motion-detection width-by-height span.
Planar and semiplanar chroma widths and 4:2:0/4:2:2 row counts are handled
separately. All three source Y/chroma inputs, both output Y/chroma buffers, and
the MV/MD buffers are mandatory; planar input additionally requires all three V
planes. This is compatible with pinned libmpp, which duplicates source frames
for lower-input modes and always supplies MV/MD storage.

The standalone libmpp test accepts nominal active widths that are not multiples
of 16, but it also sets byte stride directly from that width while the kernel
programs tile-rounded width. Those jobs cannot prove enough backing storage and
are now rejected. Decoder vproc supplies aligned virtual stride and is
unaffected. Supporting arbitrary active widths would require an ABI field that
preserves active width separately from the tile-programmed extent, not weaker
kernel bounds.

### Mutable session flags raced per-task address decoding

IEP2 received the immutable `msgs` for one task but read
`session->msg_flags` while walking every address. Two threads using the same
session could change that shared field while dma-buf import slept, causing one
task to switch between packed fd/offset and `REG_NO_OFFSET` decoding partway
through its parameter block.

The fix snapshots semantics from `msgs->flags` consistently for the entire
task. This is the same principle used by the existing exact request-block
validation: submission interpretation belongs to the task, not mutable session
state.

## Bounds and unwind paths that were already sound

The review did not find a separate defect in these areas:

- the exact single 656-byte semantic input block and exact single 412-byte
  result block, both at offset zero;
- zero-initialized task allocation and checked user copies;
- format, mode, tile-count, OSD-count, and ROI-count bounds;
- register-offset array size/count/copy validation;
- the 17-entry address table and its contiguous parameter layout;
- the eight-entry OSD programming loop and hardware OSD result clamp;
- the 56-entry motion-vector histogram loop, whose step of two leaves `i + 1`
  in range;
- the DT resource ending at `0x500`, beyond the highest used register at
  `0x4ec`;
- ROI, auxiliary-page, and workqueue allocation-failure unwind;
- zeroing the auxiliary page before read-only mapping;
- allocation/task-finalization cleanup of successfully imported dma-bufs;
- the HANDLE-bit arbitration that prevents IRQ and timeout from both finishing
  one task (waiting for an already-running callback before retirement was the
  separate lifetime bug);
  and
- the vendor behavior that clears an intermediate OSD-max interrupt but keeps
  hardware running until frame completion.

## Verification contract

### Completed without booting the port

- three independent source reviews against the pinned forward port, BSP, and
  matching libmpp layout;
- `git diff --check` plus strict `checkpatch.pl` with zero errors, warnings, or
  checks on the implementation changes;
- incremental and `W=1` Linux 6.18 builds of `mpp_iep2.o`, the full MPP
  built-in archive, `iova.o`, `rockchip-iommu.o`, and `vsi-iommu.o`;
- the complete `Image` and DTB build plus the device-free `iep2-smoke.sh`
  source/build gate; and
- a successful 11:31 `forward-port-debug` package build at source
  `7615b69a744af7e79068a7bcc9968783aac62a3b`, artifact hash
  `Pcf86-Cc271`. The build used ccache (1,461 hits, 84 misses; 94%) and
  produced image, DTB, and headers packages without installing them.

Extracting the packages, rather than trusting the seed config, confirmed
`CONFIG_KASAN=y`, `CONFIG_KASAN_GENERIC=y`,
`CONFIG_ROCKCHIP_MPP_IEP2=y`, `CONFIG_ROCKCHIP_IOMMU=y`, and
`CONFIG_VSI_IOMMU=y`. The image embeds `g7615b69a744a`, and the packaged ROCK
5B DTB contains `iep@fdbb0000`, `rockchip,iep-v2`, and `iommu@fdbb0800`.
This proves the intended instrumented payload was packaged; it is not KASAN
runtime evidence.

The project source/build harness remains
[`iep2-smoke.sh`](../../tests/iep2-smoke.sh). Its device-free build mode is:

```sh
IEP2_VALIDATE_ONLY=1 IEP2_VALIDATE_BUILD=1 \
  kernel-drivers/tests/iep2-smoke.sh
```

### Cleared on the ROCK 5B, 2026-08-03

The KASAN/lockdep build was booted and exercised. Client 28 and both platform
bindings are confirmed, and 20 consecutive TFF/BFF I5O2 runs at 320x240
produced correctly sized, high-entropy output with no KASAN, UAF, lockdep,
IOMMU-fault, or timeout report. One new defect surfaced — output is not
reproducible across runs — and a three-arm A/B root-caused it to Rockchip's
`iep2_test.c` omitting the dma-buf cache sync around its own CPU access, not to
the driver. See the
[runtime finding](../../../findings/2026-08-03-rk3588-iep2-nondeterministic-output.md).

### Runtime gates, all cleared 2026-08-03

Every gate below ran on the booted KASAN/lockdep build. Across all of them the
kernel emitted **no** log line at all except the expected rejection messages
during negative testing — no KASAN, UAF, out-of-bounds, lockdep, workqueue, IRQ,
IOMMU-fault, timeout, or reset report.

- **decoder vproc path** — an interlaced H.264 stream (`field_order=tt`) decodes
  with `device /dev/mpp_service select in vproc`, turning 60 interlaced frames
  into 116 output frames; byte-identical across 5 runs;
- **1080p boundary** — 1920x1088 is the exact `md_buf` fit (span 2088960 =
  buffer size) and passes, 20 runs byte-identical; 1920x1104 is refused by the
  driver, `offset 0 span 2088960 exceeds len 1040384`;
- **I1O1T and the auxiliary mapping** — accepted and correct: exactly one
  destination frame is written, the second stays clear;
- **negative cases** — 18 checks in
  [`tests/iep2/iep2_negative.c`](../../tests/iep2/iep2_negative.c), all refused
  synchronously: over/under-sized param and result requests, untranslated-address
  flag, packed zero-fd word, missing and never-opened fds, over-span geometry,
  undersized buffers, sub-row strides, zero and 0xffffffff tile counts, and
  invalid mode/format enums. The baseline task is accepted both before and after
  the whole sequence, so no refusal leaks a task slot or wedges the session;
- **address-encoding race** — 50 rounds in each interleaving of packed versus
  offset-alone on one session, zero deviations, so the flag is applied per task
  and never latched per session;
- **close versus completion, and import churn** — ~20,000 tasks across 8
  concurrent processes, each with freshly imported buffers, mixing normal
  completion with sessions closed while work was still in flight; and
- **soak** — the above plus 20 real 1080p runs and 5 decoder runs.

The software timeout path was **not** triggered; provoking it needs fault
injection rather than malformed input, so it remains unexercised.

The precise conclusion is now: **the source review found and repaired the known
IEP2 forward-port Oops and DMA-boundary defects, and every runtime gate above
passes on the board under KASAN and lockdep — functional output, the 1080p span
boundary in both directions, the decoder vproc path, synchronous rejection of
malformed input, per-task address-encoding interpretation, and teardown/churn
stress. The one runtime defect found belongs to vendor userspace, not the port.
The software timeout path remains unexercised.**
