// RK3588 / proprietary ARM Mali userspace variant of vk_interp_probe.c.
//
// The Rockchip libmali ICD for the RK3588/G610 stack advertises Vulkan 1.3,
// so there is no ARM-specific Vulkan source patch for this reproducer. Keep
// the shader, dynamic-rendering setup, copy-to-buffer readback, and CPU
// checker in one place by building this ARM-named wrapper around the canonical
// source file. See README-arm-blob.md for the capability notes.

#include "vk_interp_probe.c"
