# GRD's frame-starvation detector only warns — it never actuates recovery

> Scope: gnome-remote-desktop `50.1+rkmpp+git20260717.2571326-0ubuntu1~exp3`
> (branch `fix/frame-starvation-v2` @ `2571326`, i.e. patch series `0001`–`0015`)
> on the ROCK 5B, VEPU580 hardware H.264 encode backend
> Source: live `[RDP.PIPELINE]` daemon diagnostics during KASAN MPP suite run
> `20260718-103917`, plus `src/grd-rdp-renderer.c` from the shipping branch
> Date: 2026-07-18
> Trust: MEASURED (live pipeline counters) / CODE-INSPECTED (shipping source) /
> CONFIRMED (recovery trigger enumeration)

## Result

Running the MPP encode conformance suite while a remote-desktop session was live
wedged gnome-remote-desktop: graphical artifacts, no frame progress. The
`0008`/`0014`/`0015` "recover from stalled hardware encoding" work — built
precisely to fall back to software when hardware encode stalls — **did not
recover the session.** The design gap is structural, not a tuning problem: the
frame-starvation detector is **diagnostic-only**, and the recovery it should
have driven can only be triggered by a hardware encode that *completes*.

## What the pipeline counters showed

The daemon logged `[RDP.PIPELINE]` lines once per second for ~90s without
recovering. Representative:

```
buffers=11027 (climbing)   queued=10819 (climbing)      ← capture still producing
views=9245/9244                                          ← one view in flight, not completing
encodes=8486/8486(serial=10205, last-us=1151)            ← NO encode in flight
submitted=8483(serial=10205)                             ← submission frozen at serial 10205
ages-ms(submit=85890)                                    ← last submit ~86s ago and growing
reset-waits=5  cooldown=3/3
```

Key reading: `encodes_started == encodes_completed` (8486/8486) means **no
hardware encode is in flight**. The stall is upstream/downstream of the encoder
— the **view/submission stage** (`views_started 9245 > views_completed 9244`,
`submitted` frozen three frames behind `encodes_completed`). The hardware
encoder itself is idle (kernel `rkvenc-core0/1` empty, zero KASAN all boot); the
last encode completed normally in 1151µs.

## Root cause

In `grd-rdp-renderer.c`, `log_pipeline_diagnostics()` computes:

```c
has_outstanding_work =
    diagnostics.views_started   > diagnostics.views_completed ||
    diagnostics.encodes_started > diagnostics.encodes_completed;
if (has_outstanding_work && <no submit for THRESHOLD> && <warn interval>)
    warn_about_starvation = TRUE;
...
if (warn_about_starvation)
    g_warning ("[RDP.PIPELINE] Suspected frame starvation: ...");
return G_SOURCE_CONTINUE;
```

That is the **entire** starvation path: it sets a flag and logs. It never calls
`start_hw_encode_cooldown()`, never requests a full refresh, never resets the
render context, never drops the outstanding stale frame.

Software fallback (`start_hw_encode_cooldown`) has exactly **two** callers, both
requiring a hardware encode to *complete*:

1. `note_hw_encode_duration()` — when a completed HW encode's lock duration
   crosses `HW_ENCODE_STALL_THRESHOLD_US` (250 ms) once, or the slow-sample
   threshold repeatedly.
2. `on_bitstream_locked()` with `bitstream == NULL` — a completed HW encode that
   returned an error.

Both need an encode to finish. In this stall **no encode is in flight**
(`encodes 8486/8486`), so neither can ever fire. `has_outstanding_work` is true
only via the *view* stage. The recovery machinery and the stall condition are
disjoint: the one detector that trips (starvation) has no actuator, and the two
actuators that exist (slow-complete, error-complete) can't trip.

## Why the intended fallback missed this scenario

`0008`/`0015` were built for the **Firefox self-stall**: GRD's own WebRender
capture caused a *hardware encode* to run slow or error, which the
completion-based triggers catch. This wedge is a **different shape** — an
external process (the MPP encode conformance suite) monopolized the VEPU for
180 s, and GRD's strict 1-in-1-out gate stopped starting new encodes while a
view/submission frame was outstanding. No encode completes ⇒ no completion-based
trigger ⇒ the only thing that notices (the starvation detector) merely logs.
The FFmpeg bounded-low-delay-wait dependency (`540657970e`) is satisfied and is
not the issue; the installed `libavcodec.so.62` is that exact build.

## Fix direction

Make the starvation detector an **actuator**, not just a logger. When
`has_outstanding_work` persists past a recovery threshold (longer than the warn
threshold), the diagnostics watchdog should:

1. force the software-encode cooldown (`start_hw_encode_cooldown`, reason
   "pipeline starvation"), so subsequent frames use RFX/CAPROGRESSIVE and bypass
   the contended VEPU;
2. unstick the pipeline itself — drop the outstanding stale view/frame, reset
   the render context, request a full refresh, and force an IDR — since forcing
   software encode alone does not clear a view/submission-stage stall;
3. rate-limit the recovery (escalate only after N consecutive warns) so a brief
   contention blip does not thrash into software.

This makes external VEPU contention — a **supported, to-be-tested scenario**, not
one to avoid — survivable: the session degrades to software and keeps moving
instead of wedging. Implement on `fix/frame-starvation-v2` as the next patch in
`apps/gnome-remote-desktop/patches/` (0016), rebuild the exp PPA package, and
verify by deliberately contending the VEPU (run the encode suite) while a session
is live and confirming the session degrades and recovers rather than wedging.

## CORRECTION (2026-07-18, after testing exp4 / patch 0016)

The fix above was built and installed (exp4) and **did not cure the wedge**, and
live testing showed the original diagnosis was only partly right. On exp4 the
starvation actuator's own cooldown never won the race (`start_hw_encode_cooldown`
returned FALSE because a cooldown was already active), yet `cooldown=4/3` shows
the software-fallback cooldown *was* firing repeatedly via the pre-existing
slow-encode trigger — and the session **still** wedged. So the real problem is
not "recovery never triggers"; it is that **the recovery action cannot clear
this wedge**.

The wedge is a **two-gate deadlock** in `grd-rdp-surface-renderer.c`, triggered
by a single **view that hangs** (the RGB→NV12 conversion / render view — likely
Mali/panvk GPU contention under heavy load; it reproduced on **YouTube alone**,
no VEPU contention). That stuck view holds a **frame slot** and an **acquired
buffer**, and both recovery mechanisms are gated behind exactly those:

- `maybe_apply_full_refresh()` defers while `n_acquired_buffers > 0` → the full
  refresh never applies (`refresh=157/439`, deferrals climbing).
- `can_prepare_new_frame()` returns `total_frame_slots > used_frame_slots`; the
  held slot keeps it false, so `maybe_render_frame()` returns *before* the
  `GRD_RDP_ACQUIRE_CONTEXT_FLAG_FORCE_RESET` path (line ~875). The render-context
  reset that would reclaim the view never runs.

So the stuck view can only be cleared by the reset/refresh, and the reset/refresh
are blocked by the stuck view. The cooldown/software fallback (and patch 0016)
operate on the *encode* stage and never touch this, which is why nothing recovers.

**Revised fix direction:** on sustained stall, **force-reclaim** the stuck frame
slot and acquired buffer — abandon the in-flight hung view, release its slot and
buffer, then apply the render-context reset — bypassing the two gates. Open
question underneath: *why* the view hangs (GPU fence/timeout on the panvk
conversion under panfrost contention); force-reclaim recovers from it but a
fence-timeout on the conversion would also be worth bounding. Patch 0016 is
**ineffective as-is** and should be reworked into (or replaced by) the
force-reclaim fix, not shipped on its own.

## ROOT CAUSE FOUND (2026-07-18, gdb capture of the live wedge)

A watchdog auto-attached gdb to the wedged session daemon (yi-owned, PID 75635)
during a live ~85 s hang. The captured thread states are decisive:

- **"GRD EGL thread"** — `syscall=[running]`, `wchan=0`, **99.9 % CPU**, and stuck
  at the *same* `libgallium-26.0.3` frames across two samples (frame #0 at a
  ~4-byte-apart PC = a tight loop). It had burned **5+ minutes of CPU time**.
  It is **busy-spinning inside Mesa/panfrost**, not blocking. Spin site:
  `libgallium` **offset `0x436820`** (base `0xffff80eb0000` this run).
- **"View creation thread"** — `syscall=98` (futex), `wchan=futex_do_wait`,
  blocked in `g_cond_wait` waiting for the EGL thread to finish.

So the wedge is a **hard CPU spin in the Mesa/panfrost GL driver** on GRD's EGL
thread (the GL capture/import/readback path). The view-creation thread waits on
it via a condition variable, the view never completes, and the whole RDP
pipeline stalls (the frame slot + acquired buffer stay held → the two-gate
deadlock above is a *symptom*, downstream of this spin). The trigger is **GPU
contention** — panthor (Mali-G610) saturated by YouTube's video decode/composite
starves the sync the Mesa GL op spins on; panthor logs **no** job timeout/fault,
consistent with a userspace busy-wait rather than a GPU hang. Reproduces on
YouTube alone; no VEPU/encoder involvement (the encoder threads are idle in
`WaitForMultipleObjects`).

**Symbolized (mesa-libgallium 26.0.3-1ubuntu1 dbgsym, build-id match).** The spin
is a CPU pixel-format conversion inside `glReadPixels`, full stack:

```
grd_egl_thread_func → egl_task_source_dispatch → download_in_impl   (grd-egl-thread.c)
  → glReadPixels/st_ReadPixels → read_rgba_pixels
    → _mesa_format_convert (format_utils.c:451) → convert_ubyte (format_utils.c:996)  ← 100% CPU
```

The exact call (`grd-egl-thread.c:963`):

```c
glReadPixels (0, 0, width, height, GL_BGRA, GL_UNSIGNED_BYTE, dst_data);
```

`download_in_impl` reads the captured frame back to CPU memory as
`GL_BGRA`/`GL_UNSIGNED_BYTE`. On panfrost the source texture's native format does
not match that, so Mesa cannot do a straight copy and falls into its **generic
scalar CPU converter** (`_mesa_format_convert`→`convert_ubyte`), which pins a
core at 100% for seconds-to-minutes on a full-resolution frame. That readback is
synchronous on the EGL thread; the view-creation thread blocks on it via a cond
var, so the view never completes and the pipeline wedges. GPU contention
(YouTube) correlates by changing timing/format negotiation and starving the
already-slow path — panthor itself never faults.

**Implication for the fix:** this is a **GRD capture/readback performance bug**,
not a recovery-logic bug — **patch 0016 is irrelevant to it**. Fix directions in
`download_in_impl`:
1. read back in the framebuffer's native format
   (`GL_IMPLEMENTATION_COLOR_READ_FORMAT`/`_TYPE`) so Mesa does a plain copy and
   the encode side handles any swizzle — eliminates `_mesa_format_convert`; or
2. avoid `glReadPixels` entirely — use the dma-buf/Vulkan zero-copy path
   (`grd-rdp-view-creator-avc`) that maps the captured buffer directly; or
3. the async PBO readback (`reference/async-pbo-prototype.patch`) if a CPU copy
   is unavoidable.
A Mesa-side improvement (SIMD `convert_ubyte`, or a fast BGRA path on panfrost)
would also help but is upstream and secondary.

### Why the convert takes seconds–minutes (Mesa dig, confirmed)

A scalar BGRA↔RGBA convert of one frame should be ~tens of ms, not minutes. The
extra cost is **uncached memory reads**, confirmed in the Mesa/panthor source:

1. `st_ReadPixels` rejects its fast blit path (format/base-format/`needs_slow_path`
   for BGRA-from-import) and falls to `_mesa_readpixels` → `_mesa_map_renderbuffer`
   (`GL_MAP_READ_BIT`) + `_mesa_format_convert`/`convert_ubyte`.
2. Panfrost maps a **linear** imported buffer **directly** (only AFBC/AFRC/tiled
   get a cached staging blit, `pan_resource.c`). The compositor's capture buffer
   is linear → direct map.
3. panthor maps its own BOs write-back **cached** (`DRM_PANTHOR_BO_WB_MMAP`), but
   **imported** dma-bufs are **uncached** — explicit in `panthor_kmod.c:471`:
   *"we've always assumed exporters were exposing uncached mappings…"*.
4. `convert_ubyte` then reads that **uncached** buffer **per pixel**. Uncached
   reads are ~100–300 ns each; millions of pixels ⇒ seconds per frame. YouTube
   produces frames faster than GRD can convert ⇒ backlog that never drains ⇒ the
   multi-second-to-minute "hang" (5+ min accumulated CPU), not one infinite loop.

**The additional Mesa bug:** `_mesa_format_convert` reads the source directly,
per-pixel, with no bulk/streaming read into a cached bounce (Mesa ships
`util/format/streaming-load-memcpy.h` for exactly the WC/uncached-source case but
the readpix fallback doesn't use it). So on any driver that maps the readback
source uncached (panthor imports here), the fallback is pathologically slow. A
panfrost fix (blit imported-linear to a cached staging for readback, as it
already does for AFBC) would also cure it. These are upstream Mesa/panfrost bugs,
independent of the GRD fix.

Evidence saved under `scratchpad/grd-hang-150509-pid75635/`
(`gdb-backtraces.txt`, `lib-bases.txt`, `egl-spin-frames.txt`).

### Fix verified (2026-07-18, exp5 / patch 0017)

Built `exp5` (`b3f0e20`, patch `0017`), installed, restarted the user handover
service, and reproduced with full-screen YouTube. Result: **the hang is gone.**
The GPU-copy path is taken (`readback target incomplete` fallback fired 0 times),
the EGL thread now **bursts and idles** (90% → 0%) instead of pinning at 99.9%
for minutes, and `submit` age stays < 1 s and self-recovers instead of climbing
to 45–117 s. Under peak video the software readback still saturates one core and
drops frames (`stale` high), so it is **laggy but fluid, never wedged** — a
performance limit, not a hang.

**Remaining (separate) work:** this session uses GRD's *software* readback path
(gen-gl `glReadPixels`) at all. The real performance win is keeping it on the
hardware AVC/rkmpp path (`grd-rdp-view-creator-avc`, dma-buf mapped straight to
the VEPU, no CPU readback → single-digit % CPU). Why it's on the software path
(client codec negotiation vs AVC-path fallback) is the next investigation.

## Related

- The contention was produced by the KASAN MPP suite
  (`kasan-mpp-suite.sh`); that run also confirmed the kernel is memory-clean
  under the full codec matrix (`0042`/`0043` hold, zero KASAN). The MPP-side
  functional anomalies observed in the same run (`mpi_dec_multi_h265` EINVAL,
  slice-encode timeouts) are entangled with this contention and need an isolated
  re-run once GRD is recovered.
