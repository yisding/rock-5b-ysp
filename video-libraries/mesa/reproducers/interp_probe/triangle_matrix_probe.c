// Mali/Panfrost oblong-triangle varying-interpolation matrix.
//
// Mesa MR !43161 works around a hardware precision issue for "very oblong"
// blits.  This probe separates the triangle geometry from u_blitter and tries
// every geometry choice that can plausibly select a different triangle-setup
// path:
//
//   * wide and tall render targets;
//   * exact half-rectangle and oversized fullscreen triangles;
//   * all four right-angle corners;
//   * clockwise and counter-clockwise vertex order;
//   * increasing and decreasing coordinates along the long axis;
//   * baseline and zero-valued polygon offset;
//   * a raw varying check and an ordinary normalized texture() check.
//
// The raw check models the integer-boundary sensitivity of a TXF blit:
// floor(v) must select the current destination pixel.  The texture check is
// the non-integer case: a normalized floating-point varying is consumed by an
// ordinary nearest-filtered texture() operation.
//
// Build:
//   cc -O2 -Wall -Wextra -o triangle_matrix_probe triangle_matrix_probe.c
//      -lEGL -lGLESv2 -lm
//
// Run the full option matrix at 12288x1 and 1x12288:
//   ./triangle_matrix_probe
//
// Run one subset:
//   ./triangle_matrix_probe --long 12848 --short 14 --axis tall
//      --shape oversized --corner bl --winding ccw --ramp forward
//      --sample both --offset both
//
// Print only aggregate failure counts:
//   ./triangle_matrix_probe --summary-only
//
// Print only failing cases plus the aggregate counts:
//   ./triangle_matrix_probe --fail-only --long 16307 --short 16
//
// Scan short-axis sizes 1..N with a canonical oversized triangle.  The scan
// still checks both long-axis directions, both sample modes, and both offset
// states:
//   ./triangle_matrix_probe --summary-only --long 12288 --scan-short 32
//
// Exit status is 0 if every selected case is exact, 2 if any selected case
// has a precision or coverage failure, and 1 for usage/setup errors.

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

#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#define ALL_AXIS ((1u << 2) - 1)
#define ALL_SHAPE ((1u << 2) - 1)
#define ALL_CORNER ((1u << 4) - 1)
#define ALL_WINDING ((1u << 2) - 1)
#define ALL_RAMP ((1u << 2) - 1)
#define ALL_SAMPLE ((1u << 2) - 1)
#define ALL_OFFSET ((1u << 2) - 1)

enum axis {
   AXIS_WIDE,
   AXIS_TALL,
};

enum shape {
   SHAPE_EXACT,
   SHAPE_OVERSIZED,
};

enum corner {
   CORNER_BL,
   CORNER_BR,
   CORNER_TL,
   CORNER_TR,
};

enum winding {
   WINDING_CCW,
   WINDING_CW,
};

enum ramp {
   RAMP_FORWARD,
   RAMP_REVERSE,
};

enum sample {
   SAMPLE_VARYING,
   SAMPLE_TEX,
};

enum offset {
   OFFSET_BASELINE,
   OFFSET_ZERO,
};

static const char *axis_names[] = {"wide", "tall"};
static const char *shape_names[] = {"exact", "oversized"};
static const char *corner_names[] = {"bl", "br", "tl", "tr"};
static const char *winding_names[] = {"ccw", "cw"};
static const char *ramp_names[] = {"forward", "reverse"};
static const char *sample_names[] = {"varying", "tex"};
static const char *offset_names[] = {"baseline", "polygon-offset"};

struct selections {
   unsigned axis;
   unsigned shape;
   unsigned corner;
   unsigned winding;
   unsigned ramp;
   unsigned sample;
   unsigned offset;
};

struct fail_totals {
   unsigned tests;
   unsigned failed;
   unsigned axis[2];
   unsigned shape[2];
   unsigned corner[4];
   unsigned winding[2];
   unsigned ramp[2];
   unsigned sample[2];
   unsigned offset[2];
};

struct vertex {
   float x;
   float y;
   float coord;
};

struct gl_state {
   GLuint varying_program;
   GLuint tex_program;
   GLuint vao;
   GLuint vbo;
   GLuint source_tex;
   GLuint target_tex;
   GLuint fbo;
};

static const uint32_t sentinel = 0x7fc00001u;

static const char *vs_src =
   "#version 300 es\n"
   "layout(location = 0) in highp vec2 position;\n"
   "layout(location = 1) in highp float coordinate;\n"
   "out highp float v;\n"
   "void main() {\n"
   "   v = coordinate;\n"
   "   gl_Position = vec4(position, 0.0, 1.0);\n"
   "}\n";

static const char *varying_fs_src =
   "#version 300 es\n"
   "in highp float v;\n"
   "layout(location = 0) out highp uint bits;\n"
   "void main() { bits = floatBitsToUint(v); }\n";

static const char *tex_fs_src =
   "#version 300 es\n"
   "uniform highp sampler2D source_tex;\n"
   "in highp float v;\n"
   "layout(location = 0) out highp uint bits;\n"
   "void main() {\n"
   "   bits = floatBitsToUint(texture(source_tex, vec2(v, 0.5)).r);\n"
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
      char log[4096];
      glGetShaderInfoLog(shader, sizeof(log), NULL, log);
      fprintf(stderr, "shader compile failed:\n%s\n", log);
      exit(1);
   }

   return shader;
}

static GLuint
link_program(const char *fragment_src)
{
   GLuint program = glCreateProgram();
   GLuint vs = compile(GL_VERTEX_SHADER, vs_src);
   GLuint fs = compile(GL_FRAGMENT_SHADER, fragment_src);
   glAttachShader(program, vs);
   glAttachShader(program, fs);
   glLinkProgram(program);
   glDeleteShader(vs);
   glDeleteShader(fs);

   GLint ok = 0;
   glGetProgramiv(program, GL_LINK_STATUS, &ok);
   if (!ok) {
      char log[4096];
      glGetProgramInfoLog(program, sizeof(log), NULL, log);
      fprintf(stderr, "program link failed:\n%s\n", log);
      exit(1);
   }

   return program;
}

static void
usage(const char *program)
{
   fprintf(stderr,
           "usage: %s [options]\n"
           "  --long N                    long extent (default 12288)\n"
           "  --short N                   short extent (default 1)\n"
           "  --axis wide|tall|both\n"
           "  --shape exact|oversized|both\n"
           "  --corner bl|br|tl|tr|all\n"
           "  --winding ccw|cw|both\n"
           "  --ramp forward|reverse|both\n"
           "  --sample varying|tex|both\n"
           "  --offset baseline|polygon-offset|both\n"
           "  --fail-only                 print only failing per-case rows\n"
           "  --summary-only              suppress per-case output\n"
           "  --scan-short N              scan short extents 1..N using the\n"
           "                              canonical oversized triangle\n"
           "  --help\n",
           program);
}

static int
parse_positive(const char *text, int *value)
{
   char *end;
   long parsed = strtol(text, &end, 10);
   if (!text[0] || *end || parsed < 1 || parsed > (1 << 23))
      return 0;
   *value = (int)parsed;
   return 1;
}

static int
parse_choice(const char *text, const char *const *names, size_t count,
             unsigned all, unsigned *selection)
{
   if (!strcmp(text, "all") || !strcmp(text, "both")) {
      *selection = all;
      return 1;
   }

   for (size_t i = 0; i < count; i++) {
      if (!strcmp(text, names[i])) {
         *selection = 1u << i;
         return 1;
      }
   }

   return 0;
}

static void
print_fail_counts(const char *label, const char *const *names,
                  const unsigned *counts, size_t count)
{
   if (!count)
      return;

   printf("FAIL %s", label);
   for (size_t i = 0; i < count; i++)
      printf(" %s=%u", names[i], counts[i]);
   printf("\n");
}

static void
print_totals(const struct fail_totals *totals)
{
   if (!totals->failed)
      return;

   print_fail_counts("axis", axis_names, totals->axis, ARRAY_SIZE(axis_names));
   print_fail_counts("shape", shape_names, totals->shape,
                     ARRAY_SIZE(shape_names));
   print_fail_counts("corner", corner_names, totals->corner,
                     ARRAY_SIZE(corner_names));
   print_fail_counts("winding", winding_names, totals->winding,
                     ARRAY_SIZE(winding_names));
   print_fail_counts("ramp", ramp_names, totals->ramp, ARRAY_SIZE(ramp_names));
   print_fail_counts("sample", sample_names, totals->sample,
                     ARRAY_SIZE(sample_names));
   print_fail_counts("offset", offset_names, totals->offset,
                     ARRAY_SIZE(offset_names));
}

static void
pixel_vertex(struct vertex *vertex, float px, float py, int width, int height,
             enum axis axis, enum ramp ramp, enum sample sample, int long_size)
{
   const float major = axis == AXIS_WIDE ? px : py;
   float coord = ramp == RAMP_FORWARD ? major : long_size - major;
   if (sample == SAMPLE_TEX)
      coord /= long_size;

   vertex->x = 2.0f * px / width - 1.0f;
   vertex->y = 2.0f * py / height - 1.0f;
   vertex->coord = coord;
}

static void
make_triangle(struct vertex vertices[3], int width, int height, enum axis axis,
              enum shape shape, enum corner corner, enum winding winding,
              enum ramp ramp, enum sample sample, int long_size)
{
   const int right = corner == CORNER_BR || corner == CORNER_TR;
   const int top = corner == CORNER_TL || corner == CORNER_TR;
   const float cx = right ? width : 0;
   const float cy = top ? height : 0;
   const float x_other =
      shape == SHAPE_OVERSIZED ? (right ? -width : 2 * width)
                               : (right ? 0 : width);
   const float y_other =
      shape == SHAPE_OVERSIZED ? (top ? -height : 2 * height)
                               : (top ? 0 : height);

   float points[3][2] = {
      {cx, cy},
      {x_other, cy},
      {cx, y_other},
   };
   const float cross = (points[1][0] - points[0][0]) *
                          (points[2][1] - points[0][1]) -
                       (points[1][1] - points[0][1]) *
                          (points[2][0] - points[0][0]);
   const int is_ccw = cross > 0.0f;
   if ((winding == WINDING_CCW) != is_ccw) {
      float tmp_x = points[1][0];
      float tmp_y = points[1][1];
      points[1][0] = points[2][0];
      points[1][1] = points[2][1];
      points[2][0] = tmp_x;
      points[2][1] = tmp_y;
   }

   for (unsigned i = 0; i < 3; i++)
      pixel_vertex(&vertices[i], points[i][0], points[i][1], width, height,
                   axis, ramp, sample, long_size);
}

static void
create_target(struct gl_state *gl, int width, int height)
{
   if (gl->target_tex)
      glDeleteTextures(1, &gl->target_tex);

   glGenTextures(1, &gl->target_tex);
   glBindTexture(GL_TEXTURE_2D, gl->target_tex);
   glTexStorage2D(GL_TEXTURE_2D, 1, GL_R32UI, width, height);
   glBindFramebuffer(GL_FRAMEBUFFER, gl->fbo);
   glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                          gl->target_tex, 0);
   CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
   glViewport(0, 0, width, height);
}

static int
run_case(struct gl_state *gl, uint32_t *bits, int long_size, int short_size,
         enum axis axis, enum shape shape, enum corner corner,
         enum winding winding, enum ramp ramp, enum sample sample,
         enum offset offset, int fail_only, int summary_only)
{
   const int width = axis == AXIS_WIDE ? long_size : short_size;
   const int height = axis == AXIS_WIDE ? short_size : long_size;
   struct vertex vertices[3];
   make_triangle(vertices, width, height, axis, shape, corner, winding, ramp,
                 sample, long_size);

   const GLuint program =
      sample == SAMPLE_VARYING ? gl->varying_program : gl->tex_program;
   glUseProgram(program);
   if (sample == SAMPLE_TEX) {
      glActiveTexture(GL_TEXTURE0);
      glBindTexture(GL_TEXTURE_2D, gl->source_tex);
   }

   glBindBuffer(GL_ARRAY_BUFFER, gl->vbo);
   glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STREAM_DRAW);

   glBindFramebuffer(GL_FRAMEBUFFER, gl->fbo);
   glClearBufferuiv(GL_COLOR, 0, &sentinel);
   if (offset == OFFSET_ZERO) {
      glEnable(GL_POLYGON_OFFSET_FILL);
      glPolygonOffset(0.0f, 0.0f);
   } else {
      glDisable(GL_POLYGON_OFFSET_FILL);
   }

   glDrawArrays(GL_TRIANGLES, 0, 3);
   CHECK(glGetError() == GL_NO_ERROR);
   glReadPixels(0, 0, width, height, GL_RED_INTEGER, GL_UNSIGNED_INT, bits);
   CHECK(glGetError() == GL_NO_ERROR);

   long covered = 0;
   long bad = 0;
   long first_bad = -1;
   float first_value = 0.0f;
   const long total = (long)width * height;

   for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
         const long index = (long)y * width + x;
         if (bits[index] == sentinel)
            continue;

         covered++;
         const int major = axis == AXIS_WIDE ? x : y;
         const int expected =
            ramp == RAMP_FORWARD ? major : long_size - 1 - major;
         float value;
         memcpy(&value, &bits[index], sizeof(value));

         int mismatch;
         if (sample == SAMPLE_VARYING)
            mismatch = !isfinite(value) || (int)floorf(value) != expected;
         else
            mismatch = value != (float)expected;

         if (mismatch) {
            if (first_bad < 0) {
               first_bad = index;
               first_value = value;
            }
            bad++;
         }
      }
   }

   const long missing = shape == SHAPE_OVERSIZED ? total - covered : 0;
   const int failed = bad || missing || !covered;
   if (!summary_only && (!fail_only || failed)) {
      printf("axis=%s shape=%s corner=%s winding=%s ramp=%s sample=%s "
             "offset=%s size=%dx%d aspect=%.3f covered=%ld/%ld bad=%ld",
             axis_names[axis], shape_names[shape], corner_names[corner],
             winding_names[winding], ramp_names[ramp], sample_names[sample],
             offset_names[offset], width, height,
             (double)long_size / short_size, covered, total, bad);
      if (missing)
         printf(" missing=%ld", missing);
      if (first_bad >= 0) {
         const int bad_x = first_bad % width;
         const int bad_y = first_bad / width;
         printf(" first=(%d,%d) value=%.9g", bad_x, bad_y, first_value);
      }
      printf(" result=%s\n", failed ? "FAIL" : "PASS");
   }
   return failed;
}

static int
run_matrix(struct gl_state *gl, int long_size, int short_size,
           const struct selections *selections, int fail_only,
           int summary_only)
{
   const size_t pixels = (size_t)long_size * short_size;
   uint32_t *bits = malloc(pixels * sizeof(*bits));
   CHECK(bits);

   struct fail_totals totals = {0};
   for (unsigned axis = 0; axis < ARRAY_SIZE(axis_names); axis++) {
      if (!(selections->axis & (1u << axis)))
         continue;

      const int width = axis == AXIS_WIDE ? long_size : short_size;
      const int height = axis == AXIS_WIDE ? short_size : long_size;
      create_target(gl, width, height);

      for (unsigned shape = 0; shape < ARRAY_SIZE(shape_names); shape++) {
         if (!(selections->shape & (1u << shape)))
            continue;
         for (unsigned corner = 0; corner < ARRAY_SIZE(corner_names); corner++) {
            if (!(selections->corner & (1u << corner)))
               continue;
            for (unsigned winding = 0;
                 winding < ARRAY_SIZE(winding_names); winding++) {
               if (!(selections->winding & (1u << winding)))
                  continue;
               for (unsigned ramp = 0; ramp < ARRAY_SIZE(ramp_names); ramp++) {
                  if (!(selections->ramp & (1u << ramp)))
                     continue;
                  for (unsigned sample = 0;
                       sample < ARRAY_SIZE(sample_names); sample++) {
                     if (!(selections->sample & (1u << sample)))
                        continue;
                     for (unsigned offset = 0;
                          offset < ARRAY_SIZE(offset_names); offset++) {
                        if (!(selections->offset & (1u << offset)))
                           continue;
                        const int case_failed = run_case(
                           gl, bits, long_size, short_size, axis, shape, corner,
                           winding, ramp, sample, offset, fail_only,
                           summary_only);
                        totals.tests++;
                        if (case_failed) {
                           totals.failed++;
                           totals.axis[axis]++;
                           totals.shape[shape]++;
                           totals.corner[corner]++;
                           totals.winding[winding]++;
                           totals.ramp[ramp]++;
                           totals.sample[sample]++;
                           totals.offset[offset]++;
                        }
                     }
                  }
               }
            }
         }
      }
   }

   printf("SUMMARY long=%d short=%d aspect=%.3f tests=%u failed=%u\n",
          long_size, short_size, (double)long_size / short_size, totals.tests,
          totals.failed);
   print_totals(&totals);
   free(bits);
   return totals.failed;
}

static void
init_egl(void)
{
   PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress(
         "eglGetPlatformDisplayEXT");
   CHECK(get_platform_display);

   EGLDisplay dpy = get_platform_display(EGL_PLATFORM_SURFACELESS_MESA,
                                         EGL_DEFAULT_DISPLAY, NULL);
   CHECK(dpy != EGL_NO_DISPLAY);
   CHECK(eglInitialize(dpy, NULL, NULL));
   CHECK(eglBindAPI(EGL_OPENGL_ES_API));

   const EGLint config_attrs[] = {
      EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
      EGL_SURFACE_TYPE, 0,
      EGL_NONE,
   };
   EGLConfig config;
   EGLint config_count = 0;
   CHECK(eglChooseConfig(dpy, config_attrs, &config, 1, &config_count) &&
         config_count);

   const EGLint context_attrs[] = {
      EGL_CONTEXT_CLIENT_VERSION, 3,
      EGL_NONE,
   };
   EGLContext context =
      eglCreateContext(dpy, config, EGL_NO_CONTEXT, context_attrs);
   CHECK(context != EGL_NO_CONTEXT);
   CHECK(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, context));
}

static void
init_gl(struct gl_state *gl, int long_size)
{
   memset(gl, 0, sizeof(*gl));
   gl->varying_program = link_program(varying_fs_src);
   gl->tex_program = link_program(tex_fs_src);
   glUseProgram(gl->tex_program);
   glUniform1i(glGetUniformLocation(gl->tex_program, "source_tex"), 0);

   glGenVertexArrays(1, &gl->vao);
   glBindVertexArray(gl->vao);
   glGenBuffers(1, &gl->vbo);
   glBindBuffer(GL_ARRAY_BUFFER, gl->vbo);
   glEnableVertexAttribArray(0);
   glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(struct vertex),
                         (void *)0);
   glEnableVertexAttribArray(1);
   glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, sizeof(struct vertex),
                         (void *)(2 * sizeof(float)));

   float *source = malloc((size_t)long_size * sizeof(*source));
   CHECK(source);
   for (int i = 0; i < long_size; i++)
      source[i] = (float)i;

   glGenTextures(1, &gl->source_tex);
   glBindTexture(GL_TEXTURE_2D, gl->source_tex);
   glTexStorage2D(GL_TEXTURE_2D, 1, GL_R32F, long_size, 1);
   glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, long_size, 1, GL_RED, GL_FLOAT,
                   source);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
   free(source);

   glGenFramebuffers(1, &gl->fbo);
   glDisable(GL_CULL_FACE);
   glDisable(GL_BLEND);
   glDisable(GL_DEPTH_TEST);
   CHECK(glGetError() == GL_NO_ERROR);
}

int
main(int argc, char **argv)
{
   int long_size = 12288;
   int short_size = 1;
   int scan_short = 0;
   int fail_only = 0;
   int summary_only = 0;
   struct selections selections = {
      .axis = ALL_AXIS,
      .shape = ALL_SHAPE,
      .corner = ALL_CORNER,
      .winding = ALL_WINDING,
      .ramp = ALL_RAMP,
      .sample = ALL_SAMPLE,
      .offset = ALL_OFFSET,
   };

   for (int i = 1; i < argc; i++) {
      if (!strcmp(argv[i], "--help")) {
         usage(argv[0]);
         return 0;
      }
      if (!strcmp(argv[i], "--summary-only")) {
         summary_only = 1;
         continue;
      }
      if (!strcmp(argv[i], "--fail-only")) {
         fail_only = 1;
         continue;
      }
      if (i + 1 >= argc) {
         usage(argv[0]);
         return 1;
      }

      const char *option = argv[i++];
      const char *value = argv[i];
      int ok = 1;
      if (!strcmp(option, "--long"))
         ok = parse_positive(value, &long_size);
      else if (!strcmp(option, "--short"))
         ok = parse_positive(value, &short_size);
      else if (!strcmp(option, "--scan-short"))
         ok = parse_positive(value, &scan_short);
      else if (!strcmp(option, "--axis"))
         ok = parse_choice(value, axis_names, ARRAY_SIZE(axis_names), ALL_AXIS,
                           &selections.axis);
      else if (!strcmp(option, "--shape"))
         ok = parse_choice(value, shape_names, ARRAY_SIZE(shape_names),
                           ALL_SHAPE, &selections.shape);
      else if (!strcmp(option, "--corner"))
         ok = parse_choice(value, corner_names, ARRAY_SIZE(corner_names),
                           ALL_CORNER, &selections.corner);
      else if (!strcmp(option, "--winding"))
         ok = parse_choice(value, winding_names, ARRAY_SIZE(winding_names),
                           ALL_WINDING, &selections.winding);
      else if (!strcmp(option, "--ramp"))
         ok = parse_choice(value, ramp_names, ARRAY_SIZE(ramp_names), ALL_RAMP,
                           &selections.ramp);
      else if (!strcmp(option, "--sample"))
         ok = parse_choice(value, sample_names, ARRAY_SIZE(sample_names),
                           ALL_SAMPLE, &selections.sample);
      else if (!strcmp(option, "--offset"))
         ok = parse_choice(value, offset_names, ARRAY_SIZE(offset_names),
                           ALL_OFFSET, &selections.offset);
      else
         ok = 0;

      if (!ok) {
         usage(argv[0]);
         return 1;
      }
   }

   if (scan_short && scan_short > long_size) {
      fprintf(stderr, "--scan-short must not exceed --long\n");
      return 1;
   }

   init_egl();
   fprintf(stderr, "GL_RENDERER=%s\nGL_VERSION=%s\n",
           (const char *)glGetString(GL_RENDERER),
           (const char *)glGetString(GL_VERSION));

   GLint max_size = 0;
   glGetIntegerv(GL_MAX_TEXTURE_SIZE, &max_size);
   const int max_short = scan_short ? scan_short : short_size;
   if (long_size > max_size || max_short > max_size) {
      fprintf(stderr, "requested extent exceeds GL_MAX_TEXTURE_SIZE %d\n",
              max_size);
      return 1;
   }

   struct gl_state gl;
   init_gl(&gl, long_size);

   int failed = 0;
   if (scan_short) {
      const struct selections scan = {
         .axis = ALL_AXIS,
         .shape = 1u << SHAPE_OVERSIZED,
         .corner = 1u << CORNER_BL,
         .winding = 1u << WINDING_CCW,
         .ramp = ALL_RAMP,
         .sample = ALL_SAMPLE,
         .offset = ALL_OFFSET,
      };
      for (int current = 1; current <= scan_short; current++)
         failed += run_matrix(&gl, long_size, current, &scan, fail_only,
                              summary_only);
   } else {
      failed = run_matrix(&gl, long_size, short_size, &selections,
                          fail_only, summary_only);
   }

   return failed ? 2 : 0;
}
