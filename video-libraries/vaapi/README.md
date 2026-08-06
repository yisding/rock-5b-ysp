# rockchip-vaapi — VA-API over Rockchip MPP

This project records the maintained `rockchip-vaapi` fork: a libva backend
that translates desktop VA-API decode and encode requests into Rockchip
MPP/RGA operations on RK3588.

## Project brief

| Field | Contents |
|-------|----------|
| Purpose | Expose the vendor `/dev/mpp_service` codec stack through standard VA-API without patching each desktop application into RKMPP wrapper codecs. |
| Developer focus | Bridge policy, VA-API surface mapping to MPP/RGA, import/upload contracts, 10-bit layout handling, and consumer qualification. |
| Owns | Durable capability policy and evidence routes. |
| Does not own | Architecture mechanism ([guide](docs/architecture.md)), accumulated results ([scorecard](docs/validation.md)), application compatibility ([app map](../../docs/app-enablement.md)), publication ([W05](../../status.md#watch-w05)), remote tips ([W18](../../status.md#watch-w18)), or the dated browser/package verdict ([status track 14](../../status.md)). |
| Depends on | A compatible MPP/RGA kernel and userspace pair, libva, device permissions, and application-specific display or sandbox access. |

## Where it sits

`rockchip-vaapi` is a userspace driver, not a kernel driver or application
patch:

```text
Firefox / Chromium / VLC / GStreamer / FFmpeg
  -> libva
  -> rockchip_drv_video.so
  -> librockchip_mpp + librga
  -> /dev/mpp_service + /dev/rga + /dev/dma_heap/*
  -> RK3588 codec and RGA hardware
```

The [architecture guide](docs/architecture.md) explains how the bridge works;
the [validation scorecard](docs/validation.md) owns accumulated proof; and the
[application map](../../docs/app-enablement.md) owns consumer fit.

## Consumer strategy

Prefer VA-API when a consumer already speaks libva directly, uses GStreamer's
`va` plugin, or uses libavcodec's generic VAAPI codecs. Keep named RKMPP
codecs for applications already integrated with them. Advertise only contracts
MPP can implement without silently discarding client state.

That policy makes Firefox's RDD broker/seccomp rules, VLC's image/export API,
and Chromium's compiled backend, pre-decode export identity, GPU presentation,
and sandbox distinct integration contracts. Sunshine and OBS fit the ordinary
H.264 VAAPI encode shape. GNOME Remote Desktop's native path does not: it
requires application-authored packed slice headers. WayVNC additionally
requires an unsupported profile and VA video processing.

Runtime results and priorities belong to the
[application map](../../docs/app-enablement.md) and
[status track 14](../../status.md).

## Capability matrix

Exposure is policy: **Default** is advertised; **Opt-in** is implemented but
hidden behind its documented switch; **Unadvertised** fails closed; **Out of
scope** has no implementation commitment.

| Path | Exposure | Durable evidence basis | Boundary |
|------|----------|------------------------|----------|
| H.264 decode | Default | Reconstruction conformance, lifecycle/sanitizer gates, generic VAAPI and display consumers | Display and sandbox proof remain separate |
| VP9 Profile 0 decode | Default | Reconstruction conformance, retained-output routing, generic VAAPI and display consumers | Browser selection and sandboxing are consumer results |
| HEVC Main decode | Default | Broad conformance classification, reconstruction regressions, generic VAAPI and display consumers | Oversize pictures and MPP-native failures remain fail-closed |
| HEVC Main10 decode | Opt-in | AFBC NV15-to-P010 exactness, metadata, throughput, repeated RGA conversion, and display consumers | Widths below 68 are permanently unsupported; physical HDR and sandboxes are separate |
| VP9 Profile 2 decode | Opt-in | P010 exactness, throughput, and display evidence | One vector is stack-fingerprint quarantined; physical-output and sandbox gates remain |
| H.264 Main/High encode | Opt-in | FFmpeg/GStreamer interop, rate control, imports/uploads, multi-slice, concurrency, WebRTC-shaped traffic, sanitizers, and soak | 10-bit input, B-frames, and packed headers are backend walls; modifiers remain rejected |
| HEVC Main encode | Opt-in | FFmpeg/GStreamer interop, CTU64 contract, imports/uploads, multi-slice, concurrency, sanitizers, and soak | Main/NV12 only; the same backend walls apply |
| AV1 decode | Unadvertised design | Vendor packet decode and a source-inspected direct-service architecture | No direct VA job compiler, golden replay, state/layout/recovery/film-grain conformance, or application proof |
| AV1 encode | Out of scope | None | No implementation plan |
| Deinterlacing | Unadvertised | Interlaced coded frames decode; IEP2 is independently usable | No `VAEntrypointVideoProc`; decoder-internal 1:N output violates VA decode's 1:1 contract |

The driver calls `DMA_BUF_IOCTL_SYNC` directly. A kernel that enables the
known-bad DMA-BUF debug scatterlist mangling is incompatible; the
[root-cause evidence](../../findings/2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md)
and [validation scorecard](docs/validation.md#accumulated-release-evidence)
bound that precondition and its shipping-stack replay.

## Decode architecture and boundaries

VA supplies parsed codec state and slices; MPP expects a compressed packet and
parses it again. The bridge reconstructs a legal stream, submits it through a
per-context worker, routes output to the correct surface generation, and
retains external-buffer ownership. Pre-decode exports are special: their
storage identity is already visible, so output must be copied into that stable
allocation.

Ten-bit decode requests AFBC V2 NV15 and converts it to public P010 through
RGA. Kernel and librga form one storage-layout contract; a mismatched stride or
plane offset can silently corrupt chroma. The
[architecture guide](docs/architecture.md) owns the lifecycle, ownership
graph, reconstruction model, and failure policy.

AV1 remains a design, not a capability. It would replace the libmpp
parser/HAL/allocator slice with a checked, pinned VDPU job compiler while
retaining the kernel service. See the
[direct-service backend design](docs/av1-direct-mpp-service-backend.md).

### Declined: narrow AFBC 10-bit below 68 pixels

Ten-bit decode below 68 visible pixels is permanently unsupported. MPP
supplies AFBC NV15. RGA3 can read AFBC and write 10-bit raster but has a
68-pixel active-width floor; RGA2 accepts narrower 10-bit raster but cannot
read AFBC. No core matches, so the driver refuses before submission and the
application can software-decode.

Linear-NV15 and CPU-repack alternatives were not disproved; they were declined
because they serve one synthetic 64-pixel vector and no identified real
content. The retained
[closure-plan stub](docs/narrow-10bit-closure-plan.md) preserves superseded
anchors and routes its still-useful librga work separately.

## Encode surface contract

The opt-in encoders accept driver-owned NV12, checked I420/YV12 uploads,
validated linear PRIME 2 imports, supported multi-object normalization, and
packed linear RGB converted to NV12 through RGA. The driver duplicates imported
fds for the surface lifetime. Tiled or modifier-bearing imports are rejected.

Three walls are policy, not backlog:

1. **P010/Main10 encode:** RK3588's shared `vepu5xx` table maps 10-bit input to
   an unsupported sentinel; down-conversion would discard requested precision.
2. **B-frames:** the MPP H.264/HEVC backends emit I/P pictures only.
3. **Packed slice headers:** MPP emits a complete slice NAL and cannot accept a
   client-authored slice header. Partial advertisement would attach clients
   such as GRD and then discard required state.

The [validation scorecard](docs/validation.md#encode-import-and-transport-conclusions)
preserves the broader qualification and refusal evidence. The
[GRD validation owner](../../apps/gnome-remote-desktop/docs/validation.md#accumulated-capability-conclusions)
retains the consumer boundary: GRD requires all four packed-header classes,
including client-authored slice headers, so advertising a partial bridge would
turn a clean probe rejection into incorrect output.

## Packaging and browser sandbox boundary

Keep these identities separate:

| Question | Owner |
|----------|-------|
| Intended package source | Build input under [`../../packaging/ppa/`](../../packaging/ppa/README.md) |
| Published source and binaries | Launchpad; [W05](../../status.md#watch-w05) is its dated cache |
| Observed fork tips | [W18](../../status.md#watch-w18) |
| Installed and browser-qualified artifact | [Status track 14](../../status.md) and its cited evidence |
| Consumer contract | [Application map](../../docs/app-enablement.md) |

A matching version string does not prove artifact identity. A local build and
PPA binary remain different until metadata and payload hashes match and the
runtime gate is replayed through the intended artifact.

Firefox RDD needs both broker access to MPP/RGA/DMA-heap paths and a narrow
ioctl allowlist. Chromium's GPU process needs equivalent device/ioctl
attribution. Disabling a sandbox is diagnostic only, never a shipping
configuration. Ordinary processes still need the
[codec udev policy](../../packaging/codec-udev/README.md).

## Next gate

This page does not maintain a second next-gate list. Use
[status track 14](../../status.md#next-gates) for the public browser/package
gate, [W05](../../status.md#watch-w05) for publication,
[W18](../../status.md#watch-w18) for fork-tip freshness, and the
[application map](../../docs/app-enablement.md#suggested-sequencing) for
consumer-specific ordering.

A package or application observation does not itself widen the capability
matrix.

## Evidence map

Findings are live intake. This policy, architecture guide, scorecard, and
application map are their durable successors after promotion.

| Topic | Owner or evidence |
|-------|-------------------|
| Bridge mechanism, ownership, validation, debugging | [Architecture guide](docs/architecture.md) |
| Accumulated source, hardware, matrix, package, installed, and app results | [Validation scorecard](docs/validation.md) |
| Consumer compatibility | [Application map](../../docs/app-enablement.md) |
| AV1 direct vendor-service design | [Backend design](docs/av1-direct-mpp-service-backend.md) |
| Renovation, reconstruction, and AV1 boundary | [Architecture guide](docs/architecture.md), [scorecard](docs/validation.md#accumulated-release-evidence) |
| Decode, ten-bit layout, and narrow-width decision | [Decode scorecard](docs/validation.md#decode-and-conversion-conclusions), [narrow decision](docs/narrow-10bit-closure-plan.md) |
| Encode/import/transport contract and qualification | [Encode scorecard](docs/validation.md#encode-import-and-transport-conclusions) |
| Browser policy and pre-decode export ownership | [Consumer scorecard](docs/validation.md#consumer-and-sandbox-conclusions), [Chrome finding](../../findings/2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md) |
| Package/publication/runtime verdict | [PPA owner](../../packaging/ppa/README.md), [W05](../../status.md#watch-w05), [status track 14](../../status.md) |
