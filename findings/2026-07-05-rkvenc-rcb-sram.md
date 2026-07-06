# RK3588 RKVENC RCB/SRAM support is ABI-plumbed but not SRAM-backed in DT

> Scope: RK3588 VEPU580/RKVENC2 encoder RCB behavior across the Rockchip 6.1 BSP,
> the local 7.2 rewrite tree, the local forward-port, live Rock 5B procfs/sysfs,
> and local `rockchip-mpp` userspace.
> Source: `../kernel/rockchip-kernel` `b4ef083dc0c3`, `../kernel/linux`
> `c092e016fd29` (`7.2.0-rc1`), `../kernel/linux-6.18-rkvenc-av1-fwport`
> `a4b67868c0dd` plus the uncommitted best-effort RCB probe fix,
> `../rockchip-conformance/sources/rockchip-mpp` `c2c1ee502b3a`, live
> `/proc/mpp_service` and `/sys/bus/platform/devices`.
> Date: 2026-07-05
> Trust: CODE-INSPECTED for source-tree evidence, MEASURED for live procfs/sysfs
> state, ONLINE-SURVEY-NEGATIVE for public documentation.

## The fact

RK3588 RKVENC has real RCB plumbing in the userspace ABI and in both kernel
implementations studied, but neither the 6.1 vendor RK3588 device tree nor the
7.2 rewrite RK3588 device tree wires the encoder cores to an SRAM-backed RCB
region. The decoder cores are wired to SRAM RCB windows; the encoder cores are
not.

The safest statement is:

> RK3588 RKVENC supports optional RCB descriptors, and current H.264 VEPU580
> userspace emits them by default, but Rockchip's RK3588 DT does not provide an
> encoder `rockchip,sram`/`rockchip,rcb-iova` backing store. On RK3588, encoder
> RCB is therefore dormant unless a valid backing region is added explicitly.

This means the forward-port must not fail encoder probe just because
`rkvenc2_alloc_rcbbuf()` cannot find `rockchip,rcb-iova`. The 6.1 BSP calls that
helper and ignores its return value. The local forward-port briefly made that
absence fatal; that is why the current booted `6.18-rkvenc-fwport` image exposes
decoders but not RKVENC.

## Live Rock 5B evidence

On the current booted image:

```text
$ cat /proc/mpp_service/version
6.18-rkvenc-fwport

$ cat /proc/mpp_service/supports-device
---- SUPPORT DEVICES ----
DEVICE[ 4]:AV1DEC    HW_ID:0x80019000
DEVICE[ 9]:RKVDEC    HW_ID:0x53813f05
```

There is no RKVENC entry.

The CCU platform device is bound, but the two encoder cores are not:

```text
/sys/bus/platform/devices/rkvenc-ccu/driver -> ../../../bus/platform/drivers/mpp_rkvenc2
/sys/bus/platform/devices/fdbd0000.rkvenc-core/driver -> MISSING
/sys/bus/platform/devices/fdbe0000.rkvenc-core/driver -> MISSING
```

The live DT has no encoder RCB/SRAM properties:

```text
/proc/device-tree/rkvenc-core@fdbd0000/rockchip,rcb-iova absent
/proc/device-tree/rkvenc-core@fdbe0000/rockchip,rcb-iova absent
/proc/device-tree/rkvenc-core@fdbd0000/rockchip,sram absent
/proc/device-tree/rkvenc-core@fdbe0000/rockchip,sram absent
```

The kernel log shows the probe reached CCU attach and then failed:

```text
mpp_rkvenc2 fdbd0000.rkvenc-core: probing start
mpp_rkvenc2 fdbd0000.rkvenc-core: attach ccu as core 0
mpp_rkvenc2 fdbd0000.rkvenc-core: probing finish
mpp_rkvenc2 fdbd0000.rkvenc-core: probe with driver mpp_rkvenc2 failed with error -22
mpp_rkvenc2 fdbe0000.rkvenc-core: probing start
mpp_rkvenc2 fdbe0000.rkvenc-core: attach ccu as core 1
mpp_rkvenc2 fdbe0000.rkvenc-core: probing finish
mpp_rkvenc2 fdbe0000.rkvenc-core: probe with driver mpp_rkvenc2 failed with error -22
```

That failure is consistent with the forward-port treating
`rkvenc2_alloc_rcbbuf()` failure as fatal. The local fix in
`../kernel/linux-6.18-rkvenc-av1-fwport/drivers/video/rockchip/mpp/mpp_rkvenc2.c`
changes both call sites back to BSP semantics:

```c
/*
 * BSP treats the RCB SRAM mapping as best-effort. RK3588 rkvenc-core
 * nodes do not provide rockchip,rcb-iova, so do not fail probe here.
 */
rkvenc2_alloc_rcbbuf(pdev, enc);
```

## 6.1 vendor BSP evidence

Tree: `../kernel/rockchip-kernel` at `b4ef083dc0c3`
(`develop-6.1`, `origin/develop-6.1`).

The RK3588 encoder nodes in
`arch/arm64/boot/dts/rockchip/rk3588s.dtsi` define the two VEPU580 cores, their
IOMMUs, service phandle, CCU phandle, task queue, clocks, resets, and power
domains:

- `rkvenc0: rkvenc-core@fdbd0000`, lines 4916-4936.
- `rkvenc1: rkvenc-core@fdbe0000`, lines 4955-4975.

Those nodes do not contain `rockchip,sram`, `rockchip,rcb-iova`, or
`rockchip,rcb-info`.

The decoder nodes in the same file do contain SRAM RCB wiring:

- `rkvdec0` has `rockchip,sram = <&rkvdec0_sram>;`,
  `rockchip,rcb-iova = <0xFFF00000 0x100000>;`, `rockchip,rcb-info`, and
  `rockchip,rcb-min-width = <512>;` around lines 5070-5076.
- `rkvdec1` has `rockchip,sram = <&rkvdec1_sram>;`,
  `rockchip,rcb-iova = <0xFFE00000 0x100000>;`, `rockchip,rcb-info`, and
  `rockchip,rcb-min-width = <512>;` around lines 5124-5130.

A BSP-wide DTS search reinforces the pattern. `rockchip,rcb-iova` appears in
decoder nodes for RK3528/RK356x/RK3576/RK3588, while the RK3588 and RK3576
`rkvenc-core` nodes are present without encoder `rcb-iova` hits.

The 6.1 RKVENC driver nevertheless has generic RKVENC RCB support:

- `rkvenc2_extract_rcb_info()` stores userspace RCB descriptors from
  `MPP_CMD_SET_RCB_INFO` into the session-private RCB array
  (`mpp_rkvenc2.c`, lines 909-925).
- `rkvenc_extract_task_msg()` handles `MPP_CMD_SET_RCB_INFO` for RKVENC sessions
  (`mpp_rkvenc2.c`, lines 996-1000).
- `rkvenc2_set_rcbbuf()` only patches registers when `enc->sram_iova` exists.
  If there is no SRAM IOVA, accepted descriptors become a no-op
  (`mpp_rkvenc2.c`, lines 1042-1084).
- The scheduler calls `rkvenc2_set_rcbbuf()` after selecting an encoder core
  (`mpp_rkvenc2.c`, line 1288).

The BSP allocation helper proves that real SRAM-backed encoder RCB would require
both properties, not just an IOVA size:

- It reads `rockchip,rcb-iova` first (`mpp_rkvenc2.c`, lines 2949-2952).
- It reserves that fixed IOVA (`mpp_rkvenc2.c`, lines 2960-2965).
- It then requires `rockchip,sram` and resolves that phandle with
  `of_address_to_resource()` (`mpp_rkvenc2.c`, lines 2966-2978).
- It maps the physical SRAM into the RKVENC IOMMU domain with `iommu_map()`
  (`mpp_rkvenc2.c`, lines 2989-2995).
- If the SRAM region is smaller than the requested RCB size, it fills the rest
  with normal pages (`mpp_rkvenc2.c`, lines 2996-3016).

The decisive BSP behavior is that both probe paths ignore the return value:

- `rkvenc_core_probe()` calls `rkvenc2_alloc_rcbbuf(pdev, enc);` at line 3107.
- `rkvenc_probe_default()` calls `rkvenc2_alloc_rcbbuf(pdev, enc);` at line 3156.

So the vendor driver can use encoder SRAM RCB if DT supplies a valid backing
region, but the vendor RK3588 DT does not supply one, and the vendor driver does
not treat that absence as a probe failure.

## 7.2 rewrite evidence

Tree: `../kernel/linux` at `c092e016fd29`, `make kernelversion` reports
`7.2.0-rc1`.

The 7.2 rewrite DT has the same RK3588 asymmetry:

- `arch/arm64/boot/dts/rockchip/rk3588-base.dtsi` defines `rkvenc0` and
  `rkvenc1` at lines 1503-1524 and 1540-1561. Those nodes have no
  `rockchip,sram` or `rockchip,rcb-iova`.
- `arch/arm64/boot/dts/rockchip/rk3588-rock-5b.dtsi` enables `mpp_srv`,
  `rkvenc_ccu`, `rkvenc0`, `rkvenc0_mmu`, `rkvenc1`, and `rkvenc1_mmu` at
  lines 88-110, again without adding encoder RCB properties.
- The same Rock 5B DT file adds decoder SRAM RCB properties to `vdec0` and
  `vdec1`: `rockchip,sram`, `rockchip,rcb-iova`, `rockchip,rcb-info`, and
  `rockchip,rcb-min-width` around lines 144-149 and 181-186.
- Searching `rk3588*.dtsi` in the rewrite tree finds only the two decoder
  `rockchip,rcb-iova` entries.

The rewrite driver supports the RKVENC client type and RCB ABI:

- `RK_MPP_DEVICE_RKVENC = 16` is present (`mpp_rewrite.c`, lines 97-101).
- `rockchip,rkv-encoder-v2-core` binds to the RKVENC backend
  (`mpp_rewrite.c`, lines 600-606 and 626-630).
- RKVENC sessions are limited to four RCB descriptors
  (`RK_MPP_RKVENC_MAX_RCB_ELEMS`, line 68; `rk_mpp_session_rcb_limit()`,
  lines 1471-1476).
- `rk_mpp_job_store_rcb_info()` stores userspace descriptors into the job and
  session (`mpp_rewrite.c`, lines 5456-5485).
- `rk_mpp_job_apply_rcb_info()` patches registers only if the chosen hardware has
  `hw->rcb_iova` and `hw->rcb_size`; otherwise it returns 0 and the RCB
  descriptors are a no-op (`mpp_rewrite.c`, lines 5639-5678).
- `rk_mpp_execute_jobs()` applies RCB info after fd-to-IOVA translation and
  before submit (`mpp_rewrite.c`, lines 8331-8344).

The important architectural difference from the BSP is
`rk_mpp_hw_alloc_rcb()`:

- It reads `rockchip,rcb-iova`, but if the property is absent it returns 0 and
  does not allocate anything (`mpp_rewrite.c`, lines 8820-8823).
- If present, it uses `vals[1]` as a size and calls `dmam_alloc_coherent()`
  (`mpp_rewrite.c`, lines 8825-8833).
- It does not parse `rockchip,sram` and does not map a fixed SRAM phandle.

The rewrite ABI document says the same thing: `MPP_CMD_SET_RCB_INFO` is supported
for RK3588 RKVENC2/RKVDEC2, descriptors are stored per session, per-core coherent
scratch memory is allocated using the DT `rockchip,rcb-iova` size, registers are
patched after fd translation, and this uses the public DMA API rather than BSP
fixed-IOVA SRAM reservation (`mpp-rewrite/ABI.rst`, lines 220-227).

Therefore, adding `rockchip,rcb-iova` to the rewrite DT would exercise the RCB
register patching path, but it would allocate normal coherent DMA memory. It
would not prove or use on-chip SRAM.

## Userspace MPP evidence

Tree: `../rockchip-conformance/sources/rockchip-mpp` at `c2c1ee502b3a`.

Current userspace does emit encoder RCB descriptors for H.264 VEPU580 by default:

- `mpp/hal/rkenc/h264e/hal_h264e_vepu580.c` declares
  `static RK_U32 disable_rcb_buf = 0;` at line 150.
- The HAL reads the `disable_rcb_buf` environment variable at line 299.
- `setup_vepu580_ext_line_buf()` programs the external line-buffer fd into
  `ebuft_addr` and `ebufb_addr`, updates register offset 182, then sends two
  `MPP_DEV_RCB_INFO` commands if `disable_rcb_buf` is not set
  (`hal_h264e_vepu580.c`, lines 2052-2085):
  - `reg_idx = 183`, `size = offset`
  - `reg_idx = 182`, `size = 0`

The MPP service wrapper stores those descriptors and turns them into the kernel
command:

- `MPP_CMD_SET_RCB_INFO = MPP_CMD_SEND_BASE + 3`
  (`osal/inc/mpp_service.h`, lines 61-65).
- `mpp_service_rcb_info()` records `reg_idx` and `size`
  (`osal/driver/mpp_service.c`, lines 589-606).
- The send path appends `MPP_CMD_SET_RCB_INFO` when `p->rcb_count` is nonzero
  (`osal/driver/mpp_service.c`, lines 459-469).

I found `MPP_DEV_RCB_INFO` users in several H.264 VEPU families and H.265
VEPU510, but in this local tree I did not find a VEPU580 H.265 RCB emission path
matching the H.264 one. So the strongest userspace evidence is H.264 VEPU580.

## Public documentation / online search

Online search on 2026-07-05 did not find a public document confirming an RK3588
RKVENC SRAM RCB assignment or documenting `rockchip,rcb-iova` on RK3588 encoder
nodes.

Public material located during the search was either:

- high-level RK3588 product/spec summary material that confirms H.264/H.265
  encoder capability but does not discuss RCB/SRAM assignment, for example
  <https://rockchips.net/product/rk3588/>; or
- public Rockchip kernel/source references whose RK3588 DT layout matches the
  local 6.1 BSP evidence, for example
  <https://github.com/rockchip-linux/kernel/tree/develop-6.1>.

I did not find a public TRM excerpt, binding document, or vendor note saying that
RK3588 VEPU580 should borrow `vdec0_sram`/`vdec1_sram`, has its own encoder SRAM
slice, or should expose encoder `rockchip,rcb-iova` in DT.

Absence of public documentation is not proof of absence, but the source-tree
evidence is strong negative evidence: two separate RK3588 kernel tracks wire
decoder RCB SRAM and leave encoder RCB unbacked.

## Interpretation

There are three distinct facts that should not be collapsed:

1. The encoder RCB ABI is real. Userspace can send descriptors, and both kernel
   implementations can accept them.
2. The 6.1 BSP has a real fixed-IOVA SRAM mapping path for RKVENC if DT provides
   `rockchip,rcb-iova` and `rockchip,sram`.
3. RK3588 DT in both studied trees does not provide those encoder properties.

So this does not look like a simple forward-port omission. It looks like optional
generic RKVENC RCB support that Rockchip did not enable for RK3588 encoder nodes.

The performance hypothesis is plausible in the abstract: if the hardware can use
fast row-cache scratch, it may help. But there is not enough evidence to enable
real encoder SRAM on RK3588 safely. In particular:

- Adding only `rockchip,rcb-iova` is insufficient for the BSP-style driver; it
  also needs a valid `rockchip,sram` phandle.
- Reusing `vdec0_sram` or `vdec1_sram` for encoder is not justified by the
  current evidence. Those SRAM children are decoder-owned in DT, and the decoder
  actively uses them.
- The rewrite's coherent-scratch path is useful for ABI coverage and possible
  benchmarking, but it is not on-chip SRAM.

## Practical follow-up

The immediate forward-port fix is to keep `rkvenc2_alloc_rcbbuf()` best-effort,
matching the BSP. That should restore RKVENC probe on RK3588 without inventing
encoder SRAM backing.

If we want to evaluate encoder RCB performance, use staged experiments:

1. Rebuild the forward-port with the best-effort probe fix and confirm
   `/proc/mpp_service/supports-device` advertises RKVENC again.
2. Add temporary instrumentation to the RKVENC RCB path:
   - BSP/forward-port: log or count when `rkvenc2_set_rcbbuf()` sees
     `priv->rcb_inf.cnt` and whether `enc->sram_iova` is nonzero.
   - Rewrite: log or count when `rk_mpp_job_store_rcb_info()` stores descriptors
     and when `rk_mpp_job_apply_rcb_info()` patches at least one register.
3. Compare H.264 encode with and without userspace `disable_rcb_buf=1`. On the
   current unbacked RK3588 DT, there should be no kernel-side RCB patching and
   little or no performance delta attributable to RCB.
4. Do not add a real BSP-style encoder `rockchip,sram` until there is TRM/vendor
   evidence for a safe SRAM region and ownership model. If such evidence appears,
   test first with decoder idle, then with concurrent decode/encode, and watch
   for IOMMU faults, hangs, data corruption, and power-domain interactions.
5. A rewrite-only `rockchip,rcb-iova` experiment can be used to validate the ABI
   and register patching path, but document it as coherent DMA scratch, not SRAM.

## Bottom line

For RK3588 today: decoder RCB SRAM is wired and expected; encoder RCB descriptors
exist but are unbacked by SRAM in DT. The forward-port should behave like the
BSP and treat missing encoder RCB backing as optional.
