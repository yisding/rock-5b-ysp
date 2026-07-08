# The ARM Mali blob interpolation reproducer

A focused guide to the one thing this reproducer does: run the Mali-G610
varying-interpolation test on the **proprietary Arm/Rockchip Mali userspace
(`libmali`)** on a Rock 5B / RK3588, and compare it against the Mesa/Panfrost
result on the same GPU.

For the general (Mesa/Vulkan) probes see [`README.md`](README.md); for the long
step-by-step runbook see [`README-arm-blob.md`](README-arm-blob.md). This doc is
the short, ARM-specific version and the one to read first.

## What it measures

A vertex shader emits a `highp float` varying `v` that should equal `x + 0.5` at
the center of pixel `x` across a `W×1` target. The fragment shader writes the
raw float bits into an `R32UI` texture; the CPU reads them back and checks
`floor(v) == x` for every pixel.

Two modes:

- **`fragcoord`** (control): the fragment shader uses `gl_FragCoord.x` (the
  rasterizer's full-precision pixel center) instead of the varying. This must be
  exact. It isolates the test — if `fragcoord` passes but `varying` fails, the
  error is specifically in **varying interpolation**, not rasterization or
  readback.
- **`varying`** (the test): uses the interpolated `v`.

Exit codes: `0` all pixels pass, `2` at least one pixel drifted, `1` setup error.

## The result (measured, 2026-07-08)

The proprietary blob (`GL_RENDERER=Mali-LODX`, `OpenGL ES 3.2 v1.g6p0-01eac0`)
reproduces the drift **bit-for-bit identically to Mesa/Panfrost**:

| width (varying) | mismatches | first bad x | last pixel v | relative_error |
|---|---|---|---|---|
| 8192 | 0 / 8192 | — | 8191.5000 | 0 (pass) |
| 12288 | 11744 / 12288 | 529 | 12275.5312 | 9.741e-04 (0.997·2⁻¹⁰) |
| 16307 | 15672 / 16307 | 623 | 16293.2832 | 8.105e-04 (0.830·2⁻¹⁰) |

`fragcoord` is exact at every width. These numbers match the Mesa/Panfrost run
in [`README.md`](README.md) to the last bit.

**Conclusion: the drift is hardware, not a driver bug.** Two stacks that share
only the GPU — different EGL/GL userspace, different shader compilers, different
kernel driver (`bifrost_kbase` vs Panfrost) — produce the same bits. Both are
faithfully driving the Mali-G610 Valhall fixed-function varying interpolator,
which carries the value at roughly 10 fractional bits (~`2⁻¹⁰`) of precision.
Switching to the ARM blob does not avoid it; a fix must avoid relying on
high-magnitude `highp` varyings. Full write-up:
[`../../../findings/2026-07-08-arm-mali-blob-interp-drift-bit-identical-to-mesa.md`](../../../findings/2026-07-08-arm-mali-blob-interp-drift-bit-identical-to-mesa.md).

## ⚠ Use the X11 variant. The GBM variant crashes the kernel.

There are four source files — a compact and a thoroughly-explained copy of each
of two paths:

| file | path | status |
|---|---|---|
| `tiny_interp_probe_arm_blob_x11.c` | X11 client | **runnable — use this** |
| `tiny_interp_probe_arm_blob_x11_explained.c` | X11 client | runnable, heavily commented |
| `tiny_interp_probe_arm_blob.c` | GBM | **gated off — Oopses this kernel** |
| `tiny_interp_probe_arm_blob_explained.c` | GBM | gated off (documentation) |

Why the GBM path is dangerous on the Radxa 5.10 vendor kernel
(`5.10.110-39-rockchip`): the Mali GPU is `/dev/mali0` (proprietary kbase, no
DRM node), so the GBM path reaches libmali through the **rockchip-drm display
node**. libmali's GBM/EGL bring-up issues the legacy `DRM_IOCTL_SET_VERSION` on
that node, and the kernel handler **NULL-derefs** (`Oops at
drm_setversion+0x80`). The Oops teardown then deadlocks in
`rockchip_drm_lastclose → drm_master_internal_acquire`, so the faulting task
never dies, holds `drm_global_mutex` forever, and every later DRM open hangs —
the board needs a reboot / power cycle. The GBM binaries therefore **refuse to
run by default** (override only on a fixed kernel via
`MALI_PROBE_FORCE_SETVERSION=1`). Details:
[`../../../findings/2026-07-08-arm-mali-blob-gbm-setversion-kernel-oops.md`](../../../findings/2026-07-08-arm-mali-blob-gbm-setversion-kernel-oops.md).

The X11 variant sidesteps this entirely: it renders as a **client of a running X
server**, which already owns DRM master, so libmali authenticates via DRI2 and
never issues `SET_VERSION`. `SET_VERSION` is a legacy "make me the DRM master"
handshake; a plain client has no reason to send it.

## Build and run

Link `libmali` directly — the vendor `.../mali/libEGL|libGLESv2|libgbm` files are
zero-symbol forwarding stubs, so `-lEGL -lGLESv2 -lgbm` fails to link. Add
`-lX11` for `XOpenDisplay`:

```bash
cc -O2 -o tiny_interp_probe_arm_blob_x11 \
  tiny_interp_probe_arm_blob_x11.c -lmali -lX11 -lm
# or the explained copy:
cc -O2 -o tiny_interp_probe_arm_blob_x11_explained \
  tiny_interp_probe_arm_blob_x11_explained.c -lmali -lX11 -lm
```

Run against the active X server. Do the `fragcoord` control first and only trust
`varying` once the control passes and `GL_RENDERER` names Mali:

```bash
DISPLAY=:0 ./tiny_interp_probe_arm_blob_x11 8192  fragcoord   # control, must pass
DISPLAY=:0 ./tiny_interp_probe_arm_blob_x11 12288 varying     # the test
DISPLAY=:0 ./tiny_interp_probe_arm_blob_x11 16307 varying
```

### Running over SSH

The X server (here, Xorg under sddm) holds its cookie in a root-only file, so an
SSH shell has no X authority by default. Grant your user access once from a
privileged shell:

```bash
sudo env DISPLAY=:0 XAUTHORITY=/run/sddm/<cookie> xhost +SI:localuser:$USER
```

Then the runs above work as your normal user. Revoke later with
`xhost -SI:localuser:$USER` if you like. A failed X connection is harmless — the
program stops cleanly before touching the GPU; fix `DISPLAY`/authority rather
than falling back to the GBM binary.

## Reading the output

```
GL_RENDERER=Mali-LODX
GL_VERSION=OpenGL ES 3.2 v1.g6p0-01eac0...
mode=varying width=12288: floor(v) != x at 11744 of 12288 pixels (first at x=529)
last pixel x=12287: v=12275.5312 expected=12287.5 relative_error=9.741e-04 (0.997 * 2^-10)
```

- `GL_RENDERER` **must** say Mali — a stock Mesa `libEGL` also exists on disk, so
  this line is the proof the blob answered.
- Trust a `varying` failure only when the `fragcoord` control at the same width
  passed first.
- `relative_error` is also printed as a multiple of `2⁻¹⁰`, the interpolator's
  approximate precision floor.

## See also

- [`README-arm-blob.md`](README-arm-blob.md) — full multi-step runbook (incl.
  loader/env checks and the unavailable Vulkan path).
- [`../../docs/arm-mali-blob-stack.md`](../../docs/arm-mali-blob-stack.md) —
  static notes on the proprietary stack (packaging, blob symbols, DDK lines).
- `findings/2026-07-08-arm-mali-blob-*` — the measured kernel-Oops and
  bit-identical-drift findings.
