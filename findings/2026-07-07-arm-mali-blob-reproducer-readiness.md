# ARM Mali blob interp reproducer readiness on the Radxa Bullseye 5.10 vendor distro

> Scope: `video-libraries/mesa/reproducers/interp_probe` ARM-blob variants
> (`tiny_interp_probe_arm_blob.c`, `vk_interp_probe_arm_blob.c`) against the
> proprietary Arm/Rockchip Mali userspace on the same Rock 5B / RK3588 /
> Mali-G610 hardware.
> Source: on-board inspection; cross-checks against
> `video-libraries/mesa/docs/arm-mali-blob-stack.md` "Runtime Verification
> Checklist" / "Current Unknowns".
> Runtime: `rock-5b`, `Linux 5.10.110-15-rockchip aarch64`, Debian GNU/Linux 11
> (bullseye), Radxa vendor distro (repos `radxa-repo.github.io/bullseye`
> `bullseye main` + `rockchip-bullseye main`).
> Date: 2026-07-07.
> Trust: MEASURED (live commands on the board); the reproducers were **not yet
> run** — this records build/runtime *readiness*, not a `GL_RENDERER`-confirmed
> reproducer result.
>
> **UPDATE 2026-07-08:** the readiness below is accurate, but actually *running*
> the GBM path does not work — it **kernel-Oopses** in `drm_setversion` and
> wedges DRM until reboot. See
> [`2026-07-08-arm-mali-blob-gbm-setversion-kernel-oops.md`](2026-07-08-arm-mali-blob-gbm-setversion-kernel-oops.md).
> Also note the build command below is wrong for this vendor layout: the
> `mali/libEGL|libGLESv2|libgbm` stubs export 0 symbols, so link `-lmali` (not
> `-lEGL -lGLESv2 -lgbm`).

## The fact

On this vendor distro the **GLES ARM-blob reproducer path is fully wired for
the proprietary Mali stack; the Vulkan path is not available at all** from the
configured repos.

### GLES / EGL / GBM path — runtime-ready, one build gap

Measured present:

- Kernel driver: `bifrost_kbase` module loaded (the proprietary Arm kbase
  driver, **not** Panfrost/Panthor). `lsmod` shows `bifrost_kbase` with 3 refs.
- libmali blob: package `libmali-valhall-g610-g6p0-x11-gbm 1.9-1` owns
  `/usr/lib/aarch64-linux-gnu/libmali.so.1.9.0` (DDK line **g6p0**, platform
  variant **x11-gbm**). SONAME `libmali.so.1`.
- Wrapper stubs (5928-byte dispatchers into libmali) under
  `/usr/lib/aarch64-linux-gnu/mali/`: `libEGL.so{,.1}`, `libGLESv2.so{,.2}`,
  `libgbm.so{,.1}`, `libGLESv1_CM.so{,.1}`, `libMaliOpenCL.so{,.1}`. The EGL
  wrapper's `NEEDED` is `libmali_hook.so.1` + `libmali.so.1`.
- Loader ordering: `/etc/ld.so.conf.d/00-aarch64-mali.conf` adds the `mali`
  dir, and `ldconfig -p` resolves each soname to the **mali wrapper first**,
  ahead of the stock mesa copy, e.g.
  `libEGL.so.1 => /usr/lib/aarch64-linux-gnu/mali/libEGL.so.1` then
  `... => /lib/aarch64-linux-gnu/libEGL.so.1`. So `libEGL.so.1` /
  `libGLESv2.so.2` / `libgbm.so.1` resolve into libmali at runtime.
- Blob exposes `gbm_create_device`, `eglGetPlatformDisplayEXT`,
  `eglCreateContext`, `glDrawArrays`, and embeds `EGL_KHR_surfaceless_context`,
  `EGL_KHR_platform_gbm`, `GL_OES_surfaceless_context` — the exact loader model
  (`EGL_PLATFORM_GBM_KHR` + `EGL_NO_SURFACE`) the ARM GLES reproducer needs.
- Render node `/dev/dri/renderD128` (+ `renderD129`) present; the invoking user
  is in group `render` (106) and `video` (44) — no sudo needed to open the node.
- Firmware `mali_csffw.bin` present (`/lib/firmware/mali_csffw.bin`,
  `/usr/lib/firmware/mali_csffw.bin`, and
  `/usr/lib/firmware/arm/mali/arch10.8/mali_csffw.bin`).
- Toolchain: `cc`/`gcc`/`make` present.

Missing to **build** (only gap for GLES):

- Khronos dev headers absent — `EGL/egl.h`, `GLES3/gl3.h`, `gbm.h`,
  `KHR/khrplatform.h` all not found; no `*-dev` packages installed. apt has
  candidates cached: `libegl1-mesa-dev`, `libgles2-mesa-dev`, `libgbm-dev`
  (all `20.3.5-1`). After installing those, build from the reproducer dir with
  `cc -O2 -L/usr/lib/aarch64-linux-gnu/mali -o tiny_interp_probe_arm_blob
  tiny_interp_probe_arm_blob.c -lEGL -lGLESv2 -lgbm -lm` and run
  `fragcoord` (control) then `varying`. **Confirm the stderr `GL_RENDERER`
  names Mali before trusting numbers** — a stock mesa `libEGL` also exists on
  disk, so the renderer line is the proof the blob answered.

### Vulkan path — not available from these repos

- The g6p0 blob has **no** `vk_icdGetInstanceProcAddr`, `vkCreateInstance`, or
  `vkEnumeratePhysicalDevices` (checked on the installed x11-gbm blob and on
  the downloaded pure-`gbm` blob). No `libMaliVulkan.so`, no Mali Vulkan ICD
  JSON under `/usr/share/vulkan/icd.d`.
- Every G610 package the Radxa repo offers is the **same DDK line g6p0
  v1.9-1**, differing only by platform: `dummy`, `gbm`, `wayland-gbm`,
  `x11-gbm`. `apt-get download libmali-valhall-g610-g6p0-gbm` + `dpkg-deb -c`
  confirmed the pure-`gbm` package ships only EGL/GLES/GBM/OpenCL wrappers —
  no Vulkan wrapper or ICD. So **no `apt install` from the configured repos
  yields ARM-blob Vulkan.**
- `glslc` is also absent (repo only has `glslang-tools` →
  `glslangValidator`), but that is moot without a Vulkan driver.

## Why it matters / follow-up

Resolves several items in `arm-mali-blob-stack.md`'s "Current Unknowns" /
"Runtime Verification Checklist": the installed DDK line is **g6p0**
(`x11-gbm`), the kernel ABI is the **`bifrost_kbase`** proprietary module, the
render node is `renderD128`, and the surfaceless extension strings are backed by
the actually-installed blob. Still open: an actual reproducer run capturing
`GL_RENDERER` / `GL_VERSION` and the `fragcoord`-pass-then-`varying` result.

For the ARM **Vulkan** datapoint the only route is an **out-of-distro** newer
libmali (`g13p0`/`g24p0` from `tsukumijima/libmali-rockchip`, which advertise
Vulkan 1.3.276) installed manually. That replaces the whole libmali — it would
also swap the working GLES path, so it must be treated as a deliberate,
reversible step with `GL_RENDERER` re-verified afterward. Mesa `panvk` is not a
substitute here: it is the Panfrost/Mesa stack the ARM reproducer exists to
compare *against*, and bullseye's Mesa (20.3.5) predates panvk.

Watchlist-relevant (goes stale silently): this is pinned to the Radxa
bullseye repo state on 2026-07-07 and libmali `1.9-1` / DDK g6p0; a repo bump to
a Vulkan-capable G610 build would change the Vulkan answer.
