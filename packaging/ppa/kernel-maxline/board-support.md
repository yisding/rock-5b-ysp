# What maxline adds for the ROCK 5B

The short version is that maxline is a **mainline enablement kernel**, not a
newer copy of the working Armbian kernel:

- `maxline-public` starts at the exact upstream `v7.2-rc3` source and adds the
  current public RK3588 proposals that had not landed there.
- `maxline-wip` adds experimental HDMI 2.1 FRL controller support and VDPU381
  VP9 decoding on top of `maxline-public`.
- Neither profile has booted on the ROCK 5B yet. Both compile and package, but
  every hardware result is still unknown.
- Maxline does not carry the private Rockchip MPP and RGA interfaces used by
  this project's hardware-validated 6.18 media kernel.

That last point matters most in practice: maxline contains more *mainline*
RK3588 work, but it is not a drop-in upgrade for the known-working video
encode/decode stack.

## How the comparison is layered

The three reference kernels answer different questions:

| Reference | What it represents here | What maxline adds beyond it |
| --- | --- | --- |
| Armbian 6.18 | The working ROCK 5B distribution and board-integration baseline. This project's combined 6.18 build also has hardware-validated private MPP/RGA support. | Upstream RK3588 work from 6.19 through 7.2, followed by the maxline proposal queue. It does **not** retain the private MPP/RGA userspace contract. |
| Ubuntu 26.04 kernel 7.0 | Ubuntu's default generic kernel generation for 26.04. Ubuntu records that Resolute ships with 7.0 and publishes a generic arm64 build. It is a distribution/version reference here, not a ROCK 5B kernel that this project has boot-tested. | RK3588 changes merged in upstream 7.1 and 7.2, followed by the maxline proposal queue. Ubuntu-specific security, configuration, and packaging changes are not inherited because maxline starts from Torvalds' tree. |
| Upstream `v7.2-rc3` | The exact source base of both maxline profiles. | Only the checked-in maxline deltas described below. |

The Ubuntu references are the [Resolute 7.0 transition
record](https://bugs.launchpad.net/ubuntu/+source/zfs-linux/+bug/2142758) and
the [generic 7.0 arm64 image
package](https://packages.ubuntu.com/resolute-updates/linux-image-7.0.0-27-generic).
Armbian carries its own patch stack, so the version-layer summary below should
not be read as a claim that no individual feature was backported by Armbian.

## What the newer upstream base contributes

These are inherited from upstream and are **not** maxline-authored additions:

- After 6.18, upstream gained more HDMI PHY fixes, high-color-depth support,
  and HDMI CEC support for RK3588.
- Linux 7.0 added the HDMI FRL-capable PHY layer, VOP2 display cleanup, audio
  groundwork needed by DisplayPort, better HDMI-input detection, base
  VDPU381 H.264/H.265 decoding, and several AV1, RKVDEC, and CSI receiver
  fixes. The FRL PHY alone does not provide HDMI 2.1 FRL output; the HDMI
  controller and link-training half is separate.
- Linux 7.1 added Rockchip USB-C/USBDP mux fixes, FUSB302 display hot-plug
  plumbing, more display mode and infoframe support, PCIe diagnostics, and
  fixes for some USB-C DisplayPort adapters.
- Linux 7.2 added basic RGA3, VICAP video capture and MIPI CSI host support,
  the AV1 IOMMU, more RK3588 audio clocks, HDMI-input EDID fixes, and the HDMI
  FRL-enable GPIO descriptions already present in the ROCK 5B device tree.

This upstream layer is why maxline has useful gains over the 6.18 and 7.0
version baselines even before its own patch is applied.

## What `maxline-public` adds beyond upstream 7.2-rc3

The public ledger contains 38 proposal entries. Seven were already in
7.2-rc3 and are recorded only for provenance. The actual delta integrates 31
not-yet-upstream series: 20 applied directly and 11 reconciled where proposals
overlapped or needed porting. Their combined, reviewable tree is 241 commits
above `v7.2-rc3`.

| Area | Code added by maxline | What that means on the ROCK 5B |
| --- | --- | --- |
| Dual HDMI output | HDMI 2.0 SCDC scrambling and high-TMDS operation intended for 4K60, 10-bit YUV422/YUV420, forced color formats, overscan, link-health diagnostics, HDMI PHY clock fixes, and VOP2 multi-output, reset, and YUV-background fixes | The existing two HDMI outputs are described and enabled in the upstream ROCK 5B device tree, so these patches extend a real board path. No mode, cable, monitor, audio, or hot-plug behavior has been hardware-tested with maxline yet. |
| USB-C and DisplayPort | A large USBDP PHY cleanup, better lane/orientation/reinitialization handling, USB3/DP coexistence work, DW DisplayPort runtime power, audio and out-of-band hot-plug support, plus a Type-C AltMode negotiation race fix | The driver and PHY prerequisites compile, but maxline does not change the ROCK 5B device tree. Its FUSB302 Type-C controller remains marked `status = "fail"`, and the board DisplayPort route is not enabled. This is code availability, not working ROCK 5B DP AltMode. |
| Video decode and RGA | VDPU381 H.264/H.265 fixes and multicore scheduling, RGA3 parallel/multicore scheduling, shared scheduler integration, tracepoints, and per-file hardware-use statistics | The RK3588 decoder and RGA blocks are described by the upstream SoC tree and the drivers compile. These are mainline V4L2 and mainline RGA interfaces, not Rockchip's private MPP service or `librga` ABI. |
| NPU | Rocket-driver support for standalone DPU/PPU tasks and pipelined workloads | All three NPU cores are enabled by the upstream ROCK 5B device tree and the enhanced Rocket driver compiles. Workloads have not been run on this build. |
| Camera and ISP | The RKISP2 ISP driver, statistics and parameter paths, a shared RKCIF/VICAP/ISP media graph, and CSI D-PHY tuning up to 2.5 Gbit/s | The patch adds RK3588 ISP nodes, but leaves them disabled. The ROCK 5B tree has no sensor endpoints or board camera pipeline for them, and the needed libcamera pipeline/IPA is separate userspace work. This does not yet produce a usable camera. |
| HDMI input | Audio capture support for the existing Synopsys HDMI receiver | The board already enables HDMI input. Maxline adds the proposed audio side, but neither capture nor interaction with HDMI output has been tested. |
| PCIe and NVMe | System suspend/resume support, WAKE# handling, root-port/slot recovery after a lost link, and Naneng combo-PHY errata fixes | The ROCK 5B PCIe/NVMe ports already exist in its device tree, so this is intended to improve real board paths. Suspend, wake, link recovery, and NVMe integrity remain untested. |
| I2C | SCL debounce and bus-recovery improvements | A robustness improvement for RK3588 I2C buses; compiled but not exercised on the board. |
| Hardware crypto | An RK3588 crypto driver and SoC node | The driver is built as a module, but the new node remains disabled and maxline adds no ROCK 5B override to enable it. |
| CAN-FD | The RK3588 CAN-FD driver and three SoC controller nodes | The driver is built as a module, but all three nodes remain disabled on the ROCK 5B. A usable port would also need correct pins and an external CAN transceiver. |

Neither maxline profile changes `rk3588-rock-5b.dts`,
`rk3588-rock-5b.dtsi`, or the shared ROCK 5B/5B+/5T device-tree file relative
to `v7.2-rc3`. Their board effect comes from improving drivers used by
existing ROCK 5B nodes. New camera, crypto, and CAN nodes are SoC descriptions
left disabled unless a board device tree explicitly wires and enables them.

## What `maxline-wip` adds

The WIP profile is 21 commits above `maxline-public` and adds two experimental
features:

- The HDMI controller half of Fixed Rate Link: SCDC link training, FRL rate
  selection, VOP bandwidth-clock scaling, PHY mode switching, and transmitter
  feed-forward-equalization control. This joins the FRL PHY support already in
  Linux 7.0 and the ROCK 5B enable GPIOs already in 7.2. It does not complete
  the separate HDMI 8K, ARC, or HDCP work.
- A public proof of concept for VP9 decoding on VDPU381, ported onto the
  public profile's multicore decoder model.

Both features are present in the compiled objects. Neither has run on this
board, so WIP means “available for bring-up,” not “supported hardware.”

## What maxline deliberately does not promise

- No boot, storage, network, USB, display, suspend, accelerator, or rollback
  test has passed on a ROCK 5B because neither package has been installed.
- No private `/dev/mpp_service` ABI, `h264_rkmpp`/`hevc_rkmpp` path, Rockchip
  MPP encoder stack, private `/dev/rga` ABI, or `librga` compatibility. Use the
  combined Armbian 6.18 kernel when those validated interfaces are required.
- No complete mainline RK3588 H.264 or H.265 encoder. The VEPU580 work is not
  part of these profiles.
- No HDMI 8K, ARC, or HDCP; no DMC memory-frequency scaling; no IEP2; and no
  unpublished camera, encoder, decoder, or board-enablement work.
- No working claim for DisplayPort AltMode, camera, crypto, or CAN-FD on the
  ROCK 5B merely because their driver code compiled.

## Evidence and recommended use

Both profiles passed `Image modules dtbs`, Debian image/DTB/headers packaging,
and an external-module headers smoke test. That proves source integration and
package construction only.

- Keep the combined Armbian 6.18 kernel for the known-working private
  MPP/RGA media stack and as the rollback kernel.
- Try `maxline-public` first for mainline RK3588 bring-up and validation.
- Try `maxline-wip` only after the public profile is understood, and only when
  testing FRL or VDPU381 VP9.

The exact source identities and build results are in
[`manifest.yaml`](manifest.yaml). Every public input and its disposition is in
[`public-series.tsv`](public-series.tsv); every WIP donor is in
[`wip-donors.tsv`](wip-donors.tsv). The historical technical rationale is in
[`integration-design-record.md`](integration-design-record.md); the measured
build and package evidence is in [`verification.md`](verification.md).
