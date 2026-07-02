# Glossary

The vocabulary used across this repo, in one place. Each entry links to the doc
that owns the depth. Three entries are load-bearing enough that the root
[`README.md`](README.md) keeps them inline as well (marked **⚑ load-bearing**):
the CCU-vs-DCHS split, RCB SRAM-vs-DRAM, and convert-in-place.

## Hardware blocks & their drivers

- **MPP** — Rockchip *Media Process Platform*: the vendor hardware-codec
  framework (kernel `rk_vcodec.ko` + userspace `librockchip_mpp`), reached via
  `/dev/mpp_service`. **Not** V4L2. Kernel side:
  [`docs/01`](docs/01-how-the-drivers-work.md); userspace side:
  [`docs/02`](docs/02-how-the-userspace-libs-work.md).
- **VEPU580 / `rkvenc2`** — the H.264/H.265 hardware **encoder** block / its
  driver (`mpp/mpp_rkvenc2.c`). Two cores, `fdbd0000`/`fdbe0000`.
- **VDPU381 / `rkvdec2`** — the H.264/H.265/VP9 hardware **decoder** block /
  its driver. Two cores (`fdc38000`/`fdc40000`) plus a real CCU block
  (`fdc30000`). On the combined kernel the cores appear as
  `/proc/mpp_service/video-codec0/1` (the DT keeps mainline's node name —
  [`docs/07`](docs/07-device-tree.md)); earlier overlay-era revisions named
  them `rkvdec-core0/1`.
- **RGA3 / RGA2** — *Raster Graphic Acceleration*, the 2D engine (scale,
  colour-convert, rotate, blend), via `/dev/rga` (`rga3/` driver → `multi_rga`,
  wrapped by `librga`).
- **IEP** — *Image Enhancement Processor*, the BSP's video post-processing
  block (expansion verified in Rockchip's own libmpp source:
  `mpp/vproc/iep{,2}/CMakeLists.txt` — "Image Enhancement Processor").
  **This port does not include an IEP driver and `/dev/iep` does not exist on
  the board** (verified 2026-07-01, kernel `6.18.37-current-rockchip64` #7).
  The `KERNEL=="iep"` line in the udev rule is a harmless forward-compat no-op
  for BSP/vendor kernels — see
  [`packaging/codec-udev/README.md`](packaging/codec-udev/README.md).
- **CCU** — the per-cluster *core coordination unit* that picks an idle core
  and shares clocks/IOMMU across a codec cluster. **⚑ load-bearing
  disambiguation:** the **decoder's CCU is a real MMIO block** (`@fdc30000`,
  with its own DT node); the **encoder's is software-only** — no registers,
  implemented as **DCHS** (below). See
  [`docs/01` §7](docs/01-how-the-drivers-work.md) and
  [`docs/07`](docs/07-device-tree.md).
- **DCHS** — *dual-core hand-shake*: the encoder's software-only equivalent of
  the decoder's hardware CCU. See CCU above.
- **mpp_srv** — the shared MPP *service* DT node
  (`compatible = "rockchip,mpp-service"`); virtual, no `reg`; owns
  `/dev/mpp_service`. Every core attaches to it via `rockchip,srv`
  ([`docs/07`](docs/07-device-tree.md)).

## Kernel machinery

- **dma-buf** — a kernel-shared buffer passed by **fd**, zero-copy, between
  drivers (codec ↔ GPU ↔ display).
- **dma-heap** — `/dev/dma_heap/*`, the userspace DMABUF allocator `rkmpp`
  draws every frame/stream buffer from (the post-ION mainline allocator).
  Granting `mpp_service` without `dma_heap` leaves the encoder dead at init —
  see [`docs/10`](docs/10-gotchas.md).
- **IOMMU / MMU / IOVA** — the codec's own address translator: gives a dma-buf
  a device-side address (an *IOVA*) so the hardware can read/write it. Each
  core has its own IOMMU node in the DT.
- **RCB** — *Row Cache Buffer*, per-row scratch the codec keeps in fast
  memory. **⚑ load-bearing disambiguation:** the **decoder** backs RCB with
  on-chip **SRAM** (`system_sram2@ff001000`); the **encoder** row-caches from
  **DRAM** (no SRAM slice). See [`docs/07`](docs/07-device-tree.md).
- **link mode** — the decoder's descriptor-table job chaining: the hardware
  walks a coherent-DMA **linked table of task configs** by itself instead of
  the driver programming registers per task
  (`mpp_rkvdec2_link.c`, [`docs/01` §8](docs/01-how-the-drivers-work.md)).
  **Not to be confused with RCB** — both are decoder throughput features and
  both live near `mpp_rkvdec2_link.c`, but RCB is *scratch memory placement*
  and link mode is *job submission batching*; they are independent.
- **taskqueue / core-mask** — a cluster's work queue / the DT bitmask naming
  its cores. Both cores of a cluster share one `rockchip,taskqueue-node` index
  ([`docs/07`](docs/07-device-tree.md)).
- **DVFS / OPP / PVTM / devfreq** — dynamic voltage-&-frequency scaling and
  its kernel machinery (OPP = one voltage/frequency operating point; PVTM =
  Rockchip's on-chip process/voltage/temperature monitor; devfreq = the Linux
  dynamic-frequency framework). **Off in this port** — the cores run at the
  fixed DT `assigned-clock-rates` (~800 MHz); see
  [`docs/04`](docs/04-status.md) § Skipped.
- **power-domain (PD)** — an SoC power island that must be on for a block to
  run.
- **V4L2** — mainline *Video4Linux2*, the codec API this port deliberately
  does **not** use (mainline `hantro`/`rkvdec` lack H.265 encode; see
  [`docs/09`](docs/09-vanilla-kernel.md)).

## Device tree & packaging

- **convert-in-place** — **⚑ load-bearing:** the packaging trick of *retyping*
  Armbian's existing V4L2 decoder DT nodes (`vdec0`/`vdec1` from `media-0001`)
  to the vendor binding **where they sit**, instead of adding or replacing
  nodes — this is what makes the port zero-edit on Armbian's own files. See
  [`docs/08`](docs/08-armbian-packaging.md).
- **media-0001** — Armbian's backport patch
  (`media-0001-Add-rkvdec-Support-v5.patch`) that adds the V4L2 `vdec` DT
  nodes this port collides with (and then converts in place).
  DT patch 02 assumes it is present ([`patches/README.md`](patches/README.md)).
- **combined kernel** — delivery term (a): an Armbian kernel with all three
  accelerator drivers **built in (`=y`)** via the two
  [`patches/`](patches/README.md) userpatches; built/installed/validated by
  [`scripts/`](scripts/README.md). The hardware-validated path.
- **DKMS** — delivery term (b): the same driver source built **out-of-tree**
  as `rk_vcodec.ko` + `rga3.ko` on a *stock* kernel, rebuilt on every kernel
  update, plus a boot-time DT overlay
  ([`packaging/dkms/`](packaging/dkms/README.md)). **Mutually exclusive with
  the combined kernel** — on a `=y` kernel the DKMS build fails modpost with
  `'…' exported twice`. Chooser: [`INSTALL.md`](INSTALL.md).
- **userpatches** — Armbian's mechanism for user-supplied kernel patches
  (`userpatches/kernel/archive/<branch>/`), applied automatically with zero
  edits to Armbian's own files ([`docs/08`](docs/08-armbian-packaging.md)).
- **PHASH / `P####-C####`** — the hash pair Armbian bakes into kernel deb
  names: `P####` hashes the **applied kernel patch set**, `C####` the **kernel
  config** — so the pair names an *exact* build.
  `scripts/install-combined-kernel.sh` pins on it; the validated build is
  `Pb6ab-Cb831`; the hash↔patch-revision log lives in
  [`INSTALL.md`](INSTALL.md).

## Graphics side (GRD / Mesa)

- **Panfrost / panvk** — Mesa's open-source OpenGL(ES) / Vulkan drivers for
  Mali GPUs (here the Mali-G610). The GRD backend does RGB→NV12 on panvk;
  the transfer/precision work is [`mesa-panfrost-g610/`](mesa-panfrost-g610/).
- **AFBC** — *Arm FrameBuffer Compression*, "a lossless compression scheme
  natively implemented in Mali GPUs" (Mesa
  `src/panfrost/lib/pan_afbc.h:22`) used for surfaces/textures. Compute
  shaders **cannot write AFBC destinations**, which is why the COMPUTE-only
  texture-transfer direction was rejected in Mesa review (2026-07-01) — see
  [`mesa-panfrost-g610/blit-precision.md`](mesa-panfrost-g610/blit-precision.md)
  § The AFBC Constraint.
