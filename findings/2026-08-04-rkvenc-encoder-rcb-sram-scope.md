# RK3588 encoder RCB is reachable only by >4096-wide H.264, so the absent encoder SRAM costs almost nothing

> Scope: RK3588 VEPU580 encoder RCB/SRAM path — vendor MPP userspace plus the
> `rk3588-video-6.18` forward port; owning doc is
> [`kernel-drivers/mpp/docs/rcb-sram.md`](../kernel-drivers/mpp/docs/rcb-sram.md)
> Source: `../rock-5b/rockchip-conformance/sources/rockchip-mpp` @ `c2c1ee502b3a`;
> `../rock-5b/kernel/linux-6.18-rkvenc-av1-fwport` branch `rk3588-video-6.18` @
> `7615b69a744af`; `../rock-5b/kernel/rockchip-kernel` `develop-6.1` @
> `b4ef083dc0c3`. Anchors: `hal_h264e_vepu580.c` `setup_vepu580_ext_line_buf()`
> (~:2054) and `setup_vepu580_buffers()` (~:446); `hal_h265e_vepu580.c`;
> `mpp_rkvenc2.c` `rkvenc2_set_rcbbuf()` (~:1112)
> Date: 2026-08-04
> Trust: CODE-INSPECTED, SOURCE-CONFIRMED; the bandwidth-magnitude claim is
> INFERRED — no encoder bandwidth or throughput was measured

## Result

RK3588 has no encoder SRAM in device tree (BSP and forward port alike — see
[`rcb-sram.md`](../kernel-drivers/mpp/docs/rcb-sram.md)). That absence is close to
free, because the encoder RCB path is barely reachable in the first place. Two
independent gates keep it dark:

1. **H.265 never uses it.** `hal_h265e_vepu580.c` contains no ext-line-buffer and
   no `MPP_DEV_RCB_INFO` code at all — only unrelated internal ME-cache fields
   (`reg0222_me_cach.cme_linebuf_w`) and a bus-order bit
   (`reg0012_dtrns_map.ebufw_bus_ordr`, ~:2749). Every HEVC encode on this SoC is
   unaffected by encoder SRAM at any resolution.
2. **H.264 uses it only above 4096 luma width.** `setup_vepu580_buffers()` (~:446)
   allocates `ctx->ext_line_buf` only under `if (aligned_w > SZ_4K)`, where
   `aligned_w = MPP_ALIGN(prep->width, 64)` (~:430). Below that,
   `setup_vepu580_ext_line_buf()` (~:2054) zeroes `ebuft_addr`/`ebufb_addr` and
   returns **before** the two `MPP_DEV_RCB_INFO` ioctls, so no descriptor is sent.

So at 1080p, 1440p, 4K UHD (3840) and DCI 4K (4096) the encoder sends no RCB
descriptors whatsoever and runs on internal line storage; SRAM would sit unused
even if it were wired.

Enumerating every `MPP_DEV_RCB_INFO` sender in the MPP tree confirms the scope.
Encoder senders are `hal_h264e_vepu580.c`, `hal_h264e_vepu510/511/511a.c` and
`hal_h265e_vepu510.c`; of those only the VEPU580 pair registers
`soc_type = { ROCKCHIP_SOC_RK3588 }` (`hal_h264e_vepu580.c` ~:2613,
`hal_h265e_vepu580.c` ~:3531), and only the H.264 one has the RCB code. The
remaining senders are decoder-side (`vdpu34x_com.c`, `vdpu382_com.c`,
`vdpu38x_com.c`).

### What the descriptors would have redirected

The two descriptors name registers 183 (`size = ext_line_buf_size`) and 182
(`size = 0`) — the ext line buffer's two halves. Userspace has already programmed
both with the dma-buf fd of an ION allocation and an offset
(`mpp_dev_multi_offset_update(ctx->offsets, 182, offset)`), which the kernel
translates to a DDR IOVA. With encoder SRAM present, `rkvenc2_set_rcbbuf()`
(~:1112) would overwrite them with `enc->sram_iova + rcb_offset`; with
`enc->sram_iova == 0` the whole loop is skipped and the DDR IOVAs stand. The
encode is correct either way — the buffer simply lives in DDR.

### Size of the thing being missed

`ext_line_buf_size = (aligned_w - 3 * SZ_1K) / 64 * 480`:

| Encode width | Ext line buffer |
|---|---|
| ≤ 4096 | not allocated |
| 7680 | `(7680−3072)/64×480` = **34,560 B** |
| 8192 | `(8192−3072)/64×480` = **38,400 B** |

So the entire cost of absent encoder SRAM is ~34 KB of per-CTU-row line traffic
going to DDR instead of on-chip, on >4096-wide H.264 only — against the
reference and reconstruction traffic of an 8K encode.

### Not a forward-port regression

BSP `develop-6.1` `rk3588s.dtsi` carries `rockchip,sram`/`rockchip,rcb-iova` on
`rkvdec0`/`rkvdec1` only (~:5070, ~:5124); the forward port matches
(`rk3588-rock-5b.dtsi` ~:209, ~:246). Encoder SRAM has never been enabled for
RK3588 in any Rockchip release, so vendor encoder numbers are DDR-backed numbers
and an A/B against a BSP baseline will show parity. There is no SRAM-enabled
configuration to compare against without inventing DT that no TRM evidence
supports.

## Boundary

- **Nothing was measured.** No encode was run, no DDR bandwidth counter read, no
  throughput or power comparison made. The "~34 KB is noise against 8K encode
  traffic" claim is inference from buffer sizes, not a measurement.
- **>4096-wide H.264 encode was not exercised on this board at all** — this
  finding does not establish that it works, only which code path it would take.
- **The internal line-storage capacity is not pinned.** The size formula's 3072
  base and the allocation gate's 4096 disagree; between those widths the formula
  yields a positive size but no buffer is allocated. Rockchip's reasoning is
  unrecorded, so treat 4096 as the empirical gate, not as a hardware limit.
- **JPEG and VP8 encode were checked only through the `MPP_DEV_RCB_INFO` sender
  enumeration**, not read in full.
- **Decoder RCB is unaffected** and is a different story: it *is* SRAM-backed on
  both cores, with pool sizes and window behaviour measured in
  [`2026-07-28-rkvdec2-err23-picsize-oversize-width.md`](2026-07-28-rkvdec2-err23-picsize-oversize-width.md).
- Anchors are from the pinned trees above; sibling trees drift, so re-resolve by
  function name rather than line number.

## Verification gate

If this ever needs hardware confirmation rather than code inspection: enable
`DEBUG_SRAM_INFO` (`mpp_dev_debug` bit `0x200000`, root) and encode. The expected
signals are a single `sram disabled` line and **no** `rcb: reg N offset …, size …`
lines, at any resolution — because with `enc->sram_iova == 0` the descriptor loop
in `rkvenc2_set_rcbbuf()` never runs, regardless of whether descriptors arrived.
Distinguishing "descriptors sent but unused" from "descriptors never sent"
therefore needs userspace-side tracing (or `hal_h264e_debug`), not the kernel bit.

## Why it matters

It closes a standing question about whether the absent encoder SRAM is costing
throughput on this board: for every codec and resolution actually in use here, it
cannot be. It also retires the previous next-step framing in
[`rcb-sram.md`](../kernel-drivers/mpp/docs/rcb-sram.md), which proposed
instrumenting whether `MPP_CMD_SET_RCB_INFO` is received — that instrumentation
would have reported nothing received on any ordinary encode, which reads as a
broken ABI rather than an unreached code path.
