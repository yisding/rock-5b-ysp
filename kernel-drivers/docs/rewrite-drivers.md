# Clean-room rewrite drivers — `mpp-rewrite` & `rga-rewrite`

A second, independent implementation track: **public-API-only reimplementations
of the `/dev/mpp_service` and `/dev/rga` userspace ABIs**, written from the ABI
knowledge documented in [uAPI guide](./dev-uapis.md) rather than by carrying the
BSP code. This is the *opposite* strategy to the conservative forward-port
([forward-port guide](./vendor-forward-port.md), which keeps ~98% of the vendor code
byte-identical, [vendor delta](./vendor-delta.md)): here the BSP `.c` files are
not used at all, and every kernel interface is a public one — devm-managed
MMIO/IRQ/clock/reset discovery, public `dma_buf_attach`/`map` for fd imports,
the public DMA API (`dmam_alloc_coherent`) for RCB scratch instead of the BSP's
fixed-IOVA SRAM reservation, runtime PM, and plain threaded IRQs.

> **Status: advanced bring-up, not yet the shipped replacement.** MPP now covers
> the observed RK3588 userspace ABI with no required command intentionally left
> unsupported. RGA has grown from the initial blit/fill subset into a broad
> practical `librga`/FFmpeg feature subset, including AFBC/RFBC, 10-bit,
> alpha-overlay, color-key, OSD, palette, gauss, quantize, ROP, mosaic,
> rotate/translate/padding, mixed RGA2/RGA3 task batches, fences, and per-core
> scheduler counters. The remaining gap is hardware validation: no conformance
> record comparable to the forward-port's exists yet (§6). The shipped,
> hardware-validated stack is still the forward-port
> ([kernel status](./status.md), [`status.md`](../../status.md)). Location + pin in
> §6.

| | Forward-port (`mpp/`, `rga3/`) | Rewrite (`mpp-rewrite/`, `rga-rewrite/`) |
|---|---|---|
| Code origin | Rockchip 6.1 BSP, ~98% unchanged | written from scratch against the documented ABI |
| Kernel APIs | BSP-isms shimmed via `compat/` (vendor-forward-port.md §A) | public APIs only, no shims |
| Kernel target | pinned to 6.18 API surface (resyncing.md hazards) | built on 6.18; being brought up on current mainline master too (§5) |
| Userspace ABI | full BSP surface | the documented subset current `mpp-rockchip`/`librga`/`ffmpeg-rockchip` actually use |
| Audit posture | 89 verified findings latent ([BSP audit](./bsp-audit.md)) | small, reviewable, refcount-disciplined by construction |
| Size (observed 2026-07-02) | MPP ~15,822 lines + RGA3 ~19,171 lines (vendor-delta.md method) | MPP rewrite ~7,488 lines + RGA rewrite ~13,256 lines |

Kconfig makes the two tracks **mutually exclusive per device node**:
`ROCKCHIP_MPP_REWRITE` depends on `!ROCKCHIP_MPP_SERVICE` and registers
`/dev/mpp_service` in its place; `ROCKCHIP_RGA_REWRITE` depends on
`!ROCKCHIP_MULTI_RGA && !VIDEO_ROCKCHIP_RGA` and registers `/dev/rga`
(`mpp-rewrite/Kconfig`, `rga-rewrite/Kconfig`). The rewrite binds the *same DT
nodes* as the forward-port: `rockchip,rkv-encoder-v2-core`,
`rockchip,rkv-decoder-v2`, both CCU compatibles (`mpp_rewrite.c:274-277`) and
the RGA2/RGA3 compatibles incl. the mainline `rockchip,rk3588-rga`
(`rga_rewrite.c:6536-6543`).

Important codec boundary: neither the forward-port nor the MPP rewrite currently
exposes RK3588 AV1 through `/dev/mpp_service`. AV1 lives on a separate
Verisilicon/VPU981 hardware block, with a separate BSP `mpp_av1dec.c` backend and
a dedicated AV1 IOMMU. The newer upstream-style `../linux` tree has a clean
`vsi-iommu` provider and Hantro/V4L2 stateless AV1 support, but that is not the
same userspace ABI as RKMPP. See [RK3588 AV1 decode, IOMMU, and userspace
paths](./av1-rk3588.md).

Each driver carries an in-tree **`ABI.rst`** — a precise
implemented / recognized-but-unsupported / out-of-scope ledger of the BSP ioctl
surface. Those files are the authority; §2/§3 below transcribe the durable
knowledge. The current source pins are in §6 and
[source-tree pins](../../docs/source-trees.md) §8. The detailed line-number
anchors in the older ledger sections can drift as the rewrite grows; the
in-tree `ABI.rst` files at the §6 pins are the authority for the current
implemented / unsupported / outside-slice boundary.

---

## 1. Size, shape, and upstream-RGA comparison

The RGA rewrite being larger than the MPP rewrite is expected. The codec side of
`/dev/mpp_service` is mostly a register-job conveyor: userspace MPP/HAL code
builds codec-specific register images, while the kernel validates the message
stream, translates fd references to IOVAs, writes registers, handles IRQs and
timeouts, and copies readback registers to userspace. The kernel does not encode
H.264/H.265 policy or build codec recipes.

The `/dev/rga` ABI is more semantic. Userspace asks for blit/fill/scale/
color-convert/rotate/alpha operations with real image formats, strides, planes,
rectangles, fences, compression modes, and core masks. The kernel must normalize
those requests, choose an RGA2/RGA3-capable core, map buffers against that core's
DMA device, and emit the command words itself. That format and feature matrix is
why both the vendor RGA3 driver and the rewrite are bigger than their MPP peers.

That also changes the line-count expectation. The MPP rewrite still looks
structurally much smaller than the BSP forward-port because it mostly transports
userspace-built register jobs and keeps the codec recipe policy in MPP userspace.
The RGA rewrite has already grown substantially as parity moved from
copy/resize/fill into real `librga` and FFmpeg profiles: every extra RGA feature
adds validation, format/layout math, command emission, lifetime handling, and
tests. It remains smaller than the vendor RGA3 directory today, but it should no
longer be expected to stay tiny if feature parity remains the goal.

The RGA rewrite is not a fundamentally different hardware model from the vendor
RGA3 driver: the ABI and silicon force the same broad stages (copy request,
resolve buffers, pick a core, emit commands, wait for an IRQ). The difference is
in ownership and maintenance shape. The vendor driver is a broad BSP subsystem
with global `rga_drvdata`, scheduler policy, `rga_mm`, debug/procfs machinery,
legacy SoC compatibility, KERNEL_VERSION gates, and page-table walking. The
rewrite keeps the `/dev/rga` ABI but uses session-owned ids, refcounted imports
and jobs, job-owned per-core mappings, public dma-buf/DMA APIs, and explicit
`-EOPNOTSUPP` boundaries for profiles it does not yet emit. If it ends up near
the vendor size, the win is still clearer ownership, less BSP baggage, and an
auditable public-API driver. If it drifts into copied vendor tables and quirks,
that advantage shrinks.

### Upstream-style V4L2 RGA3 in `../linux`

The separate upstream-oriented RGA support compared on 2026-07-02 was the sibling
`../linux` checkout on branch `rk3588-rewrite-mainline` at local commit
`180ee72a9a80`. That branch was clean but seven commits ahead of
`linux-rock5b/rk3588-rewrite-mainline`, so treat the cite as dev-box-local until
pushed. The relevant tree is `drivers/media/platform/rockchip/rga/`, about
3,168 lines.

That driver is **not** a smaller `/dev/rga` replacement. It is a mainline-style
V4L2 mem2mem driver (`/dev/videoX`) with `V4L2_CAP_VIDEO_M2M_MPLANE |
V4L2_CAP_STREAMING`, `VB2_MMAP | VB2_DMABUF` queues, and RK3588 binding through
`rockchip,rk3588-rga3` -> `rga3_hw`. For RGA3, the command path programs one
source window (`WIN0`) to the writeback path (`WR`): scale, format/stride/CSC,
addresses, command buffer, master-mode start, and frame-done IRQ. It deliberately
exposes only the first RGA3 core until multicore scheduling lands.

Besides multicore, the current RGA3 V4L2 path is missing these vendor/librga
capabilities:

- No `/dev/rga` ABI or `librga` compatibility: no Rockchip buffer handles,
  request create/config/submit ioctls, core masks, multi-task requests, or
  explicit `sync_file` ioctl surface.
- No RGA3 rotate/flip/background-color controls. The generic V4L2 controls exist
  only behind feature flags, and `rga3_hw.features = 0`.
- No second input (`WIN1`), pattern/overlay composition, or Porter-Duff alpha
  blend surface. The RGA3 command code explicitly uses only `WIN0` because two
  inputs are not supported there yet.
- No RGA3 color fill, pattern fill, ROP, color key, OSD, mosaic, dither, or
  neural-network/quantize helpers from the vendor/librga feature surface.
- No compressed or tiled layouts: no AFBC/RFBC/FBC/tile decode or encode.
- Narrower format coverage: no 10-bit YUV, no YUV444, no planar YUV on RGA3,
  and several RGB formats are input-only.
- Incomplete crop/compose semantics for RGA3. The V4L2 selection API stores crop
  and compose rectangles, but the RGA3 command generator currently uses only the
  source crop width/height and full output size; it does not program source
  offsets or arbitrary destination placement.
- Thin error and recovery handling: the RGA3 IRQ path clears interrupts and
  returns frame-done status, but does not yet provide vendor-style error-bit
  diagnosis, timeout recovery, or reset policy.

So the upstream V4L2 driver is small because its current contract is narrow:
one-source scale/convert/blit through V4L2. It is the right mainline direction,
but it is not close to the vendor `/dev/rga`/`librga` feature surface yet.

## 2. MPP ABI ledger (`mpp-rewrite/ABI.rst`)

### Implemented

| Area | What the rewrite does | Anchor |
|------|----------------------|--------|
| `MPP_IOC_CFG_V1` message parsing | incl. **multi-message batches**; userspace message order preserved; write-like payloads copied before the ioctl returns; staged jobs in one batch are submitted before poll requests are processed in message order, matching the forward-port trigger-then-wait ordering | `mpp_rewrite.c:2346` (`cmd != MPP_IOC_CFG_V1` reject) |
| `MPP_CMD_SET_SESSION_FD` | session switching, restricted to fds that are themselves `/dev/mpp_service` files | `:2371` |
| Platform binding | RK3588 BSP-style RKVENC2/RKVDEC2 core + CCU nodes; devm MMIO/IRQ/clock/reset | `:274-277` |
| `QUERY_HW_SUPPORT` / `QUERY_HW_ID` / `QUERY_CMD_SUPPORT` | from bound cores; `QUERY_HW_ID` returns the register-0 hardware id captured at probe — preserving the forward-port's userspace-visible **HAL-selection contract** (how-the-drivers-work.md §9, dev-uapis.md) | `:473` |
| procfs discovery markers | minimal `/proc/mpp_service/supports-cmd` + `support_cmd` (read-only compatibility markers so current `mpp-rockchip` enables command probing — *not* the BSP debug/control procfs) | `:592-595` |
| `INIT_CLIENT_TYPE`, `INIT_DRIVER_DATA` (no-op), `RESET_SESSION`, `SEND_CODEC_INFO` | validated per-session state | |
| `MPP_CMD_INIT_TRANS_TABLE` | BSP-compatible **`u16` table element width** (`u16 trans_table[]`, `:169`) with KUnit coverage for successful load, oversize rejection, copy-fault return, and zero-size count reset — an ABI fact not obvious from the header | |
| `TRANS_FD_TO_IOVA` / `RELEASE_FD` | public dma-buf attach/map/unmap against a bound client hw device; explicit translation maps on the default matching core for compatibility, while the session cache is keyed by fd + DMA device and `RELEASE_FD` drops all cached mappings for that fd | |
| `MPP_CMD_SET_ERR_REF_HACK` | validated **copy-in/discard** — issued by current `mpp-rockchip` for VDPU382 H.264 capability probing and must be *accepted*, not rejected (§4) | `:2293` |
| Register jobs | flat register-image materialization (`SET_REG_WRITE`), bounded readback retention (`SET_REG_READ`), validated offset tuples (`SET_REG_ADDR_OFFSET`) with KUnit coverage for staging, duplicate-index additive apply, malformed sizes, zero-size no-op, and cap handling; fd→IOVA translation via the session table or built-in per-client default tables (`rk_mpp_rkvdec_h264d_regs[]` etc., `:325-380`), with translated dma-bufs mapped against the selected core's DMA device | |
| Job/import lifetime | translated jobs hold references on every imported dma-buf mapping (so `RELEASE_FD`/`RESET_SESSION`/close can't tear a prepared job's mappings down); **refcounted batch/session/hw job ownership** so poll vs reset vs close vs IRQ can't free a live job; `SET_SESSION_FD` batch switching splits staged jobs correctly | |
| Execution slice | queued, least-loaded dispatch across bound RK3588 encoder/decoder cores; runtime-PM resume, bulk clock enable, range-checked MMIO writes from the original `SET_REG_WRITE` spans, start-register deferral, **IRQ-driven completion**, retained `SET_REG_READ` readback, BSP-style irq-status override, decoder RLC decoded-length adjustment; contended submits queue internally instead of returning `-EBUSY` | |
| RKVDEC2 hard-CCU / link tables | VDPU383/RKVDEC2 link-MMIO start, hard-CCU link-table allocation/materialization/readback, running-list/add-mode handling, fixed-RCB link-latch setup, peer-core power ownership transfer, table-complete scanning, error containment, timeout recovery, unfinished-chain relink, and resend are implemented using public DMA/IOMMU APIs | |
| Fault/recovery | per-core timeout completion, public IOMMU fault callbacks, post-reset IOMMU refresh, and `-EIO` completion on matched active faults are implemented without private Rockchip IOMMU page-table walking | |
| `MPP_CMD_POLL_HW_IRQ` | RK3588 RKVENC2 slice result streaming: advertises `POLL_BUTT`, detects split mode from the submitted register image (`slen_fifo` + slice split), stores IRQ slice-length words in a job-owned FIFO, copies up to userspace `count_max`, and falls through to normal completion/readback on the final slice; non-split jobs use the full-frame finish path | |
| `MPP_CMD_SET_RCB_INFO` | BSP-compatible `(register index, size)` descriptors per session; per-core **coherent scratch via the public DMA API** sized from DT `rockchip,rcb-iova`; decoder gate on `rockchip,rcb-min-width` using retained `SEND_CODEC_INFO` width — no fixed-IOVA SRAM | `:2483-2492` |
| KUnit coverage | optional `ROCKCHIP_MPP_REWRITE_KUNIT_TEST` for ABI parser and staging helpers, including command range classification, command group boundary queries, payload-copy classification, translation-table storage, register-offset staging/apply, register-span overflow checks, `POLL_HW_IRQ` flexible-buffer sizing, and RKVENC2 slice-mode detection | |

### Recognized but unsupported

- No required RK3588 MPP userspace command is intentionally left in this bucket
  after the RKVENC2 `POLL_HW_IRQ` slice path.

### Outside this slice

Board-level stress validation of hard-CCU timeout/error recovery under real
IOMMU faults, runtime suspend, and decoder reset races; MPP fence export/import
semantics if current userspace evidence appears; and `MPP_IOC_CFG_V2` (which
the BSP-derived 6.18 driver also rejects in the observed path).

---

## 3. RGA ABI ledger (`rga-rewrite/ABI.rst`)

The hard-won **librga ABI facts** — what the rewrite's ABI.rst records that
real `librga`/`ffmpeg-rockchip` consumers require of a `/dev/rga`
implementation (cross-reference:
[userspace library guide](../../userspace-libraries/docs/how-the-userspace-libs-work.md) Part B):

- **Version tuples are capability keys.** `librga` capability-probing expects
  the RK3588 hardware-version tuples **RGA2E `3.2.63318`** and **RGA3
  `3.0.76831`** from `RGA_IOC_GET_HW_VERSION`
  (`rga_rewrite.c:6519-6533` — `{3, 2, 0x63318}` / `{3, 0, 0x76831}`, rendered
  `"%x.%01x.%05x"` at `:993`, hence the hex-looking revision). Report the wrong
  tuple and librga silently selects the wrong per-core capability profile.
- **Both ioctl generations must exist**: legacy `RGA_GET_VERSION` /
  `RGA2_GET_VERSION` *and* modern `RGA_IOC_GET_HW_VERSION` /
  `RGA_IOC_GET_DRVIER_VERSION` (sic — the BSP typo is ABI, dev-uapis.md; `:745`).
  `RGA2_GET_VERSION` returning `true` after copying the version string is
  intentional BSP/librga ABI behaviour, not a bug.
- **Legacy `RGA_CACHE_FLUSH`, `RGA_FLUSH`, `RGA_GET_RESULT`, and
  `RGA2_GET_RESULT` are safe as BSP-compatible no-ops** (`:6737-6741`) —
  userspace does not depend on their side effects.
- **Buffer import**: `RGA_IOC_IMPORT_BUFFER`/`RELEASE_BUFFER` for dma-buf fds
  *and* user virtual addresses — VA imports pin user pages, build sg_tables via
  `sg_alloc_table_from_pages()` (`:5923`), map with the public DMA API, and
  sync around hw execution (the common CPU-buffer librga sample path). Legacy
  no-handle `wrapbuffer_fd()`/`wrapbuffer_virtualaddr()` blits are converted to
  job-owned temporary imports; **direct physical-address channels remain
  unsupported**.
- **Acquire-fence ownership**: when a submitted task clears
  `feature.user_close_fence` (`:676`, `:2190-2200`), the *kernel* closes the
  imported acquire-fence fd after taking its own `dma_fence` reference
  (matching the forward-port's compatibility path for older userspace); when
  set, userspace keeps fd-close ownership. Async jobs own an internal release
  fence, export its fd, and complete via IRQ thread / per-core timeout worker
  (`RGA_BLIT_ASYNC` paths `:5710`, `:5751`, `:6282`).
- **BSP `rga_req.core` scheduler masks are honored**: RGA3 bits `0x1`/`0x2`,
  RGA2 bits `0x4`/`0x8`; imported images are **rebound to the selected core's
  DMA device at dispatch**, so a forced-core `wrapbuffer_fd()` submission works.
  A mask that names only an absent core is rejected instead of being rerouted to
  a different present core; masks that include a present compatible core still
  schedule normally.
- **Per-core profile coverage** (what real librga/ffmpeg consumers need):
  - **RGA3**: raster, tile8x8, and AFBC16x16 bitblits; RGB/YUV plus compact
    and unpacked 10-bit semiplanar YUV paths used by current `librga` and
    `ffmpeg-rockchip`; source crop and destination offsets; resize
    interpolation selectors; rotate/flip/mirror, including centered rotate and
    padding/reflect border commands; RGB color-key for normal `imcolorkey`;
    Porter-Duff A+B alpha blend for public `librga` modes except CLEAR and
    unlisted modes; pattern-backed ffmpeg/RKMPP overlay paths; AFBC writeback
    for supported alpha-overlay/copy profiles; and overlay pre-processing
    copies into offset pattern images.
  - **RGA2**: solid fill, YUV fill, rectangle/fill arrays, raster bitblit for
    fallback formats RGA3 does not cover, planar/semiplanar YUV,
    YCbCr400/gray, NV24/NV42, RGB555-family, ARGB/ABGR output, compact 10-bit
    source, RFBC64x4 source profiles for ffmpeg-facing Rockchip frames,
    full-CSC RGB→YUV, gray256 conversion, Y400 UV downsample, rotate/mirror,
    in-place RGB mosaic, ROP, gaussian blur, NN quantize, RGB alpha-bitmap,
    OSD alpha overlay, and color palette/update-palette commands.
  - Multi-task requests run serially under one completion/fence when every task
    matches a supported profile. Mixed RGA2/RGA3 batches now validate the whole
    request up front and select an eligible backend per task; current `librga`
    copy-splice and fill/mosaic task-array shapes are covered.
  - Minimal debugfs counters now report scheduled, dispatched, and
    hardware-started work per public RGA core bit (`rga3_core0`, `rga3_core1`,
    `rga2_core0`, `rga2_core1`) so board validation can confirm forced-core and
    load-balancing behaviour without the BSP debug ABI.
- **Remaining recognized RGA gaps** are now comparatively specific: physical
  address imports; full general RGA2/RGA3 policy and command-register
  generation; RGA3 pattern modes outside the supported alpha-overlay profile;
  color-key outside the normal RGB `imcolorkey` shape; converted no-pattern or
  mixed-depth 8/10-bit YUV-destination alpha; per-channel rotation; RGA3
  RFBC/AFBC32x8; tile outside simple bitblits; AFBC destination offsets; and
  non-bitblit operation modes outside the implemented RGA2 subsets.
- **Unsupported profiles fail *late* by design**: `-EOPNOTSUPP` is returned
  only after copy/validate/prepare/queue/dispatch/import-resolve/power-sequence
  reach the backend boundary — so the scheduler/lifetime path is exercised even
  for profiles the command generator can't emit yet.
- Optional **KUnit coverage** exists on both rewrite drivers: MPP parser helpers
  plus hard-CCU/link-table, DCHS, IOMMU-fault, `POLL_HW_IRQ`, and
  `SET_SESSION_FD` helpers via `ROCKCHIP_MPP_REWRITE_KUNIT_TEST`; and RGA
  ABI-normalization, request create/cancel lifecycle, import/release-buffer
  lifecycle, scheduler, fence, RFBC/AFBC/tile, crop/destination-offset, blend-mode,
  OSD/palette/gauss/quantize/ROP/mosaic, and ffmpeg-facing profile helpers via
  `ROCKCHIP_RGA_REWRITE_KUNIT_TEST`.

---

## 4. New uAPI facts (cross-folded into dev-uapis.md)

Three BSP ABI facts were learned during the rewrite and encoded in the
`include/uapi/linux/rk-mpp.h` extension (part of the §6 commit — **not** in
`patches/rk3588-rkvenc2-01…`, see [source-tree pins](../../docs/source-trees.md) §7):

| Name | Value | Fact |
|------|-------|------|
| `MPP_CMD_SET_ERR_REF_HACK` | `MPP_CMD_CONTROL_BASE + 4` | issued by current `mpp-rockchip` userspace for **VDPU382 H.264 capability probing**; a compatible kernel must accept it as **copy-in/discard** (rejecting it breaks probing) |
| `MPP_FLAGS_REG_OFFSET_ALONE` | `0x00000010` | the **true BSP name** for the flag dev-uapis.md knew as `REG_NO_OFFSET` (kept as an alias) — it marks the split between plain fd register values and separate offset records |
| `MPP_FLAGS_POLL_NON_BLOCK` | `0x00000020` | non-blocking poll request flag, previously undocumented in this repo |

[uAPI guide](./dev-uapis.md)'s CONTROL-command table and `MPP_FLAGS_*` list
carry these with back-pointers here.

---

## 5. Mainline-master bring-up DT (post-6.18)

The rewrite is also being brought up against **current mainline master**
(v7.2-rc1 era — the dev checkout sits at `665159e24674`), which is where it
differs most interestingly from the 6.18 DT story
([device-tree guide](./device-tree.md)): mainline now ships its own
`vdec0`/`vdec1` `video-codec@fdc38000`/`@fdc40000` nodes (V4L2
`rockchip,rk3588-vdec`), so the decoder can be **converted in place** exactly
like Armbian's `media-0001` path (armbian-packaging.md) — no inline decoder nodes needed.
The local mainline rewrite branch's DT diff: +105 lines `rk3588-base.dtsi`,
+107 lines `rk3588-rock-5b.dtsi`:

- **Encoder + CCUs inline in `rk3588-base.dtsi`** (as in patch 02): `mpp_srv`,
  virtual `rkvenc_ccu`, `rkvenc0/1` @ `fdbd0000`/`fdbe0000` (SPI 101/104,
  MMUs SPI 99+100 / 102+103), MMIO `rkvdec_ccu@fdc30000`, all
  `status = "disabled"`; board dtsi enables them.
- **`rkvenc0`/`rkvenc1` aliases in `base.dtsi`**, commented *"The MPP
  compatibility driver derives core ids from these aliases"* — same
  `of_alias_get_id` contract as the forward-port (device-tree.md §Aliases are
  mandatory).
- **Decoder via `&vdec0`/`&vdec1` overrides in the board dtsi**: retype
  `compatible` to `rockchip,rkv-decoder-v2`, replace `reg` with the vendor
  `regs`/`link` split (`fdc38100`+`fdc38000`, `fdc40100`+`fdc40000`), add the
  vendor properties (`core-mask`, `taskqueue-node = <9>`,
  `task-capacity = <16>`, `rcb-*`, `rockchip,sram = <&vdecN_sram>`), alias
  `rkvdec0 = &vdec0` / `rkvdec1 = &vdec1`, and inherit `interrupts`,
  `iommus`, `power-domains`, and the SRAM pools from mainline's own nodes —
  the post-6.18 variant of device-tree.md's convert-in-place.
- Wiring: `drivers/video/{Kconfig,Makefile}` gain a `rockchip/` subdir that
  contains **only** the two rewrite drivers (no BSP port on master).

**Interrupt reconciliation (board-verified 2026-07-01).** Mainline master pins
`vdec0` = `GIC_SPI 95`, `vdec0_mmu` = 96, `vdec1` = 97, `vdec1_mmu` = 98
(`rk3588-base.dtsi:1400-1457` at the master pin). On the running board (kernel
`6.18.37-current-rockchip64` #7, combined forward-port kernel,
convert-in-place DT), `/proc/interrupts` shows — recalling GIC_SPI *n* = hwirq
*n*+32:

```
GICv3 127 Level fdc38100.video-codec            → GIC_SPI 95  (rkvdec core 0) ✓
GICv3 129 Level fdc40100.video-codec            → GIC_SPI 97  (rkvdec core 1) ✓
GICv3 128 Level fdc38700.iommu, fdc40700.iommu  → GIC_SPI 96  (SHARED by both decoder MMUs)
```

The core IRQs confirm vanilla-kernel.md's previously-UNVERIFIED SPI 95/97. The MMU
observation is the surprise: the running (media-0001-derived) DT has **both**
decoder MMUs on SPI 96 as a shared line, whereas current mainline master gives
`vdec1_mmu` its own SPI 98. Both apparently work (the rockchip-iommu handler
reads per-instance status), but which is TRM-correct is **UNVERIFIED** —
confirm against the TRM before treating either as canonical.

---

## 6. Status & citable location

| Item | State (2026-07-02) |
|------|--------------------|
| Code | `drivers/video/rockchip/mpp-rewrite/` (`mpp_rewrite.c` 7,224 lines; 7,488 total incl. `ABI.rst`, `Kconfig`, `Makefile`) + `drivers/video/rockchip/rga-rewrite/` (`rga_rewrite.c` 12,844 lines; 13,256 total incl. `ABI.rst`, `Kconfig`, `Makefile`) |
| 6.18 state | dev worktree `/home/yi/Code/linux-6.18-rkvenc` is on branch `rk3588-rewrite-6.18` at **local commit `42fa9c66344d`** ("media: rockchip: count rga scheduler core activity"), clean and 120 commits ahead of `linux-rock5b/rk3588-rewrite-6.18`; not pushed as of this snapshot. Since `611f5fe047fd`, the committed work added a large RGA feature-coverage push: userptr import coverage, acquire-fence ownership, per-task core masks, request lifetime fixes, RGA2/RGA3 mixed-task scheduling, RGA priority, RGA2 YUV fill/full-CSC/gray/Y400/RFBC/mosaic/ROP/gauss/quantize/alpha-bitmap/OSD/palette, RGA3 resize/translate/rotate/flip/padding/color-key/tile8x8/AFBC/RFBC-facing/10-bit/P210/alpha-overlay/overlay-preprocess profiles, plus MPP `POLL_HW_IRQ`, DCHS-id, hard-CCU resend/recovery, IOMMU-refresh, and session-batch-split coverage. |
| Mainline-master state | sibling worktree `/home/yi/Code/linux` is on branch `rk3588-rewrite-mainline` at **local commit `1b8c7d948fe9`** (same tip subject), clean and 120 commits ahead of `linux-rock5b/rk3588-rewrite-mainline`; it carries the rewrite drivers plus the mainline-master DT/wiring work and the V4L2 RGA3 comparison tree discussed in §1. |
| Validation | MPP/RGA rewrite object files exist in the 6.18 worktree and the source-level ABI ledgers record the implemented/unsupported boundary per §2/§3; both rewrite drivers carry optional KUnit coverage for pure ABI/helper logic. The current local `.config` in `/home/yi/Code/linux-6.18-rkvenc` is still the vendor-driver configuration (`ROCKCHIP_MPP_SERVICE=y`, `ROCKCHIP_MULTI_RGA=y`), so the current status is code/ABI-ledger progress rather than proof from a booted rewrite kernel. [`tests/abi-probe.sh`](../tests/abi-probe.sh) is the fast non-submit ABI log-diff gate for whichever implementation owns `/dev/mpp_service` and `/dev/rga`; [`tests/librga-smoke.sh`](../tests/librga-smoke.sh) is the tiny direct librga/im2d copy/resize/fill smoke; [`tests/rewrite-smoke.sh`](../tests/rewrite-smoke.sh) runs the ABI probe plus decode/encode/transcode consumer workloads. The broader conformance plan is staged outside this repo at `../rockchip-conformance`: JeffyCN GStreamer Rockchip, official MPP tests, official librga samples, the Linux MPP/RGA/DRM demo, and RKMediaCodecDemo, with per-profile logs for rewrite vs forward-port runs. **UNVERIFIED in this repo**: the workload gate and expanded conformance bundle have not yet passed on hardware through the rewrite; no validation record equivalent to status.md exists yet. |

> **TODO — publish before relying on these cites:** the rewrite still exists
> only on the dev box (local 6.18 and mainline branches, both ahead of their
> `linux-rock5b/*` remotes by 120 commits; no public branch observed here).
> Push the 6.18 rewrite state and the mainline-master DT work to a citable
> public branch, then replace the
> local-tree cites in this
> doc and source-trees.md §8 with the public URL + hashes. Until then every anchor in
> this doc is **unresolvable outside the dev box**.

Cross-references: [uAPI guide](./dev-uapis.md) (uAPI surface),
[userspace library guide](../../userspace-libraries/docs/how-the-userspace-libs-work.md) (the librga behaviours §3
encodes), [device-tree guide](./device-tree.md) (6.18 DT), [kernel status](./status.md) /
[`status.md`](../../status.md) (project status rows),
[source-tree pins](../../docs/source-trees.md) (local rewrite/upstream-RGA pins).
