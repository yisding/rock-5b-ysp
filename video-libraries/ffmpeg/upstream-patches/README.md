# FFmpeg upstream candidate patches

This directory contains patches prepared directly against vanilla FFmpeg.
It is separate from [`../patches/`](../patches/README.md), whose 28-patch
series targets the rebased `ffmpeg-rockchip` implementation.

## RKMPP constant-QP support

[`0001-avcodec-rkmppenc-add-constant-QP-rate-control.patch`](0001-avcodec-rkmppenc-add-constant-QP-rate-control.patch)
adds fixed-QP rate control to upstream's independent H.264/HEVC RKMPP
encoder. It exposes:

- `rc=auto|vbr|cbr|cqp|avbr`;
- `qp=-1..51` as the canonical constant-quantizer option; and
- `qp_init=-1..51` as a compatibility alias for callers written for
  `ffmpeg-rockchip`.

With the default `rc=auto`, setting either QP option selects MPP's FIXQP
mode. With no QP option, `auto` resolves to VBR, preserving the encoder's
previous effective default. An explicit non-CQP rate-control mode takes
precedence over QP. Explicit `rc=cqp` uses QP 26 when neither QP option is
set.

The patch pins `rc:qp_init`, both inter-frame bounds, both intra-frame
bounds, and `rc:qp_ip` so the requested value applies to the whole stream.
Bitrate configuration is skipped in CQP mode.

## Provenance and validation

| Field | Value |
|---|---|
| Upstream base | `FFmpeg/master@ccc57378b37d9129396a037df02c83a877d8eef0` |
| Local topic commit | `eaadedce43db` (`rkmpp-cqp`) |
| Source file | `libavcodec/rkmppenc.c` |
| MPP used for compilation | system `rockchip_mpp` 1.3.10 |
| Compile result | `libavcodec/rkmppenc.o` and a minimal `ffmpeg` binary pass |
| Source checks | `make fate-source` passes |
| Option discovery | both encoders advertise `rc=auto/cqp`, `qp`, and `qp_init` |
| Hardware status | pending; this build host has no `/dev/mpp_service` |

The native build used the required system toolchain path:

```sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin
```

Apply the patch to its recorded base or a compatible newer FFmpeg checkout:

```sh
git am /path/to/0001-avcodec-rkmppenc-add-constant-QP-rate-control.patch
```

The hardware gate should cover H.264 and HEVC at several QP values, confirm
that `qp_init=22` selects FIXQP without an explicit `rc`, and recheck the
unchanged VBR, CBR, and AVBR paths.
