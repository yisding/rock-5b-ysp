# GRD's fixed-QP encoder overruns the Tailscale RDP path, stalling video while audio continues

> Scope: `gnome-remote-desktop 50.2+rkmpp+git20260729.14.24f4392-0ubuntu1~rk1`
> on the ROCK 5B, `h264_rkmpp` AVC420 backend, RDP client over Tailscale on a
> 5 GHz Wi-Fi LAN
> Source: live `ss -tin` on the daemon's port-3389 socket (PID 5534), `iw dev
> wlP2p33s0 station dump`, daemon journal; encoder configuration in
> `grd-encode-session-ffmpeg.c` `create_encoder()`
> Date: 2026-08-01
> Trust: MEASURED, SOURCE-INSPECTED, INFERRED (stall attribution)

## Result

Playing YouTube full-screen over RDP produced intermittent ~0.5 s video stalls
while audio kept playing. The cause is a rate mismatch, not packet loss and not
the radio: the encoder runs **fixed QP 22 with no bitrate ceiling**, so
full-motion content bursts past what the transport sustains, the socket send
queue backs up, and RDPGFX frames arrive late. Audio rides a separate
low-bandwidth channel and is unaffected — which is exactly the reported
asymmetry.

**Measured stream rate.** Ten `ss -tin` samples ~1 s apart while video played:
`bytes_sent` went 1,359,768,824 → 1,383,089,731, i.e. 23.3 MB in ~10 s ≈
**18.7 Mbps average**, with per-interval peaks near 22.9 Mbps. (Sample spacing
includes `ss` overhead, so this is a lower bound on the instantaneous rate.)

**It is not loss.** `bytes_retrans` stayed frozen at 487,953 across all ten
samples — zero retransmissions during the measurement window.

**It is queue/window limiting.** Over the same samples:

| signal | observed |
| --- | --- |
| `Send-Q` | oscillates 0 → 251,970 B, `notsent:49843` at peak |
| `cwnd` | 219 → 245 |
| `rtt` | 13.2–29.3 ms against `minrtt:3.262` |

An earlier sample caught a worse excursion: `cwnd:48 ssthresh:13`,
`rtt:47.673/18.544`, `Send-Q 275264` with `notsent:232451`,
`delivery_rate 6974792bps`, plus `reordering:107`, `dsack_dups:215`,
`rcv_ooopack:509`. RTT inflating 4–15× above `minrtt` with no retransmits is
queue buildup, and the reordering counters explain the window collapse under
reno (see [the reno default finding](2026-08-01-armbian-rockchip64-defaults-tcp-reno.md)).

**The radio is not the bottleneck.** `-50 dBm`, `720.6 MBit/s 80MHz HE-MCS 7
HE-NSS 2`, **`tx retries: 0`**, `tx failed: 110`, and zero netdev errors or
drops in either direction. Ethernet (`enP4p65s0`) is `NO-CARRIER`, so all
traffic is on Wi-Fi — a healthy link.

**Path shape.** The socket is `100.97.222.5:3389 → 100.73.227.50`, i.e. inside
the Tailscale tunnel: `tailscale0` MTU **1280**, so `mss:1228` / `pmtu:1280`
against 1448 on a native 1500-MTU path. The peer is on the same `/22`
(`192.168.68.65`), and Tailscale had found a direct path to it, so this is
encapsulation overhead and userspace WireGuard processing, not a DERP relay.
Connect-time autodetect had measured `6075KB/s` (~48 Mbps) with `base RTT: 4ms,
average RTT: 7ms`, so the path's headroom collapses under sustained load.

## Root cause

`create_encoder()` requested constant quality by setting `qp_init = 22` and
leaving the rate-control mode at its default, which makes ffmpeg-rockchip
auto-select MPP `FIXQP`. In that mode the encoder **ignores** `bit_rate`,
`rc_max_rate` and `rc_min_rate` entirely.

That is confirmed arithmetically. The code computed
`bit_rate = W*H*fps/4 = 39.8 Mbps`, `rc_max_rate = 100 Mbps` (cap-clamped) and
`rc_min_rate = 4.97 Mbps` for the 2056×1290@60 surface, but MPP logged
`mpp_enc: mode fixqp bps [1500000:2000000:2500000]` — 1.5/2.0/2.5 Mbps, which
are MPP's own defaults, not the computed values. The triplet never reached the
encoder. Constant QP 22 therefore had no upper bound at all.

## Fix

Capped VBR, implemented in
[the recovery/ceiling finding](2026-08-01-grd-hw-encode-watchdog-forced-idr-bitrate-ceiling.md):
explicit `rc_mode=VBR` with `qp_min = 22` so static desktop content encodes as
it did under FIXQP, `qp_max = 40` so motion degrades quality instead of
overrunning the link, and a pixel-rate-derived ceiling (~19.9 Mbps for this
surface) overridable via `GNOME_REMOTE_DESKTOP_RDP_MAX_BITRATE`.

Two transport-side changes are independent of the encoder and were **not**
applied here: pointing the client at the LAN address `192.168.69.101:3389`
instead of the Tailscale address (MTU 1500, no encapsulation), and moving off
reno.

## Boundary

The stall attribution is INFERRED, not directly captured: no trace ties an
individual dropped frame to a specific `Send-Q` excursion, and the stalls were
not reproduced under controlled load. What is measured is the rate, the absence
of retransmits, the queue and RTT behaviour, the healthy radio, and — from the
MPP log line — that the bitrate triplet was inert. The competing explanation
that some stalls came from the RDPGFX acknowledgement wedges recorded in
[2026-07-20](2026-07-20-grd-rdpgfx-focus-resume-ack-wedge.md) is not excluded;
those present as multi-second freezes rather than ~0.5 s blips, but no
discriminating capture was taken.

Nothing here was re-measured after the encoder change, so the ceiling's effect
on these stalls is unverified.

## Note: connect-time handover reads as a freeze

Separately, and not a defect: after a reboot, the RDP client connects at the
greeter, authenticates, then receives a **server redirection** and reconnects
with a routing token — the daemon logs `ERRINFO_LOGOFF_BY_USER` and
`RDP client gone` mid-sequence. On this board that handover plus encoder
negotiation spans 17:23:40 → 17:23:49, about **9 s** with the client connected
and nothing to draw, before GNOME session startup load lands on top. It is
easily mistaken for a hang.
