# RK3588 AV1 BSP and Linux 6.18 forward-port code review

> Date: 2026-07-20<br>
> BSP pin: `rockchip-kernel` `develop-6.1@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`<br>
> Forward-port pin: `linux-6.18-rkvenc-av1-fwport`
> `rkvenc-fwport-6.18@655d178191807e24e9ca4dd72e74401b449d2099`<br>
> Tracked export: [`forward-port-rk3588-av1/`](../../patches/forward-port-rk3588-av1/README.md),
> 42 patches (`0001` through `0043`, with `0012` intentionally omitted)<br>
> Method: three independent static reviews, source/differential inspection,
> patch-ID comparison, patch parse checks, and DWARF layout inspection. No new
> board, fault-injection, or sanitizer run was performed.<br>
> Trust: **CODE-INSPECTED** for confirmed defects, **INFERRED** where hardware
> behavior or exploitability is not demonstrated.

## Result

The current AV1 forward port is a useful working oracle, but it is **not safe
against an adversarial `/dev/mpp_service` client**. The most urgent defect is a
deterministic kernel-object overwrite: AV1 defines 103 address translations,
the common task object has room for 80 attachment records, and its off-by-one
guard admits record 81. One valid dma-buf fd repeated in 81 translated AV1
registers is enough to overwrite task state and workqueue fields before the
hardware runs.

The review found six other high-severity forward-port issues: unchecked custom
translation-table indexes, a reset-versus-task-allocation race, repeatable
session-initialization list corruption, uncontained raw/offset IOVAs, and
unsynchronized IOMMU callback/component teardown. These are mostly inherited
MPP-core design defects exposed by adding the three-bank AV1 backend; they are
not regressions caused by the already-reviewed request-splitting fixes.

The Rockchip 6.1 BSP also has a separate cluster of AV1 IOMMU defects. Its
private provider stores page tables in the provider rather than the IOMMU
domain, corrupts generic domain-list state during switches, frees a devm-owned
provider from domain teardown, and fails to unregister after late probe
errors. The 6.18 forward port does **not** carry that provider: it uses the
standalone VSI IOMMU implementation instead. That choice avoids the BSP
domain-model bugs, although the hybrid VSI/MPP callback lifetime still needs
hardening.

The device is deliberately exposed as `root:video 0660` by this repository's
udev policy, so “client reachable” below includes an ordinary local member of
the `video` group, not only root.

## Priority findings

| ID | Severity | Scope | Status | Finding |
|----|----------|-------|--------|---------|
| AV1-R1 | high | BSP + forward port | confirmed | The 81st translated address overwrites `mpp_task.state`, `abort_request`, and `delayed_work`; AV1 has 103 possible translations but the task stores 80 mapping records. |
| AV1-R2 | high | BSP + forward port | confirmed | `INIT_TRANS_TABLE` entries are unchecked class-local indexes; the same table is applied to 512-, 166-, and 212-word AV1 banks, permitting heap out-of-bounds reads and possible writes. |
| AV1-R3 | high | BSP + forward port | confirmed race | `RESET_SESSION` can destroy `session->dma` while a new task is allocating/importing buffers but before `task_count` is incremented. |
| AV1-R4 | high | BSP + forward port | confirmed | Issuing `INIT_CLIENT_TYPE` twice leaks the old DMA session and inserts the same `session_link` into a workqueue list twice, corrupting list topology. |
| AV1-R5 | high | BSP + forward port | security/design defect | Embedded offsets, separate offsets, and `REG_FD_NO_TRANS` can program an IOVA not proved to fall inside a dma-buf owned and pinned by the current task. |
| AV1-R6 | high | forward-port integration | confirmed lifetime gap | VSI fault-handler removal does not wait for an already-snapshotted callback; component remove also leaves the service's AV1 pointer published. Fault/completion/unbind races can reach freed task or device state. |
| AV1-R7 | medium/high | BSP + forward port | confirmed | Clock/reset getters retain `ERR_PTR`, AV1 init reports success, and reset helpers discard errors; provider deferral can become an invalid-pointer call and failed recovery is reported as success. |
| AV1-R8 | medium | BSP + forward port | confirmed | Register-offset metadata uses a floored element count but copies the original byte count, allowing a seven-byte overwrite after `elem[80]`. |
| AV1-R9 | medium | BSP + forward port | confirmed arithmetic defect; hardware impact inferred | AFBC dimension, payload-offset, and IOVA additions use unchecked `u32` arithmetic and do not validate the computed span against the imported buffer. |
| AV1-R10 | low bug / medium integration risk | forward-port VSI | confirmed / inferred | The shared VSI IRQ returns `IRQ_HANDLED` even with no VSI status; fault masking has an MPP refresh path but no equivalent recovery contract for the base Hantro consumer. |
| AV1-B1 | high | BSP private AV1 IOMMU only | confirmed | Page tables belong to the provider, not each `iommu_domain`; domain changes continue using the same translation tables and preserve stale mappings. |
| AV1-B2 | high | BSP private AV1 IOMMU only | confirmed | Optional-provider attach publishes a new domain/list link without detaching the generic old link and does not unwind the publication on provider attach failure. |
| AV1-B3 | high | BSP private AV1 IOMMU only | confirmed | Domain free destroys the devm-owned provider object; late private-probe failure leaves an already-registered IOMMU device in the global IOMMU list. |
| AV1-B4 | medium/high | BSP private AV1 IOMMU only | confirmed | `av1_pte_page_address()` always loses physical-address bits 39:32, so `iova_to_phys()` returns the wrong page above 4 GiB. |
| AV1-B5 | medium | BSP private AV1 IOMMU only | confirmed no-op / fault-storm risk | Generic MPP fault masking reaches an AV1 wrapper whose generic MMIO count is zero, while the private provider has no mask hook. |

Severity describes kernel impact, not a claim of demonstrated privilege
escalation. AV1-R1 through R4 are directly reachable state or memory-safety
failures; AV1-R5's cross-client consequence depends on a target IOVA being
known or guessed; AV1-R6 needs a fault/teardown race.

## Primary source locations

Locations below are relative to the pinned sibling worktree named in the
scope. Line numbers deliberately refer to the reviewed commits rather than a
moving branch tip. An unqualified basename uses the directory of the preceding
fully qualified path in that row.

| Finding | Forward-port evidence (`linux-6.18-rkvenc-av1-fwport`) |
|---------|--------------------------------------------------------|
| AV1-R1 | `drivers/video/rockchip/mpp/mpp_common.h:36,416-435`; `mpp_common.c:1935-1984`; `mpp_av1dec.c:205-235,435-499` |
| AV1-R2 | `drivers/video/rockchip/mpp/mpp_common.c:1416-1434,1987-2035`; `mpp_av1dec.c:160-235,472-499` |
| AV1-R3/R4 | `drivers/video/rockchip/mpp/mpp_common.c:611-672,1364-1404,1461-1482` |
| AV1-R5 | `drivers/video/rockchip/mpp/mpp_common.c:1987-2035`; `mpp_av1dec.c:415-499` |
| AV1-R6 | `drivers/iommu/vsi-iommu.c:199-215,885-901`; `drivers/video/rockchip/mpp/mpp_iommu.c:788-820,914-936`; `mpp_common.c:2426-2466` |
| AV1-R7 | `drivers/video/rockchip/mpp/mpp_common.c:685-710,2663-2684`; `mpp_av1dec.c:923-952` |
| AV1-R8 | `drivers/video/rockchip/mpp/mpp_common.c:2078-2096` |
| AV1-R9 | `drivers/video/rockchip/mpp/mpp_av1dec.c:533-630` |
| AV1-R10 | `drivers/iommu/vsi-iommu.c:235-271`; `drivers/video/rockchip/mpp/mpp_common.h:27-29` |

| Finding | BSP evidence (`rockchip-kernel`) |
|---------|------------------------------------|
| AV1-B1 | `drivers/iommu/rockchip-iommu-av1d.c:33-51,186-208,327-399,503-563` |
| AV1-B2 | `drivers/iommu/rockchip-iommu.c:1326-1353`; `rockchip-iommu-av1d.c:566-615` |
| AV1-B3 | `drivers/iommu/rockchip-iommu.c:1433-1458,1691-1754`; `rockchip-iommu-av1d.c:618-657` |
| AV1-B4 | `drivers/iommu/rockchip-iommu-av1d.c:90-131,378-404` |
| AV1-B5 | `drivers/iommu/rockchip-iommu.c:1535-1545`; `drivers/video/rockchip/mpp/mpp_iommu.c:480-490` |

## Forward-port details

### AV1-R1 — 103 AV1 translations overflow 80 task records

The common limit is inconsistent with the AV1 backend:

- `mpp_common.h` defines `MPP_MAX_REG_TRANS_NUM` as 80 and embeds
  `struct mpp_mem_region mem_regions[80]` in `struct mpp_task`;
- `mpp_av1dec.c` defines 67 VCD, 24 cache, and 12 AFBC address-register
  entries, for a total of 103;
- `mpp_task_attach_fd()` checks `task->mem_count > mem_num`, then immediately
  takes `&task->mem_regions[task->mem_count]`;
- duplicate fds still copy another `mpp_mem_region`, append another list node,
  and increment `mem_count`.

At `mem_count == 80`, the test is false and element 80 is already outside the
array. DWARF inspection of the compiled arm64 `mpp_av1dec.o` confirms that the
array ends at byte 4560 of `struct mpp_task`; `state` begins at byte 4560,
followed by `abort_request` and `delayed_work`. A duplicate entry copies 56
bytes there and then treats the overwritten area as a list node.

This is reachable with three ordinary class write requests and one valid
dma-buf fd repeated in 81 built-in translation slots. It corrupts the task
during allocation, before AV1 hardware execution. The BSP has the same `>`
guard at its `mpp_common.c:1819`.

The immediate fail-closed fix is `>=`. That alone would reject valid-looking
large AV1 jobs, so the complete fix must also size attachment/binding storage
from the backend's validated tables or deduplicate references without losing
per-register provenance. Add an exact 80/81/103 boundary test under KASAN.

### AV1-R2 — custom translation tables are not compatible with AV1 banks

`MPP_CMD_INIT_TRANS_TABLE` accepts up to 80 raw `u16` entries but validates
neither element alignment nor index range. `mpp_translate_reg_address()` then
uses each entry directly as `reg[tbl[i]]`, without receiving the register
bank's word count.

AV1 calls that helper separately with pointers to three dense allocations:

| Bank | Valid local word indexes |
|------|--------------------------|
| VCD | `0..511` |
| cache | `0..165` |
| AFBC | `0..211` |

The same session table is applied to every touched bank. An index valid for VCD
can cross the cache or AFBC allocation; a larger `u16` index produces an
unconditional heap out-of-bounds read, followed by an out-of-bounds IOVA write
if the fetched low bits resolve to a valid fd.

Custom tables also *replace* the built-in backend tables rather than augmenting
them. Omitting a known AV1 DMA register therefore leaves a literal userspace
address in the hardware image. The safest compatibility design is a
class-aware validated table that augments mandatory backend entries. If the
ABI cannot describe AV1 classes unambiguously, reject custom tables for AV1.

### AV1-R3 and AV1-R4 — the session has no serialized state machine

Task admission and reset use `task_count` as if it covered every task-creation
phase, but `mpp_process_task_default()` calls the backend `alloc_task()` first.
AV1 imports and translates dma-bufs during that call. Only afterward does the
common path initialize task lifetime state and increment
`session->task_count`.

On another thread using the same file descriptor, `RESET_SESSION` can observe
zero, take the IOMMU write semaphore between two import operations, destroy
`session->dma`, and set the pointer to NULL. Allocation or its unwind then
continues against freed or missing state. The per-operation IOMMU semaphore
does not cover the whole admission interval.

Reset also leaves the session attached to its workqueue but without a DMA
session. Reissuing `INIT_CLIENT_TYPE` is not a safe recovery path: that command
unconditionally overwrites `session->dma`/`session->mpp` and calls
`list_add_tail()` on the already-linked `session_link`. Repeating the same type
leaks the old DMA session and self-links/corrupts the queue list; changing type
also creates inconsistent queue/device ownership.

Use an explicit per-session state and admission lock. Client type should bind
once: repeating the same type may be idempotent, while changing it must return
`-EBUSY`. Reset should block new allocation, wait for both allocators and
admitted tasks, release mappings, recreate a usable DMA session, advance a
generation, then reopen admission without adding the queue link again.

### AV1-R5 — IOMMU containment is not client ownership

The normal translation path decodes the fd and offset from a userspace
register, imports the fd, and writes `buffer->iova + offset`. It does not check
the offset against `buffer->size`, include the hardware access span, or reject
addition overflow. Later `SET_REG_ADDR_OFFSET` values are added again without
checking the cumulative range.

`MPP_FLAGS_REG_FD_NO_TRANS` skips import entirely, and the driver neither
privilege-gates the flag nor proves literal addresses against mappings owned by
the session. All sessions for the AV1 device use the device's IOMMU domain; a
per-session DMA cache is not a per-session address space. The IOMMU prevents
arbitrary host-physical DMA, but an out-of-range or literal address can fault
or land in another currently mapped device IOVA.

Every known DMA-address register should resolve to a mapping owned by the
current session and remain referenced by the task through completion. Check
embedded plus separate offsets, required access length, direction, and 32-bit
addition. Raw-address compatibility should require an explicit mapping from
the same session/device and otherwise fail closed.

### AV1-R6 — fault callbacks and service publication outlive their owners

The VSI IRQ copies `fault_handler` and its token under `fault_lock`, releases
the lock, and invokes the callback. `vsi_iommu_set_fault_handler(..., NULL,
NULL)` only clears the stored pair; it does not synchronize the IRQ or wait for
a callback that already copied the token. The MPP callback dereferences the
token as `struct mpp_dev` and reads `mpp->cur_task` without taking a task
reference. AV1 completion, reset, and remove can change or free that state.

The component lifetime has a second hole. `mpp_dev_register_srv()` publishes
`srv->sub_devices[MPP_DEVICE_AV1DEC]`, but `mpp_dev_remove()` never clears the
slot, blocks admission, drains tasks, or synchronizes both AV1 and VSI IRQ
callbacks. Runtime unbind can therefore leave a service lookup pointing at
devm-freed AV1 state.

Removal order should be: mark the component unavailable and clear the service
slot under service locking; reject new/repeated binding; cancel or drain tasks
and sessions; unregister and synchronize the VSI callback and both AV1 IRQs;
then detach IOMMU/workqueue/runtime-PM state. Callback storage needs
IRQ synchronization or an RCU/SRCU-style lifetime rule.

### AV1-R7 through R10 — error and recovery paths

- `mpp_get_clk_info()` stores `devm_clk_get()` without `IS_ERR()` and returns
  success. `mpp_reset_control_get()` likewise passes error pointers through
  helpers that check only non-NULL. AV1 init logs some errors but returns zero;
  AV1 reset and the common reset path discard reset/PMU failures. Propagate
  `-EPROBE_DEFER`, require the binding's clocks/resets, and quarantine a device
  whose recovery reset fails.
- `mpp_extract_reg_offset_info()` computes `cnt = size / 8`, validates the
  floored count, then copies the original byte count. With an empty table,
  size 647 yields count 80 and copies seven bytes past the 640-byte array. The
  older cleanup draft already changes the copy length, but the exported series
  still contains the vulnerable helper. Reject non-multiple sizes as well as
  limiting the copy to remaining complete elements.
- `av1dec_set_afbc()` computes width/height products and
  `bus_address + offset` in `u32`. Maximum encoded dimensions overflow the
  product before division, and no result is checked against the dma-buf behind
  register 505. Use checked 64-bit arithmetic, hardware field limits, and the
  same owned-mapping span check required by AV1-R5.
- The VSI IRQ is requested shared but returns `IRQ_HANDLED` after an active-PM
  status read even when no VSI status bit is set. It should return `IRQ_NONE`
  when `fault == false`. The first fault also masks the provider. MPP recovery
  refreshes it, but a Hantro consumer has no equivalent contract; fault
  masking/re-enable policy belongs in the provider or must be explicit per
  consumer.

The forward port additionally replaces the BSP's real PMU bus-idle request
with a no-op and marks the ROCK 5B AV1 node to skip it. Its board override uses
only A/P resets while the base Hantro node also describes A/P BIU resets. This
is a **recovery risk**, not a proven defect: happy-path bit-exact decode does
not show whether a timeout or IOMMU fault with in-flight AXI traffic can be
recovered safely. A fault-injection test must decide whether BIU reset and a
real idle handshake are required.

## BSP-private AV1 IOMMU findings

These findings apply to Rockchip's 6.1 private `rockchip-iommu-av1d.c` path.
They are not carried into the 6.18 VSI-based forward port.

### AV1-B1 — translation tables have provider lifetime, not domain lifetime

`struct av1d_iommu` contains `dt`, `dt_dma`, `pta`, and `pta_dma`. They are
allocated once by provider probe. The private `map`, `unmap`, and
`iova_to_phys` operations ignore their `iommu_domain` argument and retrieve
that provider object from device platform data; enable always programs the
same `pta_dma`.

Consequently a default-DMA to unmanaged/VFIO domain switch does not select a
new page table or clear old translations. This violates the IOMMU domain
contract and permits stale mappings to survive into the new domain. Rockchip's
older 5.10 implementation used a domain object with its own tables; the 6.1
wrapper/provider conversion regressed that ownership model.

Restore per-domain table state and program the attached domain's root, or use
the VSI provider after it satisfies the lifetime requirements in AV1-R6.

### AV1-B2 and AV1-B3 — generic and private lifetimes disagree

The optional-provider branch of `rk_iommu_attach_device()` publishes
`iommu->domain` and adds the generic `iommu->node` to the new domain list
without first detaching an old generic-domain link. The private attach helper
only clears its private domain pointer. On a domain switch the same list node
can therefore remain in the old list and be added to the new one; if clock
enable fails, the generic publication is not rolled back.

Teardown is also inverted. Generic domain free calls the private provider's
`free`, which releases the provider-global tables and `kfree()`s the
`av1d_iommu` allocated by `devm_kzalloc()`. Platform data and IRQ/PM paths still
refer to it, and devres will later free it again.

Finally, generic probe registers `iommu_device` before calling the private AV1
probe. If the private probe fails on MMIO, clocks, IRQ, or table allocation,
the error path removes sysfs and drops the group but omits
`iommu_device_unregister()`. The global IOMMU list can retain a pointer into
devm-freed generic state.

Initialize the private provider before external registration, register last,
and fully unregister every post-registration failure. Attach must detach old
generic and private state before publication and roll both back on failure.
Domain free must release a domain object only; provider teardown belongs to
the platform device remove/devm lifetime.

### AV1-B4 and AV1-B5 — address decode and fault containment

`av1_mk_pte()` packs physical bits 39:32 into PTE bits 11:4. Its inverse masks
the 32-bit PTE with `GENMASK_ULL(39, 32)`, which is always zero, so high bits are
lost. For example, physical page `0x3456789000` is encoded as `0x56789341` but
the BSP helper decodes `0x56789000`. This corrupts `iova_to_phys()` above 4 GiB
and can make noncoherent DMA synchronization address the wrong low page. Use
the VSI inverse form and add round-trip tests at 4 GiB and the 40-bit maximum.

MPP also expects its IOMMU fault callback to mask further interrupts until
timeout recovery. The generic Rockchip mask helper loops over generic MMIO
bases, but the AV1 wrapper branches before those bases/count are populated;
the private provider exposes no mask hook. Thus masking is a no-op and a
continuing bad transaction can interrupt/log repeatedly until the watchdog
disables the line and resets. Add provider-owned mask/unmask and test a
continuing fault, not only a single reported fault.

## Architecture and maintenance findings

1. **The common ABI core does not derive limits from the backend.** AV1-R1 is
   the clearest result: a codec with 103 mandatory address registers was
   attached to a task structure hard-coded for 80. Register-bank lengths,
   translation counts, mapping records, and offset metadata need one
   backend-validated description used by parsing, allocation, translation,
   MMIO, and tests.
2. **Sessions lack explicit states and generations.** Binding, allocating,
   queued/running, resetting, closing, and component removal are coordinated by
   scattered atomics and lists. AV1-R3/R4/R6 are different symptoms of that
   missing ownership model.
3. **The register UAPI treats the IOMMU as sufficient isolation.** It is not:
   device-domain containment does not prove that one client owns an IOVA. The
   clean-room rewrite's owned-mapping rule is the right architectural target
   for this port too.
4. **AV1 has two mutually exclusive IOMMU/front-end lineages.** The BSP
   private provider is domain-incorrect; the VSI path is structurally better
   but its callback/recovery contract is partly MPP-specific while the base
   device tree also serves Hantro. Provider lifetime and recovery must not
   depend on which consumer happens to fault.
5. **The source export is reproducible but not submission-shaped.** All 42
   checked-in patches match their source commits by stable patch ID; no newer
   6.6 `mpp_av1dec.c` fix was lost. The series has no manifest (filename order
   is canonical), mixed subject numbering after patch 39, and the AV1/IOMMU
   additions lack normal sign-off/MAINTAINERS treatment. Patch `0001` also
   combines a very large vendor MPP/RGA import, making review and bisection
   expensive.
6. **Tracked source and deployment differ.** The repository series contains
   `0042`/`0043`, while the Published PPA still stops at `0041`. The latter
   therefore lacks the already-confirmed RESET_SESSION double-free and RKVENC2
   post-free-read fixes even before the new findings in this review.

## Verification and gaps

| Check | Result |
|-------|--------|
| Exact pins and clean sibling worktrees | PASS |
| BSP 6.1 versus official 6.6 `mpp_av1dec.c` | byte-identical; no lost newer AV1 backend fix |
| Tracked patch export versus forward-port commits | 42/42 stable patch IDs match; unrelated libbpf commit is intentionally absent |
| Mailbox patch parsing | PASS for all 42 files |
| Compiled arm64 task layout via `pahole` | confirms record 81 begins exactly at `mpp_task.state` |
| Existing happy-path hardware evidence | 30/30 AV1 frames bit-exact on 2026-07-04; not rerun here |
| New build, sanitizer, or hardware reproduction | not run |

The existing happy-path result remains valid evidence that the backend can
decode the tested stream. It does not cover the findings above. Before another
production publication, add at least:

- KASAN ABI tests for 80, 81, and 103 nonzero built-in translations;
- invalid custom indexes for each bank and odd-sized custom/offset tables;
- a task-allocation versus reset race and repeated same/different client init;
- owned-IOVA boundary, cumulative-offset, wrap, and raw-address cases;
- VSI fault versus completion/unbind races with callback synchronization;
- AV1 timeout/IOMMU-fault recovery under in-flight AXI, including a decision on
  PMU idle and BIU resets;
- suspend/resume loops and shared Hantro/RKMPP provider recovery;
- AFBC on/off, 8/10-bit, maximum dimensions, multi-tile, and 8K boundaries.

## Recommended order

1. **Stop-ship memory/lifetime fixes:** AV1-R1 through R4 and R6, with KASAN
   tests before packaging.
2. **Restore DMA provenance:** AV1-R5 plus checked AFBC and offset arithmetic.
3. **Make recovery fail closed:** propagate clock/reset errors, serialize
   callback removal, validate VSI/Hantro fault recovery, and decide the idle /
   BIU-reset contract.
4. **Fix or retire the BSP private provider:** AV1-B1 through B5 should block
   use of that 6.1 AV1 IOMMU path; the forward port should continue with a
   corrected VSI provider rather than importing the private provider.
5. **Then rebuild and run the full AV1 matrix:** a successful small bit-exact
   clip is necessary, but it is not a memory-safety, isolation, or recovery
   gate.

## Relation to earlier findings

This review does not reopen the seven donor `mpp_av1dec.c` defects already
fixed in [`av1-bsp-audit.md`](av1-bsp-audit.md): request fan-out overflow,
split-copy underflow, register-range arithmetic, class off-by-one, translation
iterator reuse, ignored offset-helper return, and early ISR dereference. It
also excludes the fixed VSI map/attach/identity issues in that audit and the
later `0042`/`0043` KASAN findings.

AV1-R8's unsafe copy length was already present in the unapplied common-core
cleanup draft, and AFBC arithmetic was already listed as an open follow-up.
They remain unresolved in the exported series, so they are included here as
current-code findings rather than presented as new discoveries.
