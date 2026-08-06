# GNOME Remote Desktop RKMPP validation scorecard

This page owns accumulated application-level conclusions for the RK3588 GRD
backend. It does not own release-branch heads
([W10](../../../status.md#watch-w10)), package publication
([W05](../../../status.md#watch-w05)), or the installed verdict and next proof
([status track 7](../../../status.md)).

## Evidence ladder

| Class | Positive signal | Boundary |
|-------|-----------------|----------|
| Build/unit | GRD and FFmpeg-facing objects compile; project tests pass | No hardware or package identity |
| Backend smoke | DRM PRIME input imports and one encoded packet completes | Not a visible RDP frame or reconnect |
| Live RDP | AVC420 packets decode and client frame ACKs replenish slots | One session does not prove handover/reconnect/recovery |
| Sustained session | Hardware markers, pacing, output quality, and timing remain bounded | Exact package/kernel identity still matters |
| Installed stack | Intended GRD, FFmpeg, MPP, kernel, permissions, and service are observed | Only the exercised session mode |
| Recovery/handover | Authenticated reconnect, fallback, recreation, IDR, and ACK recovery work without daemon restart | Other clients and failure modes |

TCP delivery, RDPGFX frame acknowledgement, PipeWire capture, GPU conversion,
MPP submission, encoded packet completion, and visible client progress are
separate clocks. A useful gate names which one advanced.

## Accumulated capability conclusions

| Capability | Established conclusion | Evidence owner / boundary |
|------------|------------------------|---------------------------|
| Hardware H.264 backend | GRD can wrap panvk-produced NV12 DRM PRIME frames and encode them through FFmpeg RKMPP/VEPU580 | [Design](design.md), [capture path](capture-path.md) |
| Live post-login RDP | AVC420 hardware encode sustained a real client session | [Profiling](profiling.md); exact run is historical |
| RGB-to-NV12 | Panfrost capture to panvk compute crosses drivers with explicit DMA-BUF synchronization | [Capture path](capture-path.md) |
| Throughput | The measured path was vsync-bound at 60 fps; MPP encode was a small part of the frame budget | [Profiling](profiling.md); not a universal benchmark |
| Quality | Setting bounded VBR rates avoids MPP's low default ceiling on the upstream-style encoder | [Project issue model](../README.md#2-terrible-quality-the-25-mbps-ceiling) |
| First visible frame | The startup smoke frame can consume the natural IDR; the backend must recreate or use a proven force-IDR control | [Project issue model](../README.md#1-the-frozen-desktop-no-idr-in-the-stream) |
| Backpressure | One-frame-in-flight needs stale-work dropping and bounded software fallback/retry | [Profiling](profiling.md), release patch model |
| Greeter encode | Dynamic greeter users require a stable group ACL on MPP/DMA-heap nodes | [Testing](testing.md), [gdm-hwenc package](../../../packaging/gdm-hwenc/README.md) |
| Cached readback recovery | Copying into cached driver-owned storage removes the measured imported-buffer readback cliff | [Profiling](profiling.md) |
| Frame-ACK recovery | Recovery must be gated on decoded-frame progress after ACK resume, not on transport traffic alone | [Testing](testing.md) |
| Native VA-API alternative | GRD requires client-authored packed slice headers that MPP cannot accept | [VA-API capability policy](../../../video-libraries/vaapi/README.md#encode-surface-contract) |

## Durable failure classification

1. **Capture starvation:** no new PipeWire/view work reaches the encoder.
2. **GPU conversion/readback:** DMA-BUF import, modifier, synchronization, or
   cache behavior blocks before codec submission.
3. **Encoder flow control:** MPP input/output ownership, backpressure, timeout,
   reset, IDR, or recreation stalls packet production.
4. **RDP transport/pacing:** encoded packets exist but codec negotiation,
   RDPGFX slots, frame ACKs, focus/resume, or handover prevent visibility.
5. **Package/service boundary:** the daemon, library, branch, device ACL, or
   service instance being observed is not the intended one.

Instrument the seams; do not assign ownership from the visible freeze alone.

## Operations and current route

| Goal | Route |
|------|-------|
| Understand the backend | [Design](design.md), [capture path](capture-path.md) |
| Reproduce software and hardware timing | [Baseline](baseline.md), [profiling](profiling.md), [bench](../bench/README.md) |
| Run a session safely | [Testing playbook](testing.md) |
| Inspect portable source delta | [Patch replay](../patches/README.md) |
| Check intended package source | [Build input](../../../packaging/ppa/build-source-packages.sh) |
| Check branch/publication freshness | [W10](../../../status.md#watch-w10), [W05](../../../status.md#watch-w05) |
| Execute the next public proof | [Status track 7](../../../status.md#next-gates) |

Update this scorecard only when evidence changes a durable conclusion. Keep
exact run logs in dated findings until promotion and keep the public dashboard
compact.
