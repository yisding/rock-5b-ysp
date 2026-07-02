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

> **Status: bring-up, not a replacement.** The hardware execution slice is
> implemented (one IRQ-driven job per core, §2), but large parts of the BSP
> feature surface are deliberately out of scope (§2/§3 ledgers), and no
> validation record comparable to the forward-port's exists yet (§6). The
> shipped, hardware-validated stack is still the forward-port
> ([kernel status](./status.md), [`status.md`](../../status.md)). Location + pin in
> §6.

| | Forward-port (`mpp/`, `rga3/`) | Rewrite (`mpp-rewrite/`, `rga-rewrite/`) |
|---|---|---|
| Code origin | Rockchip 6.1 BSP, ~98% unchanged | written from scratch against the documented ABI |
| Kernel APIs | BSP-isms shimmed via `compat/` (vendor-forward-port.md §A) | public APIs only, no shims |
| Kernel target | pinned to 6.18 API surface (resyncing.md hazards) | built on 6.18; being brought up on current mainline master too (§5) |
| Userspace ABI | full BSP surface | the documented subset current `mpp-rockchip`/`librga`/`ffmpeg-rockchip` actually use |
| Audit posture | 89 verified findings latent ([BSP audit](./bsp-audit.md)) | small, reviewable, refcount-disciplined by construction |
| Size | ~35,000 lines (vendor-delta.md) | `mpp_rewrite.c` 3,338 lines + `rga_rewrite.c` 7,040 lines |

Kconfig makes the two tracks **mutually exclusive per device node**:
`ROCKCHIP_MPP_REWRITE` depends on `!ROCKCHIP_MPP_SERVICE` and registers
`/dev/mpp_service` in its place; `ROCKCHIP_RGA_REWRITE` depends on
`!ROCKCHIP_MULTI_RGA && !VIDEO_ROCKCHIP_RGA` and registers `/dev/rga`
(`mpp-rewrite/Kconfig`, `rga-rewrite/Kconfig`). The rewrite binds the *same DT
nodes* as the forward-port: `rockchip,rkv-encoder-v2-core`,
`rockchip,rkv-decoder-v2`, both CCU compatibles (`mpp_rewrite.c:274-277`) and
the RGA2/RGA3 compatibles incl. the mainline `rockchip,rk3588-rga`
(`rga_rewrite.c:6536-6543`).

Each driver carries an in-tree **`ABI.rst`** — a precise
implemented / recognized-but-unsupported / out-of-scope ledger of the BSP ioctl
surface. Those files are the authority; §2/§3 below transcribe the durable
knowledge. **All line cites resolve against the rewrite sources at the §6
commit pin `981a832452454a`**, not the moving worktree — the tree was observed
under *active development* on 2026-07-01 (the worktree had already grown an
uncommitted per-core RGA timeout completion and BSP-style soft-reset recovery
slice for active jobs, with the ABI.rst "Outside this slice" row narrowed
accordingly). Expect the ledgers below to lag the code; the in-tree ABI.rst is
always current.

---

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
| `MPP_CMD_INIT_TRANS_TABLE` | BSP-compatible **`u16` table element width** (`u16 trans_table[]`, `:169`) — an ABI fact not obvious from the header | |
| `TRANS_FD_TO_IOVA` / `RELEASE_FD` | public dma-buf attach/map/unmap against a bound client hw device; explicit translation maps on the default matching core for compatibility, while the session cache is keyed by fd + DMA device and `RELEASE_FD` drops all cached mappings for that fd | |
| `MPP_CMD_SET_ERR_REF_HACK` | validated **copy-in/discard** — issued by current `mpp-rockchip` for VDPU382 H.264 capability probing and must be *accepted*, not rejected (§4) | `:2293` |
| Register jobs | flat register-image materialization (`SET_REG_WRITE`), bounded readback retention (`SET_REG_READ`), validated offset tuples (`SET_REG_ADDR_OFFSET`); fd→IOVA translation via the session table or built-in per-client default tables (`rk_mpp_rkvdec_h264d_regs[]` etc., `:325-380`), with translated dma-bufs mapped against the selected core's DMA device | |
| Job/import lifetime | translated jobs hold references on every imported dma-buf mapping (so `RELEASE_FD`/`RESET_SESSION`/close can't tear a prepared job's mappings down); **refcounted batch/session/hw job ownership** so poll vs reset vs close vs IRQ can't free a live job | |
| Execution slice | **one active job per bound core**, with kernel-translated jobs preferring an idle matching core and pretranslated `MPP_FLAGS_REG_FD_NO_TRANS` jobs staying on the default core; runtime-PM resume, bulk clock enable, range-checked MMIO writes from the original `SET_REG_WRITE` spans, start-register deferral, **IRQ-driven completion**, retained `SET_REG_READ` readback, BSP-style irq-status override, decoder RLC decoded-length adjustment; contended submits wait interruptibly (no `-EBUSY`) | |
| `MPP_CMD_POLL_HW_IRQ` | RK3588 RKVENC2 slice result streaming: advertises `POLL_BUTT`, detects split mode from the submitted register image (`slen_fifo` + slice split), stores IRQ slice-length words in a job-owned FIFO, copies up to userspace `count_max`, and falls through to normal completion/readback on the final slice; non-split jobs use the full-frame finish path | |
| `MPP_CMD_SET_RCB_INFO` | BSP-compatible `(register index, size)` descriptors per session; per-core **coherent scratch via the public DMA API** sized from DT `rockchip,rcb-iova`; decoder gate on `rockchip,rcb-min-width` using retained `SEND_CODEC_INFO` width — no fixed-IOVA SRAM | `:2483-2492` |
| KUnit coverage | optional `ROCKCHIP_MPP_REWRITE_KUNIT_TEST` for pure ABI parser helpers: command range classification, command group boundary queries, payload-copy classification, register-span overflow checks, `POLL_HW_IRQ` flexible-buffer sizing, and RKVENC2 slice-mode detection | |

### Recognized but unsupported

- No required RK3588 MPP userspace command is intentionally left in this bucket
  after the RKVENC2 `POLL_HW_IRQ` slice path.

### Outside this slice

Full BSP-equivalent RK3588 scheduling beyond simple idle-core selection
(queued software scheduling, dual-core CCU policy, SRAM fixed-IOVA RCB), full
BSP-equivalent timeout diagnostics/recovery policy and IOMMU fault recovery
(basic per-core timeout completion is implemented), decoder performance-selector
readback above the core MMIO resource, fence export/import, 32-bit compat
translation, `MPP_IOC_CFG_V2` (which the BSP-derived 6.18 driver also rejects
in the observed path).

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
- **Per-core profile coverage** (what real librga/ffmpeg consumers need):
  - **RGA3**: raster + AFBC16x16 bitblit (no-blend; 8-bit RGB/YUV +
    semiplanar 10-bit YUV), rotation/mirror via WIN0 controls, destination
    rect offsets by biasing WR plane bases (8-bit; semiplanar YUV must be
    chroma-aligned); Porter-Duff A+B alpha blend for the common composition
    paths with RGB destinations, including ffmpeg's
    `overlay_rkrga=format=<rgb>` path, and the default RKMPP overlay path with
    8-bit YUV main + RGB/RGBA pattern + 8-bit YUV destination (pattern dims
    must match destination; 10-bit/no-pattern YUV alpha remains unsupported).
  - **RGA2**: solid fill (`imfill`, RGB-family raster; forced RGA3 fill is
    intentionally `-EOPNOTSUPP` because RK3588 RGA3 does not advertise
    `RGA_COLOR_FILL` in the forward-port capability table) and raster bitblit
    for the fallback formats RGA3 lacks — planar YUV420/422, gray, NV24/NV42,
    RGB555-family, ARGB/ABGR out — incl. `rotate_mode`/`sina`/`cosa` decode
    with librga's 90/270° active-rectangle swap, and librga's RGB→YUV
    **full-CSC coefficient block**.
  - Multi-task requests run serially when all tasks match one backend profile;
    mixed RGA2/RGA3 requests are unsupported.
- **Unsupported profiles fail *late* by design**: `-EOPNOTSUPP` is returned
  only after copy/validate/prepare/queue/dispatch/import-resolve/power-sequence
  reach the backend boundary — so the scheduler/lifetime path is exercised even
  for profiles the command generator can't emit yet.
- Optional **KUnit coverage** exists on both rewrite drivers: MPP parser helpers
  plus `POLL_HW_IRQ` buffer sizing and RKVENC2 slice-mode gating via
  `ROCKCHIP_MPP_REWRITE_KUNIT_TEST`, and RGA ABI-normalization helpers via
  `ROCKCHIP_RGA_REWRITE_KUNIT_TEST` (RGA2 transform decode,
  destination-corner selection, fill core-mask dispatch).

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
The (currently uncommitted, see §6) DT diff: +105 lines `rk3588-base.dtsi`,
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

| Item | State (2026-07-01) |
|------|--------------------|
| Code | `drivers/video/rockchip/mpp-rewrite/` (`mpp_rewrite.c` 3,338 lines, `ABI.rst`, `Kconfig`, `Makefile`) + `drivers/video/rockchip/rga-rewrite/` (`rga_rewrite.c` 7,040 lines, `ABI.rst`, `Kconfig`, `Makefile`) |
| 6.18 state | dev worktree `/home/yi/Code/linux-6.18-rkvenc` is currently at **local commit `5614909e5803`** ("arm64: dts: rockchip: rk3588: VEPU580 encoder, rkvdec2 decoder, RGA3 nodes") on top of the forward-port commit `924f4232546d`; the rewrite driver files are staged/modified in that worktree rather than published as a standalone citable commit. |
| Mainline-master state | same rewrite sources present in the `/home/yi/Code/linux` master worktree (`665159e24674`, v7.2-rc1 era) as **uncommitted** changes: the §5 DT diff + `drivers/video/{Kconfig,Makefile}` wiring + untracked `drivers/video/rockchip/` and `include/uapi/linux/rk-mpp.h` |
| Validation | MPP/RGA rewrite object builds pass on both the 6.18 and mainline-master worktrees, including compile gates with `ROCKCHIP_MPP_REWRITE_KUNIT_TEST=y` / `ROCKCHIP_RGA_REWRITE_KUNIT_TEST=y`; the ABI.rst ledgers record validated-against-userspace behaviours per §2/§3, and both rewrite drivers now carry optional KUnit coverage for pure ABI/helper logic. [`tests/rewrite-smoke.sh`](../tests/rewrite-smoke.sh) is the repeatable consumer workload gate for whichever implementation owns `/dev/mpp_service` and `/dev/rga` (forward-port or rewrite). **UNVERIFIED in this repo**: that gate has not yet passed on hardware through the rewrite; no validation record equivalent to status.md exists yet. On the current 2026-07-01 board boot the script skips because both device nodes are absent. |

> **TODO — publish before relying on these cites:** the rewrite exists *only*
> on the dev box (staged/modified 6.18 worktree + uncommitted master diff; the
> dev box is a single point of failure). Push the 6.18 rewrite state and the
> mainline-master DT work to a citable public branch, then replace the
> local-tree cites in this
> doc and source-trees.md §8 with the public URL + hashes. Until then every anchor in
> this doc is **unresolvable outside the dev box**.

Cross-references: [uAPI guide](./dev-uapis.md) (uAPI surface),
[userspace library guide](../../userspace-libraries/docs/how-the-userspace-libs-work.md) (the librga behaviours §3
encodes), [device-tree guide](./device-tree.md) (6.18 DT), [kernel status](./status.md) /
[`status.md`](../../status.md) (project status rows).
