/*
 * vk_interp_probe_arm_blob_explained.c
 *
 * This is the ARM/RK3588 teaching entry point for the Vulkan reproducer.
 *
 * It intentionally does not contain a separate Vulkan implementation.
 *
 * Why the GL ARM file had to be different:
 *
 *   OpenGL ES reaches the driver through EGL. The Mesa GL reproducer asks EGL
 *   for EGL_PLATFORM_SURFACELESS_MESA, which is a Mesa platform extension.
 *   The proprietary RK3588/G610 libmali stack is packaged around GBM, Wayland
 *   plus GBM, and X11 plus GBM platform libraries. Therefore the ARM GL file
 *   opens a DRM render node, creates a gbm_device, and asks EGL for
 *   EGL_PLATFORM_GBM_KHR instead.
 *
 *   Even there, the ARM GL file still uses EGL_NO_SURFACE after context
 *   creation, because the public RK3588/G610 GBM blobs expose
 *   EGL_KHR_surfaceless_context and GL_OES_surfaceless_context. In other
 *   words: only the EGL display discovery is different; the rendering target
 *   remains the same offscreen GL framebuffer object.
 *
 * Why the Vulkan ARM file does not need a source fork:
 *
 *   Vulkan does not use EGL to create a rendering context. Vulkan talks to an
 *   Installable Client Driver, or ICD, through the Vulkan loader. The Rockchip
 *   libmali package installs a Mali Vulkan ICD JSON, and that JSON advertises
 *   Vulkan API version 1.3.276 for this stack.
 *
 *   The canonical vk_interp_probe.c already selects a Vulkan physical device
 *   by name substring, defaulting to "Mali", creates a Vulkan 1.3 instance and
 *   device, uses dynamic rendering, renders to a VK_FORMAT_R32_UINT image, and
 *   copies the raw bits back to a CPU-visible buffer.
 *
 *   Since those requirements match the RK3588 libmali Vulkan stack, adding a
 *   second copy of the Vulkan code would make the reproducers worse: future
 *   fixes could land in one file and not the other. This file gives scripts and
 *   logs an ARM-specific binary name while compiling the same explained Vulkan
 *   host program.
 *
 * Build from this directory:
 *
 *   glslc vk_interp_probe_explained.vert \
 *      -o vk_interp_probe_explained.vert.spv
 *   glslc vk_interp_probe_explained.varying.frag \
 *      -o vk_interp_probe_explained.varying.frag.spv
 *   glslc vk_interp_probe_explained.fragcoord.frag \
 *      -o vk_interp_probe_explained.fragcoord.frag.spv
 *   cc -O2 -o vk_interp_probe_arm_blob_explained \
 *      vk_interp_probe_arm_blob_explained.c -lvulkan -lm
 *
 * Run:
 *
 *   ./vk_interp_probe_arm_blob_explained
 *   ./vk_interp_probe_arm_blob_explained 12288 fragcoord
 *   ./vk_interp_probe_arm_blob_explained 16307 varying
 *
 * The included file opens the explained SPIR-V filenames above. That is why
 * this wrapper builds those shader files rather than the compact shader files.
 */

#include "vk_interp_probe_explained.c"
