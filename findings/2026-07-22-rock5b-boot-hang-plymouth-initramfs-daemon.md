# ROCK 5B boot was held by an unresponsive initramfs Plymouth daemon

> Scope: ROCK 5B dev board, running debug (lockdep-enabled) `6.18.38-current-rockchip64` while hunting Rockchip video-codec (rkvdec2/rkvenc/mpp) driver bugs
> Source: on-board `journalctl` of two failed boots and adjacent healthy boots, captured 2026-07-22; exact installed kernel and Plymouth sources
> Date: 2026-07-22
> Trust: ROOT-CAUSED for the boot transaction; MEASURED for the boot/probe sequence; SOURCE-INSPECTED for the IPC and unit behavior; OPEN for why the inherited daemon stopped servicing its event loop

## Result

The boot did not hang in the forward-port driver. It was held before
`sysinit.target` by two Plymouth clients waiting on the same unresponsive
Plymouth daemon inherited from the initramfs:

1. `plymouth-read-write.service` ran `plymouth update-root-fs --read-write`
   and remained blocked in Plymouth's untimed connect/request/reply path.
2. `plymouth-start.service` then launched another `plymouthd`. That process saw
   the inherited daemon already owned the socket and exited successfully, but
   the unit's `ExecStartPost=plymouth show-splash` connected to the same
   unresponsive daemon and also waited for an acknowledgement.
3. Both services are wanted by `sysinit.target`. The read-write service is
   explicitly `Before=sysinit.target`, is a oneshot, and has an infinite start
   timeout. Consequently `sysinit.target`, `basic.target`, NetworkManager, and
   GDM could not start. The independent networkd wait-online job later timed out
   and became the last persisted line, but did not cause the stall.

This exact fingerprint occurred twice on 2026-07-22: boot `-6` on kernel build
`#3` and boot `-1` on build `#6`. Both have unmatched Plymouth read-write/start
jobs, no `SIGRTMIN+20` response from the inherited daemon, and no
`sysinit.target`. Their adjacent healthy boots complete the Plymouth handshake
in 30–60 ms and continue immediately.

## Discriminating boot diff

| Event | Failed boot `-1` | Healthy boot `0` |
|---|---:|---:|
| Last forward-port probe finishes | 13.341 s | before PID 1 |
| Plymouth read-write starts | 14.106 s | 15.004 s |
| PID 1 receives `SIGRTMIN+20` from initramfs `plymouthd` | **never** | 15.048 s |
| Plymouth read-write finishes | **never** | 15.054 s |
| Plymouth start begins | 15.375 s | 16.220 s |
| Plymouth start completes | **never** | 16.382 s |
| udev settle finishes | 17.826 s | 18.577 s |
| `sysinit.target` / `basic.target` | **never** | 18.578 / 18.729 s |
| NetworkManager starts/completes | **never** | 19.121 / 19.742 s |

The failed boot still logged kernel activity and the networkd timeout after both
Plymouth jobs became stuck. This is a userspace boot-transaction stall, not a
kernel freeze at the video probe.

## Why the Plymouth attribution is proven

- The initramfs script starts `/usr/sbin/plymouthd` and runs
  `plymouth --show-splash`. The daemon deliberately changes `argv[0]` to begin
  with `@` so it survives the initramfs-to-real-root transition.
- Installed Plymouth is
  `24.004.60+git20250831.4a3c171d-0ubuntu8`. In its exact source,
  `plymouth update-root-fs --read-write` connects to
  `/org/freedesktop/plymouthd`, queues a system-initialized request, and runs the
  event loop until an ACK or disconnect. Ordinary requests have **no timeout**;
  only `plymouth --ping` arms one.
- If no daemon owns the socket, the connect failure invokes the failure handler
  and the client exits. Therefore the indefinitely running client, together
  with the replacement daemon's inability to bind, proves that the inherited
  daemon still owned the socket but did not complete the handshake. The
  postmortem cannot distinguish a full accept backlog from a request that was
  accepted but not dispatched.
- The daemon's system-initialized handler sends PID 1 `SIGRTMIN+20` before the
  server writes the ACK. Every healthy adjacent boot logs that signal and the
  service completion. Neither failed boot logs either one, so the inherited
  daemon never dispatched the request.
- A replacement `plymouthd` cannot take over: failure to bind the already-owned
  abstract socket is treated as "`plymouthd` is already running" and exits
  success. The subsequent `show-splash` client then waits on the bad server.
- Live systemd metadata confirms both units are wanted by `sysinit.target`;
  `plymouth-read-write.service` is `Before=sysinit.target` with
  `TimeoutStartUSec=infinity`.

## Forward-port driver exclusion

The exact installed-kernel tree is
`linux-6.18-rkvenc-av1-fwport@fa8c80ceccc5e28d93264962c56073375657919f`.
On both failed boots, every `mpp_service`, rkvdec2, rkvenc2, and AV1 probe has a
matching completion before PID 1 starts. `mpp_service_probe()` also registers
subdrivers synchronously before printing `probe success`; the only unbounded MPP
wait is in the post-boot userspace task-result ioctl path.

The later `fdba4000/fdba8000/fdbac000.video-codec` messages are mainline Hantro
VEPU121 JPEG secondary instances, not forward-port devices. Hantro intentionally
returns `-ENODEV` for those unsupported secondary instances, and the same
power-domain sync markers occur on healthy boots.

## Boundary

The boot-level cause is proven: an unresponsive inherited Plymouth socket owner
plus unbounded client waits held sysinit. The postmortem does **not** identify the
syscall or callback that stopped the daemon's single event loop. There is no
Plymouth debug stream or live task stack from the failed boots. The same
Rockchip DRM "Cannot find any crtc or sizes" messages occur in healthy boots, so
a renderer/DRM cause would be speculation.

## Why it matters / follow-up

The deterministic exclusion test is to boot once with `plymouth.enable=0`
appended after `splash=verbose` (or remove the splash argument). This prevents
the initramfs daemon from starting; the unconditional read-write client then
finds no socket and exits.

For one instrumented reproduction, use
`plymouth.debug=stream:/dev/ttyS2` so daemon traces go directly to the existing
serial console. Plain `plymouth.debug` buffers early traces in memory and only
flushes them when the very system-initialized request that is hanging succeeds.
If Plymouth must stay enabled, add finite start timeouts to both units so a
wedged splash cannot hold sysinit indefinitely.

Tracked as status.md watchlist [`W20`](../status.md#watch-w20).
