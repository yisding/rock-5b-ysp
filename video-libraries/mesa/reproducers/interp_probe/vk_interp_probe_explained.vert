// SPDX-License-Identifier: MIT
#version 450

/*
 * Vertex shader for vk_interp_probe_explained.c.
 *
 * A vertex shader runs once for each corner of the triangle. This test draws
 * one oversized triangle that covers the whole W-by-1 render target.
 *
 * Vulkan calls the current vertex number gl_VertexIndex:
 *
 *   0 -> lower-left corner
 *   1 -> far lower-right corner
 *   2 -> far upper-left corner
 *
 * The coordinates are in "clip space", where visible x/y normally runs from
 * -1 to +1. We intentionally use 3.0 for two coordinates to make a triangle
 * large enough to cover the full rectangle.
 */

layout(push_constant) uniform PC {
   /*
    * Push constants are tiny pieces of data the CPU can pass to shaders without
    * creating a full buffer. Here the only per-run value is the render width.
    */
   float width;
} pc;

/*
 * This output is the test varying. The GPU interpolates it across the triangle
 * before the fragment shader reads it.
 */
layout(location = 0) out float v;

void main()
{
   vec2 p = vec2(gl_VertexIndex == 1 ? 3.0 : -1.0,
                 gl_VertexIndex == 2 ? 3.0 : -1.0);

   /*
    * At the left edge p.x is -1, so v is 0.
    * At the right edge p.x is +1, so v is width.
    * Pixel x should therefore see v = x + 0.5 at its center.
    */
   v = (p.x + 1.0) * 0.5 * pc.width;

   gl_Position = vec4(p, 0.0, 1.0);
}
