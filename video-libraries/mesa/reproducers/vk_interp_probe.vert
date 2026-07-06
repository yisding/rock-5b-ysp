#version 450
layout(push_constant) uniform PC { float width; } pc;
layout(location = 0) out float v;
void main() {
   vec2 p = vec2(gl_VertexIndex == 1 ? 3.0 : -1.0,
                 gl_VertexIndex == 2 ? 3.0 : -1.0);
   v = (p.x + 1.0) * 0.5 * pc.width;
   gl_Position = vec4(p, 0.0, 1.0);
}
