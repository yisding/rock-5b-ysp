#version 450

/*
 * Fragment shader for the control mode.
 *
 * gl_FragCoord.x is the pixel's own x coordinate. It does not come through the
 * user varying interpolation path, so this should be exact if rasterization and
 * readback are working.
 */

layout(location = 0) out uint bits;

void main()
{
   bits = floatBitsToUint(gl_FragCoord.x);
}
