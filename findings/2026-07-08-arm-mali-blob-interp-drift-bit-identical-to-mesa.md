# ARM Mali blob reproduces the varying-interpolation drift bit-for-bit identically to Mesa/Panfrost

> Scope: `video-libraries/mesa/reproducers/interp_probe` — proprietary Arm/Rockchip
> libmali G610 vs Mesa/Panfrost, same Rock 5B / RK3588 / Mali-G610 hardware.
> Source: on-board runs of `tiny_interp_probe_arm_blob_x11` (X11-client GLES
> variant) against the recorded Mesa numbers in the reproducer `README.md`.
> Runtime: `rock-5b-vendor-510`, `Linux 5.10.110-39-rockchip aarch64`, Debian 11
> (bullseye) Radxa vendor distro; libmali `Mali-LODX`, `OpenGL ES 3.2
> v1.g6p0-01eac0…`, `arm_release_ver g6p0-01eac0`, `rk_so_ver 5`; driven as a
> client of the sddm Xorg (DISPLAY=:0), so no `SET_VERSION` / no kernel Oops.
> Date: 2026-07-08.
> Trust: MEASURED (control passes; results bit-identical to the recorded Mesa
> run; board healthy across all runs).

## The fact

On the proprietary ARM Mali blob the varying-interpolation drift is **numerically
identical, to the last bit, to the Mesa/Panfrost result on the same GPU.** This
is the reproducer result that was previously PENDING/uncaptured (blocked by the
GBM path's kernel Oops — see
[`2026-07-08-arm-mali-blob-gbm-setversion-kernel-oops.md`](2026-07-08-arm-mali-blob-gbm-setversion-kernel-oops.md));
the X11-client variant runs cleanly and produces it.

### Measured (ARM blob, `tiny_interp_probe_arm_blob_x11`, DISPLAY=:0)

```
GL_RENDERER=Mali-LODX
GL_VERSION=OpenGL ES 3.2 v1.g6p0-01eac0.efb75e2978d783a80fe78be1bfb0efc1

fragcoord control:  8192  -> 0 / 8192   mismatches (exact)      exit 0
fragcoord control: 12288  -> 0 / 12288  mismatches (exact)      exit 0
fragcoord control: 16307  -> 0 / 16307  mismatches (exact)      exit 0

varying   8192  -> 0 / 8192      mismatches, last v=8191.5000  (exact)          exit 0
varying  12288  -> 11744 / 12288 mismatches, first x=529,  last v=12275.5312,
                   expected 12287.5, rel_err 9.741e-04 (0.997 * 2^-10)          exit 2
varying  16307  -> 15672 / 16307 mismatches, first x=623,  last v=16293.2832,
                   expected 16306.5, rel_err 8.105e-04 (0.830 * 2^-10)          exit 2
```

### Side-by-side with the recorded Mesa/Panfrost run (reproducer README.md)

| width (varying) | mismatches | first bad x | last pixel v | relative_error |
|---|---|---|---|---|
| 12288 — Mesa   | 11744 / 12288 | 529 | 12275.5312 | 9.741e-04 (0.997·2⁻¹⁰) |
| 12288 — ARM blob | 11744 / 12288 | 529 | 12275.5312 | 9.741e-04 (0.997·2⁻¹⁰) |
| 16307 — Mesa   | 15672 / 16307 | 623 | 16293.2832 | 8.105e-04 (0.830·2⁻¹⁰) |
| 16307 — ARM blob | 15672 / 16307 | 623 | 16293.2832 | 8.105e-04 (0.830·2⁻¹⁰) |

Every field matches exactly. Power-of-two width 8192 passes on both; the
`fragcoord` control passes on both at every width.

## Why it matters

This settles the origin of the drift: it is **hardware**, not a Panfrost/Mesa
software or shader-compiler defect. The two stacks share nothing but the GPU —
different EGL/GL userspace, different compilers, different kernel driver
(`bifrost_kbase` vs Panfrost) — yet they produce the *same bits*. So both are
faithfully programming the Mali-G610 Valhall fixed-function varying interpolator,
which carries the interpolated value at reduced (~10 fractional bit, ~`2^-10`)
precision. The `fragcoord` control isolates it: `gl_FragCoord.x` comes from the
rasterizer's full-precision pixel-center path and is exact, while the same value
carried as a `highp float` varying drifts — so the loss is specifically in
attribute interpolation, not rasterization or readback.

Consequences:

- Any conformance/quality argument about this drift applies to the **hardware**,
  and neither switching to the ARM blob nor patching Panfrost will remove it. A
  fix must avoid relying on high-magnitude `highp` varyings (e.g. carry
  large-range quantities another way, or reconstruct from `gl_FragCoord`).
- It is a positive cross-validation of the Panfrost result: the open stack is not
  introducing error the blob avoids.

## Follow-up

- The ARM **Vulkan** datapoint is still not obtainable from these repos (g6p0
  blob has no Vulkan ICD — see the readiness finding); unchanged by this run.
- Runnable path is `tiny_interp_probe_arm_blob_x11` under a live X server only
  (the GBM variant still Oopses this kernel and is gated off). Pinned to kernel
  `5.10.110-39-rockchip`, libmali `1.9-1` DDK g6p0 — re-verify on a bump.
