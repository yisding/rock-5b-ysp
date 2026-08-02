# Forward-port scope — what we ported, what we didn't, and what we added

The scope boundary of the RK3588 media forward-port, in one place. It answers
four questions that are usually answered in fragments:

1. **What did we forward-port?** Which BSP blocks are in our 6.18 tree.
2. **What did we not port?** Which BSP blocks were left behind, and whether that
   costs anything on this board.
3. **What did we decide not to support?** Features stubbed on purpose, with the
   consequence of each stub.
4. **What does our port have that the BSP doesn't?** Where we are ahead of
   Rockchip's own code.

Companion docs, which this one links rather than repeats: the
[patch catalog](./patch-catalog.md) (per-patch provenance and BSP-backport
verdicts), [vendor delta](./vendor-delta.md) (line-level vendor-vs-ours
accounting), the [forward-port guide](../../kernel-versions/docs/vendor-forward-port.md)
(narrative of each 6.18 adaptation), the
[BSP 6.1/6.6/5.10 comparison](./bsp-6.1-6.6-comparison.md) (how the vendor
branches differ from each other), and the
[series README](../patches/forward-port-rk3588/README.md) (the mechanical patch
index).

> **Trust.** The structural facts below — file lists, Kconfig option sets, DT
> node names, enabled config symbols — were measured directly against the pinned
> trees on 2026-07-24 and are reproducible with the commands in
> [Reproducing the scope tables](#reproducing-the-scope-tables). Line-percentage
> claims are cited from [vendor delta](./vendor-delta.md) rather than
> recomputed here. Validation state is **not** covered here; that is
> [forward-port status](./forward-port-status.md) and the
> [validation runbook](./kernel-validation-runbook.md).

## The short answer

We ported **the two accelerator paths this board actually uses for video** — the
MPP service with the VEPU580 encoder, the VDPU381 decoder, and the AV1 decoder;
and the multi-RGA 2D engine covering both RGA3 and RGA2 hardware. Everything
else in the BSP's `drivers/video/rockchip/` was deliberately left behind: the
legacy pre-RK3588 codec blocks, the JPEG cores, the post-processors, and four
subsystems that serve product categories this board is not.

Structurally that is **7 of the BSP's 17 `mpp_*.c` files** and **2 of its 10
`drivers/video/rockchip/` subdirectories**. The omissions are dominated by
hardware that either does not exist on RK3588 or has no consumer in our
userspace stack — not by work left half-done.

Against the BSP we are **ahead** on correctness: the port carries 20 vendor RGA
fixes from `develop-5.10` that the 6.1 BSP never received, plus defects we found
ourselves under KASAN, DMA-debug, and hostile-ioctl replay on byte-identical BSP
code — several of them unprivileged memory-corruption bugs. The
[patch catalog](./patch-catalog.md) classes **14 patches as `BSP-BUG`**
(explicit backport candidates) and **4 as `HARDEN`**; the separate 11-patch
BSP-audit HIGH port (`0058`–`0068`) is backport material by construction, since
every one of those findings was still present in Rockchip's code.

## 1. What we forward-ported

### Kernel modules

| Ported | Our path | Hardware driven | Kconfig |
|---|---|---|---|
| MPP service core | `mpp/mpp_service.c`, `mpp_common.c`, `mpp_iommu.c` | session/task/scheduler layer over `/dev/mpp_service` | `ROCKCHIP_MPP_SERVICE` |
| VEPU580 encoder | `mpp/mpp_rkvenc2.c` | 2× H.264/H.265 encoder cores + CCU/DCHS | `ROCKCHIP_MPP_RKVENC2` |
| VDPU381 decoder | `mpp/mpp_rkvdec2.c`, `mpp_rkvdec2_link.c` | 2× H.264/H.265/VP9/AVS2 decoder cores, CCU, RCB SRAM, link mode | `ROCKCHIP_MPP_RKVDEC2` |
| AV1 decoder | `mpp/mpp_av1dec.c` | the separate Verisilicon AV1 block | `ROCKCHIP_MPP_AV1DEC` |
| Multi-RGA | `rga3/` (12 `.c`) | **both** RGA3 cores *and* RGA2 | `ROCKCHIP_MULTI_RGA` |
| MPP procfs | — | `/proc/mpp_service/*` | `ROCKCHIP_MPP_PROC_FS` |

16,540 lines under `mpp/` (plus 297 of `compat/` and 1,445 of verbatim `hack/`)
and 21,088 under `rga3/`. Of the 39,535 total, **≈ 87% is byte-identical to the 6.1 donor and ≈ 90% is
Rockchip-authored** once the 20 cherry-picked `develop-5.10` RGA commits are
counted on the vendor side — the full provenance breakdown, its caveats, and
the out-of-directory footprint are in
[vendor delta](./vendor-delta.md#the-answer-90-rockchip-10-ours).

**The RGA naming trap.** Our tree has a directory called `rga3/`, and the BSP
has three RGA directories (`rga/`, `rga2/`, `rga3/`). It is easy to read that as
"we dropped RGA2 support". We did not: the BSP's `rga3/` **is** the multi-RGA
driver and it contains `rga2_reg_info.c`, so porting it brings RGA2 hardware
with it. The BSP's separate `rga/` and `rga2/` directories are the older
standalone drivers for pre-RK3588 SoCs. On this board RGA2 is live and is
routinely the *passing* control leg in our 10-bit gates.

### Device tree

Patches `0002` and `0009` add the encoder, decoder, AV1, and RGA nodes plus
their IOMMUs and SRAM wiring: `rkvenc0`, `rkvenc1`, `rkvenc0_mmu`,
`rkvenc1_mmu`, `rkvenc_ccu`, `rkvdec_ccu`, `av1d_mmu`, `rga3_core0`,
`rga3_core1`, `rga3_0_mmu`, `rga3_1_mmu`, `rga2`. Details in
[device tree](./device-tree.md).

### The `hack/` directory

Carried verbatim from the BSP (`mpp_hack_px30.c`, `mpp_rkvdec2_hack_rk3568.c`,
`mpp_hack_rk3576.c`, …). These are other-SoC workarounds that RK3588 never
executes; they were kept unmodified rather than deleted so that re-syncing
against a newer BSP stays a clean diff. [vendor delta](./vendor-delta.md) counts
them as 0% ours.

## 2. What we have NOT forward-ported

### BSP `mpp_*.c` blocks left behind (10 of 17)

| BSP file | Kconfig | Block | Why it is not ported |
|---|---|---|---|
| `mpp_rkvdec.c` | `ROCKCHIP_MPP_RKVDEC` | RKVDEC **v1** decoder | Pre-RK3588 hardware; RK3588 has VDPU381 (v2). |
| `mpp_rkvenc.c` | `ROCKCHIP_MPP_RKVENC` | RKVENC **v1** encoder | Pre-RK3588; RK3588 has VEPU580 (v2). |
| `mpp_vdpu1.c` | `ROCKCHIP_MPP_VDPU1` | VPU1 decoder | Legacy SoC block, absent on RK3588. |
| `mpp_vepu1.c` | `ROCKCHIP_MPP_VEPU1` | VPU1 encoder | Legacy SoC block, absent on RK3588. |
| `mpp_vdpu2.c` | `ROCKCHIP_MPP_VDPU2` | VPU2 decoder | Legacy SoC block, absent on RK3588. |
| `mpp_vepu2.c` | `ROCKCHIP_MPP_VEPU2` | VPU2 encoder | Legacy SoC block, absent on RK3588. |
| `mpp_jpgdec.c` | `ROCKCHIP_MPP_JPGDEC` | JPEG decoder | Not ported. See the JPEG note below. |
| `mpp_jpgenc.c` | `ROCKCHIP_MPP_JPGENC` | JPEG encoder | Not ported. See the JPEG note below. |
| `mpp_iep2.c` | `ROCKCHIP_MPP_IEP2` | RK3588 IEP2 de-interlacer | **Real omitted RK3588 capability.** Installed libmpp probes client 28 for interlaced decoder output, but this kernel cannot create it. See the [IEP2 audit](../iep2/README.md). |
| `mpp_vdpp.c` | `ROCKCHIP_MPP_VDPP` | Separate VDPP post-processor | Absent on RK3588. The BSP driver binds VDPP instances on RK3528/RK3576, not this SoC. |

**JPEG and IEP2 are real capability gaps.** RK3588 has both JPEG codec hardware
and the IEP2 de-interlacer, and we chose not to port them. The JPEG consequence is visible and
recorded: the GStreamer suite's JPEG and VP8 encoder cases fail as
*expected diagnostics* because this kernel registers no such cores, and libmpp
logs benign `client N driver is not ready!` lines while probing for them. The
IEP2 consequence is also visible: interlaced output makes libmpp request client
28, receive `EINVAL`, disable deinterlacing, and continue decoding. Every other
unported `mpp_*` block above is hardware this SoC does not have. JPEG and IEP2
are deliberate scope decisions that can be revisited. (Mainline's own Hantro JPEG driver is a separate, coexisting
path — see [coexistence](#coexistence-with-mainline-drivers).)

### BSP subdirectories left behind (8 of 10)

| BSP directory | What it is | Why not ported |
|---|---|---|
| `rga/` | Legacy standalone RGA (v1) | Superseded by multi-RGA for RK3588. |
| `rga2/` | Legacy standalone RGA2 | Superseded — RGA2 comes via multi-RGA. |
| `iep/` | Legacy standalone Image Enhancement Processor | Separate from RK3588's MPP IEP2 path; the missing RK3588 capability is `mpp_iep2.c`, accounted for above. |
| `rve/` | RVE vector engine | Not present/needed on this board's use cases. |
| `dvbm/` | Direct Video Buffer Manager | Camera/ISP-to-encoder zero-copy plumbing; no consumer. |
| `vtunnel/` | Video tunnel device | Android-style buffer tunnelling; not applicable to a desktop Linux stack. |
| `vehicle/` | Fast Reverse Image | Automotive backup-camera feature; not applicable. |
| `mpp_osal/` | MPP OS-abstraction shim | Only needed by the blocks we did not port. |

### Other BSP subsystems out of scope

- **RKNPU** (`drivers/rknpu`, 8,598 lines) — the NPU driver is **not ported**.
  It is scoped, not abandoned: the
  [RKNPU scoping finding](../../findings/2026-07-24-rknpu-forward-port-scoping.md)
  estimates 2–4 days to probing and 1–2 weeks to validated inference, and
  identifies the three hard spots (`rknpu_iommu.c`'s dead `iova_cookie` cast,
  `rknpu_devfreq.c`'s dependence on absent BSP SoC infrastructure, and the
  collision with mainline's new `drivers/accel/rocket` claiming the same
  silicon).
- **BSP IOMMU driver** — deliberately *not* wholesale forward-ported. See the
  decision in §3.

## 3. Decisions we made to not support features

These are features the BSP has that our port **intentionally** does without.
Each is a stub or a substitution, not an oversight. Full per-shim detail is in
the [forward-port guide](../../kernel-versions/docs/vendor-forward-port.md);
this is the decision layer.

| Feature dropped | Mechanism | Consequence |
|---|---|---|
| **PVTM/OPP voltage selection** (`rockchip_opp_select`) | compat shim returns `-EOPNOTSUPP` | `rkvenc_devfreq_init()` bails → **no per-chip voltage/leakage management** on the codec cores. Tracked as W15. |
| **System monitor** (thermal/voltage coupling) | shim returns `ERR_PTR(-ENODEV)` | Driver logs "without system monitor" and continues; mainline thermal cooling substitutes. |
| **DMC / DDR devfreq coupling** | no-op lock/unlock | **Matches the BSP's own** `!CONFIG_ROCKCHIP_DMC` inlines — the stub *is* vendor behaviour, so nothing is lost. |
| **IPA static-power thermal model** | empty stub | Dead include; no symbol referenced. Deletable (W6). |
| **SiP SMC VPU reset** | shim zeroes the SMC result | ATF-based reset unavailable; the live path is the CRU-based `rkvdec2_reset()` fallback, whose callers ignore the return value. |
| **QoS save/restore** | shim returns `0` | **Matches the BSP's own** `!CONFIG_ROCKCHIP_PM_DOMAINS` inline — correct for the SIP-off reset path. |
| **PMU idle request** | shim returns `0` | Short-circuited anyway: the RK3588 DT sets `rockchip,skip-pmu-idle-request`, so the call is never reached. |
| **Codec devfreq** | `ROCKCHIP_MPP_{RKVENC2,RKVDEC2}_DEVFREQ` exist in our Kconfig but are **`is not set`** in the shipping config | No dynamic frequency scaling on the codec cores. |

Read that table carefully before treating it as capability loss: three of the
eight stubs (**DMC**, **QoS**, **PMU idle**) reproduce what the vendor driver
itself does when the corresponding BSP config is off, and one (**IPA**) is
referenced by nothing. The genuine functional reductions are **voltage/OPP
management** and **codec devfreq** — both power/thermal optimisations, neither
affecting correctness.

### The IOMMU decision

The most consequential architectural choice: we **kept mainline
`drivers/iommu/rockchip-iommu.c` as the provider** and added narrow BSP helper
semantics to it (enable/disable/reset, IRQ mask/unmask, a Rockchip fault
callback hook for MPP) instead of forward-porting the BSP's IOMMU driver
wholesale. The reasoning was to avoid fighting the 6.18 IOMMU core's DMA-domain
cookie model while restoring the media reset/fault semantics the drivers
actually need. This is why patches `0003`–`0006`, `0012`–`0015` exist at all,
and it is the same disease the RKNPU port would have to cure.

## 4. What our forward port has that the BSP does not

Grouped by the [patch catalog](./patch-catalog.md)'s provenance classes.

### 4a. Mainline-6.18 integration (`PORT`) — patches `0003`–`0016`

Exists only because the target is mainline: IOMMU/DMA provider hooks, the
Verisilicon AV1 IOMMU provider, `mpp_iommu_shared_domain` CCU helper, DT
plumbing, large-DMA-segment restoration, sub-32-bit IOVA guards, scattered
userptr mapping, optional RCB SRAM. **Not BSP-relevant** — the BSP has its own
private APIs for these jobs.

### 4b. Vendor fixes the 6.1 BSP never received (`VENDOR`) — patches `0017`–`0036`

Twenty Rockchip-authored RGA commits cherry-picked from `develop-5.10`, which
continued receiving RGA work through June 2026 that never reached `develop-6.1`
or `develop-6.6`: hardware batching, RK3588 low-voltage workarounds,
`shadow_page` for cache-line-unaligned VAs, request-lifetime and IOMMU-prefetch
fixes, CSC/scale correctness, rotate and tile fixes. **Anyone running the 6.1
BSP is missing these.**

### 4c. Defects we found in Rockchip's own code (`BSP-BUG`) — the backport-value core

Found under KASAN, lockdep, DMA-debug, and hostile-ioctl replay against
byte-identical BSP code, so they are latent in the BSP too. Two populations,
counted separately because they were found by different means: **14 patches the
[patch catalog](./patch-catalog.md) classes `BSP-BUG`** (found by us, verdict
recorded per patch), and the **11-patch BSP-audit HIGH port** `0058`–`0068`
(found by auditing, and by construction still present on the tip — see
[bsp-audit.md](./bsp-audit.md)). Highlights, several unprivileged-reachable via
the `video`-group device nodes:

- **Memory corruption / UAF:** register-translation OOB write over a
  `work_struct`; `SET_SESSION_FD` type confusion; double-`INIT_CLIENT_TYPE` UAF
  of a freed `mpp_session`; RGA request double-drop; job-vs-session-close UAF;
  RESET_SESSION double-free.
- **NULL-deref / DoS:** client-less `RELEASE_FD`; device-less session on the
  wait-result and worker paths — the proven root cause of the VP9
  `show_existing_frame` board hard-lock.
- **Bounds:** RCB register indexes, class request arrays, staged request tasks,
  physical import pages, multi-plane handles.
- **10-bit correctness:** byte-literal raster strides and plane offsets for
  P010/P210/NV15 — the stock BSP misprograms these.

### 4d. Hardening beyond the BSP (`HARDEN`)

Validation and fail-closed behaviour the BSP does not have, where the weakness
exists there too: RGA3 rejecting a 16-misaligned IOMMU window base instead of
silently returning zero pixels; the RGA2 MMU page-table builder failing closed
with `-EOPNOTSUPP` on above-4G entries instead of programming a truncated page
and bus-erroring; distinct `EOPNOTSUPP` reporting for the under-4G exclusion.

### 4e. Capability the BSP donor lacked in this configuration

**AV1 decode** (`0007` + the Verisilicon IOMMU provider in `0005`) is baked
into the single forward-port line, with bit-exact AV1 decode validated on
hardware.

### 4f. Validation infrastructure

Not kernel code, but part of what this port has and a BSP drop does not: a
conformance harness (MPP official matrix, FFmpeg, GStreamer, librga suites),
targeted gate probes per fix, KASAN reproduction harnesses for previously-fixed
memory-safety bugs, an IOMMU fuzzer, and the
[validation runbook](./kernel-validation-runbook.md)'s evidence ladder.

## Coexistence with mainline drivers

The shipping config enables mainline's own Rockchip media drivers **alongside**
the vendor stack: `VIDEO_ROCKCHIP_RGA=m`, `VIDEO_ROCKCHIP_VDEC=m`,
`VIDEO_ROCKCHIP_IEP=m`. These are the V4L2 M2M drivers, unrelated to our
`/dev/rga` and `/dev/mpp_service` paths, and mainline's Hantro JPEG instances
are the source of the routine `fdba*.video-codec` markers in boot logs. They are
not part of the forward-port; the alternative-stack analysis lives in
[mainline rkvdec V4L2](../../kernel-versions/docs/mainline-rkvdec-v4l2.md).

## Reproducing the scope tables

```sh
OURS=../rock-5b/kernel/linux-6.18-rkvenc-av1-fwport/drivers/video/rockchip
BSP=../rock-5b/kernel/rockchip-kernel/drivers/video/rockchip

# ported vs unported mpp blocks
ls "$OURS"/mpp/*.c "$BSP"/mpp/*.c | xargs -n1 basename | sort -u

# ported vs unported subsystems
ls -d "$OURS"/*/ "$BSP"/*/ | xargs -n1 basename | sort -u

# Kconfig option sets
grep -hE '^(menu)?config ' "$OURS"/mpp/Kconfig "$BSP"/mpp/Kconfig

# what the shipping kernel actually enables
grep -E '^CONFIG_ROCKCHIP_(MPP|RGA|MULTI_RGA)' /boot/config-$(uname -r)
```

## Boundary

- This doc states **scope**, not **validation state**. "Ported" here means
  present and building in the tree; what is proven on hardware, and to what
  rung, is [forward-port status](./forward-port-status.md) and the dated
  [findings](../../findings/README.md).
- The unported-block rationales are engineering judgement recorded after the
  fact. Where a row says "no consumer in our stack", that is a statement about
  *our* userspace (FFmpeg/GStreamer/GRD/librga), not a claim that the block is
  useless.
- "Absent on RK3588" for the legacy VPU/VEPU/RKVDEC-v1 blocks reflects the SoC
  generation, not a per-register audit of the TRM.
- The line counts and the ≈ 87%/90% vendor figures are current-tree measurements
  (re-audited 2026-07-24 against donor `b4ef083dc0c3`). The older **1.7% ours**
  figure quoted in some docs and dated findings belongs to the pre-AV1 two-patch
  import, not to this tree; both are kept, clearly separated, in
  [vendor delta](./vendor-delta.md). Do not mix them.
