# Glossary

The vocabulary used across this repo, in one place. Each entry links to the doc
that owns the depth. Entries marked **⚑ load-bearing** are especially important
when comparing the encoder and decoder or reconstructing the Armbian port.

## Hardware blocks & their drivers

- **MPP** — Rockchip *Media Process Platform*: the vendor hardware-codec
  framework (kernel `rk_vcodec.ko` + userspace `librockchip_mpp`), reached via
  `/dev/mpp_service`. **Not** V4L2. Kernel side:
  [kernel driver guide](./kernel-drivers/docs/how-the-drivers-work.md); userspace side:
  [userspace library guide](./vendor-libraries/docs/how-the-userspace-libs-work.md).
- **VEPU580 / `rkvenc2`** — the H.264/H.265 hardware **encoder** block / its
  driver (`mpp/mpp_rkvenc2.c`). Two cores, `fdbd0000`/`fdbe0000`.
- **VDPU381 / `rkvdec2`** — the H.264/H.265/VP9 hardware **decoder** block /
  its driver. Two cores (`fdc38000`/`fdc40000`) plus a real CCU block
  (`fdc30000`). On the combined kernel the cores appear as
  `/proc/mpp_service/video-codec0/1` (the DT keeps mainline's node name —
  [device-tree guide](./kernel-drivers/docs/device-tree.md)); earlier overlay-era revisions named
  them `rkvdec-core0/1`.
- **RGA3 / RGA2** — *Raster Graphic Acceleration*, the 2D engine (scale,
  colour-convert, rotate, blend), via `/dev/rga` (`rga3/` driver → `multi_rga`,
  wrapped by `librga`).
- **RKNPU** — Rockchip's neural-processing hardware family and the BSP kernel
  driver under `drivers/rknpu`. On RK3588 it manages device memory, IOMMU
  mappings, power, and queues for three NPU cores; it launches already-compiled
  register tasks and does not interpret neural graphs. Full stack:
  [RKNPU/RKNN guide](./kernel-drivers/rknpu/docs/how-rknpu-works.md).
- **RKNN** — Rockchip's target-specific compiled neural-network format. An
  `.rknn` contains lowered graph/weight/tensor information and NPU register
  configuration, not merely a portable framework graph.
- **RKNN-Toolkit2 / RKNNLite / RKNN Runtime** — respectively the model
  conversion/analysis Python toolchain, the board-side Python deployment API,
  and the proprietary native `librknnrt.so` that prepares memory and low-level
  RKNPU submissions. [`rknn_server` is an optional connected-debug proxy](./kernel-drivers/rknpu/docs/how-rknpu-works.md#32-toolkit2-connected-debugging),
  not a daemon required by native inference.
- **RKLLM** — Rockchip's separate large-language-model stack
  (`airockchip/rknn-llm`) over the same `drivers/rknpu` driver: a host toolkit
  that converts Hugging Face transformers to the `.rkllm` format (`w8a8`/`w4a16`
  quantization) and the `librkllmrt.so` runtime that streams tokens on the NPU.
  Distinct from RKNN — different format and runtime. Survey:
  [RKLLM stack](./kernel-drivers/rknpu/docs/rkllm-large-language-models.md).
- **IEP** — *Image Enhancement Processor*. Rockchip uses this name for both a
  legacy standalone driver (`/dev/iep`) and the related IEP2 family. The
  `KERNEL=="iep"` udev rule is a harmless no-op on the current board kernel
  because the legacy device is absent; do not use that absence to infer that
  RK3588 lacks IEP2.
- **IEP2** — RK3588's fixed-function image-enhancement/deinterlacing block.
  The BSP binds `rockchip,iep-v2` and exposes it as MPP client 28 through
  `/dev/mpp_service`, not `/dev/iep2`. The current 6.18 forward port omitted
  its driver and DT nodes. Full audit: [RK3588 IEP2 versus VDPP](./kernel-drivers/iep2/docs/rk3588-iep2-vdpp.md).
- **VDPP** — *Video Decoder Post-Processor*, a separate Rockchip hardware
  family and MPP client 29. RK3528/RK3576 have explicit VDPP instances; RK3588
  has no documented or BSP-addressable VDPP block. It is not another name for
  RK3588 IEP2.
- **CCU** — the per-cluster *Central Control Unit* coordination model used to
  pick an idle core and manage shared clocks/IOMMU. **⚑ load-bearing
  disambiguation:** the **decoder's CCU is a real MMIO block** (`@fdc30000`,
  with its own DT node). The encoder has no separate CCU register block: its
  driver-side `rkvenc_ccu` object is virtual/software coordination, while the
  cross-core handshake itself uses **hardware DCHS registers** inside each
  VEPU580 core. See
  [kernel driver guide §7](./kernel-drivers/docs/how-the-drivers-work.md) and
  [device-tree guide](./kernel-drivers/docs/device-tree.md).
- **DCHS** — *dual-core hand-shake*: a hardware TX/RX channel mechanism in the
  encoder cores. Software allocates and links the small channel IDs; hardware
  performs the handshake. See CCU above.
- **mpp_srv** — the shared MPP *service* DT node
  (`compatible = "rockchip,mpp-service"`); virtual, no `reg`; owns
  `/dev/mpp_service`. Every core attaches to it via `rockchip,srv`
  ([device-tree guide](./kernel-drivers/docs/device-tree.md)).

## Kernel machinery

- **dma-buf** — a kernel-shared buffer passed by **fd**, zero-copy, between
  drivers (codec ↔ GPU ↔ display).
- **dma-heap** — `/dev/dma_heap/*`, the userspace DMABUF allocator `rkmpp`
  draws every frame/stream buffer from (the post-ION mainline allocator).
  Granting `mpp_service` without `dma_heap` leaves the encoder dead at init —
  see [gotchas](docs/gotchas.md).
- **IOMMU / MMU / IOVA** — the codec's own address translator: gives a dma-buf
  a device-side address (an *IOVA*) so the hardware can read/write it. Each
  core has its own IOMMU node in the DT. Full walkthrough (concept → RK3588
  hardware → RGA/MPP driver code) in the
  [IOMMU explainer series](kernel-drivers/iommu/docs/01-iommu-primer.md).
- **RCB** — codec scratch buffers for row/column processing. Upstream calls
  these "Rows and Cols Buffers"; vendor shorthand often says row-cache buffers.
  **⚑ load-bearing disambiguation:** the **decoder** backs RCB with on-chip
  **SRAM** (`system_sram2@ff001000`); the **encoder** has optional RCB descriptor
  plumbing, but current RK3588 DT does not wire encoder SRAM backing. See
  [RCB/SRAM primer](./kernel-drivers/mpp/docs/rcb-sram.md) and
  [device-tree guide](./kernel-drivers/docs/device-tree.md).
- **link mode** — the decoder's descriptor-table job chaining: the hardware
  walks a coherent-DMA **linked table of task configs** by itself instead of
  the driver programming registers per task
  (`mpp_rkvdec2_link.c`, [kernel driver guide §8](./kernel-drivers/docs/how-the-drivers-work.md)).
  **Not to be confused with RCB** — both are decoder throughput features and
  both live near `mpp_rkvdec2_link.c`, but RCB is *scratch memory placement*
  and link mode is *job submission batching*; they are independent.
- **taskqueue / core-mask** — a cluster's work queue / the DT bitmask naming
  its cores. Both cores of a cluster share one `rockchip,taskqueue-node` index
  ([device-tree guide](./kernel-drivers/docs/device-tree.md)).
- **DVFS / OPP / PVTM / devfreq** — dynamic voltage-&-frequency scaling and
  its kernel machinery (OPP = one voltage/frequency operating point; PVTM =
  Rockchip's on-chip process/voltage/temperature monitor; devfreq = the Linux
  dynamic-frequency framework). **Off in this port** — the cores run at the
  fixed DT `assigned-clock-rates` (~800 MHz); see
  [kernel status](./kernel-drivers/docs/forward-port-status.md) § Skipped.
- **power-domain (PD)** — an SoC power island that must be on for a block to
  run.
- **V4L2** — mainline *Video4Linux2*, the codec API this port deliberately
  does **not** use for its shipped path (mainline `hantro`/`rkvdec` lack H.265
  encode; see [vanilla-kernel guide](./kernel-versions/docs/vanilla-kernel.md)).
  The mainline V4L2 `rkvdec` decoder itself (the upstream trajectory, and the
  `rk3588-rewrite-mainline` branch) is documented in
  [mainline V4L2 rkvdec guide](./kernel-versions/docs/mainline-rkvdec-v4l2.md).
- **mem2mem** — the V4L2 *memory-to-memory* framework
  (`drivers/media/v4l2-core/v4l2-mem2mem.c`) that mainline codec drivers build
  on: a **single-execution-unit** job scheduler (one `curr_ctx` per device).
  Why RK3588 multi-core decode is hard lives in
  [multicore scheduling](./kernel-drivers/mpp/docs/multicore-scheduling.md).
- **Request API** — the Media Request API (`MEDIA_IOC_REQUEST_ALLOC`,
  `MEDIA_REQUEST_IOC_QUEUE`) that the mainline **stateless** decoder uses to
  submit one frame's bitstream buffer **plus** its per-frame codec controls
  atomically. See [mainline V4L2 rkvdec guide § 3](./kernel-versions/docs/mainline-rkvdec-v4l2.md).
- **DPB** — *Decoded Picture Buffer*: the set of already-decoded frames kept as
  motion-compensation references. In the mainline **stateless** model userspace
  owns the DPB and passes it per-frame as a control array; the driver resolves
  each reference to a CAPTURE buffer **by timestamp** (`vb2_find_buffer`). This
  per-stream dependency is what forbids parallelizing one stream across cores —
  see [multicore scheduling § 3](./kernel-drivers/mpp/docs/multicore-scheduling.md).
- **soft / hard CCU** — the decoder CCU's two task-distribution modes
  (`RKVDEC2_CCU_TASK_SOFT`/`_HARD`, DT `rockchip,ccu-mode`): **soft** = the
  driver picks the core (software dispatch, the shipped default); **hard** = the
  CCU hardware autonomously dispatches from a task table. The V4L2-model
  consequences of each are analysed in
  [multicore scheduling § 7](./kernel-drivers/mpp/docs/multicore-scheduling.md); the
  vendor-side mechanism is [kernel driver guide § 7a](./kernel-drivers/docs/how-the-drivers-work.md).

## Boot firmware

- **BootROM** — immutable RK3588 code that chooses a ROM-supported firmware
  source and starts the earliest external image.
- **TPL / DDR blob** — the earliest DRAM-initialization role. The examined
  RK3588 builds use executable Rockchip DDR firmware where an upstream build
  supplies the external input as `ROCKCHIP_TPL`.
- **SPL** — U-Boot's size-constrained secondary program loader; it initializes
  enough hardware to load TF-A and U-Boot proper.
- **TF-A / BL31 / BL33** — Trusted Firmware-A provides the EL3 BL31 runtime;
  it transfers to the normal-world BL33 payload, U-Boot proper here. BL32 is an
  optional trusted-world payload such as OP-TEE.
- **U-Boot proper** — the full firmware program with driver model, environment,
  command shell, OS discovery, payload loading, and Linux handoff.
- **boot source / OS target** — **⚑ load-bearing:** the firmware medium and the
  Linux medium are independent. `SPI → NVMe` means BootROM/SPL/U-Boot came from
  SPI and U-Boot loaded Linux/root from NVMe.
- **control DTB / kernel DTB** — **⚑ load-bearing:** U-Boot's own device tree
  runs firmware drivers; a separate kernel device tree is later passed to
  Linux. An empty control DTB can stop BL33 before Linux is involved.
- **`idbloader.img`** — Rockchip ID-block artifact; in the inspected vendor
  path it combines the DDR binary and U-Boot SPL.
- **FIT / `u-boot.itb`** — Flattened Image Tree containing U-Boot proper, BL31
  segments, the U-Boot control DTB, hashes, and a configuration.
- **binman** — upstream U-Boot's image assembler, used to place stages, FITs,
  external blobs, offsets, and padding into final Rockchip images.
- **environment** — U-Boot key/value settings and scripts, either compiled-only
  or persisted through a selected storage backend.
- **distro boot / Bootstd** — the legacy environment-script OS scan versus
  upstream's Standard Boot driver model (`bootdev` + `bootmeth` → `bootflow`).
- **secure boot** — an enforced authentication chain rooted in trusted state;
  enabled hashes/RSA code or a signature node without a signature value is not
  sufficient proof.

Full definitions and diagrams: [`boot-firmware/`](boot-firmware/README.md).

## Device tree & packaging

- **Armbian** — a Debian/Ubuntu-based Linux distribution and build framework for
  ARM single-board computers; the ROCK 5B image and kernel used here are built
  from its tree (`github.com/armbian/build`), which is why the port ships as
  *userpatches* against Armbian rather than as a from-scratch kernel. On-ramp:
  [`install.md`](install.md).
- **convert-in-place** — **⚑ load-bearing:** the packaging trick of *retyping*
  Armbian's existing V4L2 decoder DT nodes (`vdec0`/`vdec1` from `media-0001`)
  to the vendor binding **where they sit**, instead of adding or replacing
  nodes — this is what makes the port zero-edit on Armbian's own files. See
  [Armbian packaging guide](./packaging/docs/armbian-packaging.md).
- **media-0001** — Armbian's backport patch
  (`media-0001-Add-rkvdec-Support-v5.patch`) that adds the V4L2 `vdec` DT
  nodes this port collides with (and then converts in place).
  DT patch 02 assumes it is present ([`kernel-drivers/patches/README.md`](./kernel-drivers/patches/README.md)).
- **combined kernel** — delivery term (a): an Armbian kernel with all three
  accelerator drivers **built in (`=y`)** via the two
  [`kernel-drivers/patches/`](./kernel-drivers/patches/README.md) userpatches; built/installed/validated by
  [`kernel-drivers/scripts/`](./kernel-drivers/scripts/README.md). The hardware-validated path.
- **DKMS** — delivery term (b): the same driver source built **out-of-tree**
  as `rk_vcodec.ko` + `rga3.ko` on a *stock* kernel, rebuilt on every kernel
  update, plus a boot-time DT overlay
  ([`packaging/dkms/`](packaging/dkms/README.md)). **Mutually exclusive with
  the combined kernel** — on a `=y` kernel the DKMS build fails modpost with
  `'…' exported twice`. Chooser: [`install.md`](install.md).
- **userpatches** — Armbian's mechanism for user-supplied kernel patches
  (`userpatches/kernel/archive/<branch>/`), applied automatically with zero
  edits to Armbian's own files ([Armbian packaging guide](./packaging/docs/armbian-packaging.md)).
- **PHASH / `P####-C####`** — the hash pair Armbian bakes into kernel deb
  names: `P####` hashes the **applied kernel patch set**, `C####` the **kernel
  config** — so the pair names an *exact* build.
  `kernel-drivers/scripts/install-combined-kernel.sh` pins on it; the validated build is
  `Pb6ab-Cb831`; the hash↔patch-revision log lives in
  [`install.md`](install.md).

## Graphics side (GRD / Mesa)

- **Panfrost / panvk** — Mesa's open-source OpenGL(ES) / Vulkan drivers for
  Mali GPUs (here the Mali-G610). The GRD backend does RGB→NV12 on panvk;
  the transfer/precision work is [`video-libraries/mesa/`](video-libraries/mesa).
- **AFBC** — *Arm FrameBuffer Compression*, "a lossless compression scheme
  natively implemented in Mali GPUs" (Mesa
  `src/panfrost/lib/pan_afbc.h:22`) used for surfaces/textures. Compute
  shaders **cannot write AFBC destinations**, which is why the COMPUTE-only
  texture-transfer direction was rejected in Mesa review (2026-07-01) — see
  [`video-libraries/mesa/docs/blit-precision.md`](./video-libraries/mesa/docs/blit-precision.md)
  § The AFBC Constraint.
