#version 450
layout(location = 0) out uint bits;
void main() { bits = floatBitsToUint(gl_FragCoord.x); }
