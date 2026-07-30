# gnome-remote-desktop/bench/

Micro-benchmarks behind [`apps/gnome-remote-desktop/docs/baseline.md`](../docs/baseline.md) — the measured case
for why GRD's software path on RK3588 is CPU-bound and why hardware encode is the
fix.

## `readback_bench.c`

Times the full-frame GPU→CPU readback that GRD performs once per frame on its
software path (`grd-egl-thread.c:963`, `glReadPixels(…, GL_BGRA, …)`), three ways:

1. **sync `glReadPixels(BGRA)`** — exactly what GRD does today.
2. **sync `glReadPixels(RGBA)`** — same, no B↔R swizzle (isolates the swizzle cost).
3. **async PBO + fence + map + copy** — the async-readback route, with per-stage
   timing (`t_issue` / `t_fence` / `t_map` / `t_copy`).

It uses a **surfaceless** desktop-GL context (`EGL_MESA_platform_surfaceless`),
so it touches neither mutter nor any RDP session — safe to run on the live box.
It reads a plain RGBA8 FBO, not mutter's real AFBC/tiled capture surface, so
treat the numbers as a bound rather than the exact in-situ cost (see baseline.md
§"What the benchmark does and does not measure").

```bash
cc -O2 -o readback_bench readback_bench.c -lEGL -lGL
./readback_bench [width] [height] [iterations]      # default 1920 1080 60
MESA_COMPUTE_PBO=1 ./readback_bench                 # route detile+swizzle to GPU
```

### Reference results (Mali-G610 / panfrost / Mesa 26, 1080p)

| Config | sync BGRA | async total | `t_issue` | `t_fence` |
|--------|----------:|------------:|----------:|----------:|
| default Mesa | **19.9 ms** | 29.0 ms *(worse)* | 22.9 ms *(CPU detile)* | 0.0 ms |
| `MESA_COMPUTE_PBO=1` | **11.0 ms** | 11.4 ms | 0.15 ms | 5.1 ms *(GPU)* |

sync `RGBA` is ~8.4 ms in both, so **~11 ms of the default 19.9 ms is the B↔R
swizzle alone.** The default async `t_fence`≈0 proves stock panfrost does the
readback on the CPU (nothing to overlap on the GPU); `MESA_COMPUTE_PBO=1` is the
only config that moves the heavy part onto the (idle) GPU.

The Mesa follow-up is tracked in
[`../docs/mesa-panfrost-transfer.md`](../docs/mesa-panfrost-transfer.md), which
owns the live status. In short: the sampled BLIT transfer path is not bit-exact
on Mali-G610 (varying-interpolator drift on integer texel-coordinate readbacks),
and while COMPUTE avoids that interpolator, a **COMPUTE-only** fix was rejected in
**2026-07-01** maintainer review because compute shaders cannot write
AFBC-compressed resources — so the fix is being reworked toward a
`gl_FragCoord`-based blit. Either way, `MESA_COMPUTE_PBO=1` stays a valid
board-local mitigation for the numbers above.

## `rkmpp_lifecycle_bench.c`

Isolates the synchronous RKMPP encode stall described in
[`../docs/profiling.md`](../docs/profiling.md) §9 from Firefox, PipeWire, Vulkan,
and RDP. The bench retains the relevant GRD path:

- a 64-byte-stride, linear NV12 dma-buf allocated from `/dev/dma_heap/system`;
- an `AVDRMFrameDescriptor` passed zero-copy to `h264_rkmpp`;
- GRD's dimensions, rate-control triplet, high profile, no B frames, one
  reference, and `AV_CODEC_FLAG_LOW_DELAY`; and
- synchronous one-frame-in/one-packet-out encoding.

Its primary modes change only the encoder lifetime:

| Mode | Lifecycle | Question answered |
|---|---|---|
| `reuse` | open once → encode N frames → close | Is steady-state RKMPP healthy? |
| `churn` | N × (open → encode one → close) | Does rapid context teardown/recreation expose the stall? |
| `exp2` | churn plus an idle second open/close per iteration | Does GRD `~exp2`'s exact post-smoke IDR workaround matter? |

The process that calls FFmpeg is a child. A parent watchdog treats any phase
with no output for 500 ms as a stall, emits `watchdog_timeout`, leaves a
two-second capture window, and sends `SIGKILL` only to the child. It then waits
at most 250 ms to reap the child and reports either `watchdog_worker_reaped` or
`watchdog_worker_unreaped`. This makes the parent bounded even if the encoder
task is stuck in uninterruptible kernel sleep. An older FFmpeg can still have
an infinite synchronous RKMPP wait inside the child.
The JSONL event immediately before `watchdog_timeout` identifies whether the
stall occurred in open, send, receive, or close.

Use the wrapper so the A/B run also captures RKVENC interrupts, task wait
channels/kernel stacks (when permitted), package identity, and kernel logs. It
deliberately never reads `/proc/mpp_service`: on an unpatched kernel, a procfs
read concurrent with MPP session teardown can NULL-dereference in
`rkvenc_dump_session()`.

```bash
# First disconnect every RDP session. Running as root improves kernel capture.
sudo ./rkmpp_lifecycle_experiment.sh compare --iterations 1000

# Reproduce the old GRD open/smoke/close/open sequence specifically.
sudo ./rkmpp_lifecycle_experiment.sh exp2 --iterations 1000

# If the basic run reproduces, log MPP worker wait/notify decisions too.
sudo ./rkmpp_lifecycle_experiment.sh --mpp-enc-debug 0xb0 \
  churn --iterations 1000

# Causal control: retain churn but omit MPP_ENC_SET_IDR_FRAME.
sudo ./rkmpp_lifecycle_experiment.sh churn --no-force-idr --iterations 1000
```

Artifacts default to
`$ROCK5B_WORKSPACE/rkmpp-lifecycle-runs/TIMESTAMP`, with
`ROCK5B_WORKSPACE=~/Code/rock-5b` by default; neither build nor capture data
uses `/tmp`. An idle `--system` daemon is allowed, but the wrapper
refuses to run when it sees a handover daemon, an established RDP connection,
or a GRD process holding `/dev/mpp_service`, unless explicitly overridden.

Interpretation:

- `reuse` passes and forced-IDR `churn`/`exp2` stalls: inspect the last phase and
  MPP debug ordering rather than assuming a lost hardware completion.
- forced-IDR churn stalls while `--no-force-idr` churn passes: isolate the
  trigger to the per-frame `MPP_ENC_SET_IDR_FRAME` control immediately before
  input enqueue. Use `--mpp-enc-debug 0xb0` to capture control/wait ordering.
- both modes stall at `receive_begin`, with a submitted/running task but no IRQ:
  focus on interrupt/completion/timeout recovery.
- a churn stall has no new RKVENC interrupt and the worker waits for input:
  check whether input enqueue returned `MPP_NOK`/`EAGAIN` before looking for a
  scheduler or interrupt loss.
- both modes pass: the trigger needs another GRD condition (more concurrent
  surfaces, Vulkan producer fences, or the Firefox reset cadence), or is too
  rare for that iteration count.

This is intentionally a stress experiment, not a normal smoke test. Although
the userspace wait is bounded, a vulnerable kernel may leave the encoder
unhealthy until reset. Do not run it against a live desktop session.

### 2026-07-17 reference result

On the ROCK 5B, `reuse --iterations 100` completed with one RKVENC interrupt
per frame. Forced-IDR churn reproduced twice after 360 and 364 completed
iterations, both at `send_begin`, with no new hardware task or interrupt. With
`mpp_enc_debug=0xb0`, the last ordering was:

1. FFmpeg issued `MPP_ENC_SET_IDR_FRAME`.
2. libmpp acknowledged the control command before releasing `mFrmIn->cond_lock`.
3. FFmpeg immediately called `encode_put_frame()`; libmpp's trylock failed and
   returned `MPP_NOK`, which FFmpeg mapped to `EAGAIN`.
4. The low-delay encode path nevertheless called blocking
   `encode_get_packet()`. No input frame had been queued, so no packet or IRQ
   could arrive; the MPP worker later slept waiting for input.

This is a userspace control/input handoff race, not hundreds of milliseconds of
hardware encode and not a lost completion. The root libmpp fix is to acknowledge
the control only after the input lock and post-control work are complete. FFmpeg
must also avoid a blocking packet receive when frame submission returned
`EAGAIN`; its existing 500 ms deadline remains useful containment.

The no-forced-IDR control completed 546 iterations before the old wrapper's
high-frequency `/proc/mpp_service/sessions-summary` sampler raced the next
session teardown and triggered the separate kernel Oops documented in
[`../../../findings/2026-07-17-mpp-procfs-session-teardown-oops.md`](../../../findings/2026-07-17-mpp-procfs-session-teardown-oops.md).
That run cannot be counted as a 1,000-iteration pass. Repeat it only after
rebooting into a kernel with the procfs lifetime fix.
