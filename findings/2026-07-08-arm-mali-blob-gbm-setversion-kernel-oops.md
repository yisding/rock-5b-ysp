# ARM Mali blob GBM path kernel-Oopses in drm_setversion on the Radxa 5.10 vendor kernel

> Scope: `video-libraries/mesa/reproducers/interp_probe/tiny_interp_probe_arm_blob.c`
> run against the proprietary Arm/Rockchip libmali G610 stack on Rock 5B / RK3588.
> Source: live run on the board; kernel Oops + task backtraces captured from
> `dmesg` and `/proc/<pid>/stack`. Supersedes the "reproducer-result PENDING"
> status in `2026-07-07-arm-mali-blob-reproducer-readiness.md`.
> Runtime: `rock-5b-vendor-510`, `Linux 5.10.110-39-rockchip aarch64` (`#17309c71b`),
> Debian 11 (bullseye) Radxa vendor distro, `libmali-valhall-g610-g6p0-x11-gbm
> 1.9-1`, `bifrost_kbase` loaded, Mali FW git_sha `9b8db9aa05a7...`.
> Date: 2026-07-08.
> Trust: MEASURED (reproduced twice; full Oops + hung-task backtraces captured).

## The fact

Running the GLES ARM-blob interp reproducer through libmali's **GBM/EGL path
does not merely fail — it crashes the kernel and wedges DRM until reboot.** The
reproducer builds and links fine (see below), and the userspace setup is
correct, but the first DRM ioctl libmali makes on the way up kills the box.

### Mechanism (two independent vendor-kernel defects)

libmali's GBM/EGL bring-up issues the **legacy `DRM_IOCTL_SET_VERSION`** on the
primary `card` node backing the render node it was given. On this kernel:

1. **`drm_setversion` NULL-derefs.** rockchip-drm is a modern KMS/render driver
   (not `DRIVER_LEGACY`), and its `SET_VERSION` handler dereferences a NULL at
   offset `0x10`, faulting in kernel mode:

   ```
   Unable to handle kernel NULL pointer dereference at virtual address 0x10
   pc : drm_setversion+0x80/0x18c
   CPU: 0 PID: 2241 Comm: tiny_interp_pro  Tainted: G           O  5.10.110-39-rockchip
   Call trace:
     drm_setversion+0x80/0x18c
     drm_ioctl_kernel+0xb0/0x104
     drm_ioctl+0x2fc/0x348
     vfs_ioctl / __arm64_sys_ioctl / el0_svc ...
   ```

2. **The Oops teardown then deadlocks.** The kernel kills the faulting task, and
   `do_exit` closes its DRM fd, which runs rockchip-drm's lastclose. That path
   blocks forever trying to re-acquire DRM master, so **the task never finishes
   dying and holds `drm_global_mutex` indefinitely** (`/proc/2241/stack`):

   ```
   drm_master_internal_acquire+0x2c/0x58
   drm_client_modeset_commit
   __drm_fb_helper_restore_fbdev_mode_unlocked
   rockchip_drm_lastclose
   drm_lastclose / drm_release / __fput
   do_exit  <- (entered from) die / die_kernel_fault / do_page_fault / drm_setversion
   ```

   Every subsequent DRM open then hangs on that mutex (`/proc/2315/stack`):

   ```
   drm_open+0x80/0x1e0
   drm_stub_open / chrdev_open / do_dentry_open / ... / __arm64_sys_openat
   ```

The processes are unkillable (uninterruptible `D` state inside the driver);
`timeout -s KILL` cannot reap them. After the Oops the log fills with `rk806
spi2.0: SPI transfer timed out` (the **PMIC**), `rk3x-i2c ... timeout`, and
`rockchip_cpufreq/dmcfreq ... failed to set voltage (... -110)` — the board is
left degraded and needs a reboot, in practice a hard power cycle.

### Same bug, two faces (compositor vs headless)

- **With a display server holding DRM master** (sddm/Xorg on `card0`):
  `SET_VERSION` blocks uninterruptibly on the master lock — task in `D` state,
  `wchan drm_setversion` — before reaching the NULL deref. Stopping sddm did not
  help: Xorg itself then wedged in `D`, and the earlier stuck probe stayed stuck.
- **Headless (no compositor, booted after reboot):** `SET_VERSION` proceeds past
  the master check and hits the NULL deref → full kernel Oops as above.

So a "just stop the compositor" mitigation is **not** sufficient; the headless
path is the one that actually Oopses.

### Why GBM is unavoidable and what does work

The installed blob advertises **only** `EGL_KHR_platform_gbm` and
`EGL_KHR_platform_x11` — there is **no surfaceless EGL platform** (no
`EGL_MESA_platform_surfaceless`; it exports only `eglGetDisplay`, plus
`eglGetPlatformDisplayEXT` via `EGL_EXT_platform_base`). The Mali GPU itself is
`/dev/mali0` (proprietary kbase, no DRM node); GBM is reached through the
rockchip-drm *display* node, which is what drags in the crashing `SET_VERSION`.

The intended path for this `x11-gbm` variant is **as a client under a running X
server**: the X server owns DRM master and libmali clients never call
`SET_VERSION`. libmali here exports the X11 pieces (`EGL_KHR_platform_x11`,
`eglCreatePbufferSurface`), `libX11`/`libX11-xcb`/`libxcb*` are `NEEDED` by the
blob, and `/usr/bin/Xorg` is present. That is the untried, recommended route to
actually get an ARM-blob interp number.

## Build / run facts (still valid)

- **Link:** the vendor libmali ships `libEGL`/`libGLESv2`/`libgbm` as
  zero-symbol forwarding stubs under `/usr/lib/aarch64-linux-gnu/mali`, so
  `-lEGL -lGLESv2 -lgbm` fails with undefined references. Link libmali directly:
  `cc -O2 -o tiny_interp_probe_arm_blob tiny_interp_probe_arm_blob.c -lmali -lm`
  (`ldd` then shows `libmali.so.1`). Dev headers
  (`libegl1-mesa-dev`/`libgles2-mesa-dev`/`libgbm-dev`) must be installed.
- **Reproducer guard:** `tiny_interp_probe_arm_blob.c` now REFUSES TO RUN BY
  DEFAULT, printing the backing DRM driver and the reason, and exiting `1`
  before any DRM open. `MALI_PROBE_FORCE_SETVERSION=1` overrides the Oops gate
  (only on a fixed kernel); `MALI_PROBE_ALLOW_DRM_MASTER=1` overrides the
  secondary compositor gate. Verified: default run prints the refusal and exits
  1 without touching the GPU.

## Why it matters / follow-up

- Do **not** run the GBM ARM-blob reproducer on this kernel — it is a
  deterministic kernel crash, not a flake. The gate now prevents accidental runs.
- The ARM-blob GLES interp number was captured via the **X11-client path**
  (`tiny_interp_probe_arm_blob_x11`) on 2026-07-08 — it runs cleanly (no Oops)
  and the drift is bit-identical to Mesa/Panfrost. See
  [`2026-07-08-arm-mali-blob-interp-drift-bit-identical-to-mesa.md`](2026-07-08-arm-mali-blob-interp-drift-bit-identical-to-mesa.md).
  The GBM path here remains the crashing one and stays gated off.
- Kernel-bug angle (watchlist / upstream): rockchip-drm's `drm_setversion`
  NULL-deref and the `rockchip_drm_lastclose -> drm_master_internal_acquire`
  teardown deadlock are both defects in `5.10.110-39-rockchip`. A newer vendor
  kernel may fix `drm_setversion`; re-test before trusting any GBM path.
- Pinned to: kernel `5.10.110-39-rockchip`, libmali `1.9-1` DDK g6p0 `x11-gbm`.
  A kernel or libmali bump can change this answer — this goes stale silently.
