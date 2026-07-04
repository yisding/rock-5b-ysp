# Multi-core decode: the scheduling problem

Why running the RK3588's **two** VDPU381 decoder cores at once is hard, where a
scheduler could live, what the kernel already does elsewhere, and what the CCU's
hard/soft modes actually mean for the mainline V4L2 model. This is the analytical
companion to [mainline-rkvdec-v4l2.md](../../../kernel-versions/docs/mainline-rkvdec-v4l2.md) (read that
first) and complements the **vendor** stack's already-solved multi-core treatment
in [how-the-drivers-work.md § 7](../../docs/how-the-drivers-work.md).

> **Anchors & provenance.** `file:line` for the V4L2 side resolve against the
> **mainline** tree (`rk3588-rewrite-mainline`, `drivers/media/v4l2-core/`,
> `.../rockchip/rkvdec/`). CCU claims come from the **vendor** tree
> (`rockchip-linux/kernel`, `develop-6.1`,
> `drivers/video/rockchip/mpp/mpp_rkvdec2*.c`). Web-sourced claims (the Collabora
> series, mailing-list direction) are cited in § 8; where something is **inferred**
> rather than read, it says so.

---

## 1. The problem, in one paragraph

The RK3588 has two identical VDPU381 cores. Running them in parallel is blocked by
**three** layered things, not one: (a) the V4L2 **mem2mem framework** is a
single-execution-unit scheduler, (b) the **ABI** constraint that you must not
expose one `/dev/videoN` per core, and (c) the **decoder-specific** fact that
frames within a stream depend on each other (the DPB), so you can't freely
parallelize one stream. The uAPI is *not* the blocker — the stateless request API
is agnostic to core count.

---

## 2. mem2mem is a single-execution-unit scheduler

**In plain terms.** The framework every V4L2 codec is built on can only ever have
**one** job running per device. It time-multiplexes many open contexts through a
single execution slot.

**Under the hood.** `struct v4l2_m2m_dev` holds a **single** `curr_ctx` pointer
(`v4l2-mem2mem.c:96`), not a pool. That pointer does triple duty:
1. **the busy gate** — `v4l2_m2m_try_run` bails `if (curr_ctx != NULL)` (`:257`),
   so at most one `device_run()` is outstanding;
2. **the IRQ back-reference** — drivers call `v4l2_m2m_get_curr_priv()` in their
   IRQ to learn who just finished (rkvdec does exactly this);
3. **the completion assertion** — `_v4l2_m2m_job_finish` requires
   `curr_ctx == m2m_ctx`, then sets `curr_ctx = NULL` (`:469-482`).

Everything else (`__v4l2_m2m_try_queue` `:293`, `schedule_next_job` `:448`,
`suspend` `:544`) keys off those. There is no core index, no slot count, no pool
anywhere in the framework. **To use N cores today, a driver must instantiate N
separate `v4l2_m2m_dev`s** — which is precisely the per-node ABI you don't want.

---

## 3. The load-bearing constraint: one job per stream, N streams in parallel

You **cannot** run two jobs from the same context concurrently — frame N
references frame N−1 via the DPB. But jobs from *different* contexts are
independent.

The framework already enforces one-job-per-context (a ctx carries `TRANS_QUEUED`,
`__v4l2_m2m_try_queue` refuses to re-queue it, `schedule_next_job` re-queues only
after completion). So `job_queue` holds at most one entry per context, and pulling
N distinct head entries yields N distinct contexts — **intra-stream ordering is
preserved for free.** This fixes the scope: **parallelism is across sessions, not
across frames of one session.** Cross-session is the 80 % win anyway (multiple
decode instances, transcode, tabs). Intra-stream parallelism (tiles/WPP) needs
codec-aware dependency tracking that doesn't belong in a generic scheduler.

The data path is already ready for this: references resolve by timestamp against
the shared CAPTURE queue, and CAPTURE buffers are device-global DMABUFs
([mainline-rkvdec-v4l2.md § 6c](../../../kernel-versions/docs/mainline-rkvdec-v4l2.md)).

---

## 4. Design space: where could the scheduler live?

Three options, in increasing invasiveness:

1. **In the driver, behind one node** — the driver keeps a free-core list and
   multiplexes; framework stays single-slot. *This is what ships in mainline
   today* (amphion does it; see § 5).
2. **In the mem2mem framework** — grow it a pool of slots. Most general (every
   multi-core driver benefits) but touches a load-bearing file.
3. **In userspace / a separate uAPI** — what Rockchip's downstream MPP does
   (`mpp_service` chardev load-balances across cores, non-V4L2). Mainline rejects
   this direction.

### The framework-slot sketch (option 2)

A strict superset at `num_slots == 1`:
- `curr_ctx` → `curr_ctx[N]`, add `num_slots`, `num_running`; ctx gains `cur_slot`.
- `try_run` becomes a fill-free-slots loop, and **`list_del`s the ctx on dispatch**
  (today the running ctx stays on `job_queue`; a slot loop would re-pick it).
- `_v4l2_m2m_job_finish` clears the ctx's slot via `cur_slot` (O(1)).
- new `v4l2_m2m_get_curr_priv_by_slot(dev, slot)` for **per-core IRQs** (the one
  genuinely new API — each core raises its own IRQ and needs core→ctx).
- `device_run(priv)` keeps its signature; the driver reads `cur_slot` to know
  which core to program.

### `job_ready` is *not* where core-selection goes

`job_ready(priv)` (`v4l2-mem2mem.c:361`, optional) is a **queue-time, core-
independent** gate: "does this stream have a runnable job?" (e.g. vim2m needs
`translen` buffers; wave5 walks a state machine). Core-selection is a **different,
dispatch-time** question: "can this stream run on *this core*?" — a `(ctx, core)`
predicate. Folding a slot arg into `job_ready` conflates two questions at two call
sites. If affinity ever matters (heterogeneous cores, per-core SRAM/IOMMU), add a
*separate* optional `job_eligible_on(priv, slot)`. But note it turns dispatch into
bipartite matching → head-of-line blocking + starvation policy. For **identical**
cores (RK3588) you omit it entirely and FIFO fairness holds — which is the whole
reason v1 should scope to identical cores.

---

## 5. Prior art: other multi-core schedulers in the kernel

The kernel has several "dispatch work across N hardware units" schedulers. Ordered
by closeness to this problem:

| Subsystem | Execution units | Dependencies? | Lesson |
|---|---|---|---|
| **DRM GPU scheduler** (`drivers/gpu/drm/scheduler/`) | `drm_gpu_scheduler` per engine; entity = context | **yes — dma_fence** | closest analog: `drm_sched_pick_best` load-balances across identical engines; fences model exactly the DPB dependency |
| **blk-mq** (`block/blk-mq.c`) | `blk_mq_hw_ctx`, `nr_hw_queues` | no | poster child of HW multi-queue; pluggable I/O schedulers = separate mechanism from policy |
| **crypto engine / QAT** | `crypto_engine` per unit; QAT rings | no | accelerator precedent; some drivers = one engine per queue (the N-single-slot workaround) |
| **dmaengine** (`drivers/dma/`) | `dma_chan` | no | the "own a unit" model — allocate a channel for the duration |
| **NIC multi-queue** (XPS/RSS) | TX/RX queues | no | pure identical-queue load-balance; affinity for locality |
| **padata** (`kernel/padata.c`) | CPUs | ordering only | parallelize then **re-serialize outputs to submission order** |

Takeaways for mem2mem: (1) **`drm_sched` already solves parallel-engines-with-
dependencies** — it's the one framework whose model maps 1:1 (engine=core,
entity=context, fence=DPB reference); (2) everyone separates **dispatch mechanism
from fairness policy** (blk-mq schedulers, `pick_best`, padata's serial stage) —
don't bake policy into `try_run`; (3) only `drm_sched` models per-stream ordering
as first-class, because everything else has independent work.

---

## 6. Amphion — the one in-tree multi-core-behind-one-node precedent

`drivers/media/platform/amphion/` genuinely schedules across same-type cores in
kernel, behind single dec/enc nodes: `vpu_dev` holds a `cores` list; each
`vpu_core` is a separate platform device; `vpu_core_find_proper_by_type()` picks
the **least-loaded** core; only two video nodes are ever registered. This is the
exact shape rkvdec wants. Caveat: amphion is **stateful** (firmware owns the DPB),
so it sidesteps the stateless dependency problem in-kernel. MediaTek vcodec also
dispatches across units, but they're **heterogeneous** LAT/CORE pipeline stages
(one node, subdev-per-stage, `vdec_msg_queue` handoff), not identical cores.

---

## 7. The CCU and its hard/soft modes

The RK3588 decoder has a real hardware coordinator, the **CCU** (Central Control
Unit, TRM v1.0 § 5.6.5 "VDPU381 CCU configuration flow", p. 676) — sitting in
front of the two cores. It has **two modes**, the vendor's own enum, selected by
the `rockchip,ccu-mode` device-tree property (default = soft):

| Mode | Vendor enum | Who runs the dispatch loop |
|---|---|---|
| **Soft** | `RKVDEC2_CCU_TASK_SOFT` (`<1>`) | **software** (driver kthread) |
| **Hard** | `RKVDEC2_CCU_TASK_HARD` (`<2>`) | **the CCU hardware**, autonomously |

Grounded in the vendor source (`mpp_rkvdec2.c:1748-1757`, `1959-1972`;
`mpp_rkvdec2_link.c`):

- **SOFT** (`rkvdec2_soft_ccu_worker`/`_enqueue`/`_dequeue`): a kthread dequeues a
  task and *software* assigns it to an idle core and programs registers. The CCU
  is a coordination substrate (shared IOMMU domain, core idle/status registers).
- **HARD** (`rkvdec2_hard_ccu_enqueue`, `mpp_rkvdec2_link.c:2540`): the driver
  builds a **task table in memory**, hands its address to the CCU
  (`writel(task->table->iova, ... RKVDEC_CCU_CFG_ADDR_BASE)`), sets a **core
  bitmask** (`work_mode`, `RKVDEC_CCU_CORE_WORK_BASE`), flips each core to "control
  by ccu" (`RKVDEC_LINK_BIT_CCU_WORK_MODE`), and the CCU **autonomously** fetches
  and dispatches, raising one `rkvdec2_hard_ccu_irq` on completion. This is a
  hardware scheduler / linked-command-buffer engine (the same "link" mechanism
  whose register region surfaces in mainline vdpu383).

**So SOFT/HARD is exactly the "who owns the scheduling loop" axis** — confirmed in
silicon: SOFT = CPU owns dispatch (maps onto mem2mem); HARD = CCU owns dispatch
(mem2mem demoted to a submission queue, the blk-mq shape).

> **Traced (§ 7a): SOFT and HARD have the *same parallelism model*, differing only
> in the dispatch loop.** Both dispatch a **whole-frame task to one idle core**;
> two cores run two frames at once. SOFT: `rkvdec2_get_idle_core`
> (`mpp_rkvdec2_link.c:2041`) scans a `core_idle` bitmap, then
> `rkvdec2_soft_ccu_enqueue` (`:1976`) programs that one core. HARD:
> `rkvdec2_hard_ccu_prepare` (`:2435`) builds a per-task command **table** whose
> `tb_reg_next` field chains it into a hardware-walkable **linked list**;
> `rkvdec2_hard_ccu_enqueue` (`:2540`) hands the head IOVA to the CCU
> (`RKVDEC_CCU_CFG_ADDR_BASE`), sets the core-participation mask, and the CCU
> **autonomously** dispatches each linked task to an idle core (one IRQ per task,
> `ADD_MODE` to append). **Neither mode splits a frame across cores, and neither
> enforces inter-frame dependencies** — the FIFO linked list has no reference-
> ordering logic (`rkvdec2_hard_ccu_dequeue` `:2290`; the "only 2 cores … break
> early" comment at `:2366` shows at most two *whole* tasks run at once). So HARD
> is **CPU-offload / autopilot dispatch, not a new capability** over SOFT.

### The two facts that decide the strategy

1. **Even Rockchip defaults to SOFT; HARD is effectively unvalidated** ("doesn't
   work as expected" per secondary sources). Building on HARD depends on a path
   the vendor themselves avoid, on closed silicon. The clean-room rewrite now
   honors `rockchip,ccu-mode`, defaults to SOFT, and keeps HARD opt-in, but HARD
   still needs differential soak testing before it can be treated as a safe
   performance path. See
   [rewrite-hard-ccu-finding.md](../../iommu/docs/rewrite-hard-ccu-finding.md) for the fixed
   divergence, remaining test-coverage gap, and validation/fuzz plan.
2. **Mainline's multicore series is already doing SOFT — without the CCU.** The
   vendor's `rkvdec2_attach_ccu` shares the IOMMU domain by attaching non-main
   cores to the main core's domain (`if core_id != 0 → attach main domain`). The
   Collabora series does the same high-level thing more explicitly in the V4L2
   driver: every core has its own Rockchip IOMMU hardware, but the cluster uses
   the first core's default domain as one shared IOVA address space. For
   **independent-stream** parallelism the CCU's coordination registers are
   optional — so mainline needs no CCU for the common case, which is why the
   Collabora series never mentions it.

**Corollary (revised after tracing HARD mode — see § 7a blockquote):** the CCU does
**not** unlock single-stream-across-cores. HARD mode load-balances *whole-frame
tasks* across the two cores exactly like SOFT mode; it does not split a frame and
does not resolve DPB dependencies. So the CCU's only real delta over mainline's
software scheduling is **dispatch efficiency** (autonomous hardware list-walking,
one IRQ per task, less CPU overhead) — a *performance* win, not a capability
mainline lacks. The earlier hypothesis that HARD mode is needed for a single 8K
stream on both cores was **refuted by the trace**; the "8K@30 in pair" figure is
aggregate whole-frame throughput, not frame-splitting. This *weakens* the case for
a CCU driver: mainline's software scheduling already reproduces the SOFT/HARD
parallelism model.

> **Corruption footnote.** The "running two cores concurrently corrupts memory"
> claim (earlier Collabora framing) is best read as an **IOMMU/IOVA** problem —
> the dedicated multicore-IOMMU patch is the fix, and there is **no** CCU/cache-
> coherency patch in the mainline series. The correction from the full thread is
> that the fix is **not** distinct per-core IOVA spaces: it is one shared domain,
> seeded from the first core's default DMA domain, attached to all per-core
> Rockchip IOMMUs so maps and TLB flushes reach every core. The RKMPP forward-port
> needs the same model, but as explicit CCU-owned state; see
> [mpp-ccu-iommu-plan.md](../../iommu/docs/mpp-ccu-iommu-plan.md).

---

## 8. The real upstream direction (corrects an earlier framing)

The active RK3588 multi-core work (Collabora: Detlev Casanova, Nicolas Dufresne)
goes the **mem2mem** route, **not** drm_sched, and it runs cores **in parallel**,
not time-multiplexed. From the v1 `rkvdec` multicore cover letter:

> "The 2 cores are able to work in parallel, but only contexts are parallelized:
> 1 stream, that uses 1 context, will only be able to use 1 core as it usually
> needs previous frames already decoded to use as reference frames."

i.e. **different streams on different cores; one stream stays on one core** —
exactly the § 3 model. The framework change is smaller than the slot-array sketch:
they **split `v4l2_m2m_buf_done_and_job_finish()` into a "done" and a "finish"
part** (`v4l2_m2m_buf_done_manual()`), so the driver can free the scheduler slot
and dispatch the next job while a previous one still executes, completing buffers
out-of-band from the per-core IRQ. `job_ready()` is the one-job-per-context guard.
Patch list: `buf_done_manual`, drop a `WARN_ON` in `job_finish`, RCB sizing,
multicore support, wait-for-buffers-before-stop, and a separate **multicore IOMMU
support** patch. **No CCU.**

Two corrections this supersedes: the earlier "time-multiplex to *prevent*
concurrency" framing (an older kernel-7.0-era stopgap) — the v1 series is
genuinely parallel; and "there's an active drm_sched-for-codecs discussion" —
there isn't one I could substantiate. drm_sched *is* being generalized (variable
run-queues; the `drivers/accel/` NPU users), but the **media** subsystem is
extending mem2mem, not adopting it.

---

## 9. What a CCU driver would mean for V4L2, and where it lands

Post-trace (§ 7a), the picture is simpler than the earlier "capability" framing —
both modes do whole-frame-task → idle-core, so there is no "one job → N cores"
case at all:

| Goal | Mechanism | V4L2 impact |
|---|---|---|
| Many streams → both cores | SOFT / software sched (**no CCU**) | none — the Collabora series delivers it |
| Same, but hardware-dispatched | HARD / CCU list-walker | **CPU-offload only**, no new capability; would still map onto mem2mem (each task = one `device_run` on one core), just with the CCU running the loop |

Because HARD mode is whole-task dispatch (not one-job-fans-to-N-cores), it does
**not** break `device_run` the way a true cooperative mode would. So a CCU driver,
if built, is a **uAPI-invisible execution backend** inside
`drivers/media/platform/rockchip/rkvdec/` — single `/dev/video` preserved,
stateless request API untouched, CCU below `device_run`. Precedents: amphion's
core-list, MediaTek's coordinator-subdev. Keep `v4l2-mem2mem` semantics untouched.
The variable-execution-units model gap I worried about earlier **does not
actually arise** for this silicon — there is no cooperative decode that eats all
cores for one job. (It would only matter for a *hypothetical* frame-splitting
mode, which the RK3588 CCU does not implement.)

**Recommended sequencing:** finish SOFT-equivalent independent-stream multi-core
(≈90 % there via the Collabora series, no CCU). A CCU driver is now an **optional
CPU-offload optimization** on top of that — worth it only if software-dispatch
overhead proves to be a real bottleneck, and even then gated on HARD mode's
unvalidated-silicon risk. It is **not** a prerequisite for any capability.

---

## 10. Open questions / honest caveats

- **RESOLVED (§ 7a blockquote):** HARD mode does **not** pipeline one stream's
  frames across cores or split a frame — it hardware-dispatches *whole-frame
  tasks* to idle cores, same model as SOFT, with no dependency gate (traced through
  `rkvdec2_hard_ccu_prepare`/`_enqueue`/`_dequeue`/`_worker`,
  `mpp_rkvdec2_link.c:2290–2743`). The "8K@30 in pair" figure is aggregate
  whole-frame throughput. HARD vs SOFT = CPU-offload, not capability.
- The corruption mechanism (§ 7 footnote) is inferred from the patch shape.
- Vendor findings are from `develop-6.1`; other branches may differ.
- Framework-slot design (§ 4) is a sketch, not the path taken — the shipped series
  uses the done/finish split (§ 8).

## Sources

- rkvdec multicore v1 cover letter — <https://patchew.org/linux/20260409-rkvdec-multicore-v1-0-62b316abf0f7@collabora.com/>
- Collabora, "From Panthor to RK3588 … kernel 7.0" — <https://www.collabora.com/news-and-blog/news-and-events/from-panthor-to-rk3588-advancing-graphics-video-soc-support-linux-kernel-7.html>
- LWN, "media: rockchip: Add rkvdec2 driver" — <https://lwn.net/Articles/979108/>
- PINE64 wiki, Mainline Hardware Decoding (CCU TRM §5.6.5, soft/hard, 8K@30) — <https://wiki.pine64.org/wiki/Mainline_Hardware_Decoding>
- Vendor source — `rockchip-linux/kernel` `develop-6.1`, `drivers/video/rockchip/mpp/mpp_rkvdec2.c` + `mpp_rkvdec2_link.c`.
