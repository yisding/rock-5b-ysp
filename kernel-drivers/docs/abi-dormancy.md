# Dormant ABI & dead code in the userspace libraries

What this answers: **which parts of the `librockchip_mpp` and `librga` userspace↔kernel
ABI are actually exercised at runtime, and which are defined-but-dead** — so a driver
rewrite does not waste effort supporting ioctl commands, flags, or subsystems that no
live client path ever uses.

Why it exists: the rewrite track once treated the MPP **batch server** (`MPP_DEV_BATCH_ON`
/ `mpp_server.c`) as ABI it had to support specially. It is fully dormant — the enable
switch has zero callers, so no userspace path ever reaches it. This doc catalogs every
other trap of that shape found in both libraries, with zero-caller evidence, so the same
mistake is not repeated. Companion to [`dev-uapis.md`](dev-uapis.md) (what the ABI *is*)
and [`rewrite-drivers.md`](rewrite-drivers.md) (the reimplementation track).

Sources studied:

| Source | Pin | Notes |
|--------|-----|-------|
| `mpp-rockchip` (`librockchip_mpp`) | `1375813cbbae5ad6861b166475dd8fb672183220` | `/dev/mpp_service` client; all `mpp` anchors are against this tree. |
| `librga-src` (`librga`) | `a6322179c944aced42e326519cd89483bf9da26b` | `/dev/rga` client; all `rga` anchors are against this tree. |

> **Method / trust:** MEASURED-from-source. Findings came from a multi-agent zero-caller
> sweep — for each ABI element, grep the whole tree for a *sender* (a site that writes the
> constant into a `req->cmd`/`req->flag` reaching an `ioctl()`, or a `mpp_dev_ioctl(dev, CMD)`
> call). Enum definitions, `switch` cases, bounds-checks, and vtable slots are **not**
> senders. "DORMANT" = defined and possibly handled, but never sent by any reachable path.
> Not run on hardware; the ioctl *streams* were not captured with `strace` (a good
> confirmation step — see caveats).

---

## TL;DR for the rewrite

1. **Dead-by-construction subsystems you can ignore for these two clients:** the MPP batch
   server (`mpp_server.c` + `MPP_DEV_BATCH_ON/OFF/SET_CB_CTX`), the MPP `set_flag` chain
   (and the three write-flags it gates), and the RGA2 `0x60xx` blit family (all but the
   version probe). Evidence below.
2. **But "not issued by this library" ≠ "the kernel can delete it."** Other clients
   (ffmpeg's own paths, gstreamer, older lib versions, vendor tools) may still send these.
   Treat a not-issued finding as *a lead to confirm*, not a verdict. The strongest deletion
   candidates are the ones marked **internally dead** — unreachable within the library too.
3. **Verify deadness across ALL paths.** Several elements look dead in the path you happen
   to read but are live in another (`SET_SESSION_FD`, `codec_mode`, RGA1). Reading one path
   is exactly how the batch server misled the last rewrite. See [Inverse traps](#inverse-traps).
4. **Confirm on hardware** with `strace -e ioctl -f <app>` before dropping anything — this
   doc is static analysis of two clients, not a runtime capture.

---

## The seven trap shapes

Every finding is an instance of one of these. Recognizing the shape is the point.

1. **Enable-switch with zero senders** → the whole subsystem behind it is unreachable.
2. **ABI constant defined but never emitted** by any builder.
3. **Flag bit nothing ever sets.**
4. **Config field settable but never read** (silent no-op).
5. **Vtable hook populated but never invoked.**
6. **Whole module reachable only from its unit test.**
7. **Inverse trap — dead in the path you read, LIVE in another** (the dangerous one).

---

## MPP — `/dev/mpp_service` ABI dormancy

Not issued by `librockchip_mpp`. **Internally dead** = also structurally unreachable within
the library (strongest deletion candidate for this client).

| ABI element | Kind | Defined at | Internally dead? | Conf |
|---|---|---|---|---|
| `MppDevCmd` property enum — `MPP_DEV_GET_MAX_WIDTH`, `_MAX_HEIGHT`, `_MIN_WIDTH`, `_MIN_HEIGHT`, `_GET_MMU_STATUS`, `_SET_HARD_PLATFORM`, `_ENABLE_POSTPROCCESS` | device-property enum | `osal/inc/mpp_service.h:34-45` | never wired at all — each token appears exactly once (its definition) | high |
| Batch chain: `MPP_DEV_BATCH_ON`/`BATCH_OFF`, `MPP_DEV_SET_CB_CTX`, `MPP_FLAGS_POLL_NON_BLOCK`, entire `mpp_server.c` | subsystem + trigger | `osal/inc/mpp_device.h:22-25`, `mpp_service.h:29`, `osal/driver/mpp_server.c` | ✅ `batch_io` set to 1 only in `server_attach` (`mpp_server.c:731`), reachable only via the zero-caller `MPP_DEV_BATCH_ON`; `batch_io` inits 0 (`mpp_service.c:328`) and never changes | high |
| `set_flag` chain: `MPP_DEV_SET_FLAG` → `MPP_FLAGS_REG_FD_NO_TRANS`, `_SCL_FD_NO_TRANS`, `_SECURE_MODE` | dispatch cmd + 3 flags | `mpp_device.h:35`; `mpp_service.h:26,27,30` | ✅ `MPP_DEV_SET_FLAG` has no sender → `reg_wr_flag` (`mpp_service_impl.h:64`) permanently 0 → `mpp_service_reg_wr:497` always sends `flag=0` | high |
| `MPP_CMD_INIT_DRIVER_DATA` (0x101), `INIT_TRANS_TABLE` (0x102), `RESET_SESSION` (0x400) | device-command enum | `mpp_service.h:57,58,76` | def-only (`INIT_TRANS_TABLE` also appears once as a `<=` bounds check, not a sender) | high |

**Keep these — LIVE but capability-gated** (easy to wrongly cut because they only fire on
certain HW/codecs):

| Command | Live sender path | Gate |
|---|---|---|
| `MPP_CMD_SET_SESSION_FD` (0x204) | `mpp_service_delimit` (`mpp_service.c:473`) ← `MPP_DEV_DELIMIT` ← HEVC tile-parallel (`hal_h265e_vepu580.c:2991`), multi-partition JPEG (`hal_jpege_vepu2_v2.c:721`) | `send_cmd > SET_SESSION_FD` for h265e; ungated for jpege |
| `MPP_CMD_SET_ERR_REF_HACK` (0x404) | `mpp_service_set_err_ref_hack` ← `MPP_DEV_SET_ERR_REF_HACK` ← `hal_h264d_vdpu382.c:562` | `ctrl_cmd > SET_ERR_REF_HACK` |
| `MPP_CMD_SEND_CODEC_INFO` (0x403) | `mpp_service_cmd_send:733` ← `MPP_DEV_SET_INFO` (dec + enc) | `check_cmd_valid` |
| `MPP_CMD_SET_RCB_INFO` (0x203) | `delimit`/`cmd_send` ← `MPP_DEV_RCB_INFO` (many HALs) | `check_cmd_valid` + env `disable_rcb_info` |
| `MPP_CMD_POLL_HW_IRQ` (0x301) | `mpp_service_cmd_poll:814` (encoder HALs) | `check_cmd_valid(POLL_HW_IRQ)` |
| `TRANS_FD_TO_IOVA` (0x401) / `RELEASE_FD` (0x402) | `mpp_service_ioc_attach_fd`/`detach_fd` ← `MPP_DEV_ATTACH_FD`/`DETACH_FD` (`mpp_buffer_impl.c`) | none |
| Probe trio + core set | `check_mpp_service_cap`; core send/poll; vproc + legacy clients | startup / core |

The vproc (`mpp/vproc/vdpp/*`, `iep2`) and legacy (`mpp/legacy/vpu.c`) clients build their
own `MppReqV1` arrays and issue **only** the live core set — corroborating the zero-caller
findings. (`vcodec_service.c`/`vpu.c` use the separate legacy `VPU_IOC_*` ioctls, not
`MPP_IOC_CFG_V1`.)

---

## MPP — non-ABI dormancy

| Item | Kind | Defined at | Status | Conf |
|---|---|---|---|---|
| `batch_mode` | dec config field | `mpp_dec_cfg.c:31`, `mpp_dec_cfg.h:42` | settable via `"base:batch_mode"`, **zero readers** | high |
| `internal_pts` | dec config field | `mpp_dec_cfg.c:36`, `mpp_dec_cfg.h:48` | zero readers (unrelated `use_internal_pts` elsewhere is a red herring) | high |
| `codec_mode` | dec config field | `mpp_dec_cfg.c:46`, `mpp_dec_cfg.h:58` | reachable via **public** `MPP_DEC_SET_CODEC_MODE`, but the only reader is a debug print (`mpp_dec.c:1032`) — silent no-op (HAL selects device by `hw_type`) | high |
| `vproc_task_count` | status field | `mpp_dec_cfg.h:83` | never written/read (siblings `hal_task_count`/`hal_support_fast_mode` are live) | high |
| `.attach`, `.detach`, `.set_cb_ctx`, `.set_flag` | `MppDevApi` hooks | `mpp_service.c` | populated, invoked only under zero-sender `MPP_DEV_BATCH_ON/OFF/SET_CB_CTX/SET_FLAG` | high |
| `MppDecModeApi.stop` | vtable hook | `mpp_dec_impl.h:61` | NULL in both impls (`mpp_dec_normal.c:1241`, `mpp_dec_no_thread.c:449`); no `->stop(` call anywhere | high |
| `mpp_cluster.c` (MppNode/MppCluster scheduler) | module | `mpp/base/mpp_cluster.c` | **test-only** — ships in `mpp_base`, but every entry point's sole caller is `mpp/base/test/mpp_cluster_test.c`; internal header, not public | high |

### The 28 dormant encoder config fields

All are settable `ENTRY` rows in `mpp/base/mpp_enc_cfg.c` whose backing struct member
(`inc/rk_venc_cmd.h`) has **zero behavioral readers**. Some are touched only by set-default
writers or the validate/clamp block (`mpp/codec/mpp_enc_impl.c:~880-1010`) — which does not
count as consuming the value. Confidence Med-High (word-boundary grep, non-consumer sites
subtracted).

- **Pure API stubs** (no occurrence beyond table + struct): `base:smt1_en` (:46),
  `base:smt3_en` (:47), `rc:fps_chg_no_idr` (:63), `rc:mt_st_swth_frm_qp` (:98),
  `rc:inst_br_lvl` (:99), `h264:max_ltr` (:151), `h265:max_ltr` (:183), `tune:se_mode` (:241).
- **`tune:qpmap_en` (:275) — genuine trap:** the live HAL `ctx->qpmap_en` (25 hits) is fed
  from `tune.deblur_en`, **not** from this config field, which is never read.
- **`vepu500`-only static-detection set — config ahead of hardware** (no vepu500 HAL exists
  in this tree; validation-only): `tune:lgt_chg_lvl` (:256), `tune:static_frm_num` (:257),
  `tune:madp16_th` (:258), `tune:skip16_wgt` (:259), `tune:skip32_wgt` (:260).
- **smart-v3 fg/bg QP-map set** (set-default + clamp only, no back-end): `tune:bg_delta_qp_i/p`
  (:262/:263), `tune:fg_delta_qp_i/p` (:264/:265), `tune:bmap_qpmin_i/p` (:266/:267),
  `tune:bmap_qpmax_i/p` (:268/:269), `tune:min_bg_fqp`/`max_bg_fqp` (:270/:271),
  `tune:min_fg_fqp`/`max_fg_fqp` (:272/:273), `tune:fg_area` (:274).
- **Borderline:** `tune:motion_static_switch_enable` (:254) — read only by a change-detector
  (`mpp_enc_impl.c:1005`) that triggers an rc-refresh; the value never feeds an
  encode/register decision, so functionally a no-op.

### MPP — explicitly NOT dead (do not chase these)

Public API with no in-tree caller is **not** dead — external apps call it:
`mpp_vdec_kcfg_*`/`mpp_venc_kcfg_*` (shipped `rk_vdec_kcfg.h`/`rk_venc_kcfg.h`),
`mpp_dev_set_reg_offset` (100+ HAL callers via the public helper, even though
`MPP_DEV_REG_OFFSET` has no *direct* ioctl sender), and the live `MppDevApi` hooks
(`.delimit`, `.set_err_ref_hack`, `.reg_offs`, `.rcb_info`, `.lock_map`, `.attach_fd`, …).
Parser/HAL/EncImpl op tables are live via null-checking generic wrappers; only
`MppDecModeApi.stop` is dead everywhere.

---

## RGA — `/dev/rga` ABI dormancy

`librga` opens only `/dev/rga` (`core/NormalRga.cpp:143`, `im2d_api/src/im2d_context.cpp:116`);
`/dev/dri/card0` is opened solely for DRM DUMB-buffer allocation (`core/RockchipRga.cpp:200`),
a separate helper ABI. No `/dev/rga2` and no DRM-render path exists.

**The RGA2 `0x60xx` decoy** (direct analogue of the batch trap): even when librga detects a
legacy RGA2 driver, it dispatches blits with the `0x50xx` numbers + `rga2_req` payload — never
the `0x60xx` numbers. Not issued by librga:

| ABI element | Defined at | Note | Conf |
|---|---|---|---|
| `RGA2_BLIT_SYNC` (0x6017), `RGA2_BLIT_ASYNC` (0x6018), `RGA2_FLUSH` (0x6019), `RGA2_GET_RESULT` (0x601a) | `core/hardware/rga_ioctl.h:57-60` | only `RGA2_GET_VERSION` (0x601b) from this range is live | high |
| `RGA_GET_RESULT` (0x501a) | `rga_ioctl.h:54` | zero refs | high |
| `RGA_START_CONFIG`/`END_CONFIG`/`CMD_CONFIG`/`CANCEL_CONFIG` | `rga_ioctl.h:63-66` | dead alias macros of the real `RGA_IOC_REQUEST_*` names | high |

**Keep these — the live RGA ABI the driver must support:**

- **Version/capability probe:** `RGA_IOC_GET_DRVIER_VERSION` (0x1), `RGA_IOC_GET_HW_VERSION`
  (0x2) — success flips librga into the modern `RGA_DRIVER_IOC_MULTI_RGA` path. Fallbacks
  `RGA2_GET_VERSION` (0x601b) → `RGA_GET_VERSION` (0x501b) remain live for old drivers.
- **Legacy blit family:** `RGA_BLIT_SYNC` (0x5017), `RGA_BLIT_ASYNC` (0x5018, via public
  `IM_ASYNC`/`sync_mode`), `RGA_FLUSH` (0x5019, only via public `RkRgaFlush`).
- **Modern job/buffer family:** `RGA_IOC_REQUEST_CREATE`/`SUBMIT`/`CONFIG`/`CANCEL` (0x5-0x8),
  `RGA_IOC_IMPORT_BUFFER`/`RELEASE_BUFFER` (0x3/0x4) — all reached only through the public
  im2d job/buffer API (`imbeginJob`, `imendJob`, `imcancelJob`, `importbuffer_*`, and the
  rockit MPI `improcess_ctx` for `REQUEST_CONFIG`). Payloads: `struct rga_user_request`,
  `struct rga_external_buffer`.

So a driver keeping the `0x60xx` range "for RGA2" needs, for librga's sake, only
`RGA2_GET_VERSION`.

---

## RGA — non-ABI dormancy

- **4 dead `render_mode` values** — `line_point_drawing_mode`, `blur_sharp_filter_mode`,
  `pre_scaling_mode`, `update_patten_buff_mode` (`rga_ioctl.h:88-91`). Their only writers are
  5 zero-caller **internal** setters (`NormalRgaSetLineDrawingMode` etc.,
  `core/NormalRgaApi.cpp:687,717,728,753,622`) — not public API, genuinely dead. The four live
  modes are `bitblt_mode`, `color_fill_mode`, `color_palette_mode`, `update_palette_table_mode`.
- **Dead `rga_req` bitfields:** `nn_quantize` (`rga_ioctl.h:461`), `real_color_mode` (:462),
  `secure_access` (:463) — never set by name; the aggregate `alpha_rop_flag` write only touches
  bits 0-7. Plus the explicitly `/* unused */` mask enums `rop_enable_mask`,
  `dither_enable_mask`, `fading_enable_mask`, `PD_enbale_mask` (:96-101).
- **Live and driver-relevant** newer `rga_req` fields (do not assume the struct tail is dead):
  `gauss_config`, `cfa_*`, `mosaic_info`, `osd_info`, `pre_intr_info`, `full_csc`/`full_csc_clip`,
  `rgba5551_alpha`, `uvhds_mode`/`uvvds_mode`, `feature.*`, and both `interp` (MULTI_RGA) and
  `scale_mode` (RGA2 compat) union members.
- **`RGA_CORE_MASK` scheduler-core constants** (`rga.h:191-198`) — no internal refs, but
  **public**; the `core` field is caller-supplied. Not dead.

---

## Inverse traps

The dangerous category: **dead in the path you read, LIVE elsewhere.** Verify across all
senders before cutting.

| Element | Looks dead because… | …but it is LIVE via |
|---|---|---|
| `MPP_CMD_SET_SESSION_FD` | its `mpp_server.c` batch senders are dead | `mpp_service_delimit` ← `MPP_DEV_DELIMIT` (HEVC tiles, JPEG partitions) |
| `codec_mode` (dec cfg) | it's a config field | reachable from **public** `MPP_DEC_SET_CODEC_MODE` — but does nothing (no-op, opposite trap) |
| `RGA_DRIVER_IOC_RGA1` | the legacy `NormalRga` path never assigns it (only MULTI_RGA/RGA2) | handled in the im2d path (`im2d_context.cpp:149`); folded into RGA2 in the old path |

Rule: a command is only safely "dead" when **no** sender in **any** client path reaches it —
and even then, other userspace clients outside these two trees may still send it.

---

## The two caveats (restated, because they matter most)

1. **"Not issued by this library" is necessary but not sufficient** to prove the kernel can
   drop a command. Confirm no other client uses it. The internally-dead rows are the safe ones.
2. **Static analysis of two clients is not a runtime capture.** Before deleting anything from
   the driver, `strace -e ioctl -f` the real workloads (ffmpeg decode/encode, RGA blit, GRD)
   and diff the observed command set against the "live" lists above.

---

## Scope / not covered here

- The **kmpp channel ABI** (`VCODEC_CHAN_*` in `kmpp/kmpp.c`, `KMPP_SHM_IOC_*`/`KMPP_IOCTL_IOC_*`
  in `kmpp/base/kmpp_obj.c`) is a **separate** kernel interface from `mpp_service` and is
  intentionally out of scope here — it has been explored separately.
- Only the `librockchip_mpp` and `librga` userspace clients were swept. FFmpeg/GStreamer issue
  the same ioctls *through* these libraries, so their live set is a subset of the "keep" lists —
  but confirm with `strace` if in doubt.
