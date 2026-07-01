# gnome-remote-desktop/bench/

Micro-benchmarks behind [`../BASELINE.md`](../BASELINE.md) — the measured case
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
treat the numbers as a bound rather than the exact in-situ cost (see BASELINE.md
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
[`../MESA-PANFROST-TRANSFER.md`](../MESA-PANFROST-TRANSFER.md). In short, the
sampled BLIT transfer path was rejected because Mali-G610 varying interpolation
drifts by about `2^-10` on integer texel-coordinate readbacks; the COMPUTE path
avoids that interpolator and was slightly faster than BLIT in the local transfer
microbenchmarks.
