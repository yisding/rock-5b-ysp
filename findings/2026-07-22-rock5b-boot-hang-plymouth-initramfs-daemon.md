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

## The initramfs image itself is not malformed

The failed build-`#6` boot began at 21:32:02 PDT and its immediately adjacent
healthy build-`#6` boot began at 21:38:48. Both used the same
`/boot/initrd.img-6.18.38-current-rockchip64`, which had already been generated
at 21:25:23:

```text
size:   43258724 bytes
sha256: 12265d7bab9bd83cf9531c24213fb7d083c1bd18d13d908b5cb813900c15eff6
```

The image was not regenerated between those boots. A deterministic omission or
corruption in the initramfs therefore cannot explain why the first boot stalled
and the next one completed.

An extraction of that exact image also contains the expected complete path:

- the `init-premount`, `init-bottom`, and panic Plymouth scripts;
- `/usr/bin/plymouth`, `/usr/sbin/plymouthd`, the Plymouth core/graphics
  libraries, DRM and framebuffer renderers, and two-step/details/text plugins;
- the configured Armbian theme and all of its assets;
- `libdrm`, `libudev`, `libevdev`, and the direct ELF dependencies of the
  Plymouth client, daemon, renderer, and theme plugin;
- `rockchipdrm.ko`, its DRM/bridge/PHY dependencies, and
  `usr/lib/firmware/rockchip/dptx.bin`.

The embedded client, daemon, renderers, core libraries, theme plugins, and all
three handoff scripts are byte-for-byte identical to their installed
counterparts. `dpkg -V` found no modified Plymouth package file.

The transition protocol narrows the failure further. Initramfs runs:

```text
plymouth update-root-fs --new-root-dir=${rootmnt}
```

The daemon does not ACK that command until its single event loop has dispatched
the request, chrooted into the mounted real root, loaded the progress cache, and
called the theme's root-mounted callback. The initramfs cannot finish and start
the real-root PID 1 while this client is still waiting. Because PID 1 did start
on the failed boot, the inherited daemon was alive and responsive through that
ACK. It stopped servicing requests only **after** the root handoff and before
`plymouth-read-write.service` sent its read-write request at 14.106 s.

This makes the remaining defect a runtime race or blocking callback in the
post-pivot daemon, not an initramfs construction failure. Plymouth keeps its
udev monitor and renderer file descriptors across the chroot. Its udev callback
synchronously drains DRM events and may synchronously open/re-probe the
renderer through DRM ioctls. Rockchip DRM finishes binding immediately before
PID 1 starts, so that path is a plausible timing-sensitive suspect, but it is
not proven: the same DRM messages and device path occur on the healthy boot.

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
plus unbounded client waits held sysinit. The initramfs artifact and its payload
are also excluded, and the daemon is proven responsive through the new-root
ACK. The postmortem does **not** identify the syscall or callback that stopped
the daemon's single event loop after pivot. There is no Plymouth debug stream or
live task stack from the failed boots. The same Rockchip DRM "Cannot find any
crtc or sizes" messages occur in healthy boots, so calling DRM the internal root
cause would still be speculation.

## Why it matters / follow-up

### Recommended ROCK 5B fix: disable the unused splash

The live `/boot/armbianEnv.txt` already says `bootlogo=false`, but Armbian's
`boot.cmd` implements that setting by adding `splash=verbose`, not by removing
Plymouth:

```text
if test "${bootlogo}" = "true"; then
    setenv consoleargs "splash plymouth.ignore-serial-consoles ${consoleargs}"
else
    setenv consoleargs "splash=verbose ${consoleargs}"
fi
...
setenv bootargs "... ${consoleargs} ... ${extraargs} ..."
```

Append `plymouth.enable=0` to the existing `extraargs=` line in
`/boot/armbianEnv.txt`. For this board it becomes:

```text
extraargs=cma=256M module_blacklist=snd_soc_hdmi_codec modprobe.blacklist=snd_soc_hdmi_codec pstore.backend=ramoops pstore.kmsg_bytes=262144 printk.always_kmsg_dump=1 panic=10 plymouth.enable=0
```

No `update-initramfs` or `mkimage` is required: `boot.scr` reads
`armbianEnv.txt` at boot. `extraargs` appears after `splash=verbose`, and the
initramfs Plymouth script processes the command line left-to-right, so the later
`plymouth.enable=0` wins. It prevents the initramfs daemon from starting and
causes `plymouth-start.service` to fail its condition. The unconditional
read-write client then finds no socket and exits immediately.

After reboot, verify:

```bash
tr ' ' '\n' </proc/cmdline | grep -x plymouth.enable=0
journalctl -b -o short-monotonic --no-pager |
    grep -E 'plymouth|Reached target (sysinit|basic)\.target'
```

Expected: no initramfs `plymouthd`, `plymouth-start.service` skipped,
`plymouth-read-write.service` completes rather than remaining in `Starting`,
and both targets are reached.

### Package-level hardening if Plymouth must remain enabled

Preventing a cosmetic splash failure from stopping boot requires a fail-open
path even before the daemon's internal wedge is localized:

1. Extend the existing `on_ping_timeout()` event-loop mechanism in
   `src/client/plymouth.c` to finite-time non-interactive control requests,
   especially `update-root-fs --read-write` and `show-splash`. Password prompts
   and the intentional `--wait` operation need separate semantics.
2. Add finite `TimeoutStartSec` safety nets to
   `plymouth-read-write.service`, `plymouth-start.service`,
   `plymouth-quit.service`, and `plymouth-quit-wait.service`. The installed
   read-write unit currently has an infinite start timeout, and quit-wait
   explicitly uses `TimeoutSec=0`.
3. On timeout, capture the socket owner's PID, `/proc/<pid>/syscall`,
   `wchan`, file descriptors, and a `strace`/debug trace before recovery.
   Restarting it safely also needs VT/DRM cleanup; blindly removing the pid file
   or starting another daemon cannot replace an abstract socket that is still
   owned by the wedged process.

For one instrumented reproduction, use
`plymouth.debug=stream:/dev/ttyS2` so daemon traces go directly to the existing
serial console. Plain `plymouth.debug` buffers early traces in memory and only
flushes them when the very system-initialized request that is hanging succeeds.

Tracked as status.md watchlist [`W20`](../status.md#watch-w20).
