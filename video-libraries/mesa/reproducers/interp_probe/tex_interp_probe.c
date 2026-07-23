// Minimal Mali/Panfrost ordinary-TEX varying-interpolation probe.
//
// A normalized floating-point varying runs from 0 to 1 across a wide,
// non-power-of-two render target. The fragment shader samples an R32F ramp
// with texture() and nearest filtering. Source texel x contains float(x), so
// every destination pixel x must return float(x).
//
// This is the non-integer TEX counterpart to tiny_interp_probe.c. It verifies
// that the zero-valued polygon-offset workaround avoids the Mali hardware
// erratum for an ordinary filtered texture instruction, not only for the raw
// varying or integer-coordinate TXF paths.
//
// Build:
//   cc -O2 -o tex_interp_probe tex_interp_probe.c -lEGL -lGLESv2
// Run:
//   ./tex_interp_probe 12288 baseline
//   ./tex_interp_probe 12288 polygon-offset
//
// Exits 0 when every destination pixel sampled its matching source texel,
// 2 when any pixel sampled the wrong texel, and 1 on usage or setup errors.

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
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
   "out highp float u;\n"
   "void main() {\n"
   "   vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0,\n"
   "                 gl_VertexID == 2 ? 3.0 : -1.0);\n"
   "   u = (p.x + 1.0) * 0.5;\n"
   "   gl_Position = vec4(p, 0.0, 1.0);\n"
   "}\n";

static const char *fs_src =
   "#version 300 es\n"
   "uniform highp sampler2D source_tex;\n"
   "in highp float u;\n"
   "layout(location = 0) out highp uint bits;\n"
   "void main() {\n"
   "   highp float sampled = texture(source_tex, vec2(u, 0.5)).r;\n"
   "   bits = floatBitsToUint(sampled);\n"
   "}\n";

static GLuint
compile(GLenum stage, const char *src)
{
   GLuint shader = glCreateShader(stage);
   glShaderSource(shader, 1, &src, NULL);
   glCompileShader(shader);

   GLint ok = 0;
   glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
   if (!ok) {
      char log[2048];
      glGetShaderInfoLog(shader, sizeof(log), NULL, log);
      fprintf(stderr, "shader compile failed:\n%s\n", log);
      exit(1);
   }

   return shader;
}

int
main(int argc, char **argv)
{
   int width = 12288;
   const char *workaround = "baseline";

   if (argc > 3) {
      fprintf(stderr, "usage: %s [width] [baseline|polygon-offset]\n",
              argv[0]);
      return 1;
   }

   if (argc > 1) {
      char *end;
      long parsed = strtol(argv[1], &end, 10);
      if (*argv[1] == '\0' || *end != '\0' || parsed < 1 ||
          parsed > (1 << 23)) {
         fprintf(stderr, "usage: %s [width] [baseline|polygon-offset]\n",
                 argv[0]);
         return 1;
      }
      width = (int)parsed;
   }

   if (argc > 2) {
      workaround = argv[2];
      if (strcmp(workaround, "baseline") != 0 &&
          strcmp(workaround, "polygon-offset") != 0) {
         fprintf(stderr, "usage: %s [width] [baseline|polygon-offset]\n",
                 argv[0]);
         return 1;
      }
   }

   const int use_polygon_offset =
      strcmp(workaround, "polygon-offset") == 0;

   PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress(
         "eglGetPlatformDisplayEXT");
   CHECK(get_platform_display);

   EGLDisplay dpy = get_platform_display(EGL_PLATFORM_SURFACELESS_MESA,
                                         EGL_DEFAULT_DISPLAY, NULL);
   CHECK(dpy != EGL_NO_DISPLAY);
   CHECK(eglInitialize(dpy, NULL, NULL));
   CHECK(eglBindAPI(EGL_OPENGL_ES_API));

   const EGLint cfg_attrs[] = {
      EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
      EGL_SURFACE_TYPE, 0,
      EGL_NONE,
   };
   EGLConfig cfg;
   EGLint cfg_count = 0;
   CHECK(eglChooseConfig(dpy, cfg_attrs, &cfg, 1, &cfg_count) && cfg_count);

   const EGLint ctx_attrs[] = {
      EGL_CONTEXT_CLIENT_VERSION, 3,
      EGL_NONE,
   };
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

   GLuint program = glCreateProgram();
   glAttachShader(program, compile(GL_VERTEX_SHADER, vs_src));
   glAttachShader(program, compile(GL_FRAGMENT_SHADER, fs_src));
   glLinkProgram(program);

   GLint ok = 0;
   glGetProgramiv(program, GL_LINK_STATUS, &ok);
   CHECK(ok);
   glUseProgram(program);
   glUniform1i(glGetUniformLocation(program, "source_tex"), 0);

   float *source = malloc((size_t)width * sizeof(*source));
   CHECK(source);
   for (int x = 0; x < width; x++)
      source[x] = (float)x;

   GLuint source_tex;
   glGenTextures(1, &source_tex);
   glBindTexture(GL_TEXTURE_2D, source_tex);
   glTexStorage2D(GL_TEXTURE_2D, 1, GL_R32F, width, 1);
   glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, 1, GL_RED, GL_FLOAT,
                   source);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

   GLuint target_tex, fbo;
   glGenTextures(1, &target_tex);
   glBindTexture(GL_TEXTURE_2D, target_tex);
   glTexStorage2D(GL_TEXTURE_2D, 1, GL_R32UI, width, 1);

   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                          target_tex, 0);
   CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);

   glBindTexture(GL_TEXTURE_2D, source_tex);
   glViewport(0, 0, width, 1);

   CHECK(glGetError() == GL_NO_ERROR);
   if (use_polygon_offset) {
      glEnable(GL_POLYGON_OFFSET_FILL);
      glPolygonOffset(0.0f, 0.0f);
   }
   glDrawArrays(GL_TRIANGLES, 0, 3);
   CHECK(glGetError() == GL_NO_ERROR);

   uint32_t *bits = malloc((size_t)width * sizeof(*bits));
   CHECK(bits);
   glReadPixels(0, 0, width, 1, GL_RED_INTEGER, GL_UNSIGNED_INT, bits);
   CHECK(glGetError() == GL_NO_ERROR);

   long mismatches = 0;
   int first_bad = -1;
   float first_value = 0.0f;
   float last_value = 0.0f;

   for (int x = 0; x < width; x++) {
      float sampled;
      memcpy(&sampled, &bits[x], sizeof(sampled));
      if (sampled != (float)x) {
         if (first_bad < 0) {
            first_bad = x;
            first_value = sampled;
         }
         mismatches++;
      }
      if (x == width - 1)
         last_value = sampled;
   }

   printf("fetch=TEX filter=nearest workaround=%s width=%d: "
          "sampled texel != x at %ld of %d pixels (first at x=%d",
          workaround, width, mismatches, width, first_bad);
   if (first_bad >= 0)
      printf(", sampled=%.0f", first_value);
   printf(")\n");
   printf("last pixel x=%d: sampled=%.0f expected=%d shift=%+.0f\n",
          width - 1, last_value, width - 1,
          last_value - (float)(width - 1));

   free(bits);
   free(source);
   return mismatches ? 2 : 0;
}
