# RK3588 Proprietary ARM Mali Driver Runs

This note is for the Rock 5B / RK3588 / Mali-G610 case only. It is not trying
to produce a generic "any Mali blob" fallback. The goal is to keep the ARM blob
reproducers as close as possible to the Mesa/Panfrost reproducers while
changing only the loader/context setup that is Mesa-specific.

## Capability Notes

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

## Build

Run from this directory:

```bash
cc -O2 -o tiny_interp_probe_arm_blob \
  tiny_interp_probe_arm_blob.c -lEGL -lGLESv2 -lgbm -lm

glslc vk_interp_probe.vert           -o vk_interp_probe.vert.spv
glslc vk_interp_probe.varying.frag   -o vk_interp_probe.varying.frag.spv
glslc vk_interp_probe.fragcoord.frag -o vk_interp_probe.fragcoord.frag.spv
cc -O2 -o vk_interp_probe_arm_blob vk_interp_probe_arm_blob.c -lvulkan -lm
```

If the proprietary libraries are not installed in the system loader path, point
the dynamic linker and Vulkan loader at them explicitly. Do not carry over Mesa
driver overrides from the Mesa reproducers:

```bash
unset LIBGL_DRIVERS_PATH
unset GBM_BACKENDS_PATH
unset EGL_PLATFORM
unset MESA_LOADER_DRIVER_OVERRIDE

export LD_LIBRARY_PATH=/path/to/libmali/lib:$LD_LIBRARY_PATH
export VK_ICD_FILENAMES=/path/to/mali.json
```

`VK_ICD_FILENAMES` is only needed when the Mali ICD JSON is not installed in a
standard Vulkan loader directory such as `/usr/share/vulkan/icd.d`.

## Run

```bash
./tiny_interp_probe_arm_blob
./tiny_interp_probe_arm_blob 12288 fragcoord
./tiny_interp_probe_arm_blob 16307 varying /dev/dri/renderD128

./vk_interp_probe_arm_blob
./vk_interp_probe_arm_blob 12288 fragcoord
./vk_interp_probe_arm_blob 16307 varying
```

Check stderr before interpreting the numbers:

- GLES should print the proprietary Mali `GL_RENDERER` and `GL_VERSION`, not a
  Mesa/Panfrost renderer.
- Vulkan should print a Mali physical device and the blob's `apiVersion`.

The control expectation is the same as the Mesa runs: `fragcoord` should pass,
and `varying` is the actual interpolation precision test. A passing ARM blob
run would show the hardware can produce the exact per-pixel varying values
under Arm's compiler/driver stack; a failing run would show the drift is below
the Mesa/Panfrost compiler and GL/Vulkan frontend layers.
