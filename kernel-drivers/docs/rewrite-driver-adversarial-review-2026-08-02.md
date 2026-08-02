# Rewrite-driver adversarial review: findings, fixes, and remaining decisions

> Date: 2026-08-02
> Scope: the complete MPP and RGA rewrite translation units, their Kconfig and
> ABI documents, and the memory/recovery contracts they share with the
> Rockchip IOMMU providers.
> Rewrite source: `rk3588-rewrite-6.18@2f05724a20036`; the reviewed baseline is
> its parent `8042f13c5459`.
> Comparison pins: Rockchip `develop-6.1@b4ef083dc0c3`, forward port
> `rk3588-video-6.18@c10074f4474e`, and the more focused multi-segment source
> snapshots recorded in the linked findings.
> Evidence boundary: source inspection and focused object builds are complete.
> KUnit assertions are compiled into the affected translation units, but the
> corrected kernel has not yet been installed and booted.  Hardware and booted
> KUnit claims are therefore called out separately rather than inferred from a
> successful build.

## 1. Outcome

The review found fifteen concrete implementation defects and repaired all
fifteen in the 6.18 rewrite working tree:

1. RGA's outer handle resolver disagreed with its lower plane resolver about a
   lone `v_addr` placeholder.
2. RGA could tear down a partially created selected-core mapping after the
   core's power domain had already been suspended.
3. Persistent RGA USERPTR mappings did not track CPU/device ownership and could
   perform a second copyback or cache invalidation at final unmap.
4. RGA's raw-IOMMU USERPTR route reused DMA-API synchronization after abandoning
   the DMA mapping.
5. Terminal RGA request submit and request-create rollback used an integer ID
   after dropping the lock, permitting request-ID reuse to redirect cleanup.
6. RGA used sync-file APIs without selecting `CONFIG_SYNC_FILE`.
7. RGA callback teardown did not make provider-clear and callback-drain failure
   part of the removal result.
8. MPP allowed a one-past-end DMA-BUF address for every translated register,
   although only VEPU580 bitstream-top word 172 has that meaning.
9. MPP patched RKVDEC RCB registers with driver-owned IOVAs and then rejected
   those same values because final validation knew only DMA-BUF provenance;
   its placement calculation also reserved a user-supplied short size rather
   than the trusted hardware-accessible extent.
10. HARD-CCU fault attribution could read a powered-off decoder link register,
    and the terminal coordinator drain did not retract the matching
    register-live count before gating its last clock reference.
11. RGA released DMA mappings, command storage, and power after a recovery
    reset failed to prove that the engine had stopped.
12. MPP silently skipped `SET_REG_ADDR_OFFSET` for explicit-IOVA jobs even
    though that flag combination is accepted by the ABI.
13. RGA3 accepted pattern-blend rotation while its BSP wire/canvas semantics
    were explicitly unresolved.
14. MPP could return restart semantics after an earlier poll in the same batch
    had already consumed a completion or slice record.
15. Multiple poll requests staged for one MPP job overwrote one another and
    executed as a single poll.

The review also found policy and hardware-evidence gaps that should not be
silently resolved by changing ABI behavior: resource admission limits, the
ambiguous low-address RGA legacy channel, implicit DMA reservation-object
synchronization, possible SWIOTLB behavior for persistent MPP mappings, and
reset/IOMMU restoration coverage.  Section 6 proposes explicit next steps for
each.

The multi-SG conclusion is narrower than the earlier blanket defect report.
The source now handles adjacent mapped entries, RGA2 page-table scatter, and
driver-owned USERPTR remapping.  A genuinely gapped exporter-owned DMA-BUF on
RGA3 remains unsupported by design because the hardware command contains one
linear base and the importer does not own the exporter's staging or movement.
That remaining limitation is not the old `nents != 1` bug.

The two `ABI.rst` files were rewritten during the same pass.  They now focus on
the observable contract: fixed transport, limits, buffer ownership, request or
poll lifetime, exact supported profiles, fail-stop behavior, and validation
status.  Historical investigation and implementation rationale live in this
report instead of obscuring the ABI.

## 2. Review method

Three independent adversarial lanes reviewed RGA, MPP, and cross-driver
ownership/recovery behavior.  Each lane was asked to disprove the apparent
invariants rather than confirm the implementation.  The final pass then traced
every candidate through acquisition, hardware publication, completion, error
unwind, session close, device removal, and power-off.

The review emphasized these questions:

- Does every ID-based lookup remain tied to the same object until mutation is
  complete?
- Does every DMA mapping have one current owner, one matching sync direction,
  and one teardown path?
- Can a hard IRQ or provider callback touch MMIO after its register-live proof
  has been retracted?
- Are driver-created hardware addresses distinguished from user/import-created
  addresses during final validation?
- Is a compatibility exception scoped to the exact backend and register that
  requires it?
- Does a failed partial start unwind DMA/IOMMU state while the relevant domain
  is still powered?
- Is an unsupported SG shape rejected because the hardware cannot represent it,
  or merely because the implementation expected one scatterlist entry?

The focused prior investigations remain useful supporting material:

- [RGA multi-segment memory contracts](../../findings/2026-07-31-rga-userptr-dmabuf-multisegment-contracts.md)
- [RGA rewrite multi-SG DMA-BUF and CMA finding](../../findings/2026-07-31-rga-rewrite-multisg-dmabuf-cma-einval.md)
- [RGA2 multi-segment parity plan](../rga/docs/rga2-multisegment-parity-plan.md)
- [RGA USERPTR/IOMMU investigation](../rga/docs/userptr-iommu.md)
- [Rewrite ownership refactor plan](rewrite-ownership-refactor-plan.md)

## 3. Multi-SG and gapped DMA-BUFs

### 3.1 The terms are not interchangeable

`orig_nents > 1` means the backing description has multiple physical extents.
It says nothing by itself about the device-visible address range.

`nents > 1` means the DMA API returned multiple mapped entries.  Those entries
may still be byte-adjacent:

```text
entry 0: [0x100000, 0x110000)
entry 1: [0x110000, 0x130000)
entry 2: [0x130000, 0x138000)
```

That is one representable linear span even though it has three entries.  A true
gap is different:

```text
entry 0: [0x100000, 0x110000)
entry 1: [0x210000, 0x230000)
```

RGA3 can program the first example as one base plus validated offsets.  It
cannot describe the second example in its image-address command.

### 3.2 Why the BSP could use first address plus summed lengths

The 5.10/6.1 BSP RGA path records the first DMA address and sums the mapped
lengths.  It does not independently verify adjacency.  On the pinned stack this
works because two layers cooperate:

1. The normal IOMMU-DMA SG path allocates one IOVA interval for the whole list
   and maps each physical run into consecutive slots inside it.
2. Rockchip raises the client maximum segment size to a 32-bit-wide value, so
   finalization can report the whole mapping as one large DMA segment rather
   than splitting it at the generic 64 KiB default.

The old SWIOTLB bypass also did not normally apply to the RK3588 RGA platform
device.  In the inspected 6.1 logic it was restricted to untrusted PCI devices.
The BSP shortcut was consequently reliable on that kernel/device combination,
but it was never a portable DMA-API guarantee.

Newer IOMMU-DMA code can choose per-entry bounce mappings for SG geometry that
the older whole-list path accepted.  Independent allocations may be gapped or
even descend.  This is why the 6.18 implementations must inspect every returned
entry rather than inherit the BSP assumption.

### 3.3 Why a DMA-BUF may be gapped

A DMA-BUF promises a shared logical allocation and an attachment protocol; it
does not promise physical or DMA-address contiguity.  The exporter supplies a
device-specific mapped attachment.  Gaps can result from:

- fragmented physical backing;
- an exporter-specific staging or migration layout;
- independent IOMMU allocations or SWIOTLB bounce entries;
- DMA boundary, mask, or maximum-segment constraints;
- different bus-address translations for the importing device.

System-heap pages commonly begin physically scattered, although a normal RGA3
IOMMU attachment often coalesces them into one contiguous IOVA interval.  CMA
usually begins physically contiguous, but that still does not license the
importer to assume every mapped attachment has one entry.

### 3.4 BSP, forward port, and rewrite behavior

| Input presented to selected core | BSP 5.10/6.1 | 6.18 forward port | 6.18 rewrite after the earlier multi-SG work |
|---|---|---|---|
| One mapped entry | Programs its base | Accepts after length/overflow checks | Accepts after length/overflow checks |
| Multiple byte-adjacent entries | Trusts first address plus total length | Accepts the verified full span | Accepts the verified full span |
| Gapped DMA-BUF on RGA3 | Assumes the pinned DMA stack avoided it | Rejects closed | Rejects closed |
| Gapped DMA-BUF on RGA2 | Builds the internal page table when representable | Builds page entries from the selected device mapping | Builds page entries from the selected device mapping |
| Gapped USERPTR on RGA3 | Relies on BSP IOMMU-DMA consolidation | Abandons the DMA map and creates one driver-owned contiguous IOVA | Route B creates one driver-owned contiguous IOVA |
| Gapped USERPTR on RGA2 | Builds the internal page table | Uses selected-device DMA page entries, including the audited bounce path | Uses the RGA2 page-table path when representable |

The forward port and rewrite therefore follow the same decision logic for the
important shapes.  They intentionally differ from the BSP's unchecked
first-plus-sum assumption because current kernels no longer guarantee the
assumption's prerequisites.

There is no selected-core retry after mapping.  A caller that knows its
DMA-BUF attachment is genuinely gapped must force an eligible RGA2 core mask;
an unforced job may select RGA3 and fail instead of falling back.

### 3.5 What remains open

Supporting a truly gapped DMA-BUF on RGA3 would require a new ownership model,
not deletion of the adjacency check.  Plausible designs are:

- negotiate an exporter attachment that guarantees a contiguous device view;
- allocate importer-owned contiguous staging, copy in/out with correct
  DMA-BUF CPU/device access and reservation ordering, and define when copyback
  completes; or
- route the operation to RGA2 when its profile and page-table limits support it.

The first two change cost, synchronization, and possibly ABI-visible completion
semantics.  Until one is designed and validated, rejecting a genuine gap on
RGA3 is the correct behavior.

The official librga trace captured on 2026-08-02 reaches request preparation and
handle resolution, but it does not reach `rk_rga_job_map_import()`.  It cannot
attribute the current `ysp_librga_smoke` failure to multi-SG.  The suite must be
rerun on the corrected kernel with selected-core mapping events/counters before
the runtime multi-SG gate can close.

## 4. Implemented RGA fixes

### 4.1 Plane-handle discriminator

**Failure.**  The lower resolver correctly used `uv_addr` to decide whether a
request supplied explicit plane handles, but
`rk_rga_resolve_img_handles_with_imports_locked()` still used
`uv_addr || v_addr`.  Current librga can leave a nonzero `v_addr` placeholder
while `uv_addr == 0`; the wrapper then requested imports that the lower resolver
had intentionally treated as derived planes.

**Fix.**  Both layers now define explicit planes as `!!uv_addr` and explicit V
as `explicit_planes && !!v_addr`.  A lone V placeholder is cleared and UV/V are
derived from the primary handle's validated layout.

**Regression coverage.**  The existing explicit-plane KUnit now enters through
the wrapper and covers single-handle YUV, RGB/FBC placeholders, and real
explicit-plane aliasing.

### 4.2 Powered unwind for partial selected-core mappings

**Failure.**  If source remapping succeeded and a later role failed,
`rk_rga_backend_start()` powered the core off before normal job completion
cleared the partial mapping.  The Rockchip IOMMU cannot be assumed to complete
the required invalidation after its power domain is gated.

**Fix.**  mapping-preparation failures now use the same powered release label as
later backend failures.  Every mapping is cleared before clock/runtime-PM
release.

**Required hardware check.**  Inject a second-role map failure and verify the
mapping count is zero before runtime suspend, then reuse the IOVA under IOMMU
fault tracing.

### 4.3 Stateful persistent USERPTR ownership

**Failure.**  Persistent USERPTR imports remained DMA-mapped for handle
lifetime.  A completed job synchronized them back to the CPU, but final unmap
still requested the DMA API's default CPU synchronization.  Under SWIOTLB this
can repeat copyback from stale bounce storage; on a noncoherent CPU it can
invalidate cache state a second time.

**Fix.**  `rk_rga_userptr_view` now carries `cpu_owned`.  Normal and retained
RGA2 DMA mappings transition to CPU ownership immediately after map, hand
ownership to the device only for hardware execution, and return it after use.
The transitions are stateful and idempotent.  Final unmap uses
`DMA_ATTR_SKIP_CPU_SYNC` when ownership is already with the CPU.

**Regression coverage.**  KUnit checks the ownership transition predicates,
the selected unmap attributes, and the existing boundary-shadow copy direction.

### 4.4 Route B cache maintenance

**Failure.**  Route B deliberately unmaps the preliminary DMA mapping, clears
the SG DMA fields, and installs a raw driver-owned IOMMU mapping.  Reusing
`dma_sync_sgtable_*()` afterwards would describe a DMA mapping that no longer
exists.

**Fix.**  Route B synchronizes the physical SG runs with architecture DMA cache
maintenance on noncoherent devices and does not call DMA-API SG sync on the
abandoned map.  The same `cpu_owned` state controls the direction.

### 4.5 Request-ID object identity

**Failure.**  Terminal submit cloned a request, dropped the session lock, and
removed the request later by integer ID.  A racing cancel/create could reuse the
ID and redirect the old submit's cleanup to a new request.  Create rollback had
the same identity problem around userspace ID publication.

**Fix.**  Terminal submit clones and removes the exact request under
`session->lock`, then frees that removed pointer after unlocking.  CONFIG remains
non-consuming.  CREATE holds the lock across allocation and `copy_to_user()`;
publication failure removes the same object before unlocking.

**Regression coverage.**  The request-config test now proves terminal
consumption, import-ref ownership, and immediate safe reuse of the same ID.

### 4.6 Sync-file Kconfig closure

**Failure.**  RGA unconditionally calls sync-file APIs, but Kconfig selected
only `DMA_SHARED_BUFFER`.  A minimal configuration could reach link/modpost
failure or an incomplete feature dependency.

**Fix.**  `ROCKCHIP_RGA_REWRITE` selects `SYNC_FILE`, which brings the required
DMA-BUF dependency with it.

**Remaining build check.**  Exercise both `y` and `m` configurations in clean
output trees, not just the current configured object build.

### 4.7 Provider callback teardown

**Failure.**  removal cleared local callback tracking before treating provider
clear/drain errors as part of teardown.  A failed provider mutation could leave
an IRQ callback racing freed driver state.

**Fix.**  the core lookup node is published before handler installation, so the
first delivered fault can resolve its owner.  Teardown keeps that node and the
registered state live until both provider clear and callback synchronization
succeed.  Probe failure, remove, and shutdown retry instead of freeing state
behind a stale callback token.

### 4.8 Fail-stop recovery ownership

**Failure.**  IRQ error, watchdog/IOMMU recovery, whole-core abort, and
per-session abort all called reset and then unconditionally unmapped, freed the
command buffer, dropped power, and completed the active job.  When reset
failed, the engine could still bus-master those freed resources.

**Fix.**  reset failure restores the exact job to the active slot under
`run_lock`/`job_lock`.  Its mappings, command storage, USERPTR device ownership,
power reference, hardware reference, and release fence remain live.  Queued and
newly incompatible acquire-blocked work fails separately with `-EIO`.  Close,
unbind, and shutdown retry the stop; unbind does not unregister the IOMMU
callback or release MMIO/IRQ resources until quiescence is proved.

**Regression coverage.**  KUnit checks active-slot restoration and an injected
reset failure with a live mapping: ownership, live-register count, hardware
refs, USERPTR state, and incomplete job state must remain unchanged.  The
existing queue-abort tests cover the separately safe queued-job drain.

### 4.9 Pattern-blend transform boundary

**Failure.**  RGA3 rejected rotation on the pattern image but accepted rotation
of the main pattern-blend operation even though the source comments identified
that wire/canvas transform as unresolved against the BSP.

**Fix.**  any effective pattern-blend transform now returns `-EOPNOTSUPP`, as
does a malformed nonzero transform mode.  The two BSP identity encodings remain
valid.  KUnit covers pattern-image rotation, main-operation rotation, malformed
mode data, and both identity forms.  This converts an ambiguous hardware result
into an explicit support boundary without rejecting no-op librga requests.

## 5. Implemented MPP fixes

### 5.1 Register-scoped end-exclusive address compatibility

**Failure.**  `rk_mpp_import_iova_at_offset()` accepted `offset == size` for
every backend and register.  Only VEPU580 bitstream-top word 172 is an
end-exclusive limit.  Ordinary address registers could otherwise receive a
one-past pointer.

**Fix.**  The generic helper is strict.  A job/register-aware wrapper permits
equality only for RKVENC word 172.  Translation, cumulative offset application,
and final binding validation use that wrapper.  AV1 stays strict.

**Regression coverage.**  KUnit proves the generic rejection, the one exact
RKVENC exception, adjacent-register rejection, RKVDEC rejection, AV1
post-offset rejection, and cumulative offset/overflow behavior.

### 5.2 Trusted RCB index and kernel IOVA provenance

**Failure.**  RKVDEC RCB application patched address registers with
`hw->rcb_iova`, but final explicit-address validation recognized only
DMA-BUF-backed bindings.  A valid job could therefore reject the driver's own
address.  A session-supplied RCB index also needed a trusted hardware allowlist
rather than permission to redirect arbitrary address-table words to scratch.
Finally, placement advanced by the requested size, so a deliberately short
request could put a register near the allocation tail even though hardware may
access the descriptor's complete trusted extent.

**Fix.**  An RCB request is accepted only if its register index exists in the
DT-derived hardware RCB descriptor list and its nonzero size does not exceed
the trusted maximum.  The complete trusted extent is reserved, and duplicate
indices are ignored without consuming it twice.  Accepted patches record a
separate kernel binding `(index, exact IOVA)`.  Final validation accepts that
exact value and rejects a modified value; unknown/zero/oversized descriptors
consume no scratch space.

**Regression coverage.**  KUnit covers trusted and untrusted indices,
oversized and near-tail undersized descriptors, duplicate indices, trusted
spacing, a valid zero DMA address, exact provenance acceptance, and tamper
rejection.

### 5.3 HARD-CCU fault MMIO lifetime

**Failure.**  the IOMMU fault callback could read a peer decoder's hard-CCU
descriptor register without the register lock, a live-count check, or a power
reference.  It could race terminal chain drain and read a gated link window.
The terminal drain also left `regs_live_count` inconsistent with the clock
state it was about to release.

**Fix.**  descriptor attribution now takes `regs_lock` and reads only when the
core is in HARD mode, the offset is in range, and `regs_live_count` is nonzero.
Terminal chain power drain decrements that count under the same lock before
gating each dependent core.  Normal power-off warns on underflow.

**Regression coverage.**  KUnit proves no read and unchanged sentinel output
when powered off, a read when live, and no hard-descriptor path in SOFT mode.

### 5.4 Explicit-IOVA register offsets

**Failure.**  `MPP_FLAGS_REG_FD_NO_TRANS` took an early return after RCB patching
and address validation.  Accepted `SET_REG_ADDR_OFFSET` tuples were therefore
silently ignored for explicit IOVAs, while the ABI described offsets as part of
the register image.

**Fix.**  explicit jobs apply checked cumulative offsets before RCB patching,
then validate every final nonzero address against a retained import.  This is
deliberately stricter and more coherent than the forward port's silent skip.

**Regression coverage.**  a fresh explicit-IOVA fixture with no preexisting
bindings now proves valid offset application, `u32` overflow rejection, and a
final IOVA outside the retained import.

### 5.5 Deterministic MPP batch polling

**Failure.**  One staged job stored only one poll descriptor but accepted and
counted multiple poll requests, silently replacing the earlier request.  Across
jobs, a successful poll could consume a completion or slice record before a
later interrupted poll returned `-ERESTARTSYS`; restarting the ioctl would then
repeat destructive work and observe the wrong result.  Zero-buffer slice polls
are destructive too because they intentionally discard records.

**Fix.**  a staged job accepts at most one poll request.  Batch execution tracks
successful completion/slice consumption and converts an interrupt to `-EINTR`
after either submission or destructive poll progress.  Slice polling tracks
buffered copies and zero-buffer discards separately, and stops traversal on an
interrupt.

**Regression coverage.**  KUnit covers the per-job request limit, interrupt
conversion, and the lossy zero-buffer slice path.  The ABI now states exactly
when slice records and `count_ret` are consumed or updated.

## 6. Open findings and proposed fixes

### 6.1 RGA legacy direct-address ambiguity

The legacy no-handle classifier treats every nonzero `yrgb_addr <= INT_MAX` as
a DMA-BUF fd.  A valid low compat/userspace virtual address is therefore
indistinguishable on the wire from an fd-shaped integer.

**Proposed policy:** attempt DMA-BUF acquisition first; if it fails because the
integer is not a DMA-BUF fd, fall back to USERPTR.  A valid DMA-BUF fd wins.
Document this precedence and add tests for valid fd, invalid fd/valid low VA,
and an integer that is valid in both namespaces.  Do not implement the fallback
until that ABI precedence is accepted explicitly.

### 6.2 RGA USERPTR pin and object admission

USERPTR imports use `FOLL_LONGTERM`, and imports, requests, prepared jobs, and
pending acquire-fence jobs currently lack a coherent per-session/global
admission policy.  `import_count` measures only explicit handle imports; direct
job-owned imports are outside it.

**Proposed implementation:** introduce one reservation object acquired before
pin/allocation and released by final object destruction.  Charge pinned pages
to the originating `mm` using the kernel's locked-memory accounting rules, then
add configurable per-session and global count/byte ceilings.  Count direct and
handle imports separately in debugfs, and expose pinned pages/bytes, live
requests, live jobs, and pending-acquire jobs.  Choose limits from measured
normal and stress workloads rather than baking the first suggested values into
ABI.  Preserve the modern request wrapper's documented `-EFAULT` normalization
while recording the underlying admission errno in the rejection journal.

### 6.3 MPP persistent imports and unreaped jobs

MPP keeps session DMA-BUF mappings alive for reuse and retains submitted jobs
until userspace polls or closes.  Both are legitimate lifetime choices, but
neither has an admission ceiling.

**Proposed implementation:** account each mapping object once through its final
reference, including mapped bytes per DMA device, and count pending jobs at
queue admission.  Start with telemetry and high-water marks, establish normal
multi-stream demand, then enforce per-session and global count/byte limits with
deterministic errors.  Add close/reset/release-fd tests proving every charge
returns to zero.

### 6.4 Implicit DMA-BUF synchronization

Neither rewrite driver waits on or publishes implicit `dma_resv` fences.  The
current ABI is explicit-only: RGA uses sync-file acquire/release fences, while
MPP requires external producers to finish before submission and consumers to
wait for the consuming poll.  This is an intentional documented contract, not
an accidental promise of implicit ordering.

**Proposed validation:** trace current librga, libmpp, FFmpeg, GStreamer, DRM,
and allocator call chains and test cross-device producer/consumer handoffs.  If
that integration evidence shows clients depend on reservation-object fences,
expanding the ABI to role-aware waits and completion publication becomes a
separate compatibility change.

### 6.5 MPP persistent mappings under forced SWIOTLB

The reviewed MPP mapping references and device lifetimes are internally
consistent.  A conditional gap remains: a session-long
`DMA_BIDIRECTIONAL` mapping under forced SWIOTLB/no-IOMMU operation may keep an
output in bounce storage across jobs and defer the final copyback beyond the
consumer's expected point.

**Proposed hardware experiment:** force the bounce path, submit an output job,
consume the buffer before `RELEASE_FD`/close, and compare device, CPU, and peer
device views with DMA-API debugging enabled.  If stale data is reproduced,
move to role-aware per-job mapping/synchronization or reject that bounced
persistent shape.  Do not add blind extra sync calls without first identifying
the current owner.

### 6.6 MPP reset and IOMMU restoration

RGA centralizes provider refresh after recovery.  MPP has several reset paths,
and source inspection alone cannot prove that every one needs or must avoid an
additional provider refresh on the current Rockchip implementation.

**Proposed hardware experiment:** force timeout, error IRQ, and IOMMU fault on
two simultaneous streams; record reset/provider-refresh counters and verify the
next job on each core.  Once the measured requirement is known, centralize the
post-reset provider action in the common recovery transition and add assertions
that no resend occurs before restoration succeeds.

### 6.7 Conformance cases requiring absent vendor heaps

The 2026-08-02 suite result included official samples that hard-code
`system-uncached` or `system-uncached-dma32`, heap types absent from the
upstream-style kernel.  Such a failure measures platform allocator inventory,
not the rewrite driver.

**Implemented harness policy:** the thirteen vendor-heap samples are outside
the default required list and return only when
`LIBRGA_ENABLE_VENDOR_HEAP_CASES=1`.  The device-free
`LIBRGA_SUITE_VALIDATE_CASES=1` selftest ensures they cannot leak back into the
default list.  A previously generated summary can still contain them if it
predates that change, explicitly overrides `RGA_REQUIRED_CASES`, or enables the
opt-in variable; preserve the environment with each run.

### 6.8 Copyout and partial-array transaction boundaries

Several BSP-compatible interfaces mutate state before the last userspace
copyout:

- a ready RGA async job may dispatch before its release-fd number is copied;
  copyout failure publishes no fd but does not prove the blit did not execute;
- MPP `TRANS_FD_TO_IOVA` retains mappings completed before a later bad fd or
  copyout failure, while `RELEASE_FD` keeps earlier releases when a later fd is
  invalid;
- MPP finish poll consumes the completed job before readback copyout, and slice
  poll pops a record before copying it, so `-EFAULT` is destructive.

The streamlined ABI documents these boundaries rather than claiming rollback
that the source does not provide.

**Proposed redesign:** add explicit prepare/commit state for RGA async fence
publication, transactional mapping batches for MPP translation, and a claimed
but retryable reap state for MPP readback/slice delivery.  Each change affects
observable BSP behavior and needs libmpp/librga fault-injection tests before it
can replace the documented contract.

## 7. Validation matrix

| Evidence | Current result | What it proves |
|---|---|---|
| `rga_rewrite.o` configured build | Pass | RGA implementation and embedded KUnit code compile in the current 6.18 configuration |
| `mpp_rewrite.o` configured build | Pass | MPP implementation and embedded KUnit code compile in the current 6.18 configuration |
| `git diff --check` in both worktrees | Pass | No whitespace-error patch defects |
| KUnit manifest check | Pass | Named suite inventory matches the source: 92 MPP and 152 RGA cases |
| Rewrite KUnit source audit | Pass: 305 signals, 0 new | No new production-singleton or fixture-debt signals |
| Default librga case-list selftest | Pass: vendor heaps 0 | The 13 absent-heap cases stay out of the default required run |
| YSP `scripts/check-repo.sh` | Pass | Repository documentation/link/handoff contract |
| Booted MPP/RGA KUnit | Not run on corrected source | Required before claiming logic-level runtime closure |
| Official librga suite on corrected kernel | Not run | Required for userspace/hardware closure and CMA failure localization |
| Forced SWIOTLB and recovery fault injection | Not run | Required for the conditional MPP/RGA cache and reset questions |

The configured build commands use the native package toolchain path required on
this host:

```sh
cd /home/yi/Code/rock-5b/kernel/linux-6.18-rkvenc
PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  make -j2 drivers/video/rockchip/rga-rewrite/rga_rewrite.o
PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  make -j2 drivers/video/rockchip/mpp-rewrite/mpp_rewrite.o
```

The next booted gate is deliberately separate:

1. build/install the corrected kernel and reboot;
2. persist the complete MPP/RGA KTAP interval and fatal-log scan;
3. rerun the default librga suite with its environment captured;
4. inspect `summary.tsv`, artifacts, driver events, selected-core counters, and
   dmesg together;
5. run the opt-in vendor-heap cases only on a kernel that actually exposes
   those heap nodes; and
6. run targeted forced-Route-B, forced-RGA2, timeout/error, and SWIOTLB tests.

## 8. Release interpretation

The code changes close the source-level invariants described in Sections 4 and
5.  They do not by themselves turn the rewrite into a production-validated
kernel.  In particular:

- the currently supplied function-graph trace proves request preparation, not
  the selected-core DMA mapping branch or its return value;
- a configured object build proves compilation, not interrupt/power race
  behavior;
- embedded KUnit changes prove nothing until their booted KTAP result is
  preserved; and
- the absence of vendor DMA heaps must be represented as an opt-in capability
  difference, not counted as a rewrite-driver failure.

With those boundaries, the main source conclusion is firm: the former blanket
multi-SG rejection is fixed, the rewrite and forward port now share the same
representability decisions, and the remaining genuine RGA3 gap is a deliberate
hardware/ownership limitation.  The remaining work is admission policy and
hardware evidence, not another unchecked first-address-plus-summed-lengths
shortcut.
