# Mesa all-blit workaround benchmark validates correctness but not per-blit cost

> Scope: `video-libraries/mesa`; Mesa MR !43161 all-blit depth-bias workaround on ROCK 5B / Mali-G610
> Source: YSP `ec44ae8` (`blit_workaround_bench.c` and `run_blit_workaround_bench.py`); Mesa `0c1cf4a71b4`
> Date: 2026-07-27
> Trust: MEASURED, BOARD-REPRODUCED, FIX-RUNTIME-VERIFIED, PARTIAL

## Result

The instrumented single-binary `PAN_BLIT_DEPTH_BIAS=off|on` A/B completed the
six phase-one `R32UI` sizes. Each size ran two ABBA/BAAB blocks, for eight
driver processes, with 11 accepted samples per point, two warmups, a four-pair
resource ring, and both batched-throughput and isolated-latency schedules.
All 48 processes used:

```text
GL_RENDERER=Mali-G610 MC4 (Panfrost)
GL_VERSION=OpenGL ES 3.1 Mesa 26.3.0-devel (git-0c1cf4a71b)
```

The matrix was run twice. The first pass produced 6,512 timing samples with
zero disjoint flags but could not lock devfreq. The second pass repeated the
same 48-process matrix with `--expect-gpu-hz 500000000`: all 108 runner clock
checks reported min, max, and current at exactly 500 MHz; all 6,512 samples
again had zero disjoint flags. Correctness was identical in both passes,
separating the A/B at both known-problem geometries: every off process failed
with the same mismatch count and every on process was exact. The ordinary and
display sizes were exact in both modes.

| Size | Counts | Off result per process | On result per process |
|------|--------|------------------------|-----------------------|
| `256x256` | `1,2,4,8,16,64,256` | `0 / 262144` mismatches | `0 / 262144` |
| `1024x1024` | `1,2,4,8,16,64` | `0 / 4194304` | `0 / 4194304` |
| `1920x1080` | `1,2,4,8,16` | `0 / 8294400` | `0 / 8294400` |
| `3840x2160` | `1,2,4,8` | `0 / 33177600` | `0 / 33177600` |
| `12288x1` | `1,2,4,8,16,64,256,1024` | `46976 / 49152` mismatches | `0 / 49152` |
| `9350x11` | `1,2,4,8,16,64,256` | `32956 / 411400` mismatches | `0 / 411400` |

The performance half remains not decision-grade even after closing the GPU
clock-control gap. The primary batched GPU query still did not scale with
operation count. In the fixed-clock 4K run, its eight per-process slopes were
only `0.015..0.063 us/blit`, while the same processes' wall slopes were
`908..1029 us/blit` and CPU submission slopes were `262..324 us/blit`.
At `256x256` and `12288x1`, GPU slopes still straddled zero. Most fitted GPU
`R²` values were poor.

The resulting paired `on - off` GPU slope deltas must not be quoted as the
workaround cost. The query apparently does not own the intended deferred tile
work; `run_batched()` ending the query before `glFlush()` is the next timing
boundary to inspect, but a trace or corrected experiment is needed before
assigning that as the cause. CPU 6 also remained under the `ondemand` governor,
and the boot was the KASAN kernel
`6.18.40-video-port-kasan-rockchip-rk3588`.

## Evidence and reproduction

- **Identity:** Radxa ROCK 5B / RK3588, Mali-G610 MC4, Mesa instrumented branch
  `benchmark/mr43161-all-blits` at `0c1cf4a71b4`, built from MR !43161 commit
  `647256dc2ae`; fixed-clock rerun from YSP `ec44ae8`.
- **Build:** `PATH=/usr/sbin:/usr/bin:/sbin:/bin
  CCACHE_DIR=/home/yi/Code/.ccache ninja -C build-bench` completed successfully
  in `/home/yi/Code/rock-5b/fdo/mesa-mr43161-bench`.
- **Exercise:** each matrix row used
  `meson devenv -C /home/yi/Code/rock-5b/fdo/mesa-mr43161-bench/build-bench env
  EGL_PLATFORM=surfaceless
  video-libraries/mesa/reproducers/run_blit_workaround_bench.py --blocks 2
  --cpu 6 --expect-gpu-hz 500000000 -- ... --samples 11 --warmups 2 --ring 4
  --schedule both`, with the row's size and count list.
- **Pass/fail signal:** all six fixed-clock runner invocations exited 0; the
  runner required both the patched driver's
  `PAN_BLIT_DEPTH_BIAS=<mode>` acknowledgement and exact 500 MHz clock reads.
  Off-mode exit 2 was accepted only for the two expected baseline correctness
  failures.
- **Artifacts:** raw logs, before/after metadata, and `SHA256SUMS` are in two
  machine-local, untracked 544 KiB bundles:
  `/home/yi/Code/rock-5b/build/mesa/mesa-blit-workaround-bench-20260727` for the initial pass and
  `/home/yi/Code/rock-5b/build/mesa/mesa-blit-workaround-bench-20260727-500mhz` for the fixed-clock
  rerun.

## Verification gate

Before using this harness for an "apply to all blits" performance decision:

1. make the batched GPU query demonstrably include the blit tile work, with
   time increasing with `N`;
2. add or run the planned API-operation, internal-draw, workaround-decision,
   descriptor-emission, job, and fallback counters;
3. capture matching off/on shader hashes and a descriptor trace proving only
   `depth_bias_enable` changes while factor, units, and clamp remain zero; and
4. rerun the corrected timing boundary on a non-KASAN kernel with a controlled
   CPU frequency; keep the now-proven 500 MHz devfreq enforcement.

The functional result is useful now: forcing the zero-valued depth-bias state
fixes both affected phase-one geometries without corrupting the four ordinary
controls. It does not yet quantify recurring per-blit cost.

## Boundary

This run covers only `R32UI`, 1:1 nearest `glBlitFramebuffer` operations on one
Mali-G610. It does not cover `RGBA8`, `RGBA16F`, format-changing PBO readback,
scaled, flipped, scissored, layered, or MSAA paths; application frame pacing;
other Mali generations; or a valid per-blit GPU cost despite the fixed-clock
rerun. The test instrumentation forces all V9-V10 internal fullscreen blits in
on mode, so it validates the proposed broad policy's measured functional
subset, not every path reached by that policy.
