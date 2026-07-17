# Rockchip BSP driver quality is feature-strong but below mature mainline robustness

> Scope: Rockchip `develop-6.1` BSP, with detailed inspection of RK3588
> MPP/RGA and the RKNPU kernel/userspace stack, plus representative DRM,
> clock/pinctrl/IOMMU/PHY, and camera samples; compared with mainline media,
> DRM, and accelerator-driver patterns at Linux `v7.2-rc2`
> Source: `rockchip-kernel@b4ef083dc0c3`,
> `airockchip/rknn-toolkit2@59a913d172e7` (RKNN Runtime 2.3.2),
> `linux-6.18-rkvenc-av1-fwport@1c9a110129fe`, and
> `linux@v7.2-rc2` (`4c45e14df2f4`)
> Date: 2026-07-16
> Trust: CODE-INSPECTED / SOURCE-INSPECTED / MEASURED / INFERRED for the
> comparative ratings

## Result

The Rockchip BSP is strong hardware-enablement code but its BSP-only
accelerator stacks are below mature mainline-driver quality in hostile-input
validation, resource lifetime handling, client isolation, kernel-framework
integration, public review traceability, and cross-branch maintenance.

It is appropriate to describe the MPP/RGA/RKNPU stacks as usable for a fixed
appliance with trusted matching userspace, but not as generally safe
unprivileged kernel ABIs. Access to `/dev/mpp_service`, `/dev/rga`, and the
RKNPU render or misc node is a security boundary. This does not justify calling
every Rockchip driver poor: upstream-derived/framework-led areas such as DRM
display are materially closer to normal mainline quality.

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
  upstream-stable `Linux 6.1.141@58485ff1a74f`; official RKNN distribution
  `59a913d172e7`, containing `librknnrt` 2.3.2; current RK3588 forward port
  `1c9a110129fe`; mainline comparison `v7.2-rc2@4c45e14df2f4`.
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

### RKNPU deep dive: capable fixed stack, unsafe multi-client ABI

The canonical explanation of how the stack works is now the diagram-rich
[`RKNPU/RKNN guide`](../kernel-drivers/rknpu/docs/how-rknpu-works.md). This
section is deliberately the quality and security appendix to that architectural
guide.

The RKNPU result is more serious than the earlier mechanical sample suggested.
The driver is a compact and feature-rich kernel resource manager, but the
default DRM render-node ABI discards the ownership guarantees that GEM handles
are meant to provide. The matching userspace is convenient at the public API
level but the graph compiler, command emitter, ioctl bridge, and runtime are
distributed as proprietary prebuilt binaries. Taken together, this is a
closely coupled appliance stack rather than a reviewable, independently
maintainable accelerator platform.

#### Where the implementation lives

The inspected public distribution splits responsibility as follows:

| Layer | Inspected form | Responsibility and quality consequence |
|---|---|---|
| RKNN Toolkit2 | Python examples plus architecture-specific 2.3.2 `.whl` files | Converts, quantizes, and optimizes source models into target-specific RKNN models; the compiler implementation is not source-visible. |
| RKNN Toolkit-Lite2 | Python examples plus aarch64 2.3.2 `.whl` files | Provides the board-side Python API over the native runtime; examples are readable, the implementation is not. |
| RKNN Runtime | headers, examples, stripped `librknnrt.so` and `rknn_server` binaries | Loads RKNN models, allocates/imports buffers, emits low-level task/register-command data, submits work, and implements the C API. |
| RKNPU kernel driver | 8,598 lines of GPL-2.0 C/headers under `drivers/rknpu` | Owns GEM/dma-buf memory, IOMMU mappings, per-core queues, register launch, IRQ completion, fences, power/devfreq, and reset. |

The aarch64 Linux `librknnrt.so` is a stripped 7,726,232-byte ELF. Its exported
API includes model/context lifecycle, blocking and asynchronous run/wait,
dma-buf/physical-memory imports, zero-copy tensor memory, cache synchronization,
core selection, custom operators, and matmul. Its embedded version is
`2.3.2 (429f97ae6b@2025-04-09T09:09:27)`. Binary strings name per-target
`RKNPUEmitter` implementations, register-command and task buffers, both
`/dev/rknpu` and DRM render nodes, and explicit minimum-driver-version checks.
This corroborates the source-level boundary: the kernel does not parse an RKNN
graph; opaque userspace turns that graph into the low-level data the kernel
launches.

The repository's top-level **RKNN SDK License** permits limited Rockchip-product
use and modification but prohibits decompilation, reverse engineering, and
attempts to derive source. Individual examples carry open-source headers, but
that does not make the compiler or runtime implementation open source. This
prevents normal source review, sanitizer builds, downstream bug fixes, and
independent ABI conformance testing of the most complicated part of the stack.

#### What is good

The implementation is not a minimal proof of concept:

- one driver covers the RK356x, RK3588, RK3562, RK3576, RV1106, and RV1126B
  families through explicit SoC configuration;
- the default backend uses DRM GEM and PRIME dma-buf sharing, while an alternate
  misc-device backend integrates Rockchip dma-heaps;
- buffers can use contiguous or scatter-gather backing, cacheable mappings,
  SRAM/NBUF plus DDR in one IOVA range, DMA32, and up to 16 switchable IOMMU
  domains;
- the runtime API exposes dma-buf import, zero-copy tensors, explicit cache
  synchronization, core masks, asynchronous execution, and fence fds;
- kernel integration includes clocks, resets, regulators, multiple power
  domains, delayed power-off, OPP/devfreq/thermal control, load accounting,
  debugfs/procfs, timeout logging, and soft reset; and
- the runtime checks the kernel driver version and reports an incompatibility
  rather than blindly assuming every binary/kernel pairing works.

Those are meaningful product-engineering strengths. They explain why the stack
can work well when Rockchip qualifies one board image, kernel, runtime, and
model-toolchain tuple.

#### Kernel ABI and correctness findings

The same source also contains several independently reproducible high-risk
paths. These are static source findings; exploitability beyond denial of service
has not been demonstrated here.

1. **The DRM ABI exposes and then trusts kernel pointers.**
   `rknpu_gem_create_ioctl()` returns both a device DMA address and
   `obj_addr = (uintptr_t)rknpu_obj` to userspace. `rknpu_job_alloc()` casts the
   submitted `task_obj_addr` straight back to `struct rknpu_gem_object *` and
   increments its GEM reference. `rknpu_job_subcore_commit_pc()` dereferences
   the same pointer. `rknpu_gem_sync_ioctl()` likewise casts `obj_addr` and
   dereferences it. Submit and sync receive `struct drm_file *` but do not use
   it to look up a file-local handle. This leaks a kernel address, permits
   attacker-selected kernel-pointer dereferences/refcount operations, and
   bypasses per-open GEM ownership.
2. **Task-buffer bounds and command provenance are not validated.** The submit
   gate checks only nonzero `task_number` and a numeric upper bound on
   `core_mask`. It does not prove that `task_start + task_number` or any
   per-subcore range fits the task GEM object, that the object is kernel-mapped,
   that job and object use the same IOMMU domain, or that `regcmd_addr` and
   `task_base_addr` name admitted command buffers. The commit path indexes
   `task_obj->kv_addr` with those caller-controlled ranges, reads the first and
   last task, later writes interrupt status through the derived last-task
   pointer, and programs caller-supplied device addresses into NPU registers.
3. **All six private DRM ioctls are `DRM_RENDER_ALLOW`, including global
   controls.** Any process admitted by render-node file permissions can request
   a device-wide soft reset, change bandwidth priority/expectation/time-window
   registers, switch the global RKNPU IOMMU domain, and call
   `set_user_nice(current, value)`. There is no `capable()` check; the last path
   bypasses the normal `setpriority(2)` permission gate and can give the caller
   a negative nice value. Reset and bandwidth actions also let one client
   disrupt others.
4. **The IOMMU domains serialize mappings but do not isolate clients.** Domain
   ids are global, caller-selected numbers rather than per-file objects. Submit
   ignores `file_priv`, does not bind a domain or task object to an open file,
   and does not require the submission domain to match the task object's
   allocation domain. The refcount prevents detaching a domain while an
   operation holds it; it is not an authorization model.
5. **Fence error and timeout paths are inconsistent.** An invalid input fence
   or interrupted fence wait returns after job allocation without freeing the
   job or its task-object reference. A zero return from
   `dma_fence_wait_timeout()` means timeout, but the driver treats only negative
   values as failure and can launch the job before the dependency signals. It
   also passes the API's millisecond timeout directly where the fence helper
   expects jiffies. Output-fence fd creation does not release a reserved fd if
   `sync_file_create()` fails, and the submit path does not reject a negative
   fd returned by `rknpu_fence_get_fd()`.
6. **The alternate misc-device backend adds a kernel-stack overwrite path.**
   Its top-level ioctl dispatch switches only on `_IOC_NR(cmd)`, without
   checking the ioctl type, direction, or encoded size. MEM_CREATE then obtains
   `in_size = _IOC_SIZE(cmd)` and copies that many bytes into a fixed-size
   `struct rknpu_mem_create` on the kernel stack. A crafted command can encode a
   size larger than that structure. This path is configuration-dependent; GEM
   is the Kconfig default.
7. **The custom scheduler admits invalid shapes and has fragile recovery.** On
   three-core RK3588, masks `0x5` and `0x6` pass the numeric mask check but have
   no case in `rknpu_job_commit()`, so queued work does not launch. The public
   `priority` field is not used by the per-core FIFO scheduler. Async timeout
   cleanup compares a microsecond delta directly with the millisecond timeout
   field and performs a device-wide reset; blocking waits convert the same
   field with `msecs_to_jiffies()`. Removal warns about live/queued jobs rather
   than draining them through a framework-owned teardown path.
8. **Flags, reserved fields, and cache ranges are weakly checked.** The public
   header defines `RKNPU_JOB_MASK`, `RKNPU_MEM_MASK`, and
   `RKNPU_MEM_SYNC_MASK`, but the implementation does not reject unknown bits.
   Cache sync takes a raw object pointer and caller-controlled offset/size
   without first proving file ownership or bounding the range to the object.

The highest-priority defect is the raw `obj_addr` contract because it defeats
the safety property the DRM front end appears to provide. Merely changing node
names from `/dev/rknpu` to `/dev/dri/renderD*` does not make a private ABI safe.

#### Comparison with mature accelerator drivers

The relevant comparison is not whether other drivers also accept device command
streams; many do. It is how they bind those streams and buffers to the calling
client and contain malformed input.

| Property | RKNPU 0.9.8 | Mature in-tree examples |
|---|---|---|
| Object identity | Exports a kernel pointer and DMA address; submit/sync trust the pointer | DRM GEM specifies file-local integer handles retrieved with `drm_gem_object_lookup()`; dma-buf fds are used for intentional sharing. |
| Per-open state | DRM submit, sync, and action ignore `file_priv` | Intel IVPU keeps a refcounted `ivpu_file_priv` with a per-client MMU context, command-queue xarray, job-id range, limits, and close/abort cleanup. |
| Client authorization | Global caller-selected domain id; no object/domain/file binding | QAIC looks up every BO through the caller's DRM file and verifies that the selected DMA bridge belongs to that client's handle before execution. |
| Submit validation | Nonzero task count and numeric core-mask ceiling | Etnaviv rejects unknown flags/states, caps stream/BO/relocation counts, looks up BO handles, validates command streams where required, applies relocations, and pins reservations before launch. |
| Scheduling and recovery | Private per-core FIFO, custom fences, global reset | Etnaviv/Panfrost and many current accelerator drivers use DRM scheduler entities/jobs and standard dma-fence/syncobj dependency and teardown machinery. |
| UAPI visibility | Header lives inside `drivers/rknpu`; low-level userspace bridge is prebuilt | In-tree accelerator UAPIs live under `include/uapi`, are documented, source-reviewable, and evolve through subsystem review. |

The Linux DRM memory-management documentation explicitly defines GEM handles as
local to a DRM file and directs drivers to recover the associated object with
`drm_gem_object_lookup()`. The current
[QAIC accelerator documentation](https://docs.kernel.org/accel/qaic/qaic.html)
likewise makes client ownership an explicit isolation property. RKNPU uses the
GEM allocation and PRIME helpers, but its performance-critical ioctls bypass
that ownership model.

This does not mean Etnaviv, Panfrost, IVPU, or QAIC is bug-free or feature-
equivalent to RK3588. It means their kernel/userspace boundaries preserve
standard object identity, per-open lifetime, and scheduler concepts that RKNPU
reimplements or omits.

#### RKNPU-specific assessment

| Dimension | Assessment |
|---|---|
| Hardware/SoC enablement | A- |
| Public C/Python API ergonomics | B |
| Fixed vendor-tuple functionality | B |
| Power, memory, and dma-buf integration | B- |
| Kernel UAPI design and client isolation | F |
| Hostile-input validation and error paths | D- |
| Scheduling/recovery architecture | D+ |
| Userspace openness and reproducibility | D |
| Overall as a trusted single-purpose appliance stack | C+ |
| Overall against mature open multi-client accelerator stacks | D+ |

These ratings are judgments. The code and distribution facts above, not the
letter grades, should drive engineering decisions.

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
3.5 million added lines in the Rockchip BSP. The MPP/RGA conclusion has both a
detailed audit and direct hardware evidence. RKNPU received a focused
kernel/userspace ABI, lifetime, isolation, and recovery review, but no hardware
exercise, malformed-ioctl test, fuzzer run, or exploit development. Camera,
core Rockchip drivers, and DRM display were sampled rather than audited at the
same depth.

The ratings compare against mature in-tree driver expectations, not against a
survey of other vendors' BSP kernels. No claim is made that Rockchip is uniquely
poor among silicon-vendor product kernels.

Checkpatch counts do not measure correctness. Git trailers do not reveal
unrecorded internal review. Existing YSP hardware results were inspected but
not re-run for this finding. Mainline RGA has a much narrower feature contract,
so its smaller and cleaner source cannot be treated as feature parity with the
vendor `/dev/rga` implementation.

The RKNN userspace assessment inspected the official repository layout,
license, API headers, examples, ELF metadata, exported symbols, and diagnostic
strings. It did not decompile the proprietary binaries. RKNPU severity beyond
the source-visible pointer, bounds, ownership, and ioctl defects is inferred;
no claim of a working privilege-escalation exploit is made. IVPU, QAIC,
Etnaviv, and Panfrost differ materially in hardware and firmware architecture,
so they are reference designs for kernel boundary quality, not performance or
feature-parity comparisons.

The current forward port includes material RGA, IOMMU, AV1, fault-containment,
and buffer-validation hardening beyond the original BSP. It nevertheless
retains the directly confirmed MPP defects above and should not be described as
having absorbed the separate BSP cleanup audit series.

## Why it matters / follow-up

1. Keep `/dev/mpp_service`, `/dev/rga`, `/dev/rknpu`, and the RKNPU DRM render
   node restricted to trusted workloads; `video`/`render` membership or a seat
   ACL is a security boundary, not merely a convenience.
2. Replace RKNPU `obj_addr`/`task_obj_addr` with file-local GEM handles, look up
   and reference every object through `drm_file`, validate task/subcore ranges,
   flags, cache ranges, command-buffer membership, core-mask combinations, and
   object/domain consistency before scheduling.
3. Gate or remove render-client reset/bandwidth/nice/domain actions; make IOMMU
   and job contexts per-open, fix the misc ioctl's full-command/size validation,
   and repair fence/timeout/fd unwind before enabling untrusted access.
4. Add RKNPU KUnit and ioctl selftests plus syzkaller descriptions for create,
   import, sync, submit, fence, timeout, close, reset, and concurrent-client
   teardown. Exercise them under KASAN/KCSAN and fault injection.
5. Prioritize MPP session-fd type validation, every userspace-derived
   size/index, RGA refcount/fence paths, sleep-in-atomic findings, probe unwind,
   and raw physical imports.
6. Repair the cleanup split series' patch-0024 compile defect, obtain human
   review of refcount/bounds/security edits, then run its still-missing booted
   encode/decode/transcode and targeted-trigger regression gate.
7. Use KASAN/KCSAN, allocation and usercopy fault injection, and syzkaller-style
   ioctl tests before describing the private ABIs as production-safe.
8. Prefer standard V4L2/DRM/accelerator drivers where their feature coverage is
   sufficient;
   retain the BSP ABI as a compatibility path for hardware features not yet
   represented by the upstream interfaces.

The cleanup compile/runtime gap is already tracked in `status.md`; this finding
does not add a separate watchlist item.
