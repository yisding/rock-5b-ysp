# RK3588 Proprietary ARM Mali Driver Runs

This note is for the Rock 5B / RK3588 / Mali-G610 case only. It is not trying
to produce a generic "any Mali blob" fallback. The goal is to keep the ARM blob
reproducers as close as possible to the Mesa/Panfrost reproducers while
changing only the loader/context setup that is Mesa-specific.

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

That is the clean path for this probe. The Khronos
`EGL_KHR_surfaceless_context` extension exists so applications that render only
to client API targets, such as GL framebuffer objects, do not need a throw-away
EGL surface:
https://registry.khronos.org/EGL/extensions/KHR/EGL_KHR_surfaceless_context.txt

## What Changes

`tiny_interp_probe_arm_blob.c` is a patched copy of `tiny_interp_probe.c`.
The shader strings, triangle, `GL_R32UI` target, raw `glReadPixels` path, and
CPU checker are intentionally unchanged.

Only the EGL setup changes:

- Add `fcntl.h`, `gbm.h`, and `unistd.h`.
- Accept optional `argv[3]` as the DRM render node, defaulting to
  `/dev/dri/renderD128`.
- Open the render node and create a `gbm_device`.
- Replace Mesa's `EGL_PLATFORM_SURFACELESS_MESA` display with
  `EGL_PLATFORM_GBM_KHR`.
- Keep `eglMakeCurrent` surfaceless with `EGL_NO_SURFACE` for draw and read.
- Link with `-lgbm`.

`vk_interp_probe_arm_blob.c` deliberately does not fork the Vulkan test. It
includes `vk_interp_probe.c` so ARM-named build/run scripts can exist without
duplicating or drifting from the canonical Vulkan source. The searched RK3588
libmali ICD advertises Vulkan 1.3, so the existing dynamic-rendering probe is
the right first run on this hardware.

The `*_explained.c` ARM files are the teaching copies:

- `tiny_interp_probe_arm_blob_explained.c` is standalone because the GLES/EGL
  setup really differs from the Mesa tiny probe. It explains each ARM-specific
  step: DRM render node, GBM device, GBM EGL display, and surfaceless
  `eglMakeCurrent`.
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

```bash
cc -O2 -o tiny_interp_probe_arm_blob \
  tiny_interp_probe_arm_blob.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o tiny_interp_probe_arm_blob_explained \
  tiny_interp_probe_arm_blob_explained.c -lEGL -lGLESv2 -lgbm -lm
```

The compact and explained binaries run the same test. Use the compact binary
for logs and the explained binary when reading through the code.

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
