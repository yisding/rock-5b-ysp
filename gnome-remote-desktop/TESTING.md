# Testing & benchmarking GRD on this box — the playbook

Hard-won operational knowledge from benchmarking and prototyping GRD on the
ROCK 5B. Most of these cost us a broken session, a killed shell, or an hour of
"why is it idle" before we understood them. Read this before touching a live
daemon; the surfaceless micro-benchmark ([`bench/`](bench/)) is the only thing
here that is unconditionally safe.

## 0. The box

| | |
|---|---|
| SoC / board | RK3588, Radxa ROCK 5B — 4× Cortex-A76 + 4× Cortex-A55, 15.4 GiB |
| GPU / driver | Mali-G610 MC4, **Panfrost**, Mesa **26.0.3**, OpenGL **3.1** (GLES 3.1) |
| Kernel | 6.18.37-current-rockchip64, `cma=256M` |
| GRD | 50.1 |
| Session | Wayland (gnome-shell/mutter), RDP on port 3389/3390 |

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
- The micro-benchmark in [`bench/`](bench/) is exempt — it's a surfaceless GL
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

## 6. The safe micro-benchmark

[`bench/readback_bench.c`](bench/readback_bench.c) isolates the readback in a
**surfaceless** GL context — no mutter, no session, safe on the live box:

```bash
cd bench && cc -O2 -o readback_bench readback_bench.c -lEGL -lGL
./readback_bench 1920 1080 60
MESA_COMPUTE_PBO=1 ./readback_bench 1920 1080 60
```

This is how the numbers in [`BASELINE.md`](BASELINE.md) were obtained. It reads a
plain RGBA8 FBO, not mutter's real capture surface, so treat it as a bound (see
BASELINE §5).

## 7. Is it actually on hardware? — a quick checklist

When validating the rkmpp backend (this repo), confirm the HW path really engaged
rather than silently falling back to software RFX:

- **Threads:** the daemon has an `mpp_h264e` (or similar MPP) worker thread.
  `ps -T -p <pid>` / `top -H`.
- **FDs:** it holds an open `/dev/mpp_service` (and `/dev/dma_heap/*`) fd.
  `ls -l /proc/<pid>/fd | grep -E 'mpp_service|dma_heap'`.
- **Logs:** GRD's `g_debug`/`g_message` codec-selection tags show the chosen path
  (`[HWAccel.VAAPI]`, and this repo's FFmpeg/rkmpp tags). `g_message` always
  reaches the journal, no debug-env dance needed.
- **On the wire:** `ss -ti` on the RDP socket — `bytes_sent` growing in KB bursts
  = real frames flowing; flat = nothing (encoder stalled *or* client not acking —
  the bitstream dump distinguishes them, see [`README.md`](README.md) #1).
- **Fallback tell:** if you instrumented the selection point and see the buffer
  pass every gate yet still land on software, suspect the silent
  encode-session-*create* failure (a permission error on `/dev/mpp_service` /
  `/dev/dma_heap`, or a `vk_device` gate) — see [`CAPTURE-PATH.md`](CAPTURE-PATH.md)
  §3–4 and [`README.md`](README.md) #3.
