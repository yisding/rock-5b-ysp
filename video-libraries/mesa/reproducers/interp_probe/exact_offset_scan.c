// SPDX-License-Identifier: MIT
// Scan which one-triangle widths produce bit-identical varying interpolation
// with and without the zero-valued polygon-offset workaround.
//
// The draw is the same fullscreen-style triangle as tiny_interp_probe.c.  For
// each width, render once with baseline rasterizer state and once with
// GL_POLYGON_OFFSET_FILL + glPolygonOffset(0, 0), read back raw R32UI float
// bits, and classify:
//
//   same-as-offset: baseline raw bits equal workaround raw bits at every pixel
//   baseline-exact: baseline raw bits equal float(x + 0.5) at every pixel
//   offset-exact: workaround raw bits equal float(x + 0.5) at every pixel
//   baseline-floor-pass: floor(baseline_v) == x at every pixel
//
// Build:
//   cc -O2 -Wall -Wextra -Werror -o exact_offset_scan exact_offset_scan.c -lEGL -lGLESv2 -lm
//
// Run:
//   ./exact_offset_scan             # widths 1..4096, concise ranges
//   ./exact_offset_scan 8192        # widths 1..8192, concise ranges
//   ./exact_offset_scan --details   # also print per-width mismatch counts

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

static const char *fs_src =
   "#version 300 es\n"
   "in highp float v;\n"
   "out highp uint bits;\n"
   "void main() { bits = floatBitsToUint(v); }\n";

struct width_result {
   unsigned same_as_offset;
   unsigned baseline_exact;
   unsigned offset_exact;
   unsigned baseline_floor_pass;
   unsigned offset_floor_pass;
};

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

static uint32_t
float_bits(float f)
{
   uint32_t bits;
   memcpy(&bits, &f, sizeof(bits));
   return bits;
}

static float
bits_float(uint32_t bits)
{
   float f;
   memcpy(&f, &bits, sizeof(f));
   return f;
}

static void
draw_and_read(GLint width_loc, int width, int use_offset, uint32_t *bits)
{
   glUniform1f(width_loc, (float)width);
   glViewport(0, 0, width, 1);

   if (use_offset) {
      glEnable(GL_POLYGON_OFFSET_FILL);
      glPolygonOffset(0.0f, 0.0f);
   } else {
      glDisable(GL_POLYGON_OFFSET_FILL);
   }

   glDrawArrays(GL_TRIANGLES, 0, 3);
   CHECK(glGetError() == GL_NO_ERROR);

   glReadPixels(0, 0, width, 1, GL_RED_INTEGER, GL_UNSIGNED_INT, bits);
   CHECK(glGetError() == GL_NO_ERROR);
}

static void
print_ranges(const char *label, const struct width_result *results,
             unsigned count, unsigned (*pred)(const struct width_result *))
{
   printf("%s:", label);

   int printed = 0;
   for (unsigned w = 1; w <= count;) {
      if (!pred(&results[w])) {
         w++;
         continue;
      }

      unsigned start = w;
      while (w + 1 <= count && pred(&results[w + 1]))
         w++;

      printf("%s%u", printed ? "," : " ", start);
      if (w != start)
         printf("-%u", w);
      printed = 1;
      w++;
   }

   if (!printed)
      printf(" none");
   printf("\n");
}

static unsigned
same_as_offset(const struct width_result *r)
{
   return r->same_as_offset;
}

static unsigned
baseline_exact(const struct width_result *r)
{
   return r->baseline_exact;
}

static unsigned
offset_exact(const struct width_result *r)
{
   return r->offset_exact;
}

static unsigned
baseline_floor_pass(const struct width_result *r)
{
   return r->baseline_floor_pass;
}

static unsigned
offset_floor_pass(const struct width_result *r)
{
   return r->offset_floor_pass;
}

int
main(int argc, char **argv)
{
   int max_width = 4096;
   int details = 0;

   for (int i = 1; i < argc; i++) {
      if (!strcmp(argv[i], "--details")) {
         details = 1;
      } else {
         char *end;
         long w = strtol(argv[i], &end, 10);
         if (*argv[i] == '\0' || *end != '\0' || w < 1 || w > (1 << 23)) {
            fprintf(stderr, "usage: %s [--details] [max-width]\n", argv[0]);
            return 1;
         }
         max_width = (int)w;
      }
   }

   if (argc > 3) {
      fprintf(stderr, "usage: %s [--details] [max-width]\n", argv[0]);
      return 1;
   }

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
   if (max_width > max_size) {
      fprintf(stderr, "max width %d exceeds GL_MAX_TEXTURE_SIZE %d\n",
              max_width, max_size);
      return 1;
   }

   GLuint prog = glCreateProgram();
   glAttachShader(prog, compile(GL_VERTEX_SHADER, vs_src));
   glAttachShader(prog, compile(GL_FRAGMENT_SHADER, fs_src));
   glLinkProgram(prog);

   GLint ok = 0;
   glGetProgramiv(prog, GL_LINK_STATUS, &ok);
   CHECK(ok);
   glUseProgram(prog);
   GLint width_loc = glGetUniformLocation(prog, "width");
   CHECK(width_loc >= 0);

   GLuint tex, fbo;
   glGenTextures(1, &tex);
   glBindTexture(GL_TEXTURE_2D, tex);
   glTexStorage2D(GL_TEXTURE_2D, 1, GL_R32UI, max_width, 1);

   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                          tex, 0);
   CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);

   uint32_t *baseline = calloc((size_t)max_width, sizeof(*baseline));
   uint32_t *offset = calloc((size_t)max_width, sizeof(*offset));
   struct width_result *results =
      calloc((size_t)max_width + 1, sizeof(*results));
   CHECK(baseline && offset && results);

   unsigned same_count = 0;
   unsigned baseline_exact_count = 0;
   unsigned offset_exact_count = 0;
   unsigned baseline_floor_count = 0;
   unsigned offset_floor_count = 0;

   if (details) {
      printf("width,diff_pixels,baseline_exact_bad,offset_exact_bad,"
             "baseline_floor_bad,offset_floor_bad,first_diff,"
             "baseline_first_exact_bad,offset_first_exact_bad\n");
   }

   for (int width = 1; width <= max_width; width++) {
      draw_and_read(width_loc, width, 0, baseline);
      draw_and_read(width_loc, width, 1, offset);

      unsigned diff = 0;
      unsigned baseline_exact_bad = 0;
      unsigned offset_exact_bad = 0;
      unsigned baseline_floor_bad = 0;
      unsigned offset_floor_bad = 0;
      int first_diff = -1;
      int baseline_first_exact_bad = -1;
      int offset_first_exact_bad = -1;

      for (int x = 0; x < width; x++) {
         const uint32_t expected = float_bits((float)x + 0.5f);
         const float baseline_f = bits_float(baseline[x]);
         const float offset_f = bits_float(offset[x]);

         if (baseline[x] != offset[x]) {
            if (first_diff < 0)
               first_diff = x;
            diff++;
         }

         if (baseline[x] != expected) {
            if (baseline_first_exact_bad < 0)
               baseline_first_exact_bad = x;
            baseline_exact_bad++;
         }

         if (offset[x] != expected) {
            if (offset_first_exact_bad < 0)
               offset_first_exact_bad = x;
            offset_exact_bad++;
         }

         if (!isfinite(baseline_f) || (int)floorf(baseline_f) != x)
            baseline_floor_bad++;

         if (!isfinite(offset_f) || (int)floorf(offset_f) != x)
            offset_floor_bad++;
      }

      results[width].same_as_offset = diff == 0;
      results[width].baseline_exact = baseline_exact_bad == 0;
      results[width].offset_exact = offset_exact_bad == 0;
      results[width].baseline_floor_pass = baseline_floor_bad == 0;
      results[width].offset_floor_pass = offset_floor_bad == 0;

      same_count += results[width].same_as_offset;
      baseline_exact_count += results[width].baseline_exact;
      offset_exact_count += results[width].offset_exact;
      baseline_floor_count += results[width].baseline_floor_pass;
      offset_floor_count += results[width].offset_floor_pass;

      if (details && (diff || baseline_exact_bad || offset_exact_bad ||
                      baseline_floor_bad || offset_floor_bad)) {
         printf("%d,%u,%u,%u,%u,%u,%d,%d,%d\n",
                width, diff, baseline_exact_bad, offset_exact_bad,
                baseline_floor_bad, offset_floor_bad, first_diff,
                baseline_first_exact_bad, offset_first_exact_bad);
      }
   }

   printf("SUMMARY max_width=%d same_as_offset=%u baseline_exact=%u "
          "offset_exact=%u baseline_floor_pass=%u offset_floor_pass=%u\n",
          max_width, same_count, baseline_exact_count, offset_exact_count,
          baseline_floor_count, offset_floor_count);

   print_ranges("same-as-offset widths", results, max_width, same_as_offset);
   print_ranges("baseline-exact widths", results, max_width, baseline_exact);
   print_ranges("offset-exact widths", results, max_width, offset_exact);
   print_ranges("baseline-floor-pass widths", results, max_width,
                baseline_floor_pass);
   print_ranges("offset-floor-pass widths", results, max_width,
                offset_floor_pass);

   free(results);
   free(offset);
   free(baseline);
   return 0;
}
