# Baseline — why the software path is slow, measured

The [`README.md`](README.md) and [`DESIGN.md`](DESIGN.md) describe the hardware
encode backend and *why* it exists. This is the third companion: the **measured
"before."** It quantifies exactly why GRD's software fallback on an RK3588 is a
"laggy, CPU-bound desktop," locates the single operation responsible, and records
the software-only mitigations we evaluated and **rejected** on the way to
deciding that hardware encode (the rest of this repo) is the only real fix.

> **One sentence.** On stock RK3588, GRD spends **~20 ms per frame at 1080p**
> doing one thing — a `glReadPixels` GPU→CPU copy — and that single copy is
> **~90 % of the daemon's CPU**; it exists *only* because the software RFX
> encoder needs the pixels in a CPU buffer, and hardware encode deletes it
> outright by consuming the GPU dma-buf directly.

All numbers below were measured on this box (Radxa ROCK 5B, Mali-G610 MC4,
Panfrost, Mesa 26.0.3, OpenGL 3.1; full spec in [`TESTING.md`](TESTING.md) §0)
with the harness in [`bench/readback_bench.c`](bench/readback_bench.c), re-run
live while writing this doc.

> **Companions.** [`CAPTURE-PATH.md`](CAPTURE-PATH.md) maps *where* in GRD's code
> this readback lives (the view-creators, the encode-session selection, the
> PipeWire negotiation). [`TESTING.md`](TESTING.md) is the playbook for measuring
> it without evicting your session.

---

## 1. The bottleneck is one operation

With no VA-API, no NVENC, and (before this repo) no working Vulkan path, GRD
falls back to **software RemoteFX-progressive (RFX)** encoding. Software encode
runs on the CPU, so every captured frame must be brought from GPU memory into a
CPU-readable buffer first. GRD does that with a single blocking call in its EGL
thread:

```c
// grd-egl-thread.c:963  (read_pixels, on the DMA-BUF / gen-gl path)
glReadPixels (0, 0, width, height, GL_BGRA, GL_UNSIGNED_BYTE, dst_data);
```

That one call is the whole story. Measured cost of the full-frame readback:

| Resolution | Bytes/frame | `glReadPixels(BGRA)` | vs. a plain `memcpy` |
|-----------:|------------:|---------------------:|---------------------:|
| 720p  | 3.7 MB | **8.5 ms** | ~27× |
| 1080p | 8.1 MB | **19.9 ms** | ~30× |
| 1440p | 14.7 MB | **34.1 ms** | ~31× |

At 1080p/30 fps that is ~60 % of a CPU core spent purely relocating pixels,
before a single bit of compression. The live proof, captured earlier with a
**real** macOS RDP client driving a 1080p session over the software path:

```
gnome-remote-desktop daemon:  100.7 % CPU
  └─ "GRD EGL thread":          90.9 % CPU   ← the readback
```

The EGL thread — which does essentially nothing *but* this readback — accounts
for ~90 % of the daemon. Compression, RDP framing, and everything else share the
remaining sliver. **The readback is the pipeline.**

---

## 2. Why it is slow — it is *not* the transfer

The intuitive guess ("copying across the GPU/CPU boundary is expensive") is
wrong here. RK3588 is a **UMA** part — CPU and GPU share the same physical DRAM —
so there is no bus copy to pay for. The `memcpy` column above (~0.6 ms at 1080p)
is what moving 8 MB of RAM actually costs. The other **~19 ms is not movement**;
it is three CPU-side transforms on the way out:

1. **De-tiling.** Mutter's capture buffer is not linear. Depending on the
   modifier it is tiled (u-interleaved) or AFBC-compressed; either way the bytes
   must be reordered into linear scanlines. panfrost does this on the CPU, single
   threaded, scalar. (For AFBC there is no software decoder at all — panfrost
   instead does a GPU staging blit to a linear texture plus a full pipeline
   stall; for tiled it is a CPU detile loop.)
2. **The B↔R swizzle.** GRD asks for `GL_BGRA`; the surface is RGBA. That
   channel swap is a *separate* Mesa state-tracker pass. The benchmark isolates
   it precisely: **RGBA readback is 8.4 ms, BGRA is 19.9 ms** — so **~11 ms, over
   half the cost, is just the byte-order swap.**
3. **Uncached reads.** The CPU mapping of the GPU buffer is write-combine /
   uncached, so the read itself is slow per byte relative to cached DRAM.

### Which cost you pay depends on the modifier

The detile cost is not one number — it depends entirely on the **DRM format
modifier** of the surface mutter hands over. panfrost has **no** software AFBC
routines (`pan_resource.c`), so the three cases are genuinely different code
paths, not degrees of the same one:

| Surface modifier | What panfrost does on readback | Relative cost |
|---|---|---|
| **AFBC / AFRC** (compressed) | GPU blit to a LINEAR staging texture **+ full pipeline stall** (`panfrost_bo_wait`, `INT64_MAX`) + copy — *no* CPU decompress | highest, and it stalls the GPU |
| **Tiled** (u-interleaved) | scalar, single-threaded **CPU detile** loop (memcpy/pixel) | high (this is the ~19 ms case) |
| **Linear** | direct pointer — no reorder | cheapest |

The B↔R swizzle is a *separate* Mesa state-tracker pass on top of whichever of
these runs — which is why the benchmark, reading a plain linear RGBA8 FBO, still
shows an 8 → 20 ms jump between `RGBA` and `BGRA`.

> **The one un-profiled question that decides the real bottleneck:** which
> modifier does mutter's screencast dma-buf actually carry — AFBC, tiled, or
> linear? Real GRD reads native `BGRA` from mutter's buffer, so it may *not* pay
> the swizzle the benchmark shows; but if the buffer is AFBC it pays a GPU stall
> the benchmark's linear FBO never triggers. Profiling that on the real path (see
> [`TESTING.md`](TESTING.md)) is the highest-value open measurement. Forcing a
> **LINEAR** capture surface would sidestep the detile entirely — the one
> in-process lever that attacks the mechanism rather than relocating it.

### The root cause: a never-implemented Mesa capability

panfrost could push the detile+swizzle onto the GPU's compute engine (which sits
idle during a software encode) instead of the CPU. It doesn't, because it never
advertises the capability:

```c
// mesa: src/gallium/drivers/panfrost/pan_screen.c:828
caps->texture_transfer_modes = 0;   // unconditional, since the 2019 driver stub
```

This is **not an intentional disable** — it is inherited unchanged from the
original driver skeleton, with no rationale comment. We investigated this in
Mesa MR **!42563**. The first finding was a real Panfrost shader-image unbind
bug exposed by GPU texture transfers; that is fixed separately in the MR. The
second finding was that the tempting `BLIT` transfer cap is not safe on
Mali-G610 for integer readback/format-conversion paths.

The sampled `u_blitter` path compiled to the expected Mali varying load,
`LD_VAR_IMM.slot0.v4.f32.center...`, followed by `F32_TO_S32.rtz` and
`TEX_FETCH`. The problem is not an obvious compiler bug: the interpolated
coordinate from `LD_VAR_IMM` drifts by about `2^-10`, so a 16307-wide integer
readback selects previous texels for 15672/16307 samples. The fix direction is
therefore **COMPUTE**, not BLIT: compute uses integer invocation coordinates and
bypasses the varying interpolator. Full notes:
[`MESA-PANFROST-TRANSFER.md`](MESA-PANFROST-TRANSFER.md).

> **What `MESA_COMPUTE_PBO=1` actually does.** It is the manual override of
> exactly this gap. Mesa's `st_pbo.c` normally uses the compute path only when the
> driver advertises `PIPE_TEXTURE_TRANSFER_COMPUTE` (the `texture_transfer_modes`
> cap above) — which stock panfrost did not — but it also reads the `MESA_COMPUTE_PBO`
> environment variable via `debug_get_option` and, when set, takes the compute
> path regardless of the cap. So the env var force-enables the GPU-compute
> detile+swizzle that the driver *could* do but never opts into. It is an
> **internal/debug knob**, not a documented or supported user setting, which is
> why there is essentially no documentation for it and why it can't be relied on
> as a shipping configuration.

If Mesa !42563 lands in COMPUTE form, this debug override should no longer be
needed for Panfrost texture transfers: the driver would advertise the compute
path directly.

---

## 3. The measurement

[`bench/readback_bench.c`](bench/readback_bench.c) reproduces the exact operation
(`glReadPixels` of a full frame) in a surfaceless desktop-GL context, timed three
ways. It touches neither mutter nor any RDP session, so it is safe to run on the
live box. Fresh output from this machine at 1080p:

**Default Mesa:**
```
sync glReadPixels BGRA :  19.92 ms   (grd today)
sync glReadPixels RGBA :   8.43 ms   (delta = B<->R swizzle ≈ 11.5 ms)

async PBO+fence total  :  28.99 ms   ← WORSE than sync
  t_issue (readpixels) :  22.86 ms   ← CPU detile happens HERE (no GPU offload)
  t_fence (GPU wait)   :   0.00 ms   ← nothing ran on the GPU
  t_copy (memcpy out)  :   6.13 ms
```

**`MESA_COMPUTE_PBO=1`** (routes detile+swizzle through a GPU compute shader):
```
sync glReadPixels BGRA :  11.01 ms   ← ~½ the default, zero code change
async PBO+fence total  :  11.42 ms
  t_issue (readpixels) :   0.15 ms   ← cheap: work deferred to GPU
  t_fence (GPU wait)   :   5.13 ms   ← real GPU work overlapped here
  t_copy (memcpy out)  :   6.13 ms
```

Two things fall out of this immediately, and they drive §4:

- The default PBO `t_fence` is **0.00 ms** — proof that on stock panfrost the
  "async" readback does its work on the *CPU* during `t_issue`; there is nothing
  on the GPU to overlap with. Async without the compute path is pure overhead.
- `MESA_COMPUTE_PBO=1` moves the heavy part onto the GPU: `t_issue` collapses
  from 22.9 ms to 0.15 ms and reappears as a 5.1 ms GPU `t_fence` the thread can
  *sleep* on. That is the only configuration in which the async route helps.

---

## 4. Software-only levers we evaluated (and why none suffice)

Everything here keeps the software encoder and tries to make the readback hurt
less. Ranked by return:

| Lever | Effect | Verdict |
|-------|--------|---------|
| **`MESA_COMPUTE_PBO=1`** | GPU does the detile+swizzle; readback **19.9 → 11 ms**, zero code | Highest ROI, but an **undocumented Mesa test override** — not a shipping config. Not yet validated on GRD's *real* AFBC dma-buf (see §5). |
| **async PBO + fence** (prototyped, `GRD_ASYNC_READBACK`) | Lets the EGL thread *sleep* on the GPU fence instead of burning a core — **only** together with `MESA_COMPUTE_PBO=1` | On default Mesa it is **worse** (29 vs 20 ms). GRD's RFX consumer is **single-in-flight** (frame N+1 isn't issued until N's callback returns), so a PBO ring gives **no** cross-frame pipelining. Do **not** ship default-on. |
| **MemFd instead of DMA-BUF** (prototyped) | Avoids GRD's readback entirely — capture arrives in a CPU shm buffer | **Relocates, doesn't remove.** Mutter then does the *same* `glReadPixels` in gnome-shell to fill the shm buffer. Net system CPU is conserved; the only gain is moving the 19 ms off GRD's bottleneck thread onto another process. |
| **Force LINEAR capture + native BGRA** | Skips the detile (linear) and/or the swizzle (native order) | Real in-process win, but bounded — the uncached-read cost remains, and it depends on what mutter will negotiate. Never reduces *total* work like HW encode. |

### The MemFd prototype, in detail

Swapping GRD from DMA-BUF to MemFd is a ~2-line producer/consumer negotiation
change, and it **works** once done correctly — but it was instructive mainly for
what it *doesn't* buy:

- The naive change touches only `allowed_buffer_types` at
  `grd-rdp-pipewire-stream.c:536` (forcing `SPA_DATA_MemFd`) but leaves
  `add_format_params` (`:327`) still advertising a **modifier-bearing (DMA-BUF)**
  `EnumFormat`. Mutter fixates the modifier format and builds buffers with
  `dataType = 1<<SPA_DATA_DmaBuf`; GRD demands `1<<SPA_DATA_MemFd`;
  `8 & 4 = 0` → empty param intersection → libpipewire
  `error alloc buffers: Invalid argument`. The fix is to gate **both** blocks
  (e.g. on `!g_getenv("GRD_FORCE_MEMFD")`), after which the session establishes
  on the `gen-sw` (direct-mmap, no-readback) path.
- But mutter's MemFd path fills the shm buffer with its **own** cogl/`glReadPixels`
  read, so the ~19 ms simply **moves into gnome-shell** (corroborated by mutter
  issue #2745 — the non-dmabuf screencast path *is* the slow readback on ARM, and
  by a paired run here where the load shifted from GRD to gnome-shell). So "add
  MemFd support to mutter" was the wrong question: there is nothing to add, and
  the swap doesn't cut total work.

**Net:** the software path has exactly one deep lever (`MESA_COMPUTE_PBO`, and it
is not a supported knob) and several shallow ones that relocate rather than
remove the cost. None of them make a 1080p desktop feel native. That is the
empirical case for the hardware backend.

---

## 5. What the benchmark does and does *not* measure

Honest bounds on the numbers above:

- It reads a plain **RGBA8 FBO**, not mutter's real capture surface. The real
  buffer carries whatever **modifier** mutter negotiated (AFBC vs tiled vs
  linear), and *that* determines whether the real path pays a CPU detile, a GPU
  staging blit + stall, or nothing. So these numbers are a **lower bound** on the
  real detile cost and an **upper bound** on the swizzle (real GRD may read
  native BGRA and skip it). **The key un-profiled question remains: which
  modifier does mutter's screencast dma-buf actually use?** That decides the true
  in-situ bottleneck.
- End-to-end daemon CPU is hard to reproduce headlessly: a synthetic glxgears
  window does **not** reliably make mutter deliver steady screencast frames to a
  virtual monitor (GRD often idles near 0 % despite glxgears at 900 fps). The
  trustworthy live figure remains the **100.7 % daemon / 90.9 % EGL-thread**
  captured with a real client driving the session.

---

## 6. Why hardware encode is the actual fix

Every software lever above either relocates the readback or shaves it. Hardware
encode **deletes** it: the VEPU580 consumes the capture dma-buf directly (after
an RGB→NV12 step that is itself a GPU compute pass, not a CPU copy), so the frame
never has to land in a CPU buffer at all. There is no `glReadPixels`, no CPU
detile, no swizzle — the ~20 ms/frame at 1080p goes to **zero**, which is exactly
why the same desktop drops from a CPU-bound ~100 % daemon to a few percent.

That is the entire subject of this directory:

- The backend that consumes the dma-buf on the VEPU580 → [`README.md`](README.md)
  and patches [`0001`–`0003`](patches/).
- Unblocking the Mali GPU so the shared RGB→NV12 view-creator exists at all
  (the Vulkan/panvk probe rejection) → [`DESIGN.md`](DESIGN.md) and patches
  [`0004`–`0006`](patches/). **Note:** on the *pure software* box that probe
  rejection looked harmless — its only consumer was the absent VA-API encoder —
  but it is precisely what gates the view-creator that the rkmpp backend needs
  too, which is why fixing it was load-bearing here.
- The device-permission side of reaching `/dev/mpp_service` + `/dev/dma_heap`
  (root-only, no `uaccess` ACL — the greeter bug) → [`README.md`](README.md) #3
  and [`../packaging/gdm-hwenc/`](../packaging/gdm-hwenc/).

### Footnote: why this slowness is essentially unreported upstream

The RK3588 community never hits it because it never reads back through the GPU:
the standard pattern is **capture KMS dma-buf → HW VPU encoder (rkmpp/MPP) + RGA
colour-convert, zero-copy** (ffmpeg-rockchip, gstreamer `rockchipmpp`, Jellyfin).
Slow panfrost readback only bites an application like GRD that *does* pull pixels
back to the CPU — and the answer to that is the same zero-copy HW path this repo
builds, not a faster memcpy.

---

## 7. Reproduce

```bash
cd gnome-remote-desktop/bench
cc -O2 -o readback_bench readback_bench.c -lEGL -lGL

./readback_bench 1920 1080 60                 # default Mesa
MESA_COMPUTE_PBO=1 ./readback_bench 1920 1080 60   # GPU-offloaded detile+swizzle
./readback_bench 1280 720                      # other resolutions
```

This micro-benchmark is safe on the live box (surfaceless — it never touches
mutter). A **live A/B against the real daemon** is a different, hazardous
exercise: mutter's RemoteDesktop API *evicts* an existing session, so it must be
run with **no** other RDP client connected, and driving frames headlessly is
unreliable. The full procedure — environment setup, swapping in a manual build,
the eviction hazard, killing safely, and why the headless numbers are soft — is
in [`TESTING.md`](TESTING.md). The two prototype worktrees (`grd-async-pbo-wt`,
`grd-memfd-wt`) carry the opt-in env toggles (`GRD_ASYNC_READBACK`,
`GRD_FORCE_MEMFD`) referenced above.
