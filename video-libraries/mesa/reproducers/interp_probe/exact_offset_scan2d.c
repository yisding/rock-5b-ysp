// 2D baseline-vs-zero-polygon-offset interpolation scanner.
//
// This is the 2D counterpart to exact_offset_scan.c.  It draws the same
// fullscreen-style triangle, but carries a vec2 varying that should evaluate
// to vec2(x + 0.5, y + 0.5) at each pixel center.
//
// Modes:
//
//   --lines
//      Full-pixel scans for Wx1, 1xH, Wx2, and 2xH for 1..max.
//
//   --pow2
//      Full-pixel scans for all power-of-two W,H combinations up to max.
//
//   --sample-grid
//      Scissored one-pixel scan for every WxH pair in 1..max.  This avoids the
//      70T-fragment exhaustive scan by rendering only the top-right pixel,
//      W-1,H-1, for each size.  Each pair maps naturally to output pixel
//      W-1,H-1 in one max-sized texture, so the scan uses one bulk readback for
//      the baseline pass and one bulk readback for the offset pass.
//
//   --sample-major-pow2
//      Same top-right sampled scan, but only for pairs where the larger
//      dimension is a power of two.
//
//   --main-results
//      Curated full-surface reproducer for the main baseline-vs-zero-offset
//      bit-equality result: both dimensions powers of two produce the same bits,
//      while representative non-power-of-two cases do not, including
//      one-dimension-power-of-two and low-aspect cases.
//
//   --full-grid-floor
//      Full-pixel baseline integer-bin scan for every WxH pair in 1..max,
//      capped at max=500.  Uses an occlusion-query shader to avoid reading the
//      full surfaces back to the CPU.
//
// Build:
//   cc -O2 -Wall -Wextra -Werror -o exact_offset_scan2d exact_offset_scan2d.c -lEGL -lGLESv2 -lm
//
// Run:
//   ./exact_offset_scan2d --lines --pow2
//   ./exact_offset_scan2d --sample-grid --max 4096
//   ./exact_offset_scan2d --sample-major-pow2 --max 4096
//   ./exact_offset_scan2d --main-results
//   ./exact_offset_scan2d --full-grid-floor --max 500 --progress 50

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <inttypes.h>
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

#define COMPONENTS 2
#define MAX_FAIL_EXAMPLES 16
#define FLOOR_QUERY_BATCH 1024

static const char *vs_src =
   "#version 300 es\n"
   "uniform highp vec2 extent;\n"
   "out highp vec2 v;\n"
   "void main() {\n"
   "   vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0,\n"
   "                 gl_VertexID == 2 ? 3.0 : -1.0);\n"
   "   v = (p + 1.0) * 0.5 * extent;\n"
   "   gl_Position = vec4(p, 0.0, 1.0);\n"
   "}\n";

static const char *fs_src =
   "#version 300 es\n"
   "in highp vec2 v;\n"
   "out highp uvec2 bits;\n"
   "void main() { bits = uvec2(floatBitsToUint(v.x), floatBitsToUint(v.y)); }\n";

static const char *fs_floor_src =
   "#version 300 es\n"
   "in highp vec2 v;\n"
   "out highp uvec2 bits;\n"
   "void main() {\n"
   "   ivec2 p = ivec2(gl_FragCoord.xy);\n"
   "   if (int(floor(v.x)) == p.x && int(floor(v.y)) == p.y)\n"
   "      discard;\n"
   "   bits = uvec2(1u, 0u);\n"
   "}\n";

struct gl_state {
   GLuint prog;
   GLuint floor_prog;
   GLint extent_loc;
   GLint floor_extent_loc;
   GLuint tex;
   GLuint fbo;
   uint32_t *baseline;
   uint32_t *offset;
   size_t max_values;
};

struct compare_result {
   int width;
   int height;
   uint64_t pixels;
   uint64_t diff_pixels;
   uint64_t baseline_exact_bad;
   uint64_t offset_exact_bad;
   uint64_t baseline_floor_bad;
   uint64_t offset_floor_bad;
   int first_diff_x;
   int first_diff_y;
   int baseline_first_exact_bad_x;
   int baseline_first_exact_bad_y;
   int offset_first_exact_bad_x;
   int offset_first_exact_bad_y;
};

struct line_result {
   unsigned same_as_offset;
   unsigned baseline_exact;
   unsigned offset_exact;
   unsigned baseline_floor_pass;
   unsigned offset_floor_pass;
};

struct main_result_case {
   const char *label;
   int width;
   int height;
};

struct full_grid_floor_result {
   uint64_t cases;
   uint64_t pixels;
   uint64_t failing_cases;
   int first_w;
   int first_h;
   int last_w;
   int last_h;
   int most_square_w;
   int most_square_h;
   double most_square_aspect;
   unsigned example_count;
   int example_w[MAX_FAIL_EXAMPLES];
   int example_h[MAX_FAIL_EXAMPLES];
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

static int
is_pow2_or_one(unsigned n)
{
   return n == 1 || (n && !(n & (n - 1)));
}

static void
draw_and_read(struct gl_state *gl, int width, int height, int use_offset,
              int scissor, int sx, int sy, int read_width, int read_height,
              uint32_t *bits)
{
   glUseProgram(gl->prog);
   glUniform2f(gl->extent_loc, (float)width, (float)height);
   glViewport(0, 0, width, height);

   if (scissor) {
      glEnable(GL_SCISSOR_TEST);
      glScissor(sx, sy, read_width, read_height);
   } else {
      glDisable(GL_SCISSOR_TEST);
   }

   if (use_offset) {
      glEnable(GL_POLYGON_OFFSET_FILL);
      glPolygonOffset(0.0f, 0.0f);
   } else {
      glDisable(GL_POLYGON_OFFSET_FILL);
   }

   glDrawArrays(GL_TRIANGLES, 0, 3);
   CHECK(glGetError() == GL_NO_ERROR);

   glReadPixels(sx, sy, read_width, read_height, GL_RG_INTEGER,
                GL_UNSIGNED_INT, bits);
   CHECK(glGetError() == GL_NO_ERROR);
}

static void
compare_pixels(const uint32_t *baseline, const uint32_t *offset, int width,
               int height, int read_width, int read_height, int origin_x,
               int origin_y, struct compare_result *r)
{
   memset(r, 0, sizeof(*r));
   r->width = width;
   r->height = height;
   r->pixels = (uint64_t)read_width * (uint64_t)read_height;
   r->first_diff_x = -1;
   r->first_diff_y = -1;
   r->baseline_first_exact_bad_x = -1;
   r->baseline_first_exact_bad_y = -1;
   r->offset_first_exact_bad_x = -1;
   r->offset_first_exact_bad_y = -1;

   for (int y = 0; y < read_height; y++) {
      for (int x = 0; x < read_width; x++) {
         const int dst_x = origin_x + x;
         const int dst_y = origin_y + y;
         const size_t i = ((size_t)y * read_width + x) * COMPONENTS;

         const uint32_t expected_x = float_bits((float)dst_x + 0.5f);
         const uint32_t expected_y = float_bits((float)dst_y + 0.5f);
         const uint32_t bx = baseline[i + 0];
         const uint32_t by = baseline[i + 1];
         const uint32_t ox = offset[i + 0];
         const uint32_t oy = offset[i + 1];
         const float bxf = bits_float(bx);
         const float byf = bits_float(by);
         const float oxf = bits_float(ox);
         const float oyf = bits_float(oy);

         if (bx != ox || by != oy) {
            if (r->first_diff_x < 0) {
               r->first_diff_x = dst_x;
               r->first_diff_y = dst_y;
            }
            r->diff_pixels++;
         }

         if (bx != expected_x || by != expected_y) {
            if (r->baseline_first_exact_bad_x < 0) {
               r->baseline_first_exact_bad_x = dst_x;
               r->baseline_first_exact_bad_y = dst_y;
            }
            r->baseline_exact_bad++;
         }

         if (ox != expected_x || oy != expected_y) {
            if (r->offset_first_exact_bad_x < 0) {
               r->offset_first_exact_bad_x = dst_x;
               r->offset_first_exact_bad_y = dst_y;
            }
            r->offset_exact_bad++;
         }

         if (!isfinite(bxf) || !isfinite(byf) ||
             (int)floorf(bxf) != dst_x || (int)floorf(byf) != dst_y)
            r->baseline_floor_bad++;

         if (!isfinite(oxf) || !isfinite(oyf) ||
             (int)floorf(oxf) != dst_x || (int)floorf(oyf) != dst_y)
            r->offset_floor_bad++;
      }
   }
}

static struct compare_result
full_compare(struct gl_state *gl, int width, int height)
{
   struct compare_result r;
   draw_and_read(gl, width, height, 0, 0, 0, 0, width, height, gl->baseline);
   draw_and_read(gl, width, height, 1, 0, 0, 0, width, height, gl->offset);
   compare_pixels(gl->baseline, gl->offset, width, height, width, height, 0, 0,
                  &r);
   return r;
}

static void
print_result(const char *prefix, const struct compare_result *r)
{
   printf("%s size=%dx%d pixels=%" PRIu64 " diff=%" PRIu64
          " baseline_exact_bad=%" PRIu64 " offset_exact_bad=%" PRIu64
          " baseline_floor_bad=%" PRIu64 " offset_floor_bad=%" PRIu64,
          prefix, r->width, r->height, r->pixels, r->diff_pixels,
          r->baseline_exact_bad, r->offset_exact_bad, r->baseline_floor_bad,
          r->offset_floor_bad);

   if (r->first_diff_x >= 0)
      printf(" first_diff=(%d,%d)", r->first_diff_x, r->first_diff_y);
   if (r->baseline_first_exact_bad_x >= 0)
      printf(" baseline_first_exact_bad=(%d,%d)",
             r->baseline_first_exact_bad_x, r->baseline_first_exact_bad_y);
   if (r->offset_first_exact_bad_x >= 0)
      printf(" offset_first_exact_bad=(%d,%d)",
             r->offset_first_exact_bad_x, r->offset_first_exact_bad_y);

   printf("\n");
}

static const char *
same_label(int same)
{
   return same ? "same" : "different";
}

static const char *
pass_label(int pass)
{
   return pass ? "PASS" : "FAIL";
}

static int
run_main_results(struct gl_state *gl)
{
   const struct main_result_case cases[] = {
      {"both-pow2-rect", 1024, 2048},
      {"both-pow2-square", 2048, 2048},
      {"both-pow2-max", 4096, 4096},
      {"one-dim-pow2-wide", 4096, 3},
      {"one-dim-pow2-tall", 3, 4096},
      {"one-dim-pow2-near-square", 4096, 4095},
      {"both-nonpow2-near-square", 4095, 4095},
      {"both-nonpow2-aspect-10", 4095, 383},
      {"both-nonpow2-aspect-12", 4095, 341},
   };
   unsigned passed = 0;
   unsigned failed = 0;
   unsigned same_cases = 0;
   unsigned different_cases = 0;

   printf("MAIN-RESULT-PREDICATE suite_expected_same_as_offset="
          "both_dimensions_are_powers_of_two\n");

   for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
      const struct main_result_case *c = &cases[i];
      struct compare_result r = full_compare(gl, c->width, c->height);
      const int expected_same =
         is_pow2_or_one((unsigned)c->width) &&
         is_pow2_or_one((unsigned)c->height);
      const int actual_same = r.diff_pixels == 0;
      const int baseline_floor = r.baseline_floor_bad == 0;
      const int offset_floor = r.offset_floor_bad == 0;
      const int ok = actual_same == expected_same;
      const double aspect = c->width > c->height ?
         (double)c->width / (double)c->height :
         (double)c->height / (double)c->width;

      same_cases += actual_same;
      different_cases += !actual_same;
      passed += ok;
      failed += !ok;

      printf("MAIN-RESULT label=%s size=%dx%d aspect=%.6f expected=%s "
             "observed=%s verdict=%s same_as_offset=%u baseline_exact=%u "
             "offset_exact=%u baseline_floor=%u offset_floor=%u "
             "diff=%" PRIu64 " baseline_exact_bad=%" PRIu64
             " offset_exact_bad=%" PRIu64 " baseline_floor_bad=%" PRIu64
             " offset_floor_bad=%" PRIu64,
             c->label, c->width, c->height, aspect,
             same_label(expected_same), same_label(actual_same),
             pass_label(ok), r.diff_pixels == 0,
             r.baseline_exact_bad == 0, r.offset_exact_bad == 0,
             baseline_floor, offset_floor, r.diff_pixels,
             r.baseline_exact_bad, r.offset_exact_bad, r.baseline_floor_bad,
             r.offset_floor_bad);

      if (r.first_diff_x >= 0)
         printf(" first_diff=(%d,%d)", r.first_diff_x, r.first_diff_y);
      if (r.baseline_first_exact_bad_x >= 0)
         printf(" baseline_first_exact_bad=(%d,%d)",
                r.baseline_first_exact_bad_x, r.baseline_first_exact_bad_y);
      if (r.offset_first_exact_bad_x >= 0)
         printf(" offset_first_exact_bad=(%d,%d)",
                r.offset_first_exact_bad_x, r.offset_first_exact_bad_y);

      printf("\n");
   }

   printf("MAIN-RESULT-SUMMARY cases=%u passed=%u failed=%u same=%u "
          "different=%u\n",
          passed + failed, passed, failed, same_cases, different_cases);

   return failed;
}

static double
aspect_ratio(int width, int height)
{
   return width > height ?
      (double)width / (double)height :
      (double)height / (double)width;
}

static void
record_full_grid_floor_failure(struct full_grid_floor_result *r,
                               int width, int height)
{
   const double aspect = aspect_ratio(width, height);

   if (!r->first_w) {
      r->first_w = width;
      r->first_h = height;
   }

   r->last_w = width;
   r->last_h = height;

   if (!r->most_square_w || aspect < r->most_square_aspect) {
      r->most_square_w = width;
      r->most_square_h = height;
      r->most_square_aspect = aspect;
   }

   if (r->example_count < MAX_FAIL_EXAMPLES) {
      r->example_w[r->example_count] = width;
      r->example_h[r->example_count] = height;
      r->example_count++;
   }

   r->failing_cases++;
}

static void
issue_floor_query(struct gl_state *gl, int width, int height, GLuint query)
{
   glUniform2f(gl->floor_extent_loc, (float)width, (float)height);
   glViewport(0, 0, width, height);
   glBeginQuery(GL_ANY_SAMPLES_PASSED, query);
   glDrawArrays(GL_TRIANGLES, 0, 3);
   glEndQuery(GL_ANY_SAMPLES_PASSED);
}

static void
drain_floor_queries(GLuint *queries, int *widths, int *heights, unsigned count,
                    struct full_grid_floor_result *result)
{
   for (unsigned i = 0; i < count; i++) {
      GLuint any_failed = 0;
      glGetQueryObjectuiv(queries[i], GL_QUERY_RESULT, &any_failed);
      if (any_failed)
         record_full_grid_floor_failure(result, widths[i], heights[i]);
   }
}

static void
run_full_grid_floor(struct gl_state *gl, int max_size, int progress_step)
{
   struct full_grid_floor_result result;
   GLuint queries[FLOOR_QUERY_BATCH];
   int widths[FLOOR_QUERY_BATCH];
   int heights[FLOOR_QUERY_BATCH];
   unsigned pending = 0;

   memset(&result, 0, sizeof(result));
   glGenQueries(FLOOR_QUERY_BATCH, queries);

   glUseProgram(gl->floor_prog);
   glDisable(GL_SCISSOR_TEST);
   glDisable(GL_POLYGON_OFFSET_FILL);

   for (int height = 1; height <= max_size; height++) {
      for (int width = 1; width <= max_size; width++) {
         if (pending == FLOOR_QUERY_BATCH) {
            CHECK(glGetError() == GL_NO_ERROR);
            drain_floor_queries(queries, widths, heights, pending, &result);
            pending = 0;
         }

         widths[pending] = width;
         heights[pending] = height;
         result.cases++;
         result.pixels += (uint64_t)width * (uint64_t)height;

         issue_floor_query(gl, width, height, queries[pending]);
         pending++;
      }

      if (progress_step > 0 && (height % progress_step) == 0) {
         fprintf(stderr, "full-grid-floor baseline progress: height=%d/%d\n",
                 height, max_size);
      }
   }

   CHECK(glGetError() == GL_NO_ERROR);
   drain_floor_queries(queries, widths, heights, pending, &result);
   glDeleteQueries(FLOOR_QUERY_BATCH, queries);

   printf("FULL-GRID-FLOOR-SUMMARY max=%d path=baseline cases=%" PRIu64
          " pixels=%" PRIu64
          " failing_cases=%" PRIu64
          " first_failure=%dx%d"
          " last_failure=%dx%d"
          " most_square_failure=%dx%d"
          " most_square_failure_aspect=%.6f\n",
          max_size, result.cases, result.pixels, result.failing_cases,
          result.first_w, result.first_h, result.last_w, result.last_h,
          result.most_square_w, result.most_square_h,
          result.most_square_aspect);

   for (unsigned i = 0; i < result.example_count; i++) {
      struct compare_result r =
         full_compare(gl, result.example_w[i], result.example_h[i]);
      print_result("FULL-GRID-FLOOR-FAIL", &r);
   }
}

static unsigned
same_as_offset(const struct line_result *r)
{
   return r->same_as_offset;
}

static unsigned
baseline_exact(const struct line_result *r)
{
   return r->baseline_exact;
}

static unsigned
offset_exact(const struct line_result *r)
{
   return r->offset_exact;
}

static unsigned
baseline_floor_pass(const struct line_result *r)
{
   return r->baseline_floor_pass;
}

static unsigned
offset_floor_pass(const struct line_result *r)
{
   return r->offset_floor_pass;
}

static void
print_ranges(const char *label, const struct line_result *results,
             unsigned count, unsigned (*pred)(const struct line_result *))
{
   printf("%s:", label);

   int printed = 0;
   for (unsigned i = 1; i <= count;) {
      if (!pred(&results[i])) {
         i++;
         continue;
      }

      unsigned start = i;
      while (i + 1 <= count && pred(&results[i + 1]))
         i++;

      printf("%s%u", printed ? "," : " ", start);
      if (i != start)
         printf("-%u", i);
      printed = 1;
      i++;
   }

   if (!printed)
      printf(" none");
   printf("\n");
}

static void
run_line_scan(struct gl_state *gl, const char *label, int max_size,
              int varying_width, int fixed)
{
   struct line_result *results =
      calloc((size_t)max_size + 1, sizeof(*results));
   CHECK(results);

   unsigned same_count = 0;
   unsigned baseline_exact_count = 0;
   unsigned offset_exact_count = 0;
   unsigned baseline_floor_count = 0;
   unsigned offset_floor_count = 0;
   unsigned failing_cases = 0;

   for (int i = 1; i <= max_size; i++) {
      const int width = varying_width ? i : fixed;
      const int height = varying_width ? fixed : i;
      struct compare_result r = full_compare(gl, width, height);

      results[i].same_as_offset = r.diff_pixels == 0;
      results[i].baseline_exact = r.baseline_exact_bad == 0;
      results[i].offset_exact = r.offset_exact_bad == 0;
      results[i].baseline_floor_pass = r.baseline_floor_bad == 0;
      results[i].offset_floor_pass = r.offset_floor_bad == 0;

      same_count += results[i].same_as_offset;
      baseline_exact_count += results[i].baseline_exact;
      offset_exact_count += results[i].offset_exact;
      baseline_floor_count += results[i].baseline_floor_pass;
      offset_floor_count += results[i].offset_floor_pass;

      if (r.baseline_floor_bad || r.offset_floor_bad) {
         if (failing_cases < MAX_FAIL_EXAMPLES)
            print_result("LINE-FAIL", &r);
         failing_cases++;
      }
   }

   printf("LINE-SUMMARY %s max=%d same_as_offset=%u baseline_exact=%u "
          "offset_exact=%u baseline_floor_pass=%u offset_floor_pass=%u "
          "floor_failing_cases=%u\n",
          label, max_size, same_count, baseline_exact_count,
          offset_exact_count, baseline_floor_count, offset_floor_count,
          failing_cases);

   char range_label[128];
   snprintf(range_label, sizeof(range_label), "%s same-as-offset", label);
   print_ranges(range_label, results, max_size, same_as_offset);
   snprintf(range_label, sizeof(range_label), "%s baseline-exact", label);
   print_ranges(range_label, results, max_size, baseline_exact);
   snprintf(range_label, sizeof(range_label), "%s offset-exact", label);
   print_ranges(range_label, results, max_size, offset_exact);
   snprintf(range_label, sizeof(range_label), "%s baseline-floor-pass", label);
   print_ranges(range_label, results, max_size, baseline_floor_pass);
   snprintf(range_label, sizeof(range_label), "%s offset-floor-pass", label);
   print_ranges(range_label, results, max_size, offset_floor_pass);

   free(results);
}

static void
run_pow2_scan(struct gl_state *gl, int max_size)
{
   unsigned total = 0;
   unsigned same_count = 0;
   unsigned baseline_exact_count = 0;
   unsigned offset_exact_count = 0;
   unsigned baseline_floor_count = 0;
   unsigned offset_floor_count = 0;
   unsigned failures = 0;

   for (int width = 1; width <= max_size; width <<= 1) {
      for (int height = 1; height <= max_size; height <<= 1) {
         struct compare_result r = full_compare(gl, width, height);
         total++;
         same_count += r.diff_pixels == 0;
         baseline_exact_count += r.baseline_exact_bad == 0;
         offset_exact_count += r.offset_exact_bad == 0;
         baseline_floor_count += r.baseline_floor_bad == 0;
         offset_floor_count += r.offset_floor_bad == 0;

         if (r.diff_pixels || r.baseline_exact_bad || r.offset_exact_bad ||
             r.baseline_floor_bad || r.offset_floor_bad) {
            if (failures < MAX_FAIL_EXAMPLES)
               print_result("POW2-NONEXACT", &r);
            failures++;
         }
      }
   }

   printf("POW2-SUMMARY max=%d cases=%u same_as_offset=%u "
          "baseline_exact=%u offset_exact=%u baseline_floor_pass=%u "
          "offset_floor_pass=%u nonexact_cases=%u\n",
          max_size, total, same_count, baseline_exact_count,
          offset_exact_count, baseline_floor_count, offset_floor_count,
          failures);
}

static void
render_sample_grid_pass(struct gl_state *gl, int max_size, int use_offset,
                        const char *label, int progress_step, uint32_t *bits)
{
   if (use_offset) {
      glEnable(GL_POLYGON_OFFSET_FILL);
      glPolygonOffset(0.0f, 0.0f);
   } else {
      glDisable(GL_POLYGON_OFFSET_FILL);
   }

   glEnable(GL_SCISSOR_TEST);

   for (int height = 1; height <= max_size; height++) {
      for (int width = 1; width <= max_size; width++) {
         const int sx = width - 1;
         const int sy = height - 1;

         glUniform2f(gl->extent_loc, (float)width, (float)height);
         glViewport(0, 0, width, height);
         glScissor(sx, sy, 1, 1);
         glDrawArrays(GL_TRIANGLES, 0, 3);
      }

      if (progress_step > 0 && (height % progress_step) == 0) {
         fprintf(stderr, "sample-grid %s render progress: height=%d/%d\n",
                 label, height, max_size);
      }
   }

   CHECK(glGetError() == GL_NO_ERROR);
   glDisable(GL_SCISSOR_TEST);

   glReadPixels(0, 0, max_size, max_size, GL_RG_INTEGER, GL_UNSIGNED_INT,
                bits);
   CHECK(glGetError() == GL_NO_ERROR);
}

static void
run_sample_grid(struct gl_state *gl, int max_size, int progress_step)
{
   uint64_t pairs = 0;
   uint64_t same_count = 0;
   uint64_t baseline_exact_count = 0;
   uint64_t offset_exact_count = 0;
   uint64_t baseline_floor_count = 0;
   uint64_t offset_floor_count = 0;
   uint64_t same_pred_mismatch = 0;
   uint64_t baseline_exact_pred_mismatch = 0;
   uint64_t offset_exact_pred_mismatch = 0;
   uint64_t baseline_floor_failures = 0;
   uint64_t offset_floor_failures = 0;
   uint64_t baseline_floor_fail_h1 = 0;
   uint64_t baseline_floor_fail_w1 = 0;
   uint64_t baseline_floor_fail_both_nonpow2 = 0;
   int baseline_floor_fail_min_w = 0;
   int baseline_floor_fail_max_w = 0;
   int baseline_floor_fail_min_h = 0;
   int baseline_floor_fail_max_h = 0;
   int baseline_floor_fail_first_w = 0;
   int baseline_floor_fail_first_h = 0;
   int baseline_floor_fail_last_w = 0;
   int baseline_floor_fail_last_h = 0;
   int baseline_floor_fail_square_w = 0;
   int baseline_floor_fail_square_h = 0;
   double baseline_floor_fail_square_aspect = 0.0;
   int baseline_floor_fail_both_nonpow2_square_w = 0;
   int baseline_floor_fail_both_nonpow2_square_h = 0;
   double baseline_floor_fail_both_nonpow2_square_aspect = 0.0;
   int baseline_floor_fail_both_nonpow2_largest_min_w = 0;
   int baseline_floor_fail_both_nonpow2_largest_min_h = 0;
   int baseline_floor_fail_both_nonpow2_largest_min = 0;
   unsigned printed_floor_failures = 0;

   render_sample_grid_pass(gl, max_size, 0, "baseline", progress_step,
                           gl->baseline);
   render_sample_grid_pass(gl, max_size, 1, "offset", progress_step,
                           gl->offset);

   for (int height = 1; height <= max_size; height++) {
      for (int width = 1; width <= max_size; width++) {
         struct compare_result r;
         const int x = width - 1;
         const int y = height - 1;
         const size_t i =
            ((size_t)y * (size_t)max_size + (size_t)x) * COMPONENTS;

         compare_pixels(&gl->baseline[i], &gl->offset[i], width, height,
                        1, 1, x, y, &r);
         const int expected_exact =
            is_pow2_or_one((unsigned)width) &&
            is_pow2_or_one((unsigned)height);
         const int same = r.diff_pixels == 0;
         const int b_exact = r.baseline_exact_bad == 0;
         const int o_exact = r.offset_exact_bad == 0;
         const int b_floor = r.baseline_floor_bad == 0;
         const int o_floor = r.offset_floor_bad == 0;

         pairs++;
         same_count += same;
         baseline_exact_count += b_exact;
         offset_exact_count += o_exact;
         baseline_floor_count += b_floor;
         offset_floor_count += o_floor;
         same_pred_mismatch += same != expected_exact;
         baseline_exact_pred_mismatch += b_exact != expected_exact;
         offset_exact_pred_mismatch += o_exact != expected_exact;
         baseline_floor_failures += !b_floor;
         offset_floor_failures += !o_floor;

         if (!b_floor) {
            if (!baseline_floor_fail_first_w) {
               baseline_floor_fail_first_w = width;
               baseline_floor_fail_first_h = height;
            }
            baseline_floor_fail_last_w = width;
            baseline_floor_fail_last_h = height;

            if (!baseline_floor_fail_min_w ||
                width < baseline_floor_fail_min_w)
               baseline_floor_fail_min_w = width;
            if (!baseline_floor_fail_min_h ||
                height < baseline_floor_fail_min_h)
               baseline_floor_fail_min_h = height;
            if (width > baseline_floor_fail_max_w)
               baseline_floor_fail_max_w = width;
            if (height > baseline_floor_fail_max_h)
               baseline_floor_fail_max_h = height;
            baseline_floor_fail_h1 += height == 1;
            baseline_floor_fail_w1 += width == 1;

            const double aspect = width > height ?
               (double)width / (double)height :
               (double)height / (double)width;
            if (!baseline_floor_fail_square_w ||
                aspect < baseline_floor_fail_square_aspect) {
               baseline_floor_fail_square_w = width;
               baseline_floor_fail_square_h = height;
               baseline_floor_fail_square_aspect = aspect;
            }

            if (!is_pow2_or_one((unsigned)width) &&
                !is_pow2_or_one((unsigned)height)) {
               const int minor = width < height ? width : height;

               baseline_floor_fail_both_nonpow2++;

               if (!baseline_floor_fail_both_nonpow2_square_w ||
                   aspect < baseline_floor_fail_both_nonpow2_square_aspect) {
                  baseline_floor_fail_both_nonpow2_square_w = width;
                  baseline_floor_fail_both_nonpow2_square_h = height;
                  baseline_floor_fail_both_nonpow2_square_aspect = aspect;
               }

               if (minor > baseline_floor_fail_both_nonpow2_largest_min) {
                  baseline_floor_fail_both_nonpow2_largest_min = minor;
                  baseline_floor_fail_both_nonpow2_largest_min_w = width;
                  baseline_floor_fail_both_nonpow2_largest_min_h = height;
               }
            }
         }

         if ((!b_floor || !o_floor) && printed_floor_failures < MAX_FAIL_EXAMPLES) {
            print_result("SAMPLE-FLOOR-FAIL", &r);
            printed_floor_failures++;
         }
      }
   }

   printf("SAMPLE-GRID-SUMMARY max=%d sample=top-right pairs=%" PRIu64
          " same_as_offset=%" PRIu64 " baseline_exact=%" PRIu64
          " offset_exact=%" PRIu64 " baseline_floor_pass=%" PRIu64
          " offset_floor_pass=%" PRIu64
          " same_pred_mismatch=%" PRIu64
          " baseline_exact_pred_mismatch=%" PRIu64
          " offset_exact_pred_mismatch=%" PRIu64
          " baseline_floor_failures=%" PRIu64
          " offset_floor_failures=%" PRIu64
          " baseline_floor_fail_width_range=%d..%d"
          " baseline_floor_fail_height_range=%d..%d"
          " baseline_floor_fail_first=%dx%d"
          " baseline_floor_fail_last=%dx%d"
          " baseline_floor_fail_most_square=%dx%d"
          " baseline_floor_fail_most_square_aspect=%.6f"
          " baseline_floor_fail_both_nonpow2=%" PRIu64
          " baseline_floor_fail_both_nonpow2_most_square=%dx%d"
          " baseline_floor_fail_both_nonpow2_most_square_aspect=%.6f"
          " baseline_floor_fail_both_nonpow2_largest_min=%dx%d"
          " baseline_floor_fail_both_nonpow2_largest_min_dim=%d"
          " baseline_floor_fail_h1=%" PRIu64
          " baseline_floor_fail_w1=%" PRIu64 "\n",
          max_size, pairs, same_count, baseline_exact_count,
          offset_exact_count, baseline_floor_count, offset_floor_count,
          same_pred_mismatch, baseline_exact_pred_mismatch,
          offset_exact_pred_mismatch, baseline_floor_failures,
          offset_floor_failures, baseline_floor_fail_min_w,
          baseline_floor_fail_max_w, baseline_floor_fail_min_h,
          baseline_floor_fail_max_h, baseline_floor_fail_first_w,
          baseline_floor_fail_first_h, baseline_floor_fail_last_w,
          baseline_floor_fail_last_h, baseline_floor_fail_square_w,
          baseline_floor_fail_square_h, baseline_floor_fail_square_aspect,
          baseline_floor_fail_both_nonpow2,
          baseline_floor_fail_both_nonpow2_square_w,
          baseline_floor_fail_both_nonpow2_square_h,
          baseline_floor_fail_both_nonpow2_square_aspect,
          baseline_floor_fail_both_nonpow2_largest_min_w,
          baseline_floor_fail_both_nonpow2_largest_min_h,
          baseline_floor_fail_both_nonpow2_largest_min,
          baseline_floor_fail_h1, baseline_floor_fail_w1);
}

static void
render_sample_major_pow2_pass(struct gl_state *gl, int max_size, int use_offset,
                              const char *label, int progress_step,
                              uint32_t *bits)
{
   if (use_offset) {
      glEnable(GL_POLYGON_OFFSET_FILL);
      glPolygonOffset(0.0f, 0.0f);
   } else {
      glDisable(GL_POLYGON_OFFSET_FILL);
   }

   glEnable(GL_SCISSOR_TEST);

   for (int major = 1; major <= max_size; major <<= 1) {
      for (int minor = 1; minor <= major; minor++) {
         for (int orient = 0; orient < 2; orient++) {
            if (orient && minor == major)
               continue;

            const int width = orient ? minor : major;
            const int height = orient ? major : minor;
            const int sx = width - 1;
            const int sy = height - 1;

            glUniform2f(gl->extent_loc, (float)width, (float)height);
            glViewport(0, 0, width, height);
            glScissor(sx, sy, 1, 1);
            glDrawArrays(GL_TRIANGLES, 0, 3);
         }
      }

      if (progress_step > 0 && (major % progress_step) == 0) {
         fprintf(stderr,
                 "sample-major-pow2 %s render progress: major=%d/%d\n",
                 label, major, max_size);
      }
   }

   CHECK(glGetError() == GL_NO_ERROR);
   glDisable(GL_SCISSOR_TEST);

   glReadPixels(0, 0, max_size, max_size, GL_RG_INTEGER, GL_UNSIGNED_INT,
                bits);
   CHECK(glGetError() == GL_NO_ERROR);
}

static void
run_sample_major_pow2(struct gl_state *gl, int max_size, int progress_step)
{
   uint64_t pairs = 0;
   uint64_t both_pow2_pairs = 0;
   uint64_t same_count = 0;
   uint64_t baseline_exact_count = 0;
   uint64_t offset_exact_count = 0;
   uint64_t baseline_floor_count = 0;
   uint64_t offset_floor_count = 0;
   uint64_t nonexact_cases = 0;
   uint64_t same_pred_mismatch = 0;
   uint64_t baseline_exact_pred_mismatch = 0;
   uint64_t offset_exact_pred_mismatch = 0;
   uint64_t baseline_floor_failures = 0;
   uint64_t offset_floor_failures = 0;
   unsigned printed_nonexact = 0;
   unsigned printed_floor_failures = 0;

   render_sample_major_pow2_pass(gl, max_size, 0, "baseline", progress_step,
                                 gl->baseline);
   render_sample_major_pow2_pass(gl, max_size, 1, "offset", progress_step,
                                 gl->offset);

   for (int major = 1; major <= max_size; major <<= 1) {
      for (int minor = 1; minor <= major; minor++) {
         for (int orient = 0; orient < 2; orient++) {
            if (orient && minor == major)
               continue;

            const int width = orient ? minor : major;
            const int height = orient ? major : minor;
            const int x = width - 1;
            const int y = height - 1;
            const size_t i =
               ((size_t)y * (size_t)max_size + (size_t)x) * COMPONENTS;
            struct compare_result r;

            compare_pixels(&gl->baseline[i], &gl->offset[i], width, height,
                           1, 1, x, y, &r);

            const int expected_exact =
               is_pow2_or_one((unsigned)width) &&
               is_pow2_or_one((unsigned)height);
            const int same = r.diff_pixels == 0;
            const int b_exact = r.baseline_exact_bad == 0;
            const int o_exact = r.offset_exact_bad == 0;
            const int b_floor = r.baseline_floor_bad == 0;
            const int o_floor = r.offset_floor_bad == 0;

            pairs++;
            both_pow2_pairs += expected_exact;
            same_count += same;
            baseline_exact_count += b_exact;
            offset_exact_count += o_exact;
            baseline_floor_count += b_floor;
            offset_floor_count += o_floor;
            same_pred_mismatch += same != expected_exact;
            baseline_exact_pred_mismatch += b_exact != expected_exact;
            offset_exact_pred_mismatch += o_exact != expected_exact;
            baseline_floor_failures += !b_floor;
            offset_floor_failures += !o_floor;

            if (!same || !b_exact || !o_exact) {
               if (printed_nonexact < MAX_FAIL_EXAMPLES)
                  print_result("SAMPLE-MAJOR-POW2-NONEXACT", &r);
               printed_nonexact++;
               nonexact_cases++;
            }

            if ((!b_floor || !o_floor) &&
                printed_floor_failures < MAX_FAIL_EXAMPLES) {
               print_result("SAMPLE-MAJOR-POW2-FLOOR-FAIL", &r);
               printed_floor_failures++;
            }
         }
      }
   }

   printf("SAMPLE-MAJOR-POW2-SUMMARY max=%d sample=top-right pairs=%" PRIu64
          " both_pow2_pairs=%" PRIu64
          " same_as_offset=%" PRIu64
          " baseline_exact=%" PRIu64
          " offset_exact=%" PRIu64
          " baseline_floor_pass=%" PRIu64
          " offset_floor_pass=%" PRIu64
          " nonexact_cases=%" PRIu64
          " same_pred_mismatch=%" PRIu64
          " baseline_exact_pred_mismatch=%" PRIu64
          " offset_exact_pred_mismatch=%" PRIu64
          " baseline_floor_failures=%" PRIu64
          " offset_floor_failures=%" PRIu64 "\n",
          max_size, pairs, both_pow2_pairs, same_count, baseline_exact_count,
          offset_exact_count, baseline_floor_count, offset_floor_count,
          nonexact_cases, same_pred_mismatch, baseline_exact_pred_mismatch,
          offset_exact_pred_mismatch, baseline_floor_failures,
          offset_floor_failures);
}

static void
usage(const char *argv0)
{
   fprintf(stderr,
           "usage: %s [options]\n"
           "  --max N           maximum width/height (default 4096)\n"
           "  --lines           full scans of Wx1, 1xH, Wx2, 2xH\n"
           "  --pow2            full scans of all power-of-two W,H combos\n"
           "  --sample-grid     scissored top-right sample for every WxH pair\n"
           "  --sample-major-pow2 scissored sample where max(W,H) is pow2\n"
           "  --main-results    curated full-surface same-as-offset reproducer\n"
           "  --full-grid-floor full-pixel baseline integer-bin scan, max<=500\n"
           "  --case W H        full scan of one size\n"
           "  --progress N      sampled-render progress interval (default 256)\n"
           "  --help\n",
           argv0);
}

static void
init_gl(struct gl_state *gl, int max_size)
{
   memset(gl, 0, sizeof(*gl));

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

   GLint gl_max_size = 0;
   glGetIntegerv(GL_MAX_TEXTURE_SIZE, &gl_max_size);
   if (max_size > gl_max_size) {
      fprintf(stderr, "max size %d exceeds GL_MAX_TEXTURE_SIZE %d\n",
              max_size, gl_max_size);
      exit(1);
   }

   gl->prog = glCreateProgram();
   glAttachShader(gl->prog, compile(GL_VERTEX_SHADER, vs_src));
   glAttachShader(gl->prog, compile(GL_FRAGMENT_SHADER, fs_src));
   glLinkProgram(gl->prog);

   GLint ok = 0;
   glGetProgramiv(gl->prog, GL_LINK_STATUS, &ok);
   CHECK(ok);
   glUseProgram(gl->prog);
   gl->extent_loc = glGetUniformLocation(gl->prog, "extent");
   CHECK(gl->extent_loc >= 0);

   gl->floor_prog = glCreateProgram();
   glAttachShader(gl->floor_prog, compile(GL_VERTEX_SHADER, vs_src));
   glAttachShader(gl->floor_prog, compile(GL_FRAGMENT_SHADER, fs_floor_src));
   glLinkProgram(gl->floor_prog);

   ok = 0;
   glGetProgramiv(gl->floor_prog, GL_LINK_STATUS, &ok);
   CHECK(ok);
   glUseProgram(gl->floor_prog);
   gl->floor_extent_loc = glGetUniformLocation(gl->floor_prog, "extent");
   CHECK(gl->floor_extent_loc >= 0);

   glUseProgram(gl->prog);

   glGenTextures(1, &gl->tex);
   glBindTexture(GL_TEXTURE_2D, gl->tex);
   glTexStorage2D(GL_TEXTURE_2D, 1, GL_RG32UI, max_size, max_size);

   glGenFramebuffers(1, &gl->fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, gl->fbo);
   glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                          gl->tex, 0);
   CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);

   gl->max_values = (size_t)max_size * (size_t)max_size * COMPONENTS;
   gl->baseline = calloc(gl->max_values, sizeof(*gl->baseline));
   gl->offset = calloc(gl->max_values, sizeof(*gl->offset));
   CHECK(gl->baseline && gl->offset);
}

int
main(int argc, char **argv)
{
   int max_size = 4096;
   int run_lines = 0;
   int run_pow2 = 0;
   int run_samples = 0;
   int run_major_pow2_samples = 0;
   int run_main_result_cases = 0;
   int run_full_grid_floor_cases = 0;
   int run_case = 0;
   int case_width = 0;
   int case_height = 0;
   int progress_step = 256;

   for (int i = 1; i < argc; i++) {
      if (!strcmp(argv[i], "--help")) {
         usage(argv[0]);
         return 0;
      } else if (!strcmp(argv[i], "--lines")) {
         run_lines = 1;
      } else if (!strcmp(argv[i], "--pow2")) {
         run_pow2 = 1;
      } else if (!strcmp(argv[i], "--sample-grid")) {
         run_samples = 1;
      } else if (!strcmp(argv[i], "--sample-major-pow2")) {
         run_major_pow2_samples = 1;
      } else if (!strcmp(argv[i], "--main-results")) {
         run_main_result_cases = 1;
      } else if (!strcmp(argv[i], "--full-grid-floor")) {
         run_full_grid_floor_cases = 1;
      } else if (!strcmp(argv[i], "--max") && i + 1 < argc) {
         max_size = atoi(argv[++i]);
      } else if (!strcmp(argv[i], "--progress") && i + 1 < argc) {
         progress_step = atoi(argv[++i]);
      } else if (!strcmp(argv[i], "--case") && i + 2 < argc) {
         run_case = 1;
         case_width = atoi(argv[++i]);
         case_height = atoi(argv[++i]);
      } else {
         usage(argv[0]);
         return 1;
      }
   }

   if (max_size < 1 || max_size > 4096 || progress_step < 0 ||
       case_width < 0 || case_height < 0 ||
       case_width > max_size || case_height > max_size) {
      usage(argv[0]);
      return 1;
   }

   if (run_full_grid_floor_cases && max_size > 500) {
      fprintf(stderr, "--full-grid-floor is capped at --max 500\n");
      return 1;
   }

   if (run_case && (!case_width || !case_height)) {
      usage(argv[0]);
      return 1;
   }

   if (!run_lines && !run_pow2 && !run_samples && !run_major_pow2_samples &&
       !run_main_result_cases && !run_full_grid_floor_cases && !run_case)
      run_lines = run_pow2 = 1;

   struct gl_state gl;
   init_gl(&gl, max_size);
   int main_result_failures = 0;

   if (run_case) {
      struct compare_result r = full_compare(&gl, case_width, case_height);
      print_result("CASE", &r);
   }

   if (run_main_result_cases)
      main_result_failures = run_main_results(&gl);

   if (run_full_grid_floor_cases)
      run_full_grid_floor(&gl, max_size, progress_step);

   if (run_lines) {
      run_line_scan(&gl, "Wx1", max_size, 1, 1);
      run_line_scan(&gl, "1xH", max_size, 0, 1);
      run_line_scan(&gl, "Wx2", max_size, 1, 2);
      run_line_scan(&gl, "2xH", max_size, 0, 2);
   }

   if (run_pow2)
      run_pow2_scan(&gl, max_size);

   if (run_samples)
      run_sample_grid(&gl, max_size, progress_step);

   if (run_major_pow2_samples)
      run_sample_major_pow2(&gl, max_size, progress_step);

   free(gl.offset);
   free(gl.baseline);
   return main_result_failures ? 2 : 0;
}
