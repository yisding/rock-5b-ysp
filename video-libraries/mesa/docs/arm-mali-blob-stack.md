# RK3588 Proprietary ARM Mali Userspace Notes

This note records what was learned while preparing the interpolation
reproducers for the proprietary Arm/Rockchip Mali stack on the same Rock 5B /
RK3588 / Mali-G610 MC4 hardware.

Scope: package metadata and static binary inspection, plus the on-board runtime
results captured 2026-07-08 (see [Runtime Results](#runtime-results-measured-2026-07-08)).
The static sections below predate the runtime run and are kept as the reasoning
that led to it; the runtime section records what actually happened on hardware
(`GL_RENDERER`, DDK build, kernel ABI, and the GBM-vs-X11 outcome).

## Source Package Facts

Checked on 2026-07-06 against the public `tsukumijima/libmali-rockchip`
GitHub mirror:

- `gpu-chips.txt` maps `valhall-g610` to `rk3588`.
  Source:
  https://raw.githubusercontent.com/tsukumijima/libmali-rockchip/master/gpu-chips.txt
- The aarch64 library tree contains RK3588/G610 Valhall blobs for DDK lines
  `g6p0`, `g13p0`, and `g24p0`.
  Source:
  https://github.com/tsukumijima/libmali-rockchip/tree/master/lib/aarch64-linux-gnu
- The G610 platform variants visible in that tree include GBM, Wayland+GBM,
  X11+GBM, X11+Wayland+GBM, and dummy variants. The GBM-only files checked
  directly were:
  - `libmali-valhall-g610-g6p0-gbm.so`
  - `libmali-valhall-g610-g13p0-gbm.so`
  - `libmali-valhall-g610-g24p0-gbm.so`
- `meson_options.txt` defaults `platform` to `gbm`, `opencl-icd` to `true`,
  `wrappers` to `auto`, `hooks` to `true`, `optimize-level` to `O3`, and
  `firmware-dir` to `/lib/firmware`.
  Source:
  https://raw.githubusercontent.com/tsukumijima/libmali-rockchip/master/meson_options.txt
- `meson.build` declares package version `1.9.0`.
  Source:
  https://raw.githubusercontent.com/tsukumijima/libmali-rockchip/master/meson.build
- The package chooses one prebuilt blob, links it as `libmali-prebuilt.so`, and
  uses symbol probes to decide which wrappers to install.
- The package probes for `gbm_create_device` to decide GBM availability.
- The package probes for `eglCreateContext` before installing EGL/GLES
  wrappers.
- The package probes for `vk_icdGetInstanceProcAddr` before installing the
  Vulkan wrapper and ICD JSON.
- If any of GBM, Wayland, or X11 is present, the package adds `libdrm` as a
  dependency. Wayland builds add `wayland-client` and `wayland-server`; X11
  builds add X11/XCB dependencies.
- The wrapper names/versioned sonames are generated from this map:
  - `gbm` -> `libgbm.so.1`
  - `EGL` -> `libEGL.so.1`
  - `GLESv1_CM` -> `libGLESv1_CM.so.1`
  - `GLESv2` -> `libGLESv2.so.2`
  - `wayland-egl` -> `libwayland-egl.so.1`
  - `MaliOpenCL` or `OpenCL` -> OpenCL wrapper/ICD depending on
    `opencl-icd`
  - `MaliVulkan` -> `libMaliVulkan.so.1`
- GBM header/pkg-config version is selected by blob features:
  - hook library enabled -> `23.1.3`
  - `gbm_bo_get_fd_for_plane` -> `21.1.0`
  - `gbm_bo_get_modifier` -> `17.1.0`
  - otherwise -> `10.4.0`
- If `gpu == 'valhall-g610'`, the package installs
  `firmware/g610/mali_csffw.bin` into the configured firmware directory.
- The package installs `/etc/profile.d/mali-priority.sh` content that exports
  `MALI_SCHED_RT_THREAD_PRIORITY=95`.
- If `opencl-icd` is enabled and the blob exposes OpenCL entrypoints, the
  package installs an OpenCL ICD vendor file under
  `${sysconfdir}/OpenCL/vendors`. The generated ICD points at
  `libMaliOpenCL.so.1`.
- OpenCL header/pkg-config target version is selected by symbol probes:
  `clCreateBufferWithProperties` -> OpenCL 3.0, `clSetProgramReleaseCallback`
  -> 2.2, `clCloneKernel` -> 2.1, `clCreatePipe` -> 2.0, otherwise 1.2.
- The Vulkan ICD template points the loader at `libMaliVulkan.so.1` and
  advertises Vulkan API version `1.3.276`.
  Source:
  https://raw.githubusercontent.com/tsukumijima/libmali-rockchip/master/data/vulkan/mali.json.in
- The Vulkan ICD JSON is installed under `${datadir}/vulkan/icd.d` when the
  Vulkan entrypoint probe passes.
- With `vendor-package=true`, wrapper libraries are installed under
  `${libdir}/mali`, and an ld.so config file is installed under
  `/etc/ld.so.conf.d`.

## Static Binary Inspection

The public G610 GBM blobs were downloaded from the `lib/aarch64-linux-gnu`
tree on 2026-07-06 and inspected locally. The blobs are not stored in this
repository.

```bash
base=https://raw.githubusercontent.com/tsukumijima/libmali-rockchip/master/lib/aarch64-linux-gnu
curl -L --fail -o /tmp/libmali-valhall-g610-g6p0-gbm.so \
  "$base/libmali-valhall-g610-g6p0-gbm.so"
curl -L --fail -o /tmp/libmali-valhall-g610-g13p0-gbm.so \
  "$base/libmali-valhall-g610-g13p0-gbm.so"
curl -L --fail -o /tmp/libmali-valhall-g610-g24p0-gbm.so \
  "$base/libmali-valhall-g610-g24p0-gbm.so"
```

Recorded hashes:

| File | SHA-256 |
|---|---|
| `libmali-valhall-g610-g6p0-gbm.so` | `59370c96327170661a2ea3bf6cf641af90ea961a26c8670358d436441d25aeb2` |
| `libmali-valhall-g610-g13p0-gbm.so` | `d760d8b67de2511dd20415098f8778cc50a416ec069cc8e6ce8bcde536acb0ea` |
| `libmali-valhall-g610-g24p0-gbm.so` | `4d7cb76a1d073c39a4fee34692e0422b1421ff258045a6cef40e9f91492c89a6` |

`file` identified all three as AArch64 ELF shared objects. Build IDs printed
for two of them:

| File | Build ID from `file` |
|---|---|
| `libmali-valhall-g610-g6p0-gbm.so` | `2e1f063098c9b7580fc0dd8a90e60eb3a437a4e2` |
| `libmali-valhall-g610-g13p0-gbm.so` | `a3240c01d145a7f44e1128ce6bbcd11bc6cb156f` |
| `libmali-valhall-g610-g24p0-gbm.so` | no build ID printed by `file` |

`readelf -d` reported the same soname and main dynamic dependencies for all
three GBM blobs:

- SONAME: `libmali.so.1`
- NEEDED:
  - `libdrm.so.2`
  - `libpthread.so.0`
  - `libdl.so.2`
  - `libstdc++.so.6`
  - `libm.so.6`
  - `libc.so.6`
  - `libgcc_s.so.1`

The order of the `NEEDED` entries differs slightly by DDK build, but the set is
the same for the inspected GBM blobs.

## EGL And GL Extension Strings

The surfaceless-context claim used by the ARM GLES reproducers is based on the
extension strings embedded in the public GBM blobs:

```bash
for f in /tmp/libmali-valhall-g610-g6p0-gbm.so \
         /tmp/libmali-valhall-g610-g13p0-gbm.so \
         /tmp/libmali-valhall-g610-g24p0-gbm.so; do
  basename "$f"
  strings "$f" |
    rg -o 'EGL_EXT_platform_base|EGL_KHR_platform_gbm|EGL_KHR_surfaceless_context|GL_OES_surfaceless_context' |
    sort -u
done
```

All three inspected GBM blobs contain:

- `EGL_EXT_platform_base`
- `EGL_KHR_platform_gbm`
- `EGL_KHR_surfaceless_context`
- `GL_OES_surfaceless_context`

They also contain `EGL_EXT_client_extensions` and `EGL_KHR_no_config_context`.

Consequence: the GLES ARM reproducer does not need to create a throw-away
pbuffer. It can create the EGL display through GBM and still make the context
current with:

```c
eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx);
```

That is exactly what `EGL_KHR_surfaceless_context` is for when the program
renders only to GL framebuffer objects. Khronos extension text:
https://registry.khronos.org/EGL/extensions/KHR/EGL_KHR_surfaceless_context.txt

## Loader Model

For GLES, libmali is still reached through EGL:

1. Open a DRM render node such as `/dev/dri/renderD128`.
2. Wrap the fd with `gbm_create_device`.
3. Call `eglGetPlatformDisplayEXT(EGL_PLATFORM_GBM_KHR, gbm, NULL)`.
4. Initialize EGL and create a GLES context.
5. Make the context current with `EGL_NO_SURFACE` for both draw and read.
6. Render into an API-created GL framebuffer object.

The GBM device is only the native display object used to find the libmali EGL
backend. It is not the reproducers' render target.

For Vulkan, EGL and GBM are not part of context creation. Vulkan reaches the
blob through the Vulkan loader and the Mali ICD JSON. Because the inspected
package advertises Vulkan `1.3.276`, the ARM Vulkan reproducer intentionally
does not fork the canonical Vulkan probe's dynamic-rendering source path.

## Reproducer Implications

The ARM GLES variant differs from the Mesa/Panfrost tiny probe only because the
EGL display discovery differs:

- Mesa tiny probe:
  - `EGL_PLATFORM_SURFACELESS_MESA`
  - `EGL_DEFAULT_DISPLAY`
  - `EGL_NO_SURFACE`
- RK3588 libmali GBM probe:
  - open `/dev/dri/renderD128`
  - `gbm_create_device`
  - `EGL_PLATFORM_GBM_KHR`
  - `EGL_NO_SURFACE`

The shader, draw, `GL_R32UI` target, raw `glReadPixels`, and CPU checker stay
unchanged.

The ARM Vulkan variant is only an ARM-named wrapper. It includes the canonical
Vulkan source so that test scripts can produce ARM-specific binary/log names
without creating a second Vulkan implementation.

See:

- [`../reproducers/interp_probe/README-arm-blob.md`](../reproducers/interp_probe/README-arm-blob.md)
- [`../reproducers/interp_probe/tiny_interp_probe_arm_blob.c`](../reproducers/interp_probe/tiny_interp_probe_arm_blob.c)
- [`../reproducers/interp_probe/vk_interp_probe_arm_blob.c`](../reproducers/interp_probe/vk_interp_probe_arm_blob.c)

## Runtime Results (measured 2026-07-08)

Captured on `rock-5b-vendor-510`, `Linux 5.10.110-39-rockchip`, Debian 11 Radxa
vendor distro, `libmali-valhall-g610-g6p0-x11-gbm 1.9-1`, `bifrost_kbase`
loaded. The reproducer runbook is
[`../reproducers/interp_probe/arm-mali-reproducer.md`](../reproducers/interp_probe/arm-mali-reproducer.md).

### Build / loader

- The vendor libmali ships `libEGL`/`libGLESv2`/`libgbm` under
  `/usr/lib/aarch64-linux-gnu/mali/` as **zero-symbol forwarding stubs**; the
  real symbols live in `libmali.so.1`. So `-lEGL -lGLESv2 -lgbm` fails to link
  (GNU ld `--no-copy-dt-needed-entries`) — link `libmali` directly (`-lmali`).
- `ldconfig` resolves `libEGL.so.1`/`libGLESv2.so.2`/`libgbm.so.1` to the `mali`
  wrappers ahead of stock mesa via `/etc/ld.so.conf.d/00-aarch64-mali.conf`.

### GBM path Oopses the kernel (do not use it)

The Mali GPU is `/dev/mali0` (proprietary kbase, no DRM node), so the GBM path
reaches libmali through the **rockchip-drm display node**. libmali's GBM/EGL
bring-up issues the legacy `DRM_IOCTL_SET_VERSION` on the primary card node, and
on this kernel that handler **NULL-derefs**:

```
Unable to handle kernel NULL pointer dereference at 0x10
pc : drm_setversion+0x80/0x18c
Call trace: drm_setversion / drm_ioctl_kernel / drm_ioctl / __arm64_sys_ioctl
```

The Oops teardown then deadlocks: the dying task's `drm_release` runs
`rockchip_drm_lastclose -> drm_master_internal_acquire`, so it never finishes
dying and holds `drm_global_mutex` forever — every later DRM open hangs
(`drm_open`, unkillable `D`-state), with a PMIC `rk806` SPI + i2c + cpufreq
cascade, needing a reboot/power cycle. With a compositor holding DRM master the
same call *deadlocks* instead of Oopsing, so stopping the display manager is not
a fix. The GBM reproducer therefore refuses to run by default. Trust:
MEASURED (reproduced twice, full Oops + hung-task backtraces).

### X11-client path works

Driving libmali as a client of a running X server avoids `SET_VERSION` (the X
server already owns DRM master; the client authenticates via DRI2). That path
runs cleanly:

- `GL_RENDERER=Mali-LODX`, `GL_VERSION=OpenGL ES 3.2 v1.g6p0-01eac0…`,
  `arm_release_ver g6p0-01eac0`, `rk_so_ver 5`. This resolves the DDK-line /
  kernel-ABI / renderer unknowns: **g6p0**, `bifrost_kbase`, `Mali-LODX`.

### Interpolation result: bit-identical to Mesa/Panfrost

The `fragcoord` control is exact at 8192/12288/16307; the `varying` drift is
**numerically identical, to the last bit, to the Mesa/Panfrost run** on the same
GPU:

| width (varying) | mismatches | first bad x | last pixel v | relative_error |
|---|---|---|---|---|
| 8192 | 0 / 8192 | — | 8191.5000 | 0 (pass) |
| 12288 | 11744 / 12288 | 529 | 12275.5312 | 9.741e-04 (0.997·2⁻¹⁰) |
| 16307 | 15672 / 16307 | 623 | 16293.2832 | 8.105e-04 (0.830·2⁻¹⁰) |

Two stacks that share only the GPU — different EGL/GL userspace, compilers, and
kernel driver (`bifrost_kbase` vs Panfrost) — emit the same bits, so **the drift
is hardware**, not a Panfrost/Mesa compiler bug. **Correction, 2026-07-22:** a
Mesa maintainer identified it as a hardware erratum; zero-valued polygon
offset makes the same Panfrost varying exact, and equivalent zero-valued
Vulkan depth bias makes PanVK exact. The `~2⁻¹⁰` value is therefore a measured
signature at these widths, not an inherent ten-fractional-bit Valhall limit.
The workaround has not been established on the proprietary stack; see the
[maintained Mesa validation boundary](validation.md#depth-bias-workaround-validation).
The proprietary-compiler question in the old "Current Unknowns" is still
answered by the bit-identical baseline.

### Vulkan: unavailable from these repos

Every Radxa-repo G610 package is DDK **g6p0** with no `vk_icdGetInstanceProcAddr`
/ `libMaliVulkan` / ICD JSON (checked on the installed x11-gbm blob and the
downloaded `gbm` blob). ARM-blob Vulkan needs an out-of-distro g13p0/g24p0
libmali, which would also replace the working GLES path. Trust: MEASURED.

## Runtime Verification Checklist

The 2026-07-08 run above satisfies this checklist; keep it for re-runs (a kernel
or libmali bump can change the answer). Preserve:

- exact libmali package/build source
- chosen DDK line (`g6p0`, `g13p0`, `g24p0`, or another)
- SHA-256 of the loaded blob if not system-packaged
- `ldd ./tiny_interp_probe_arm_blob`
- `LD_DEBUG=libs` excerpt if driver selection is ambiguous
- `GL_RENDERER` and `GL_VERSION`
- Vulkan device name, `apiVersion`, and `driverVersion`
- `VK_ICD_FILENAMES` value, or the installed ICD JSON path
- `/dev/dri/renderD*` node used
- whether `fragcoord` passed before interpreting any `varying` failure

Do not treat a varying failure as useful unless the `fragcoord` control passes
and the renderer/device lines prove the proprietary stack answered the calls.

## Current Unknowns

Most of the original unknowns are resolved by the
[Runtime Results](#runtime-results-measured-2026-07-08) above (runtime output
captured, DDK line `g6p0`, kernel ABI `bifrost_kbase`, and the varying-drift
behavior — bit-identical to Mesa, i.e. hardware). Still open:

- OpenCL wrapper/ICD behavior was not exercised (not relevant to the interp
  probe).
- The GBM `SET_VERSION` NULL-deref is a vendor-kernel bug pinned to
  `5.10.110-39-rockchip`; a fixed kernel could make the GBM path usable. The
  bit-identical varying result should be re-confirmed on any kernel or libmali
  bump.
