# Testing & benchmarking GRD on this box — the playbook

Hard-won operational knowledge from benchmarking and prototyping GRD on the
ROCK 5B. Most of these cost us a broken session, a killed shell, or an hour of
"why is it idle" before we understood them. Read this before touching a live
daemon; the surfaceless micro-benchmark ([`apps/gnome-remote-desktop/bench`](../bench)) is the only thing
here that is unconditionally safe.

## 0. The box

| | |
|---|---|
| SoC / board | RK3588, Radxa ROCK 5B — 4× Cortex-A76 + 4× Cortex-A55, 15.4 GiB |
| GPU / driver | Mali-G610 MC4, **Panfrost**, Mesa **26.0.3**, OpenGL **3.1** (GLES 3.1) |
| Kernel | 6.18.37-current-rockchip64, `cma=256M` |
| GRD | 50.1 |
| Session | Wayland (gnome-shell/mutter), RDP on port 3389/3390 |

> **Two Mesa builds appear in this section's numbers.** Everything measured
> *through GRD* ([`baseline.md`](baseline.md), [`apps/gnome-remote-desktop/bench`](../bench),
> [`profiling.md`](profiling.md)) ran on the **system Mesa 26.0.3** above. The
> Mesa/Panfrost texture-transfer investigation
> ([`mesa-panfrost-transfer.md`](mesa-panfrost-transfer.md),
> [`video-libraries/mesa`](../../../video-libraries/mesa)) used a **26.2-devel local
> build** (that's where the MR !42563 patches live). Don't compare timings
> across the two without noting the build.

## 1. ⚠️ The cardinal rule: never run a second GRD against the same mutter

Mutter's RemoteDesktop/ScreenCast D-Bus API is **single-tenant**. Starting a
second GRD instance (e.g. a manually built one for testing) against the running
mutter **evicts the existing session**:

```
disconnection initiated by an administrative tool … in another session
```

— which **drops any live RDP client**, including the one you may be connected
*through*. This bit us directly: a "harmless isolated loopback test" disconnected
the active session. Rules that follow from it:

- Do end-to-end GRD testing with **no other RDP client connected**, or on a
  separate machine/VM.
- Prefer testing from a **local tmux/SSH** session, not from within the RDP
  session you're about to evict.
- The micro-benchmark in [`apps/gnome-remote-desktop/bench`](../bench) is exempt — it's a surfaceless GL
  context that never touches mutter.

## 2. Environment for a shell that isn't the graphical session

From tmux/SSH the shell lacks the session bus and display env. Graphical clients
(`xfreerdp3`, `glxgears`) and D-Bus tools need it exported by hand:

```bash
export DISPLAY=:0
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
# XAUTHORITY: take the path Xwayland was launched with —
#   ps aux | grep Xwayland   → the `-auth <file>` argument
export XAUTHORITY=<that file>
```

## 3. Swapping in a manually built GRD

`grdctl rdp enable` **D-Bus-activates the *system* binary's user service**, not
your build. To test a manual binary:

```bash
systemctl --user mask gnome-remote-desktop.service   # stop D-Bus from launching the packaged one
# … run your built ./src/gnome-remote-desktop-daemon by hand …
systemctl --user unmask gnome-remote-desktop.service # ALWAYS restore afterwards
```

Build gotchas for the manual binary:
- **ccache**: the default `~/.cache/ccache` may be root-owned → *permission
  denied*. `export CCACHE_DIR=<writable dir>`.
- **Vulkan shaders**: the daemon aborts at startup if it can't find its `.spv`
  shaders under `GRD_DATA_DIR`. Configure a writable prefix and populate it:
  `meson configure build --prefix=<writable>/install`, rebuild, then copy
  `src/shaders/*.spv` into the prefix's
  `share/gnome-remote-desktop/shaders/`.

## 4. Killing the daemon safely

**Do not** `pkill -f 'rdp-port 3390'` from a tool-driven shell — the pattern
matches the tool's *own wrapper argv* and kills the shell itself (exit 144). Kill
by PID instead:

```bash
pid=$(ss -tnlpH 'sport = :3390' | grep -oP 'pid=\K[0-9]+' | head -1)
kill "$pid"
```

## 5. Headless capture is unreliable — trust the live number

Driving frames without a real client is fiddly, and the numbers are soft:

- **`Meta-0` only exists after a client connects.** GRD captures the *virtual
  monitor* it creates for the RDP session; that monitor (`Meta-0` at `0,0`) does
  not exist until a client is connected. Launch any motion source (e.g.
  `glxgears`) **after** the client is up, positioned at `+0+0` so it lands on the
  captured monitor.
- **A synthetic `glxgears` does not reliably drive screencast frames.** Even at
  900 fps in the window, mutter often delivers nothing to the virtual monitor and
  GRD idles near 0 %. Headless end-to-end CPU numbers are therefore *lower bounds*
  and jittery.
- **The trustworthy figure** is the one captured with a **real client** driving
  the session: `100.7 %` daemon / `90.9 %` EGL thread at 1080p on the software
  path. Cite that, not the headless number.

> **One headless configuration did work.** The hardware-path profiling ran a
> *dedicated* `mutter --headless --wayland` + `grd --headless` + a
> frame-counting AVC420 FreeRDP client + `eglgears_wayland`, and captured a
> clean 60 fps with zero drops — see [`profiling.md`](profiling.md) §4. The
> soft-numbers warning above is about driving frames on a client-created
> virtual monitor inside the *live* session; the dedicated headless compositor
> avoided both the eviction hazard (§1) and the idle-capture problem.

## 6. The safe micro-benchmark

[`apps/gnome-remote-desktop/bench/readback_bench.c`](../bench/readback_bench.c) isolates the readback in a
**surfaceless** GL context — no mutter, no session, safe on the live box. The
build+run invocation is in [`apps/gnome-remote-desktop/bench/README.md`](../bench/README.md). This is how
the numbers in [`baseline.md`](baseline.md) were obtained. It reads a plain RGBA8
FBO, not mutter's real capture surface, so treat it as a bound (see BASELINE §5).

## 7. Is it actually on hardware? — a quick checklist

When validating the rkmpp backend (this repo), confirm the HW path really engaged
rather than silently falling back to software RFX:

- **Client caps first.** ⚠️ A client that doesn't advertise **AVC420** silently
  negotiates RFX/`RDPGFX_CODECID_CAPROGRESSIVE` even when the server-side HW
  path is healthy — every other check below can pass while you stream software
  RFX to *that* client. Build FreeRDP with `-DWITH_OPENH264=ON`, or use the
  macOS/Windows Microsoft clients, and check the **client** log for AVC420 vs
  CAPROGRESSIVE surface commands — [`profiling.md`](profiling.md) §5.
- **Threads:** the daemon has an `mpp_h264e` (or similar MPP) worker thread.
  `ps -T -p <pid>` / `top -H`.
- **FDs:** it holds an open `/dev/mpp_service` (and `/dev/dma_heap/*`) fd.
  `ls -l /proc/<pid>/fd | grep -E 'mpp_service|dma_heap'`.
- **Logs:** grep the journal for the committed `[HWAccel.FFmpeg]` tags —
  `Initialized FFmpeg/rkmpp encode backend` and
  `Created h264_rkmpp encode session` are `g_message` (always reach the
  journal, no debug-env dance); the failure lines are
  `[RDP] Did not initialize FFmpeg/rkmpp: …` and (`g_debug`)
  `[HWAccel.FFmpeg] Could not create rkmpp encode session: …`. Full signal
  table with exact strings: [`profiling.md`](profiling.md) §7. (The
  `[ACKDBG]`-style tags in [`README.md`](../README.md)'s methodology section were
  throwaway instrumentation — in no committed patch, don't grep for them.)
- **Multiple frames.** `Created … encode session` alone proves only the smoke
  encode, not the view-creator — run several frames and re-check the
  thread/fds ([`design.md`](design.md) §lesson).
- **On the wire:** `ss -ti` on the RDP socket — `bytes_sent` growing in KB bursts
  = real frames flowing; flat = nothing (encoder stalled *or* client not acking —
  the bitstream dump distinguishes them, see [`README.md`](../README.md) #1).
- **Fallback tell:** if you instrumented the selection point and see the buffer
  pass every gate yet still land on software, suspect the silent
  encode-session-*create* failure (a permission error on `/dev/mpp_service` /
  `/dev/dma_heap`, or a `vk_device` gate) — see [`capture-path.md`](capture-path.md)
  §3–4 and [`README.md`](../README.md) #3.

(The related open measurement — which DRM modifier mutter's screencast dma-buf
actually carries — still has no verified procedure; the open item lives at
[`profiling.md`](profiling.md) §8.)

## 8. Verifying the *greeter* is on hardware (gdm-hwenc)

The §7 checklist targets the logged-in **session** daemon. After installing
[`packaging/gdm-hwenc`](../../../packaging/gdm-hwenc), verify the **login
screen** separately — the greeter runs its *own* GRD daemon as a dynamic
`gdm-greeter-*` user ([`README.md`](../README.md) #3), so your user journal and
your session's pid are the wrong places to look:

```bash
# 1. The ACL grant is in place (a group grant, so it survives greeter churn):
getfacl /dev/dma_heap/system /dev/mpp_service    # must list  group:gdm:rw-

# 2. Log out (or restart GDM) so a fresh greeter starts, then from SSH find
#    the greeter's own daemon — it runs as a gdm-greeter* user, not you:
ps -eo pid,user:16,comm | grep -E 'gdm-greeter.*gnome-remote'

# 3. Run the §7 signals against THAT pid (mpp_h264e thread, /dev/mpp_service
#    fd), and grep the SYSTEM journal — the greeter daemon never writes to
#    your user journal:
journalctl -b -g 'HWAccel.FFmpeg'

# 4. Connect an RDP client to the login screen and confirm AVC420
#    client-side (profiling.md §5).
```

The [`gdm-hwenc` README](../../../packaging/gdm-hwenc/README.md) covers the
package-side verify (the `getfacl` line and what the greeter should
negotiate); this section is the daemon-side confirmation.

## 9. `~exp3` Firefox freeze regression gate

Install the matching pair. The hardening is internal to `rkmppenc`, so there is
intentionally no new FFmpeg option to probe; verify the package versions:

```bash
apt-cache policy ffmpeg libavcodec62 gnome-remote-desktop
dpkg-query -W -f='${Package}\t${Version}\n' \
  ffmpeg libavcodec62 gnome-remote-desktop
```

Then reconnect with an AVC420-capable client and repeat the actual trigger:

1. follow the handover journal and preserve all `RDP.PIPELINE`,
   `HWAccel.FFmpeg`, `Hardware encode`, and `Failed to lock bitstream` lines;
2. start Firefox, open/resize several content-heavy pages, switch tabs, scroll,
   play video, and toggle full-screen for at least ten minutes;
3. confirm the remote image and input remain responsive, the client stays on
   AVC420, and submitted-frame counters continue advancing;
4. if a hardware timeout is injected or occurs naturally, require a failure
   within about 500 ms, a hardware-cooldown log, continued CAPROGRESSIVE
   software frames, and a later successful hardware retry; and
5. disconnect/reconnect the macOS Windows App once after the stress run to
   cover the independent handover fixes carried by the same package.

A freeze is not accepted as fixed from process liveness alone. During the test,
`journalctl -k` must remain free of codec/GPU/IOMMU faults, the independent
pipeline watchdog must keep logging if submission stops, and the RDP socket's
`bytes_sent` must continue increasing during visible motion.

## 10. exp6/exp7 macOS focus/resume gate

Patches `0018` and `0019` target two separate focus-return failures. Windows
App can suspend RDPGFX frame acknowledgements while it is in another macOS
desktop, then resume with enough reconstructed history to leave GRD throttled
at zero frame slots. Independently, the first new view after an idle interval
can be charged against the old pre-idle hardware-submission timestamp and
immediately trigger a false pipeline-starvation cooldown.

The first live pass used installed `exp6@7e958e6`. Its ACK watchdog fired once
with two stalled acknowledgements, forced refresh, and restored hardware
submissions, validating that recovery. GDB also caught the separate false
42.493-second starvation decision exactly. Repeat the combined gate with final
`exp7@3e4480e` and the matching FFmpeg pair:

```bash
dpkg-query -W -f='${Package}\t${Version}\n' \
  libavcodec62 gnome-remote-desktop
journalctl --user -u gnome-remote-desktop-handover.service -f \
  -o short-iso --no-pager
```

The final GRD version must be
`50.1+rkmpp+git20260720.8.3e4480e-0ubuntu1~exp7`, and `libavcodec62` must be at
least `7:8.0.3+rockchip+git20260719.da5befc806-0ubuntu1~rk1`.

1. Connect from macOS Windows App and confirm AVC420/hardware encode using §7.
2. Start YouTube or another continuously changing full-screen workload.
3. Switch to a different macOS desktop for 15–30 seconds, return to Windows
   App, and repeat several times.
4. Require the image and input to remain live after every return. A short burst
   of accumulated frames is useful evidence but is not itself a failure.
5. Preserve all `[RDP.RDPGFX.ACK]`, `[RDP.PIPELINE]`, `[HWAccel.FFmpeg]`, and
   `Hardware encode` journal lines.

Expected transition logs include `Frame acknowledgements suspended` and `Frame
acknowledgements resumed`. If the client resumes but makes no decode progress,
the bounded recovery must emit `No frame-ack progress for 2000 ms`, return the
surface to an unthrottled state, force a full refresh, and continue hardware
frames. A focus return must not immediately emit `Hardware encode is
unavailable (pipeline starvation)` with a duration inherited from the time
spent away; a genuine continuously outstanding stall may still fire after the
normal three-second threshold. A disconnected session, repeated recovery loop,
software-only continuation, stalled socket, or kernel codec/GPU/IOMMU fault
fails the gate.

The core-backed diagnosis and exact counters are recorded in the
[focus/resume acknowledgement finding](../../../findings/2026-07-20-grd-rdpgfx-focus-resume-ack-wedge.md).
The independently captured false-actuator transition is recorded in the
[focus-return pipeline-starvation finding](../../../findings/2026-07-20-grd-focus-return-false-pipeline-starvation.md).
