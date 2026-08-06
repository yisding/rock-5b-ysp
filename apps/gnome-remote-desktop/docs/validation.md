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
| Fixed-QP transport pressure | The measured encoder ignored bitrate fields in FIXQP mode and averaged 18.7 Mbps over the Tailscale path while the send queue and RTT inflated without retransmissions | [Promoted transport evidence](#fixed-qp-transport-pressure); the VBR candidate still needs its live gate |
| Greeter encode | Dynamic greeter users require a stable group ACL on MPP/DMA-heap nodes | [Testing](testing.md), [gdm-hwenc package](../../../packaging/gdm-hwenc/README.md) |
| Cached readback recovery | Copying into cached driver-owned storage removes the measured imported-buffer readback cliff | [Profiling](profiling.md) |
| Frame-ACK recovery | Recovery must be gated on decoded-frame progress after ACK resume, not on transport traffic alone | [Testing](testing.md) |
| AVC color signaling | The shader emits full-range BT.709 values; matching H.264 VUI signaling survives FFmpeg/MPP and corrected muted colors on the tested macOS client after a clean reboot | [Promoted color evidence](#full-range-bt709-signaling); visual result, not colorimetry |
| Native VA-API alternative | GRD requires client-authored packed slice headers that MPP cannot accept | [VA-API capability policy](../../../video-libraries/vaapi/README.md#encode-surface-contract) |

### Fixed-QP transport pressure

On the 2056x1290@60 AVC420 path, ten one-second socket samples during
full-screen video measured about 18.7 Mbps average with interval peaks near
22.9 Mbps. `bytes_retrans` did not move, while `Send-Q` reached roughly 252 KiB
and RTT rose from a 3.262 ms minimum into the 13.2–29.3 ms range. A worse
sample combined `cwnd:48`, `ssthresh:13`, reordering/DSACK evidence, 47.7 ms
RTT, and a 275 KiB send queue. The Wi-Fi link itself reported strong signal,
high PHY rate, and no retries during the focused sample.

Source and MPP logs explain why the computed bitrate triplet was inert:
`qp_init=22` selected FIXQP, whose logged 1.5/2.0/2.5 Mbps values were MPP
defaults rather than the 39.8 Mbps target computed by GRD. The measured queue,
rate, no-loss, and mode evidence is strong; attributing each half-second visual
stall to the queue remains inferred because no per-frame transport trace was
captured. The uninstalled [watchdog/VBR finding](../../../findings/2026-08-01-grd-hw-encode-watchdog-forced-idr-bitrate-ceiling.md)
owns the candidate ceiling and its re-measurement gate.

### Full-range BT.709 signaling

The AVC conversion shader uses full-range BT.709 coefficients, but the old
encoder context declared limited range and no matrix. A one-variable package
set `AVCOL_RANGE_JPEG` and `AVCOL_SPC_BT709`; the staged and installed daemon
matched byte-for-byte, and a focused VPU A/B changed the H.264 metadata from
unspecified/limited defaults to `color_range=pc` and `color_space=bt709`.
After a clean reboot, the tested Microsoft macOS RDP client no longer showed
the muted colors.

The retained [experiment bundle](../evidence/2026-07-28-grd-avc-fullrange709/README.md)
owns the exact patch, package fingerprints, metadata output, failed first
handover timeline, and static comparison chart. The final verdict is a
package-verified visual observation, not a colorimeter or paired-pixel result;
other clients, transfer functions, and display profiles remain outside it.

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
