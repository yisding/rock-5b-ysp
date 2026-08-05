// SPDX-License-Identifier: MIT
// Minimal Mali/Panfrost varying-interpolation precision probe.
//
// Addresses the "u_blitter is misusing varyings" hypothesis by removing
// everything except varying interpolation itself: no u_blitter, no texture
// sampling, no TXF, no filtering, no tie-breakers, no window system, no GBM.
// One triangle covers a WIDTH x 1 render target; the vertex shader sets up a
// varying v that must interpolate to exactly x + 0.5 at the center of pixel
// x. The fragment shader stores the raw bits of v to R32UI and the CPU
// checks floor(v) == x after a format-matching glReadPixels.
//
// mode "fragcoord" writes gl_FragCoord.x instead of the varying through the
// otherwise identical pipeline. It reads back bit-exact on Mali-G610, which
// pins the drift on varying interpolation rather than raster or readback.
//
// Build from this directory:
//        cc -O2 -o tiny_interp_probe tiny_interp_probe.c -lEGL -lGLESv2 -lm
// Run:   ./tiny_interp_probe                  # 12288 x 1, varying
//        ./tiny_interp_probe 12288 fragcoord  # control: passes
//        ./tiny_interp_probe 8192             # pow2 control: passes
//        ./tiny_interp_probe 16307 varying    # width used in older captures
//        ./tiny_interp_probe 12288 varying polygon-offset
//                                             # hardware-erratum workaround
//
// Exits 0 when every pixel satisfies floor(v) == x, 2 when any pixel fails,
// 1 on usage or EGL/GL setup errors.

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(x)                                                               \
   do {                                                                        \
      if (!(x)) {                                                              \
         fprintf(stderr, "check failed at line %d, egl=0x%x gl=0x%x\n",        \
                 __LINE__, eglGetError(), glGetError());                       \
         exit(1);                                                              \
      }                                                                        \
   } while (0)

static const char *vs_src =
   "#version 300 es\n"
   "uniform float width;\n"
   "out highp float v;\n"
   "void main() {\n"
   "   vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0,\n"
   "                 gl_VertexID == 2 ? 3.0 : -1.0);\n"
   "   v = (p.x + 1.0) * 0.5 * width;\n"
   "   gl_Position = vec4(p, 0.0, 1.0);\n"
   "}\n";

static const char *fs_varying =
   "#version 300 es\n"
   "in highp float v;\n"
   "out highp uint bits;\n"
   "void main() { bits = floatBitsToUint(v); }\n";

static const char *fs_fragcoord =
   "#version 300 es\n"
   "out highp uint bits;\n"
   "void main() { bits = floatBitsToUint(gl_FragCoord.x); }\n";

static GLuint
compile(GLenum stage, const char *src)
{
   GLuint s = glCreateShader(stage);
   glShaderSource(s, 1, &src, NULL);
   glCompileShader(s);

   GLint ok = 0;
   glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
   if (!ok) {
      char log[2048];
      glGetShaderInfoLog(s, sizeof(log), NULL, log);
      fprintf(stderr, "shader compile failed:\n%s\n", log);
      exit(1);
   }

   return s;
}

int
main(int argc, char **argv)
{
   int width = 12288;
   const char *mode = "varying";
   const char *workaround = "baseline";

   if (argc > 4) {
      fprintf(stderr, "usage: %s [width] [varying|fragcoord] "
                      "[baseline|polygon-offset]\n", argv[0]);
      return 1;
   }

   if (argc > 1) {
      char *end;
      long w = strtol(argv[1], &end, 10);
      if (*argv[1] == '\0' || *end != '\0' || w < 1 || w > (1 << 23)) {
         fprintf(stderr, "usage: %s [width] [varying|fragcoord] "
                         "[baseline|polygon-offset]\n", argv[0]);
         return 1;
      }
      width = (int)w;
   }
   if (argc > 2) {
      mode = argv[2];
      if (strcmp(mode, "varying") != 0 && strcmp(mode, "fragcoord") != 0) {
         fprintf(stderr, "usage: %s [width] [varying|fragcoord] "
                         "[baseline|polygon-offset]\n", argv[0]);
         return 1;
      }
   }
   if (argc > 3) {
      workaround = argv[3];
      if (strcmp(workaround, "baseline") != 0 &&
          strcmp(workaround, "polygon-offset") != 0) {
         fprintf(stderr, "usage: %s [width] [varying|fragcoord] "
                         "[baseline|polygon-offset]\n", argv[0]);
         return 1;
      }
   }
   int use_fragcoord = strcmp(mode, "fragcoord") == 0;
   int use_polygon_offset = strcmp(workaround, "polygon-offset") == 0;

   PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress(
         "eglGetPlatformDisplayEXT");
   CHECK(get_platform_display);

   EGLDisplay dpy = get_platform_display(EGL_PLATFORM_SURFACELESS_MESA,
                                         EGL_DEFAULT_DISPLAY, NULL);
   CHECK(dpy != EGL_NO_DISPLAY);
   CHECK(eglInitialize(dpy, NULL, NULL));
   CHECK(eglBindAPI(EGL_OPENGL_ES_API));

   EGLint cfg_attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                         EGL_SURFACE_TYPE, 0, EGL_NONE};
   EGLConfig cfg;
   EGLint cfg_count = 0;
   CHECK(eglChooseConfig(dpy, cfg_attrs, &cfg, 1, &cfg_count) && cfg_count);

   EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
   EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
   CHECK(ctx != EGL_NO_CONTEXT);
   CHECK(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx));

   fprintf(stderr, "GL_RENDERER=%s\nGL_VERSION=%s\n",
           (const char *)glGetString(GL_RENDERER),
           (const char *)glGetString(GL_VERSION));

   GLint max_size = 0;
   glGetIntegerv(GL_MAX_TEXTURE_SIZE, &max_size);
   if (width > max_size) {
      fprintf(stderr, "width %d exceeds GL_MAX_TEXTURE_SIZE %d\n", width,
              max_size);
      return 1;
   }

   GLuint prog = glCreateProgram();
   glAttachShader(prog, compile(GL_VERTEX_SHADER, vs_src));
   glAttachShader(prog, compile(GL_FRAGMENT_SHADER,
                                use_fragcoord ? fs_fragcoord : fs_varying));
   glLinkProgram(prog);

   GLint ok = 0;
   glGetProgramiv(prog, GL_LINK_STATUS, &ok);
   CHECK(ok);
   glUseProgram(prog);
   glUniform1f(glGetUniformLocation(prog, "width"), (float)width);

   GLuint tex, fbo;
   glGenTextures(1, &tex);
   glBindTexture(GL_TEXTURE_2D, tex);
   glTexStorage2D(GL_TEXTURE_2D, 1, GL_R32UI, width, 1);

   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                          tex, 0);
   CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
   glViewport(0, 0, width, 1);

   CHECK(glGetError() == GL_NO_ERROR);
   if (use_polygon_offset) {
      glEnable(GL_POLYGON_OFFSET_FILL);
      glPolygonOffset(0.0f, 0.0f);
   }
   glDrawArrays(GL_TRIANGLES, 0, 3);
   CHECK(glGetError() == GL_NO_ERROR);

   // Format-matching readback: R32UI read as RED_INTEGER moves raw bits with
   // no conversion. (Not the ES-mandated RGBA_INTEGER combo, but supported
   // here and error-checked below.)
   uint32_t *bits = malloc((size_t)width * sizeof(*bits));
   CHECK(bits);
   glReadPixels(0, 0, width, 1, GL_RED_INTEGER, GL_UNSIGNED_INT, bits);
   CHECK(glGetError() == GL_NO_ERROR);

   long bad = 0;
   int first_bad = -1;
   for (int x = 0; x < width; x++) {
      float v;
      memcpy(&v, &bits[x], sizeof(v));
      if ((long)floorf(v) != x) {
         if (first_bad < 0)
            first_bad = x;
         bad++;
      }
   }

   float last;
   memcpy(&last, &bits[width - 1], sizeof(last));
   double ideal = (double)width - 0.5;
   double rel_err = (ideal - (double)last) / ideal;

   printf("mode=%s workaround=%s width=%d: "
          "floor(v) != x at %ld of %d pixels (first at x=%d)\n",
          mode, workaround, width, bad, width, first_bad);
   printf("last pixel x=%d: v=%.4f expected=%.1f relative_error=%.3e "
          "(%.3f * 2^-10)\n",
          width - 1, last, ideal, rel_err, rel_err * 1024.0);

   free(bits);
   return bad ? 2 : 0;
}
