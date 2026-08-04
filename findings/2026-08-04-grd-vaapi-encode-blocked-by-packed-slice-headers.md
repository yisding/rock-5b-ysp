# GRD has a native VA-API encoder and does not need FFmpeg — but it demands packed slice headers, which MPP cannot serve

> Scope: apps/gnome-remote-desktop and C15 hardware codecs; why the GRD hardware
> encode path goes through FFmpeg rather than the VA-API backend GRD already
> ships, and whether `rockchip-vaapi` could serve it directly. Also the current
> GRD gap inventory and two pieces of record drift.
> Source: installed `gnome-remote-desktop
> 50.2+rkmpp+git20260729.15.c4ef3c9-0ubuntu1~rk2` (2026-08-02 14:54) and
> `/usr/libexec/gnome-remote-desktop-daemon`; GRD source worktree
> `~/Code/rock-5b/gnome/grd/grd-upstream-20260729` at
> `fix/forced-idr-recovery@100da72` on released `c4ef3c9` —
> `src/grd-hwaccel-vaapi.c` (~:105-275), `src/grd-encode-session-vaapi.c`
> (~:560-600, ~:627, ~:732, ~:968, ~:1075-1095);
> `/usr/include/rockchip/rk_mpi_cmd.h` (~:134, ~:136, ~:179),
> `/usr/include/rockchip/rk_venc_cmd.h` (~:580-583);
> `rockchip-vaapi` `main@184d7d4` — `src/rockchip_drv_video.c`
> `rk_GetConfigAttributes()` (~:229-231) and `rk_CreateConfig()` (~:335);
> `/etc/environment.d/61-rockchip-vaapi.conf`; booted
> `6.18.42-ysp-rockchip64`.
> Date: 2026-08-04
> Trust: **SOURCE-INSPECTED** (GRD backend contract, MPP command surface,
> driver attributes) + **MEASURED** (installed package and binary symbol
> inspection, environment contract) + **INFERRED** (the slice-splice
> infeasibility argument is reasoned from H.264 entropy-coding structure and the
> absence of an MPP API, not from an attempted implementation)

## Result

**GRD does not need FFmpeg for hardware encode.** It ships a native VA-API
backend — `grd-hwaccel-vaapi.c` and `grd-encode-session-vaapi.c` — alongside the
NVIDIA, Vulkan and FFmpeg ones. The chain could be
`GRD -> VA-API -> rockchip-vaapi -> libmpp` instead of today's
`GRD -> FFmpeg -> h264_rkmpp -> libmpp`.

The plumbing is already in place. GRD opens a DRM render node and builds a
`VADisplay` from it; `/etc/environment.d/61-rockchip-vaapi.conf` sets
`LIBVA_DRIVER_NAME=rockchip`, so opening `/dev/dri/renderD128` (Panfrost) still
binds our driver, which is correct because `rockchip-vaapi` reaches the codec
through `/dev/mpp_service` rather than the DRM fd.

**One requirement blocks it, and it is not satisfiable over MPP.**

## What GRD requires, against what the driver advertises

`grd-hwaccel-vaapi.c` probes `VAProfileH264High` and rejects the device unless
every one of these holds:

| Requirement | `rockchip-vaapi` | |
|---|---|---|
| `VAProfileH264High` + an AVC encode entrypoint | yes, behind `RK_VAAPI_EXPERIMENTAL_ENCODE=h264` | ok |
| `VA_RT_FORMAT_YUV420` | yes | ok |
| `VA_RC_CQP` | yes (CQP/CBR/VBR) | ok |
| `VAConfigAttribEncMaxRefFrames` >= 1 | 1 | ok |
| `VAConfigAttribEncPackedHeaders` with **SEQUENCE, PICTURE, SLICE and RAW_DATA** | `VA_ENC_PACKED_HEADER_NONE` | **blocks** |

The failure is explicit and total — *"Unsuitable device, device does not support
required packed headers"* — raised at probe, before any session exists. All four
bits are required together.

**This is the previously unrecorded reason the GRD path uses FFmpeg.** No
document in this repo stated it; it had to be rediscovered by reading the
backend. `h264_rkmpp` works precisely because it lets MPP own the entire
bitstream, which is the shape MPP supports.

## Why packed headers cannot be implemented over MPP

GRD does not merely prepend SPS/PPS. `grd-encode-session-vaapi.c` emits all four
header types per frame, and the slice one is unconditional:

```c
header_data = grd_nal_writer_get_slice_header_bitstream (nal_writer, &slice_param,
                                                         &sequence_param,
                                                         &picture_param,
                                                         &header_length);
create_packed_header_buffers (…, VAEncPackedHeaderSlice, header_data, header_length, …);
```

GRD is driving the low-level VA-API encode model in which the **application owns
the entire NAL layer** and the hardware contributes only entropy-coded slice
payload.

MPP's entire header control surface is two commands: `MPP_ENC_SET_HEADER_MODE`
(`MPP_ENC_HEADER_MODE_DEFAULT` or `_EACH_IDR`, i.e. whether SPS/PPS accompany
each IDR) and `MPP_ENC_GET_HDR_SYNC` (retrieve them). Nothing accepts an
externally-authored header. So:

| VA packed header | Feasible over MPP | Why |
|---|---|---|
| `RawData` (SEI/AUD) | **yes** | arbitrary bytes, prepend to the stream |
| `Sequence` (SPS) | plausible | suppress MPP's via header mode, emit the app's |
| `Picture` (PPS) | plausible | same |
| `Slice` | **no** | see below |

MPP emits a complete slice NAL — its own slice header immediately followed by
entropy-coded data — as one inseparable unit. Honouring an external slice header
would require splicing, and that fails twice over:

- **Bit alignment.** Slice payload is not byte-aligned to the slice header. A
  substituted header of different length shifts every subsequent bit, so the
  whole entropy-coded payload would need bit-level re-alignment.
- **Semantics.** The slice header carries fields that must describe what the
  hardware actually did — `first_mb_in_slice`, `slice_qp_delta`, reference list
  modifications. Bytes that disagree yield a stream that parses and decodes to
  the wrong picture.

That second failure mode is exactly what this driver's bitstream-reconstruction
design exists to prevent, stated in its own README: ignored syntax or an
underspecified header can produce a stream that parses while decoding the wrong
picture.

**Advertising all four bits and honouring three is therefore not an option.**
GRD's probe checks them together, so partial support would pass the probe, GRD
would attach, and the driver would silently discard slice headers while emitting
its own — producing intermittently wrong video rather than a clean refusal. The
roadmap's "no silent failure — every unsupported input returns a real
`VAStatus`" rule forbids it, and the symptom would be miserable to diagnose.

## A correction to the same day's capability triage

The [capability-gap triage](2026-08-04-rockchip-vaapi-capability-gap-triage.md)
assessed packed headers as "implementable and genuinely ours, but with no
current consumer" and recommended deferring until an app demanded them. **Both
halves were wrong**, in opposite directions:

- there **is** a consumer, and it is the GRD hardware encode path; and
- they are **not** implementable over MPP as that consumer requires.

The `rockchip-vaapi` README carried the same "no current consumer" claim and is
corrected alongside this finding.

## Options, none of which is a small local change

1. **Implement `RawData` + `Sequence` + `Picture` only**, advertising exactly
   those three bits. Honest, and it may serve other VA clients — but GRD still
   refuses, so it should not be started without first identifying a client it
   actually unblocks.
2. **Stay on FFmpeg.** `h264_rkmpp` matches MPP's whole-bitstream shape. This is
   the status quo and it works; the cost is the FFmpeg dependency and its own
   failure modes.
3. **Patch GRD** to make the packed-slice-header requirement conditional and use
   MPP's slice headers. This is the only route that reaches GRD-over-VA-API on
   this hardware, and it is an upstream conversation rather than a local hack.
4. **Direct `/dev/mpp_service` encode backend inside GRD**, bypassing both. Large
   and duplicates what `h264_rkmpp` already does.

## GRD gap inventory as of 2026-08-04

| # | Gap | State |
|---|---|---|
| 1 | Idle-reconnect replay | Both preconditions now met; **blocked on root-only RDP credentials** |
| 2 | exp6/exp7 focus/resume | Blocked on the same |
| 3 | Compressed-audio interop | Blocked on the same |
| 4 | Watchdog / forced-IDR / VBR ceiling | Built and verified present in `fix/forced-idr-recovery@100da72`; **absent from the installed binary**, never executed |
| 5 | Transport-congestion re-measure | Depends on 4 — nothing new to measure until it ships |
| 6 | FFmpeg `c9428bedaa` + fallback/recreation gate | No built candidate exists; needs a full package build |
| 7 | Upstream submission of the reconnect fix | Gated on 1 |

## Record drift corrected

- **GRD was already installed.** `~rk2` went on at 2026-08-02 14:54 with the
  system daemon enabled and listening on 3389, while status track 7 and both
  halves of W10 — dated the same day — still said installation remained. The
  reconnect gate's stated blockers were in fact already clear: the booted
  `6.18.42-ysp-rockchip64` sets neither `CONFIG_DMABUF_DEBUG` nor
  `CONFIG_KASAN`.
- **The encoder-recovery work is unshipped.** The installed daemon contains none
  of the strings `Rate control`, `ceiling` or `watchdog`; the build from
  `100da72` contains all three (1, 3 and 5 occurrences). Since `100da72` sits
  directly on the released `c4ef3c9`, it is a clean single-commit test article.

## Boundary

- **No RDP session was established.** Nothing here is a runtime result for GRD:
  the VA-API backend was never exercised against `rockchip-vaapi`, because the
  probe rejects the device before a session exists. The rejection is read from
  source, not observed.
- **The splice infeasibility is reasoned, not attempted.** No implementation was
  written and failed. The argument rests on H.264 entropy-coding structure and on
  the absence of any MPP command accepting an external header — established by
  inspecting the installed public headers, which would not reveal an
  undocumented private interface.
- **Only H.264 was considered.** GRD's VA-API backend probes `VAProfileH264High`
  only; nothing here examines HEVC, and the driver's HEVC encode has the same
  `VA_ENC_PACKED_HEADER_NONE` posture.
- **Option 3 is unscoped.** Whether GRD can use MPP-authored slice headers
  without breaking its RDPGFX AVC420/AVC444 framing was not investigated, and
  that is the question deciding whether option 3 is viable at all.

## Verification gate

1. Before any work on option 1, identify a VA client that requires only
   `RawData`/`Sequence`/`Picture`. Without one it is effort with no consumer —
   the same error this finding corrects.
2. For option 3, determine whether GRD's RDPGFX framing depends on the exact
   slice headers it authors, or only on their presence. That decides viability
   before any upstream conversation.
3. Unblock gaps 1-3 with system RDP credentials
   (`sudo grdctl --system status --show-credentials`), then run the reconnect
   replay against the installed `~rk2` before swapping in the forced-IDR build,
   so the gate measures the Published package it was written against.

## Why it matters / follow-up

An architectural dependency existed for a real reason that nobody had written
down, so the reason had to be rediscovered from source. That is the cost this
repo exists to avoid, and it argues for recording *why a path was not taken*
alongside the path that was.

It also shows a capability audit can be wrong in both directions at once. The
morning's triage judged packed headers by looking only at the driver, concluded
"no consumer", and recommended deferral. The consumer was one directory away in
a project already in this repo, and the feature was simultaneously infeasible.
Auditing a capability without checking its would-be callers produces confident
and useless answers.

The `tls-cert` note is separate and small: the user-level GRD setting still
points at a dangling per-session scratchpad path under `/tmp`, which needs
repointing at durable storage before user RDP is re-enabled.
