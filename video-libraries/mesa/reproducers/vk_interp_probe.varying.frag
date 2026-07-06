#version 450
layout(location = 0) in float v;
layout(location = 0) out uint bits;
void main() { bits = floatBitsToUint(v); }
