# Rewrite-driver retrospective: keep the ownership model, change the architecture and qualification order

> Scope: `kernel-drivers` — the `mpp-rewrite` and `rga-rewrite` downstream
> compatibility drivers, their KUnit suites, and the two-kernel replay workflow.
> Source: `../rock-5b/kernel/linux-6.18-rkvenc` branch
> `rk3588-rewrite-6.18@db09af2111768`; initial rewrite commit
> `6826e7174b8b6`; current project evidence through the
> [round-3 review](2026-08-01-rewrite-driver-review-round-3.md),
> [cross-core reset-wedge result](2026-08-01-rewrite-soft-ccu-cross-core-reset-wedge.md),
> [KUnit suite audit](2026-08-01-rewrite-kunit-boot-failures-and-suite-audit.md),
> and [`rewrite-validation-plan.md`](../kernel-drivers/docs/rewrite-validation-plan.md).
> Date: 2026-08-01
> Trust: **CODE-INSPECTED**, **MEASURED** where linked to the booted wedge and
> KUnit findings, **INFERRED** for the architectural assessment, **DESIGN** for
> the counterfactual implementation plan.

## Result

The rewrite chose the right **ownership direction** and the wrong
**implementation order**.

The durable gains are real: session-owned state, immutable or stable submitted
jobs, retained imports and hardware, exact active-slot claims, generation-tagged
recovery, fail-closed address provenance, explicit ABI ledgers, and quarantine
when reset cannot prove DMA stopped. Those properties are materially stronger
than the BSP's distributed global service/request/memory ownership and should
survive any future implementation.

The mistake was allowing the drivers to become broad compatibility products
before three foundations were stable:

1. the shared-hardware topology and recovery owner;
2. a one-way validated request/command representation; and
3. a source-bound hardware differential gate run after each vertical slice.

The git history makes the sequencing debt visible. The first rewrite commit
added **10,756 lines** in one change: 3,338 lines of MPP, 7,067 lines of RGA,
two ABI ledgers, and build wiring. At `db09af2111768`, `git log` reports **300
commits touching the two rewrite directories**. The later commit granularity is
good, but review began from a large simultaneous MPP+RGA base and then expanded
feature breadth faster than board qualification could retire it.

The strongest evidence is the *shape* of the defects rather than their count.
The 2026-08-01 round-3 audit found 11 defects; eight were previously recorded
fixes applied to one site but missed at a structural twin: one RGA emitter but
not another, one completion path but not recovery, five DCHS retirement paths
but not the sixth, one user-sized allocation but not its sibling, and final
address revalidation followed by a later user-directed RCB register write. A
ledger saying a class was fixed was therefore stronger than the structure the
code actually enforced.

This is not an argument that the rewrite failed. It is an argument that the
best part of it is the model, while the main remaining risk comes from
hand-repeating that model across a large private-ABI implementation.

## What should be kept

### Explicit lifetime owners

Keep the four distinct lifetimes:

- service/module state;
- one-open session state;
- refcounted accepted job state; and
- refcounted hardware/mapping state.

An ioctl returning is not completion. Jobs retain the session, selected
hardware, imports, mappings, descriptors, callback state, and fence state that
can outlive the syscall. Close and remove disable admission before draining.
IRQ, timeout, fault, reset, close, and remove contend for one protected active
slot instead of each independently freeing a global task.

### Fail-closed admission

Keep the rewrite's refusal to guess:

- unknown commands and flags are rejected;
- raw RGA physical-address and kernel-pointer imports are not compatibility
  obligations;
- literal MPP IOVAs must resolve inside retained session mappings;
- image planes and command/register regions are extent-checked;
- DMA mappings belong to the selected device/domain, not merely to a buffer;
- topology, MMIO sizes, hardware identities, core masks, and shared-domain
  assumptions are checked before admission; and
- a core or dependency group is quarantined after failed recovery proof.

This is the rewrite's largest safety improvement over the BSP and a reason to
retain a downstream compatibility implementation even if a separate standard
media interface is developed.

### The forward port as a differential oracle

Keep the BSP-derived forward port after the rewrite becomes usable. It contains
silicon knowledge and established userspace behavior that source elegance
cannot replace. Identical assets, commands, artifacts, counters, and timing
across dual boots are the strongest available rewrite test.

### Evidence boundaries

Keep the distinction between build, KUnit, boot, hardware conformance,
recovery, performance, and soak. KUnit can prove parser, arithmetic, ownership,
and state-transition contracts. It cannot prove real MMIO semantics, clocks,
IRQs, IOMMU retirement, reset ordering, pixels, or bitstreams. A green case
manifest is the first qualification rung, not a release verdict.

## What should change

### 1. Choose the product before choosing the implementation

There are two different products:

1. a downstream drop-in implementation of `/dev/mpp_service` and `/dev/rga`
   for existing `librockchip_mpp` and `librga`; and
2. an upstream-style V4L2/vb2/media-request implementation.

The rewrite is the first. Using public kernel mechanisms reduces version drift,
but preserving the BSP UAPIs still requires bespoke parsers, buffer/import
ownership, scheduling, polling, fences, and recovery. It can become a strong
downstream driver, but it does not incrementally turn into the second product.
A V4L2-facing path needs a separate frontend and contract.

Share hardware lifecycle/backend code only where the semantics genuinely
overlap. Do not make upstreamability depend on accepting a raw register-job
UAPI, and do not make full `librga` compatibility depend on pretending V4L2's
narrower one-source mem2mem contract expresses composition, proprietary
compression, request IDs, and the entire RGA operation matrix.

The “public API only” description should also be audited literally. Current
RGA source includes `<linux/dma-map-ops.h>`, whose header says it is for DMA
mapping implementations rather than ordinary DMA-API consumers; the include
appears unnecessary, but that should be compile-verified before removal. Both
drivers also require new Rockchip/VSI fault-provider hooks. Those hooks may be
well-defined and exported, but they are bespoke cross-subsystem integration
that still needs independent IOMMU review.

### 2. Make shared hardware a first-class owner

The original model centered `rk_mpp_hw`, then layered cross-core rules onto it.
That is the wrong ownership altitude for RK3588 decoder recovery.

A future MPP design should construct explicit **CCU group**, **reset domain**,
and **DMA/IOMMU group** objects during topology validation. Those objects own:

- group power references and sibling-power sequencing;
- reset assertion/deassertion serialization;
- the coordinator arm-to-START critical section;
- shared link/descriptor state;
- IOMMU refresh and fault routing;
- group quarantine and recovery; and
- removal of a group member while dependent work exists.

Per-core hardware should own only private registers, IRQ state, a queue/active
slot, and private clocks/resets. A per-core lock must not be expected to make a
group-wide reset invariant true.

The measured evidence is decisive. The soft-CCU reset stress repeatedly wedged
the full interconnect when sibling power-on deassert overlapped a core's reset
pulse. Seventeen consecutive stress runs survived after the reset-domain lock.
The lock fixed the immediate defect; the counterfactual lesson is that the
reset domain should have been the object performing both operations from the
first implementation.

### 3. Replace procedural validation with a one-way typed pipeline

Use an explicit pipeline:

```text
raw ABI
  -> normalized request
  -> validated semantic plan
  -> selected-core/mapped plan
  -> sealed command or register image
  -> hardware
```

Each stage consumes the previous representation and produces a new one. Later
stages must not read untrusted raw fields that the validator interpreted
differently.

For RGA this means, at minimum:

- distinct wire-orientation and canvas-orientation rectangles;
- one normalized layout record containing checked strides, planes, extents,
  offsets, compression geometry, rotation, and alias policy;
- profile booleans derived from the validator that succeeded, never directly
  from raw request flags; and
- emitters that accept only the validated profile/layout, not `struct rga_req`.

That structure would have prevented the portrait-rotation and
quantize/color-key classes: a WIN0 emitter could not silently consume raw
pre-swapped geometry, and an emitter could not enable a feature whose validator
never ran.

For MPP, all transformations that can write a register image — fd translation,
separate offsets, RCB insertion, CCU/DCHS patching, and fixed backend fixups —
must precede one authoritative **seal** operation. The seal re-reads every
selector, verifies every address-like word against retained mappings or
kernel-owned scratch, and makes the image immutable. No path may write a
hardware-visible word afterward. The 2026-08-01 RCB ordering defect existed
because “final validation” was a comment and call position rather than a state
the type system and helpers enforced.

### 4. Have one completion and recovery engine

IRQ, timeout, IOMMU fault, reset-session, close, unbind, and shutdown should be
**triggers**, not independent implementations of terminal work.

Each trigger should:

1. claim the exact active job/generation under the small state lock;
2. choose a reason and required recovery policy; and
3. enter one shared slow transition engine.

The engine owns stop/reset proof, IOMMU refresh, mapping retirement, userptr
copyback, task advancement, result publication, fence/waiter notification,
power release, quarantine, and the scheduler kick. Backend adapters can supply
register-specific stop/reset/readback operations, but they must return to one
common tail.

This is the structural answer to round 3's missed twins. A source audit should
not need to confirm that six similar completion paths all remembered the DCHS
lock, multi-task advancement, deadline preservation, and scheduler wakeup.

### 5. Split source by ownership, not by historical BSP subsystem

Retain local ownership while breaking up the translation units. A reasonable
shape is:

```text
mpp-rewrite/
  service.c        session.c       uapi.c
  dma.c            scheduler.c     recovery.c
  cluster.c        rkvenc2.c       rkvdec2.c       av1.c
  internal.h       tests/*_kunit.c

rga-rewrite/
  service.c        session.c       uapi.c
  import.c         layout.c        scheduler.c     recovery.c
  rga2.c           rga3.c          internal.h      tests/*_kunit.c
```

This should be pure code motion before further behavior changes. The objective
is not smaller files for their own sake; it is to give parsing, normalization,
mapping, lifecycle, group recovery, and each backend one reviewable owner
without recreating the BSP's global cross-manager lifetime.

The current embedded KUnit regions — about 5,499 MPP lines and 11,284 RGA lines
at the round-3 pin — bisect production code and force test-only forward
declarations and struct members. Move them first, with a source-audit signal
count proving that the move changed no logic.

### 6. Rebuild the test hierarchy around independent oracles

Use three deliberately separate layers:

1. **Device-free KUnit** for bounded parsing, normalization, arithmetic,
   routing, address provenance, and independently specified golden command
   words.
2. **Isolated lifecycle KUnit** for ownership, fences, timeout generations,
   abort, recovery, and removal, built only through complete production
   constructors or explicit test builders that establish every invariant.
3. **Public-ABI and hardware conformance** for behavior visible through device
   nodes, pixels, bitstreams, counters, logs, IRQs, DMA, IOMMU, power, and reset.

Do not use a target case count. The gate should compare the ordered or named
manifest and report missing/new cases. Consolidate consumer-named tests that
reach the same normalized recipe into parameterized vectors. A golden expected
value must not be computed by the production helper being tested.

No KUnit case may unregister or reprobe a production driver, reuse a production
singleton as scratch state, hand-build a partial 45-field hardware object, or
depend on cleanup after a fatal assertion. A failing case must produce one
attributable failure, not poison later cases, live lockdep, the service mutex,
or the runtime device.

### 7. Qualify vertical slices before broadening scope

The implementation order should be:

1. non-submit ABI discovery, import/release, version, and negative paths;
2. one core with linear DMA-BUF for H.264/H.265 and RGA copy/scale/convert;
3. byte-exact forward-port differential plus hostile close/reset under
   KASAN/lockdep;
4. multicore scheduling and first-class shared-domain/reset recovery;
5. async fences and userptr;
6. 10-bit, AFBC/tile, and advanced RGA operations required by measured current
   consumers;
7. AV1 and opt-in hard CCU last.

Every slice must boot and pass its source-bound hardware differential before
the next feature family lands. Unsupported profiles remain explicit
`-EOPNOTSUPP`; they are not implementation debt unless an observed current
consumer or chosen compatibility contract requires them.

This order would have surfaced shared-CCU power/reset behavior, IOTLB refresh,
real librga rotation geometry, and small-geometry AFBC behavior while the
relevant code was still small. It would also have kept hard-CCU and broad RGA2
feature work from competing with qualification of the default Rock 5B path.

### 8. Make source identity and replay mechanical

Keep one canonical driver series and replay it automatically onto supported
kernel bases. Require byte-identical driver/UAPI/ABI files as an output check,
not as a manually maintained property of two branches. Use dedicated clean
worktrees and build packages only from immutable archives of exact commits.

Generate source pins, manifests, and line/case counts where practical. The
rewrite history has already shown the cost of shared mutable build worktrees:
an ostensibly forward-port source package swept in rewrite files and a
rewrite-side IOMMU implementation. Path exclusions alone cannot protect shared
files such as `rockchip-iommu.c`; the whole exported tree must be tied to the
intended commit and compared against the canonical source.

## Driver-specific counterfactual

### MPP: rewrite again, but cluster-first and narrower

MPP remains a good rewrite target. Its private ABI is mostly a register-job
transport, so excluding legacy hardware and vendor infrastructure produces a
meaningful source and ownership simplification. The rewrite also directly
removes dangerous BSP assumptions around session state, literal addresses,
global task retirement, and failed reset.

Start with the CCU/reset/DMA groups, one decoder and encoder core, and a sealed
register image. Add multicore only after group recovery is hardware-proven.
Keep hard CCU opt-in until the default soft-CCU path is qualified. Treat AV1 as
a separate backend with separate VSI-IOMMU evidence rather than letting its
source availability imply parity.

### RGA: do not chase the complete private matrix in one rewrite

RGA's kernel ABI is semantic: the driver must understand formats, planes,
strides, rectangles, transforms, composition, compression, tiling, fences,
core masks, and multi-task behavior, then emit hardware commands. That
complexity does not disappear when ownership improves.

For full `librga` compatibility, retain the hardened forward port as the broad
shipping implementation while a rewrite grows only from measured consumer
profiles. In parallel, an upstream-style V4L2 path can own a narrower
one-source scale/convert/blit contract. Share backend/lifecycle code where the
contracts align, but do not make either frontend pretend to cover the other.

If a full downstream `/dev/rga` rewrite remains the chosen product, build it
from normalized, validated operation plans and parameterized format/layout
tables. Do not add a feature solely because the UAPI has a field for it.

## Language choice

C was not the primary mistake. The missed defects came from topology,
duplicated transitions, raw-to-emitter coupling, and qualification order.

Rust becomes attractive when the target kernels provide usable safe
abstractions for dma-buf, dma-fence/sync_file, userptr pinning, DMA/IOMMU
attachment and IOVA management, and the deployment path can build them
reliably. Until then, a Rust rewrite would put large unsafe bindings exactly at
the lifetime-critical boundary while adding cross-kernel and DKMS churn. The
near-term safety return is higher from first-class group ownership, sealed
plans, one recovery engine, complete fixtures, KASAN/KCSAN, and hardware
differential testing.

## Evidence and reproduction

Source-history measurements used in this assessment:

```sh
git -C ../rock-5b/kernel/linux-6.18-rkvenc show --stat 6826e7174b8b6
git -C ../rock-5b/kernel/linux-6.18-rkvenc \
    log --format='%H' db09af2111768 -- \
    drivers/video/rockchip/mpp-rewrite \
    drivers/video/rockchip/rga-rewrite | wc -l
```

The structural-twin count and current test-region measurements come from the
round-3 audit. The shared-reset conclusion and 17-run post-lock discriminator
come from the cross-core wedge finding. Test-fixture conclusions come from the
KUnit lifecycle, rationalization, and boot-suite findings linked above.

No new kernel was compiled or booted for this retrospective.

## Boundary

This is a counterfactual design assessment, not proof that the proposed
architecture is bug-free or cheaper in total engineering time. Some RK3588
hardware relationships remain incompletely documented by the TRM, so even a
group-first model still requires BSP comparison and board experiments.

The line and commit counts measure history and source shape, not defect density
or author productivity. The large KUnit body is not itself a quality defect;
its placement, fixture isolation, duplicated oracles, and substitution for
hardware proof are the problems.

The recommendation does not change the current deployment verdict. Keep the
hardware-validated forward port as the shipping implementation until the
rewrite satisfies the complete production-readiness gate: booted sanitizer
evidence, byte-exact differential parity, hostile recovery, fuzz coverage of
the recovery lines, performance, and soak.

## Why it matters

The rewrite already contains the reference model needed for a better second
implementation. Repeating it as another feature-for-feature transcription
would waste the most valuable lesson: ownership clarity is necessary but not
sufficient. The next design should make shared topology, validation stages, and
terminal transitions structurally singular, then force hardware evidence to
arrive before feature breadth.
