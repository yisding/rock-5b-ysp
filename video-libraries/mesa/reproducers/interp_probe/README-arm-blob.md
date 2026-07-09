# RK3588 Proprietary ARM Mali Driver Runs

This note is for the Rock 5B / RK3588 / Mali-G610 case only. It is not trying
to produce a generic "any Mali blob" fallback. The goal is to keep the ARM blob
reproducers as close as possible to the Mesa/Panfrost reproducers while
changing only the loader/context setup that is Mesa-specific.

> **⚠ DANGER — the GBM path crashes the kernel on the Radxa 5.10 vendor kernel.**
> On `5.10.110-39-rockchip`, libmali's GBM/EGL bring-up issues the legacy
> `DRM_IOCTL_SET_VERSION` on the rockchip-drm primary node, which **NULL-derefs
> the kernel** (`Oops at drm_setversion+0x80`); the Oops teardown then deadlocks
> in `rockchip_drm_lastclose → drm_master_internal_acquire`, so the task never
> dies, holds `drm_global_mutex` forever, and every later DRM open hangs
> (`D`-state, unkillable, PMIC/i2c/cpufreq cascade) — reboot / power cycle
> required. With a compositor holding DRM master it *deadlocks* instead of
> Oopsing, so stopping the display manager is **not** enough. Because of this,
> `tiny_interp_probe_arm_blob` now **refuses to run by default**
> (`MALI_PROBE_FORCE_SETVERSION=1` overrides only if your kernel is fixed). The
> blob has no surfaceless EGL platform (only `EGL_KHR_platform_gbm` /
> `EGL_KHR_platform_x11`), so GBM-on-the-display-node is unavoidable — the
> **recommended way to actually get a number is to drive libmali as an X11
> client** under a running Xorg (X owns DRM master → no `SET_VERSION`). Full
> trace and mechanism: [`../../docs/arm-mali-blob-stack.md`](../../docs/arm-mali-blob-stack.md) → "Runtime Results".

## Capability Notes

The longer stack note is
[`../../docs/arm-mali-blob-stack.md`](../../docs/arm-mali-blob-stack.md). This
section keeps the subset directly relevant to running the interpolation
reproducers.

The Rockchip libmali package data maps `valhall-g610` to `rk3588`:
https://raw.githubusercontent.com/tsukumijima/libmali-rockchip/master/gpu-chips.txt

The same package tree contains aarch64 G610 binaries for GBM-oriented Rockchip
platforms, including `g6p0`, `g13p0`, and `g24p0` builds named `*-gbm.so`,
`*-wayland-gbm.so`, `*-x11-gbm.so`, and `*-x11-wayland-gbm.so`:
https://github.com/tsukumijima/libmali-rockchip/tree/master/lib/aarch64-linux-gnu

The package's Meson options default `platform` to `gbm`:
https://raw.githubusercontent.com/tsukumijima/libmali-rockchip/master/meson_options.txt

The package build probes the blob for `gbm_create_device`, `eglCreateContext`,
GLES wrapper symbols, and `vk_icdGetInstanceProcAddr`; when present, it installs
GBM/EGL/GLES/Vulkan wrapper libraries and a Vulkan ICD JSON:
https://raw.githubusercontent.com/tsukumijima/libmali-rockchip/master/meson.build

That Vulkan ICD template advertises `api_version` `1.3.276`:
https://raw.githubusercontent.com/tsukumijima/libmali-rockchip/master/data/vulkan/mali.json.in

I also checked the embedded extension strings in the public G610 GBM binaries
`libmali-valhall-g610-g6p0-gbm.so`,
`libmali-valhall-g610-g13p0-gbm.so`, and
`libmali-valhall-g610-g24p0-gbm.so`. All three contain:

- `EGL_EXT_platform_base`
- `EGL_KHR_platform_gbm`
- `EGL_KHR_surfaceless_context`
- `GL_OES_surfaceless_context`

Those extensions would make GBM a clean surfaceless path on paper — but on this
board's kernel the GBM route never gets that far: it crashes in
`DRM_IOCTL_SET_VERSION` before first draw (see the DANGER banner above), so the
runnable variant is the X11-client one. The Khronos
`EGL_KHR_surfaceless_context` extension exists so applications that render only
to client API targets, such as GL framebuffer objects, do not need a throw-away
EGL surface:
https://registry.khronos.org/EGL/extensions/KHR/EGL_KHR_surfaceless_context.txt

## What Changes

There are two GLES ARM variants. Both are patched copies of
`tiny_interp_probe.c` — the shader strings, triangle, `GL_R32UI` target, raw
`glReadPixels` path, and CPU checker are intentionally unchanged; only the EGL
setup differs. Both link `libmali` directly (`-lmali`), because the vendor
`.../mali/libEGL|libGLESv2|libgbm` files are zero-symbol forwarding stubs.

`tiny_interp_probe_arm_blob_x11.c` — **the runnable one.** It renders as a
client of a running X server:

- Add `X11/Xlib.h`; `XOpenDisplay` connects to the server named by `$DISPLAY`.
- Get the EGLDisplay via `EGL_PLATFORM_X11_KHR` on that X `Display*`.
- Make current against a throwaway 1×1 pbuffer (the test still draws to the FBO).
- Because the X server already owns DRM master, libmali authenticates via DRI2
  and never issues the kernel-crashing `SET_VERSION`.

`tiny_interp_probe_arm_blob.c` — **the GBM variant, gated off** (crashes this
kernel; see the DANGER banner). Kept for the record:

- Add `fcntl.h`, `gbm.h`, `unistd.h`; accept optional `argv[3]` render node
  (default `/dev/dri/renderD128`); open it and create a `gbm_device`.
- Replace Mesa's `EGL_PLATFORM_SURFACELESS_MESA` display with
  `EGL_PLATFORM_GBM_KHR`; keep `eglMakeCurrent` surfaceless (`EGL_NO_SURFACE`).
- Refuses to run unless `MALI_PROBE_FORCE_SETVERSION=1`.

`vk_interp_probe_arm_blob.c` deliberately does not fork the Vulkan test. It
includes `vk_interp_probe.c` so ARM-named build/run scripts can exist without
duplicating or drifting from the canonical Vulkan source. (The installed g6p0
blob ships no Vulkan ICD, so this is currently unrunnable on this board.)

The `*_explained.c` ARM files are the teaching copies:

- `tiny_interp_probe_arm_blob_x11_explained.c` is the heavily-commented copy of
  the runnable X11 variant — read this one. It explains the X-client vs GBM
  choice, why GBM Oopses the kernel, and the DRI2/no-`SET_VERSION` reasoning.
- `tiny_interp_probe_arm_blob_explained.c` is the comment-heavy GBM variant,
  kept as documentation of the route that does not work here.
- `vk_interp_probe_arm_blob_explained.c` is a documented wrapper around
  `vk_interp_probe_explained.c` because Vulkan does not use EGL, and the
  RK3588 libmali ICD advertises the Vulkan 1.3 path used by the canonical
  reproducer.

## Detailed Runbook

Run these commands on the Rock 5B itself, or on an RK3588 system with the same
proprietary Mali userspace stack installed. Start from the reproducers
directory:

```bash
cd video-libraries/mesa/reproducers/interp_probe
```

### 1. Check The Render Node

The GLES ARM reproducer opens a DRM render node so it can create the GBM display
that libmali expects:

```bash
ls -l /dev/dri/renderD*
```

The default is `/dev/dri/renderD128`. If your board exposes a different render
node, pass it as the third argument to the GLES reproducer. If opening the node
fails with `Permission denied`, run as a user with render-node access or
temporarily use `sudo` for the reproducer command.

### 2. Clear Mesa Loader Overrides

If you have been running the Mesa/Panfrost reproducers from the same shell,
clear the Mesa-specific loader variables before testing the proprietary stack:

```bash
unset LIBGL_DRIVERS_PATH
unset GBM_BACKENDS_PATH
unset EGL_PLATFORM
unset MESA_LOADER_DRIVER_OVERRIDE
```

These reproducers print the renderer they actually reached. Do not interpret
the numbers until stderr confirms the proprietary Mali driver, not Panfrost.

### 3. Point At libmali If Needed

If the libmali wrapper libraries are installed system-wide, you should not need
`LD_LIBRARY_PATH`. If you are testing an unpacked libmali build or package tree,
point the dynamic linker at the directory containing the ARM blob wrappers:

```bash
export LD_LIBRARY_PATH=/path/to/libmali/lib:$LD_LIBRARY_PATH
```

The Vulkan loader also needs to find the Mali ICD JSON. If the package installed
it into a standard location such as `/usr/share/vulkan/icd.d`, leave
`VK_ICD_FILENAMES` unset. If the ICD JSON lives in an unpacked tree, point at it
explicitly:

```bash
export VK_ICD_FILENAMES=/path/to/mali.json
```

For a quick sanity check, this should list a Mali ICD path when the Vulkan JSON
is installed system-wide:

```bash
ls /usr/share/vulkan/icd.d/*mali* 2>/dev/null
```

### 4. Build The GLES Reproducers

The Radxa vendor libmali installs `libEGL`/`libGLESv2`/`libgbm` under
`/usr/lib/aarch64-linux-gnu/mali/` as **zero-symbol forwarding stubs** (the real
`egl*`/`gl*`/`gbm_*` symbols live in `libmali.so.1`). GNU ld's default
`--no-copy-dt-needed-entries` means linking those stubs fails with undefined
references, so **link libmali directly** with `-lmali`:

```bash
cc -O2 -o tiny_interp_probe_arm_blob \
  tiny_interp_probe_arm_blob.c -lmali -lm
cc -O2 -o tiny_interp_probe_arm_blob_explained \
  tiny_interp_probe_arm_blob_explained.c -lmali -lm
```

(This needs the dev headers `libegl1-mesa-dev libgles2-mesa-dev libgbm-dev`.)
`ldd ./tiny_interp_probe_arm_blob` should then show `libmali.so.1`.

The compact and explained binaries run the same test. Use the compact binary
for logs and the explained binary when reading through the code.

**These binaries refuse to run by default on the RK3588 vendor kernel** (see the
DANGER banner above): the GBM path Oopses the kernel. `MALI_PROBE_FORCE_SETVERSION=1`
overrides the safety gate, but only do that on a kernel whose `drm_setversion` is
known fixed — otherwise you will crash the board.

### 4b. Build The GLES X11-Client Reproducer (the runnable path)

Because the GBM path crashes this kernel, the runnable GLES variant is
`tiny_interp_probe_arm_blob_x11.c`. It drives libmali as a **client of a running
X server**: the X server already owns DRM master, so the libmali client
authenticates through DRI2 and never issues the `SET_VERSION` that Oopses the
kernel. It opens no DRM node itself; a 1×1 pbuffer just makes the context
current, and the test still renders into the same `GL_R32UI` FBO.

```bash
cc -O2 -o tiny_interp_probe_arm_blob_x11 \
  tiny_interp_probe_arm_blob_x11.c -lmali -lX11 -lm
```

Run it against the active X server. It reads `$DISPLAY` (and needs X authority —
set `XAUTHORITY`/use `xhost` if running over SSH):

```bash
DISPLAY=:0 ./tiny_interp_probe_arm_blob_x11 8192 fragcoord
DISPLAY=:0 ./tiny_interp_probe_arm_blob_x11 12288 varying
```

As with every variant, trust the number only when stderr `GL_RENDERER` names
Mali and the `fragcoord` control passes first. Do **not** fall back to the GBM
binary if the X11 one fails to connect — fix `DISPLAY`/authority instead.

> Status: **RUN AND VERIFIED on hardware (2026-07-08).** Driven as a client of
> the sddm Xorg on `5.10.110-39-rockchip`, this path completes with no kernel
> Oops: `GL_RENDERER=Mali-LODX`, `OpenGL ES 3.2 v1.g6p0-01eac0…`, `fragcoord`
> control exact at 8192/12288/16307, and the `varying` drift comes out
> **bit-for-bit identical to the Mesa/Panfrost numbers** (12288 → 11744/12288,
> last v=12275.5312, 0.997·2⁻¹⁰; 16307 → 15672/16307, last v=16293.2832,
> 0.830·2⁻¹⁰), proving the drift is hardware. Full write-up:
> [`../../docs/arm-mali-blob-stack.md`](../../docs/arm-mali-blob-stack.md) → "Runtime Results".
> Requires a live X server (`DISPLAY=:0` + X authority); the GBM variant still
> Oopses this kernel and stays gated off.

### 5. Build The Vulkan Reproducers

Compile the shader files first, then the host programs:

```bash
glslc vk_interp_probe.vert           -o vk_interp_probe.vert.spv
glslc vk_interp_probe.varying.frag   -o vk_interp_probe.varying.frag.spv
glslc vk_interp_probe.fragcoord.frag -o vk_interp_probe.fragcoord.frag.spv
cc -O2 -o vk_interp_probe_arm_blob vk_interp_probe_arm_blob.c -lvulkan -lm

glslc vk_interp_probe_explained.vert \
  -o vk_interp_probe_explained.vert.spv
glslc vk_interp_probe_explained.varying.frag \
  -o vk_interp_probe_explained.varying.frag.spv
glslc vk_interp_probe_explained.fragcoord.frag \
  -o vk_interp_probe_explained.fragcoord.frag.spv
cc -O2 -o vk_interp_probe_arm_blob_explained \
  vk_interp_probe_arm_blob_explained.c -lvulkan -lm
```

The Vulkan binaries open their `.spv` files by relative filename, so run them
from this directory unless you copy the `.spv` files next to the executable.

### 6. Run The GLES Control First

Run `fragcoord` before the varying test:

```bash
./tiny_interp_probe_arm_blob 12288 fragcoord /dev/dri/renderD128
```

Expected shape:

- stderr prints proprietary Mali `GL_RENDERER` and `GL_VERSION`.
- stdout reports `floor(v) != x at 0 of 12288 pixels`.
- exit code is `0`.

This proves the ARM blob rendered, read back, and interpreted `gl_FragCoord.x`
correctly through the same offscreen integer framebuffer path.

### 7. Run The GLES Varying Test

Run the default problem width:

```bash
./tiny_interp_probe_arm_blob 12288 varying /dev/dri/renderD128
```

Useful follow-up widths:

```bash
./tiny_interp_probe_arm_blob 8192 varying /dev/dri/renderD128
./tiny_interp_probe_arm_blob 16307 varying /dev/dri/renderD128
```

`8192` is a power-of-two control. `12288` and `16307` are widths where the Mesa
Panfrost path showed interpolation drift on this board.

Exit code `2` is not a harness failure here. It means the reproducer ran and
found at least one pixel where `floor(v) != x`.

### 8. Run The Vulkan Control And Test

Run the control:

```bash
./vk_interp_probe_arm_blob 12288 fragcoord Mali
```

Expected shape:

- stderr prints a Mali Vulkan physical device and its `apiVersion`.
- stdout reports `floor(v) != x at 0 of 12288 pixels`.
- `unwritten=0`.
- exit code is `0`.

Then run the varying cases:

```bash
./vk_interp_probe_arm_blob 12288 varying Mali
./vk_interp_probe_arm_blob 16307 varying Mali
```

The Vulkan ARM binary is an ARM-named wrapper around the canonical Vulkan
reproducer. If it fails at setup, first confirm that the Vulkan loader is seeing
the Mali ICD JSON, then confirm that the `.spv` files were built in this
directory.

### 9. Optional Teaching Runs

The explained binaries take the same arguments:

```bash
./tiny_interp_probe_arm_blob_explained 12288 fragcoord /dev/dri/renderD128
./tiny_interp_probe_arm_blob_explained 12288 varying /dev/dri/renderD128
./vk_interp_probe_arm_blob_explained
./vk_interp_probe_arm_blob_explained 12288 fragcoord
```

### 10. Save Logs Without Losing Exit Codes

When collecting logs, use `set -o pipefail` so a failing varying test still
returns exit code `2` even when piped through `tee`:

```bash
set -o pipefail
./tiny_interp_probe_arm_blob 12288 fragcoord /dev/dri/renderD128 \
  2>&1 | tee arm-gles-fragcoord-12288.log
echo "exit=$?"

./tiny_interp_probe_arm_blob 12288 varying /dev/dri/renderD128 \
  2>&1 | tee arm-gles-varying-12288.log
echo "exit=$?"

./vk_interp_probe_arm_blob 12288 fragcoord Mali \
  2>&1 | tee arm-vk-fragcoord-12288.log
echo "exit=$?"

./vk_interp_probe_arm_blob 12288 varying Mali \
  2>&1 | tee arm-vk-varying-12288.log
echo "exit=$?"
```

### 11. Interpret The Result

The control expectation is the same as the Mesa runs: `fragcoord` should pass,
and `varying` is the actual interpolation precision test. A passing ARM blob
run would show the hardware can produce the exact per-pixel varying values
under Arm's compiler/driver stack; a failing run would show the drift is below
the Mesa/Panfrost compiler and GL/Vulkan frontend layers.

Read the result in this order:

1. Confirm the renderer/device line names the proprietary Mali stack.
2. Confirm the `fragcoord` control reports zero mismatches.
3. Confirm `unwritten=0` for Vulkan.
4. Compare `varying` mismatch counts and last-pixel relative error with the
   Mesa/Panfrost runs at the same width.

If `fragcoord` fails, do not use the `varying` result yet. That would mean the
control path, readback path, or driver selection is wrong.
