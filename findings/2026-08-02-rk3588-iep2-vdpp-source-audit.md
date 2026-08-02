# RK3588 exposes IEP2 deinterlacing, not VDPP, and the YSP 6.18 port omits IEP2

> Scope: RK3588/ROCK 5B post-processing hardware identity, Rockchip BSP
> kernel/DT and libmpp integration, current YSP 6.18 exposure, code-size
> accounting, and forward-port scale.
>
> Source: RK3588 TRM Part 2 Rev 1.0; Rockchip BSP kernel
> `develop-6.1@b4ef083dc0c3608e744deabb43dc6b781aadbe6e`; maintained forward-port
> `rk3588-video-6.18@5b87d46eefdcbb276f1e15dd199deb6ea6b12893`; libmpp
> `ysp/main@ad32534571564aae2ee5cca26547c3738e3366ed`; extracted ROCK 5B BSP DT;
> installed `librockchip_mpp.so.1`; running MPP supported-device inventory and
> ysp8 interlaced-decode logs.
>
> Date: 2026-08-02
>
> Trust: **CODE-INSPECTED** and **SOURCE-CORROBORATED** (hardware identity and
> BSP flow) / **MEASURED** (installed symbols, running device inventory, and
> failed vproc probe) / **INFERRED** (engineering estimates) / **PARTIAL** (no
> IEP2 job or deinterlaced output has run on the forward-port kernel).

## Result

RK3588 has an IEP2 block and the ROCK 5B BSP DT enables it. The BSP binds
`rockchip,iep-v2` at `fdbb0000` with a paired IOMMU and registers it as MPP
client type 28 through `/dev/mpp_service`. libmpp's default vproc build contains
the matching IEP2 consumer.

No inspected RK3588 source layer contains a VDPP instance: there is no TRM
chapter/name, SoC DT node, clock/reset ID, kernel compatible, or libmpp VDPP
SoC selection for RK3588. RK3528 and RK3576 explicitly instantiate both IEP and
VDPP, proving they are distinct blocks. The precise conclusion is therefore
“no documented or BSP-addressable VDPP on RK3588,” not merely “VDPP is disabled
in the ROCK 5B board DTS.”

The current 6.18 forward port omitted `mpp_iep2.c`, its register header, and the
RK3588 IEP2 DT/IOMMU nodes. The running MPP service advertises only AV1DEC,
RKVDEC, and RKVENC—not client 28 or 29.

## Runtime warning correction

The `cmd 100 ret -22` warning observed on the interlaced H.264 ysp8 test is an
IEP2 probe, not VDPP. The log identifies command `0x100` but does not print the
client. Matching libmpp source, build defaults, and installed symbols establish
the chain:

1. an interlaced decoder frame triggers `mpp_dec_vproc`;
2. `get_iep_ctx()` selects the IEP2 allocator because `/dev/mpp_service`
   exists;
3. `iep2_init()` requests MPP client type 28;
4. the partial kernel has no subdevice 28 and returns `EINVAL`; and
5. libmpp disables deinterlacing and continues decoding.

The decoded clip being bit-exact proves decode fallback, not hardware
deinterlacing. The immediate noise fix belongs in libmpp capability selection;
actual deinterlacing requires the IEP2 kernel/DT port.

## Code-size result

Raw physical-line counts distinguish the misleading comparisons:

| Layer | IEP2 | VDPP |
|---|---:|---:|
| BSP kernel implementation | 1,350 (`mpp_iep2.c` 1,166 + register header 184) | 828 (`mpp_vdpp.c`) |
| libmpp implementation directory, top-level non-test `.c`/`.h` | 1,638 | 10,484 |

IEP2 is not smaller in the kernel. VDPP is much larger in userspace because it
contains three hardware generations, extensive register/tuning definitions,
and a broad scale/quality pipeline. IEP2 sends semantic deinterlace parameters
and lets the kernel construct registers; VDPP userspace constructs
generation-specific register images for the kernel to submit.

## Forward-port inference

The minimum vendor-ABI import is roughly 1,350 driver/register lines plus
Kconfig/Makefile and RK3588 DT/IOMMU wiring. The existing MPP service already
retains the IEP2 enum and registration scaffolding, and installed libmpp already
has the consumer. A planning estimate is 1–3 engineering days to compile/bind,
2–5 days total to first deinterlaced output, and about 1–2 weeks for recovery,
buffer-lifetime, format/mode, field-order, and soak validation. A clean
upstream-style V4L2 design is a different, several-week project.

## Promotion

The maintained explanation, reproduction notes, and completion gate now live
in [kernel-drivers/iep2](../kernel-drivers/iep2/README.md).
