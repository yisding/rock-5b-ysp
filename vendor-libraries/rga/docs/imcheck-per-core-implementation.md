# librga per-core imcheck — detailed implementation plan

> Scope: workstream A of the
> [narrow 10-bit closure plan](../../../video-libraries/vaapi/docs/narrow-10bit-closure-plan.md);
> remediates the accept-then-`no core match` defect from the
> [no-core-match finding](../../../findings/2026-07-29-rga-no-core-match-narrow-afbc-10bit.md).
>
> Source pins: librga fork `~/Code/rock-5b/rockchip-userspace/librga-fork`
> (`yisding/librga@main`, tip `26a50ef`) — all `im2d_*` cites below verified
> against it. Kernel oracle: `drivers/video/rockchip/rga3/rga_policy.c` and
> `rga_hw_config.c` on the forward-port tree `rk3588-video-6.18`
> ([source-trees §1](../../../docs/source-trees.md)).
>
> Date: 2026-07-29. Status: **PLANNED**; all cites SOURCE-CONFIRMED unless
> marked UNVERIFIED.

## 1. Objective and honesty contract

Make `imcheck()` and `improcess()` return `IM_STATUS_NOT_SUPPORTED`, with a
reason naming each core's disqualifier, for jobs that **no** RGA core can run —
instead of today's behavior where `imcheck` passes and the kernel scheduler
later fails the submit with `no core match` and librga surfaces
`IM_STATUS_FAILED` (0).

**Direction invariant (necessary, not sufficient):** the userspace check may
only reject jobs the kernel scheduler is guaranteed to reject. A userspace pass
does *not* guarantee kernel acceptance — some exclusions are kernel-only by
nature (the RGA2 under-4G memory placement exclusion in `rga_policy.c`'s
assign loop cannot be known from descriptors). The test plan enforces both
directions: no false rejections (critical), and the finding's job rejected
early (the goal).

**Containment:** no installed-header changes, no new exported symbols, no new
`IM_STATUS` values; behavior toggleable by env var. See the closure plan §A.1
containment contract.

## 2. The kernel oracle — what must be mirrored

The scheduler's per-core gate sequence (`rga_policy.c`, assign loop ending at
`optional_cores |= scheduler->core`, "no core match" when the mask stays 0):

| # | Kernel gate | Semantics | Cite |
|---|---|---|---|
| 1 | `rd_mode & data->win[n].rd_mode` | bitmask intersection per channel: src0→win0, src1→win1, dst→win2. Color-fill jobs skip the src gates entirely | assign loop; `rga3_win_data`/`rga2e_win_data` |
| 2 | `rga_check_scale` | up/down factor vs `max_upscale_factor`/`max_downscale_factor` (RGA3 `1<<3`=8×, RGA2e `1<<4`=16×) | `rga_policy.c:257` |
| 3 | `rga_check_channel` → `rga_check_resolution` | **active rectangle** (`act_w`/`act_h`) vs `input_range`/`output_range`, both min and max. Two extras: (a) RGA3-only re-check of `act_w + x_offset` / `act_h + y_offset` vs `input_range`; (b) dst is checked with w/h **swapped** under 90°/270° rotation (`need_swap`) | `rga_policy.c:195-256`, `:105-114` |
| 4 | `rga_check_format` | exact per-win, per-rd_mode format lists | `rga_policy.c:116-160` |
| 5 | `rga_check_align` | `vir_w` vs `byte_stride_align` (RGA3 16, RGA2e 4), with the fork's 10-bit byte-stride convention (`w_stride * 8` bits for 10-bit formats) | `rga_policy.c:162-193` |
| 6 | `rga_check_csc`, `rga_check_rotate` | CSC mode and rotation support per core | `rga_policy.c:47`, `:297` |

Core envelopes (`rga_hw_config.c`):

| Core | input_range | output_range | byte_stride | win rd_mode |
|---|---|---|---|---|
| RGA3 (`rga3_data:572`) | {68,2}–{8176,8176} | {68,2}–{8128,8128} | 16 | all three wins: `RASTER\|FBC\|TILE` (`:363,378,393`) |
| RGA2e (`rga2e_data:596`) | {2,2}–{8192,8192} | {2,2}–{4096,4096} | 4 | all wins: `RASTER` only (`:406,417,428`) |

The 68×2 floor is also vendor-published as the RGA3 hardware envelope
(`Rockchip_FAQ_RGA_EN.md:688` and the debugfs `hardware` report).

## 3. Existing userspace structure — hook points

Verified at `26a50ef`:

- **Check flow**: `imcheck`/`imcheck_composite` (macros,
  `im2d_common.h:90/:109`) → `imcheck_t` (`im2d.cpp:2196`) →
  `rga_check_external` (`im2d_impl.cpp:2040`) → `rga_task_prepare`
  (`:907`) → `rga_check` (`:1946`). The **submit path shares `rga_check`**
  (`rga_single_task_submit`, `im2d_impl.cpp:2656`), so one hook upgrades both.
- **Active-rect semantics**: `rga_task_prepare` → `rga_image_prepare` (`:887`)
  calls `rga_apply_rect` (`im2d_impl.h:91-96`), which **overwrites
  `image->width/height` with the rect dims** when a rect is set, and defaults
  `rd_mode` to `IM_RASTER_MODE` (`:901-902`). So inside `rga_check`,
  `img.width/height` *is* the kernel's `act_w/act_h`; `rect.x/.y` is the
  offset; `wstride/hstride` is the canvas. No recomputation needed.
- **Channel enablement**: `rga_task_prepare`'s `buffer_mask` (`:918-927`):
  `IM_COLOR_FILL` → dst only; `IM_UPDATE_LUT` → src only; valid pat +
  palette/blend/CFA → src+src1+dst; else src+dst. The matcher mirrors this.
- **Per-core data already present**: `session->core_version`
  (`im2d_context.h:64`) retains the kernel's per-core version triples
  (`RGA_IOC_GET_HW_VERSION`, `rga_ioctl.h:43,365-378`). `rga_get_info`
  (`im2d_impl.cpp:964-1282`) decodes each entry to a `hw_info_table[]` row
  (RK3588: `0x76831`→RGA3 at `:993-997`; `0x63318`→RGA2_ENHANCE + fixups at
  `:1013-1025`) and collapses everything through
  `rga_support_info_merge_table` at `:1247` (formats/features OR'd, resolutions
  take the larger core — `:433-472`, with the vendor's own per-core-validation
  TODO at `:461-465`).
- **String-fallback path**: `TRY_TO_COMPATIBLE` (`:1252-1281`) sniffs
  `version[0].str` only and yields a single row — per-core matching must be
  disabled when this path was taken.
- **rd_mode enum is bit-identical to the kernel's**: `IM_RASTER_MODE 1<<0` …
  `IM_AFBC32x8_MODE 1<<5` (`im2d_type.h:97-107`) ↔ `RGA_RASTER_MODE` …
  `RGA_AFBC32x8_MODE`. Constraint masks can be stored directly in `IM_RD_MODE`
  bits with no translation.
- **Core mask flow**: effective core = `opt.core ? opt.core :
  g_im2d_context.core` at request build (`im2d_impl.cpp:2978`);
  `g_im2d_context` is thread-local (`:431`), set via
  `imconfig(IM_CONFIG_SCHEDULER_CORE)` (`im2d.cpp:879`). `rga_check` can read
  the thread-local directly; per-call `opt.core` is not visible there (§5.4).
- **Why a sidecar table, not new row fields**: `hw_info_table[]` rows
  (`im2d_hardware.h:182-457`) use positional aggregate initialization; adding
  struct fields would force editing all nine vendor rows — a large, permanent
  rebase burden. A parallel constraints table in a new file touches no vendor
  row.

## 4. New internal module: `im2d_api/src/im2d_percore.{h,cpp}`

All new logic lives in one new internal file pair; hooks into vendor files are
single lines. Nothing here is installed or exported.

### 4.1 Sidecar constraints table

```c
typedef struct {
    int version_index;                  /* IM_RGA_HW_VERSION_*_INDEX key */
    rga_info_resolution_t input_min;    /* kernel input_range.min  */
    rga_info_resolution_t output_min;   /* kernel output_range.min */
    unsigned int input_rd_mode;         /* IM_RD_MODE bits; kernel win[0]/win[1].rd_mode */
    unsigned int output_rd_mode;        /* IM_RD_MODE bits; kernel win[2].rd_mode */
} rga_core_constraints_t;

static const rga_core_constraints_t hw_core_constraints[] = {
    { IM_RGA_HW_VERSION_RGA_3_INDEX,
      {68, 2}, {68, 2},
      IM_RASTER_MODE | IM_AFBC16x16_MODE | IM_TILE8x8_MODE,
      IM_RASTER_MODE | IM_AFBC16x16_MODE | IM_TILE8x8_MODE },
    { IM_RGA_HW_VERSION_RGA_2_ENHANCE_INDEX,
      {2, 2}, {2, 2}, IM_RASTER_MODE, IM_RASTER_MODE },
    /* other generations: add rows only as kernel tables are read for them */
};
```

**Lookup-miss = no narrowing.** A class whose `version_index` has no
constraints row keeps today's merged-table behavior. This makes rollout
incremental and safe on SoCs we cannot measure: worst case is the status quo
(kernel refuses at submit). RK3588 needs exactly the two rows above.
(RGA2_PRO's `RASTER|TILE4x4|RKFBC|AFBC32x8` wins are visible in the kernel
tables (`rga_hw_config.c:482-521`) and can be added later — UNVERIFIED on
hardware here, and RK3576-only.)

### 4.2 Class model and session storage

```c
typedef struct {
    rga_info_table_entry caps;                  /* per-core row + SoC fixups, pre-merge */
    const rga_core_constraints_t *constraints;  /* NULL = unmodeled, no narrowing */
    unsigned int core_mask;                     /* IM_SCHEDULER_CORE bits */
    int core_count;
} rga_core_class_t;
```

`rga_session_t` (`im2d_context.h:53-70`, internal) gains
`rga_core_class_t core_classes[RGA_HW_SIZE]; int core_class_count;
bool per_core_check;`.

**Core-bit attribution**: decoded RGA3-family entries take the next unused bit
of {`IM_SCHEDULER_RGA3_CORE0`, `IM_SCHEDULER_RGA3_CORE1`}; RGA2-family entries
the next of {`IM_SCHEDULER_RGA2_CORE0`, `IM_SCHEDULER_RGA2_CORE1`}
(`im2d_type.h:109-118` — the vendor's own uapi core-bit convention).
Consecutive identical classes coalesce: RK3588's two RGA3 cores become one
class with `core_mask 0x3, core_count 2`. The attribution is an inference from
family, not from the ioctl (which carries no core ids) — UNVERIFIED for exotic
probe orders; the drift test (§7.3) validates it on RK3588, and matching at
*class* granularity means a core0/core1 ordering mistake cannot change any
verdict (same-class cores have identical capabilities).

### 4.3 Population

`rga_get_info` (internal, declared `im2d_impl.h:98`) gains two optional
out-parameters, defaulting to NULL so the RT-Thread variant and any other
caller compile unchanged:

```c
IM_STATUS rga_get_info(struct rga_hw_versions_t *version,
                       rga_info_table_entry *return_table,
                       rga_core_class_t *classes /*= NULL*/,
                       int *class_count /*= NULL*/);
```

Inside the existing per-core loop, immediately before the merge call at
`im2d_impl.cpp:1247` — the point where `merge_table` holds the fully-fixed-up
per-core row — append/coalesce a class (constraints looked up by the decoded
`IM_RGA_HW_VERSION_*_INDEX`). On `TRY_TO_COMPATIBLE`, set `*class_count = 0`.
`rga_session_init` (`im2d_context.cpp:179-194`) passes the session arrays and
reads the env toggle into `session->per_core_check`.

### 4.4 Matching pass

One hook at the end of `rga_check()` (`im2d_impl.cpp:2037`, after all existing
merged checks pass — the pass is purely additive/narrowing):

```c
    return rga_check_core_match(session, src, dst, pat, pat_enable,
                                src_rect, dst_rect, pat_rect, mode_usage);
```

Algorithm:

```
if (!session->per_core_check || session->core_class_count == 0)  return NOERROR;
if (no class has constraints)                                    return NOERROR;
mask = g_im2d_context.core ? g_im2d_context.core : IM_SCHEDULER_MASK;
channels = mirror of rga_task_prepare buffer_mask rules (src / src1 / dst enables)
for each class C with (C.core_mask & mask) and C.constraints:
    for each enabled channel ch (src, pat → input side; dst → output side):
        rd_mode:  ch.rd_mode & C.constraints->{input,output}_rd_mode
        range:    ch.width/height (== act dims, §3) within
                  {input,output}_min .. C.caps.{input,output}_resolution
                  RGA3-family extra: (width + rect.x, height + rect.y) within input range
                  dst under ROT_90|ROT_270 in usage: check with w/h swapped
        format:   category bit of ch.format ∈ C.caps.{input,output}_format
        align:    ch.wstride vs C.caps.byte_stride (10-bit byte-stride convention)
    scale:    src→dst ratio (rotation-aware, as rga_check_limit) ≤ C.caps.scale_limit
    feature:  usage-derived feature needs (as rga_check_feature) ⊆ C.caps.feature
    depth:    10-bit formats require C.caps.pixel_depth >= 10
    if all passed → return NOERROR                     /* first fit wins */
    else record (class, first failing gate) for the report
/* nothing fit */
IM_LOGW("per-core check: no core can run this job: RGA3(cores 0x3): src act_w 64 < min 68; "
        "RGA2e(0x4): src rd_mode AFBC16x16 unsupported");
return IM_STATUS_NOT_SUPPORTED;
```

**Quiet predicates, one consolidated report.** The probe loop must not reuse
the existing logging sub-checks (`rga_check_info` etc. `IM_LOGW` on every
failure): jobs that legitimately match only one class — every color fill
(RGA2-only), every AFBC job (RGA3-only) — would emit spurious warnings on
every call. The predicates are small pure comparisons (~120 lines); only the
no-class-fits outcome logs, and that single `IM_LOGW` lands in the error
buffer that `imStrError()` returns (`im2d_log.h:105` path).

**Semantics deliberately coarser than the kernel in one place**: format
checking uses the existing `IM_RGA_SUPPORT_FORMAT_*` category bits per class,
not the kernel's exact per-win per-rd_mode format lists. Where a category bit
is present but the kernel list lacks one specific format, we pass and the
kernel refuses — today's behavior, allowed by the direction invariant. No
category is *narrower* than the kernel list for the two RK3588 rows (checked
against `rga3_win_data`/`rga2e_win_data` during implementation review).

### 4.5 Env toggle

`ROCKCHIP_RGA_PER_CORE_CHECK`: unset or `1` → enabled; `0` → disabled
(pass-through to today's behavior). Read once in `rga_session_init`, following
the `getenv` precedent in `im2d_log.cpp:95` (Android property counterpart
`vendor.rga.per_core_check` for platform parity). The toggle also powers the
equivalence harness (§7.1).

## 5. Explicitly untouched / deferred

1. **All existing merged checks stay.** The pass is narrowing-only; removing
   or relaxing anything is out of scope.
2. **The merged `byte_stride = MAX` false-rejection** (RGA3's 16 masking
   RGA2e's 4 for raster jobs, `im2d_impl.cpp:456`) is a real bug in the
   *permissive* direction — fixing it changes accepted-job behavior and is
   deferred to a separately-validated follow-up.
3. **Legacy `c_RkRgaBlit()`/NormalRga path** does not route through
   `rga_check` and keeps today's behavior (kernel still refuses; GStreamer's
   legacy path is unaffected by this work).
4. **Per-call `opt.core`** is not visible inside `rga_check` (resolved later
   at `im2d_impl.cpp:2978`). Phase 1 intersects only the thread-local
   `g_im2d_context.core`; plumbing `opt.core` into the submit-path call site
   is a possible phase 2 (internal signature change only). `imcheck` has no
   opt parameter at all, so this is submit-path-only either way.
5. **Kernel-only exclusions** (RGA2 under-4G buffer placement) are not
   modeled — descriptors cannot know physical placement.

## 6. Build integration and patch series

New files added to the im2d source lists in all four build systems
(`meson.build`, `CMakeLists.txt`, `Android.mk`/`Android.bp`, `SConscript`);
`getenv` guarded for the RT-Thread build the way `im2d_log.cpp` does it.

Patch series (each compiles and passes tests standalone):

1. `im2d: capture per-core capability classes at session init` — §4.1-4.3,
   no behavior change (classes populated, unused).
2. `im2d: match jobs against per-core capabilities in rga_check` — §4.4-4.5.
3. `samples: add im2d per-core check self-test` — §7.1 binary (follows the
   `samples/*_demo` conventions).
4. `docs: CHANGELOG entry for the per-core check`.

Patches 1–3 are the upstream PR payload. No `im2d_version.h` bump (closure
plan §A.1 containment contract); the Debian package version carries provenance.

## 7. Test plan

### 7.1 Self-test + kernel-equivalence harness

Descriptor-only cases (no allocation needed — §3, `imcheck` never
dereferences buffers). NV15 = `RK_FORMAT_YCbCr_420_SP_10B`; expected verdicts:

| # | Case | Expect | Guards |
|---|---|---|---|
| 1 | src NV15 AFBC 64×240 (ws 64, hs 256) → dst P010 raster 64×240 | `NOT_SUPPORTED` | the finding's exact job |
| 2 | same, 68×240 | `SUCCESS` | boundary; matches measured 68×240 pass |
| 3 | src NV12 raster 64×240 → NV12 | `SUCCESS` | no global 68 floor (RGA2e min 2) |
| 4 | src NV15 AFBC 64×240 with wstride 128 | `NOT_SUPPORTED` | active rect governs, not stride (finding §"rectangle, not stride") |
| 5 | src NV15 AFBC 128×240, src_rect {0,0,64,240} | `NOT_SUPPORTED` | the crop-rect trigger |
| 6 | src NV12 **AFBC** 8192×240 | `NOT_SUPPORTED` | max-side honesty (RGA3 max 8176; RGA2e no AFBC) |
| 7 | `imconfig` core=RGA2 + AFBC src / core=RGA3 + raster 64-wide | `NOT_SUPPORTED` both | forced-core intersection |
| 8 | src NV15 AFBC 68×240 ROT_90 → dst 240×68 / dst 240×64 | `SUCCESS` / `NOT_SUPPORTED` | dst swap mirrors kernel `need_swap` |
| 9 | `IM_COLOR_FILL` dst raster 64×240 / same with core=RGA3 | `SUCCESS` / `NOT_SUPPORTED` | channel enablement; RGA3 lacks COLOR_FILL |

**Equivalence harness (hardware, the invariant proof):** rerun every case as a
real `improcess` with dma-buf allocations, twice —
`ROCKCHIP_RGA_PER_CORE_CHECK=0` (job reaches the kernel; record kernel
verdict) and `=1` (record early verdict). Assert both directions: every
early-rejected case is kernel-rejected (no false rejections — the critical
direction), and case 1's kernel `no core match` disappears from dmesg with the
check on.

### 7.2 Conformance regression

Full `librga-smoke.sh`, `gstreamer-suite.sh`, and the FFmpeg wrapper from the
conformance bundle, before/after: identical pass/fail sets; zero new kernel
`no core match` lines; ASan/UBSan build of the self-test.

### 7.3 Kernel drift guard

Root-only test parsing `/sys/kernel/debug/rkrga/hardware`
(`RGA_DEBUGGER_ROOT_NAME "rkrga"`, `rga_debugger.c:26,691`): assert per-core
count, input/output ranges, and `byte_stride_align` match the session's class
table (self-test binary dumps its classes under a debug flag for comparison).
Catches future kernel policy-table changes.

### 7.4 Cross-stack check

`rockchip-vaapi`'s `check-main10-narrow-fallback.sh` against the patched
librga: unchanged (its refusal fires before librga today). After workstream B
lands, the vaapi converter simply never submits impossible jobs; the librga
check remains the backstop for every other caller.

## 8. Acceptance criteria

1. Case 1 refused at `imcheck` and `improcess` with a message naming both
   cores' disqualifiers via `imStrError()`; zero kernel submission.
2. Equivalence harness green in both directions on RK3588.
3. Conformance suites byte-identical pass/fail before/after.
4. No installed-header diff vs the vendor tree; no new exported symbols.
5. PPA `librga2` snapshot cut and installed-package gates re-run.
6. Upstream PR opened against `airockchip/librga` (patches 1–3) citing their
   per-core-validation TODO at `im2d_impl.cpp:461-465`. Fork policy: work
   lands on `yisding/librga@main`; `librga-mirror` stays vendor-mirror-only.

## 9. Risks and open items

- **Dst-rotation swap fidelity** — the one gate where a mirroring mistake
  produces false rejections; covered by case 8 plus the equivalence harness.
- **Core-bit attribution** for unusual probe orders — UNVERIFIED beyond
  RK3588; class-granularity matching bounds the damage to forced-core flows,
  and the drift test pins RK3588.
- **Vendor lands their own per-core validation** — drop patches 1–2 at rebase
  time; the self-test (patch 3) remains valid against their implementation.
- **`imcheck_composite`/task APIs** — all funnel through `rga_check`; verify
  during implementation that no submit path bypasses it (grep for direct
  `ioctl(RGA_IOC_REQUEST_*` outside `rga_single_task_submit`).
- **Log-buffer interaction** — the consolidated `IM_LOGW` must remain under
  the same level gating as today's warnings so `imStrError()` behavior is
  unchanged for existing rejection paths.
