#version 450

/*
 * Fragment shader for the failing/test mode.
 *
 * A fragment shader runs once for each pixel covered by the triangle. The input
 * "v" is the interpolated value from the vertex shader.
 */

layout(location = 0) in float v;
layout(location = 0) out uint bits;

void main()
{
   /*
    * Store the exact bit pattern of the float, not a rounded integer version of
    * it. The CPU will reinterpret these bits as a float during verification.
    */
   bits = floatBitsToUint(v);
}
