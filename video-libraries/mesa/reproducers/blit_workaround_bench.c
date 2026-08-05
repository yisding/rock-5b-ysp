// SPDX-License-Identifier: MIT
// End-to-end Mesa internal-blit benchmark for the Mali depth-bias workaround.
//
// This intentionally calls glBlitFramebuffer for every measured operation.
// The direct-draw offset_perf_probe.c answers a different, steady-state GPU
// question and must not be substituted for this benchmark.
//
// Build:
//   cc -O2 -Wall -Wextra -Werror -o blit_workaround_bench
//      blit_workaround_bench.c -lEGL -lGLESv2 -lm
//
// Run one process-side of an instrumented-Mesa A/B:
//   PAN_BLIT_DEPTH_BIAS=off ./blit_workaround_bench --label off
//   PAN_BLIT_DEPTH_BIAS=on  ./blit_workaround_bench --label on
//
// The environment variable is consumed by the test-only Mesa instrumentation.
// Use run_blit_workaround_bench.py for process-level A/B, dual-context
// diagnostics, or the primary single-context balanced-order A/B.

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <getopt.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define GL_TIME_ELAPSED_EXT 0x88BF
#define GL_QUERY_RESULT_EXT 0x8866
#define GL_GPU_DISJOINT_EXT 0x8FBB

#define MAX_COUNTS 32

#define CHECK(x)                                                               \
   do {                                                                        \
      if (!(x)) {                                                              \
         fprintf(stderr, "failure at line %d (EGL 0x%x, GL 0x%x)\n",           \
                 __LINE__, eglGetError(), glGetError());                       \
         exit(1);                                                              \
      }                                                                        \
   } while (0)

typedef void (*gen_queries_fn)(GLsizei, GLuint *);
typedef void (*begin_query_fn)(GLenum, GLuint);
typedef void (*end_query_fn)(GLenum);
typedef void (*get_query_fn)(GLuint, GLenum, GLuint64 *);

enum schedule_mode {
   MODE_BATCHED,
   MODE_ISOLATED,
   MODE_COALESCED,
};

struct options {
   int width;
   int height;
   int samples;
   int warmups;
   int ring_size;
   int counts[MAX_COUNTS];
   int count_count;
   int run_batched;
   int run_isolated;
   int run_coalesced;
   int isolated_first;
   int in_process_blocks;
   int single_context;
   int reverse_counts;
   int expected_gpu_hz;
   const char *label;
   const char *context_option;
   const char *context_a_value;
   const char *context_b_value;
   const char *dynamic_option;
};

struct resources {
   GLuint *src_tex;
   GLuint *dst_tex;
   GLuint *src_fbo;
   GLuint *dst_fbo;
   int *expected_src;
   uint32_t *pixels;
};

struct timing {
   double cpu_us;
   double gpu_us;
   double wall_us;
   int disjoint;
};

struct point {
   int count;
   double cpu_median;
   double gpu_median;
   double wall_median;
   double tail_median;
};

struct fit {
   double intercept;
   double slope;
   double r2;
   double rms;
   double max_abs;
};

struct context_state {
   EGLContext context;
   struct resources resources;
   GLuint query;
   const char *label;
};

static gen_queries_fn gen_queries;
static begin_query_fn begin_query;
static end_query_fn end_query;
static get_query_fn get_query;

static const char *gpu_devfreq =
   "/sys/devices/platform/fb000000.gpu/devfreq/fb000000.gpu";

static void
usage(const char *program)
{
   fprintf(stderr,
           "usage: %s [options]\n"
           "  --width N          target width (default 1024)\n"
           "  --height N         target height (default 1024)\n"
           "  --counts LIST      comma-separated operation counts\n"
           "                     (default 1,2,4,8)\n"
           "  --samples N        valid samples per count (default 11)\n"
           "  --warmups N        untimed runs per mode/count (default 2)\n"
           "  --ring N           source/destination resource pairs (default 8)\n"
           "                     must cover the largest batched count\n"
           "  --schedule MODE    batched, isolated, coalesced, both, or all\n"
           "                     (default both)\n"
           "  --order ORDER      batched-first or isolated-first\n"
           "  --label TEXT       A/B label printed in every record\n"
           "  --in-process-blocks N\n"
           "                     create A/B contexts and run N ABBA/BAAB blocks\n"
           "  --context-option NAME\n"
           "                     per-context driver option (default\n"
           "                     PAN_BLIT_DEPTH_BIAS)\n"
           "  --context-a VALUE  context A option value (default off)\n"
           "  --context-b VALUE  context B option value (default on)\n"
           "  --single-context   switch A/B through a test-only dynamic option\n"
           "  --dynamic-option NAME\n"
           "                     per-draw selector used by --single-context\n"
           "                     (default PAN_BLIT_DEPTH_BIAS_DYNAMIC)\n"
           "  --expect-gpu-hz N  verify fixed GPU min/max/current between runs\n",
           program);
}

static int
positive_int(const char *text, const char *what)
{
   char *end = NULL;
   long value = strtol(text, &end, 10);
   if (!text[0] || *end || value < 1 || value > (1 << 24)) {
      fprintf(stderr, "invalid %s: %s\n", what, text);
      exit(1);
   }
   return (int)value;
}

static int
positive_hz(const char *text)
{
   char *end = NULL;
   long value = strtol(text, &end, 10);
   if (!text[0] || *end || value < 1 || value > INT_MAX) {
      fprintf(stderr, "invalid expected GPU Hz: %s\n", text);
      exit(1);
   }
   return (int)value;
}

static void
parse_counts(struct options *options, const char *text)
{
   char *copy = strdup(text);
   CHECK(copy);
   char *save = NULL;
   char *item = strtok_r(copy, ",", &save);
   options->count_count = 0;

   while (item) {
      if (options->count_count == MAX_COUNTS) {
         fprintf(stderr, "too many operation counts (maximum %d)\n",
                 MAX_COUNTS);
         exit(1);
      }
      int value = positive_int(item, "operation count");
      if (options->count_count &&
          value <= options->counts[options->count_count - 1]) {
         fprintf(stderr, "operation counts must be strictly increasing\n");
         exit(1);
      }
      options->counts[options->count_count++] = value;
      item = strtok_r(NULL, ",", &save);
   }

   free(copy);
   if (options->count_count < 2) {
      fprintf(stderr, "at least two operation counts are required for a fit\n");
      exit(1);
   }
}

static void
parse_options(int argc, char **argv, struct options *options)
{
   *options = (struct options){
      .width = 1024,
      .height = 1024,
      .samples = 11,
      .warmups = 2,
      .ring_size = 8,
      .run_batched = 1,
      .run_isolated = 1,
      .label = "unlabeled",
      .context_option = "PAN_BLIT_DEPTH_BIAS",
      .context_a_value = "off",
      .context_b_value = "on",
      .dynamic_option = "PAN_BLIT_DEPTH_BIAS_DYNAMIC",
   };
   parse_counts(options, "1,2,4,8");

   static const struct option long_options[] = {
      {"width", required_argument, NULL, 'w'},
      {"height", required_argument, NULL, 'h'},
      {"counts", required_argument, NULL, 'c'},
      {"samples", required_argument, NULL, 's'},
      {"warmups", required_argument, NULL, 'u'},
      {"ring", required_argument, NULL, 'r'},
      {"schedule", required_argument, NULL, 'm'},
      {"order", required_argument, NULL, 'o'},
      {"label", required_argument, NULL, 'l'},
      {"in-process-blocks", required_argument, NULL, 'b'},
      {"context-option", required_argument, NULL, 'e'},
      {"context-a", required_argument, NULL, 'a'},
      {"context-b", required_argument, NULL, 'd'},
      {"single-context", no_argument, NULL, 'S'},
      {"dynamic-option", required_argument, NULL, 'D'},
      {"expect-gpu-hz", required_argument, NULL, 'g'},
      {"help", no_argument, NULL, 'H'},
      {NULL, 0, NULL, 0},
   };

   int option;
   while ((option = getopt_long(argc, argv, "", long_options, NULL)) != -1) {
      switch (option) {
      case 'w':
         options->width = positive_int(optarg, "width");
         break;
      case 'h':
         options->height = positive_int(optarg, "height");
         break;
      case 'c':
         parse_counts(options, optarg);
         break;
      case 's':
         options->samples = positive_int(optarg, "sample count");
         break;
      case 'u':
         options->warmups = positive_int(optarg, "warmup count");
         break;
      case 'r':
         options->ring_size = positive_int(optarg, "ring size");
         break;
      case 'm':
         options->run_batched = strcmp(optarg, "batched") == 0 ||
                                strcmp(optarg, "both") == 0 ||
                                strcmp(optarg, "all") == 0;
         options->run_isolated = strcmp(optarg, "isolated") == 0 ||
                                 strcmp(optarg, "both") == 0 ||
                                 strcmp(optarg, "all") == 0;
         options->run_coalesced = strcmp(optarg, "coalesced") == 0 ||
                                  strcmp(optarg, "all") == 0;
         if (!options->run_batched && !options->run_isolated &&
             !options->run_coalesced) {
            fprintf(stderr,
                    "schedule must be batched, isolated, coalesced, both, "
                    "or all\n");
            exit(1);
         }
         break;
      case 'o':
         if (strcmp(optarg, "batched-first") == 0) {
            options->isolated_first = 0;
         } else if (strcmp(optarg, "isolated-first") == 0) {
            options->isolated_first = 1;
         } else {
            fprintf(stderr,
                    "order must be batched-first or isolated-first\n");
            exit(1);
         }
         break;
      case 'l':
         if (strchr(optarg, ',') || strchr(optarg, '\n')) {
            fprintf(stderr, "label must not contain a comma or newline\n");
            exit(1);
         }
         options->label = optarg;
         break;
      case 'b':
         options->in_process_blocks =
            positive_int(optarg, "in-process block count");
         break;
      case 'e':
         if (!optarg[0] || strchr(optarg, '=')) {
            fprintf(stderr, "context option must be a non-empty name\n");
            exit(1);
         }
         options->context_option = optarg;
         break;
      case 'a':
         options->context_a_value = optarg;
         break;
      case 'd':
         options->context_b_value = optarg;
         break;
      case 'S':
         options->single_context = 1;
         break;
      case 'D':
         if (!optarg[0] || strchr(optarg, '=')) {
            fprintf(stderr, "dynamic option must be a non-empty name\n");
            exit(1);
         }
         options->dynamic_option = optarg;
         break;
      case 'g':
         options->expected_gpu_hz = positive_hz(optarg);
         break;
      case 'H':
         usage(argv[0]);
         exit(0);
      default:
         usage(argv[0]);
         exit(1);
      }
   }

   if (optind != argc) {
      usage(argv[0]);
      exit(1);
   }

   if (options->run_batched &&
       options->counts[options->count_count - 1] > options->ring_size) {
      fprintf(stderr,
              "ring size must be at least the largest batched operation "
              "count; reusing a destination lets the tile renderer combine "
              "fullscreen overwrites into one framebuffer batch\n");
      exit(1);
   }
   if (options->in_process_blocks &&
       (!options->context_a_value[0] || !options->context_b_value[0])) {
      fprintf(stderr, "context option values must be non-empty\n");
      exit(1);
   }
   if (options->single_context && !options->in_process_blocks) {
      fprintf(stderr, "--single-context requires --in-process-blocks\n");
      exit(1);
   }
}

static double
now_us(void)
{
   struct timespec time;
   CHECK(clock_gettime(CLOCK_MONOTONIC_RAW, &time) == 0);
   return (double)time.tv_sec * 1000000.0 + (double)time.tv_nsec / 1000.0;
}

static long
read_long_file(const char *directory, const char *name)
{
   char path[512];
   CHECK(snprintf(path, sizeof(path), "%s/%s", directory, name) > 0);
   FILE *file = fopen(path, "r");
   if (!file)
      return -1;

   long value = -1;
   if (fscanf(file, "%ld", &value) != 1)
      value = -1;
   fclose(file);
   return value;
}

static void
verify_gpu_clock(const struct options *options, const char *phase)
{
   if (!options->expected_gpu_hz)
      return;

   const long minimum = read_long_file(gpu_devfreq, "min_freq");
   const long maximum = read_long_file(gpu_devfreq, "max_freq");
   const long current = read_long_file(gpu_devfreq, "cur_freq");
   printf("CLOCK,%s,%ld,%ld,%ld\n", phase, minimum, maximum, current);
   if (minimum != options->expected_gpu_hz ||
       maximum != options->expected_gpu_hz ||
       current != options->expected_gpu_hz) {
      fprintf(stderr,
              "GPU clock is not fixed at %d Hz during %s "
              "(min=%ld max=%ld current=%ld)\n",
              options->expected_gpu_hz, phase, minimum, maximum, current);
      exit(1);
   }
}

static int
has_extension(const char *name)
{
   GLint count = 0;
   glGetIntegerv(GL_NUM_EXTENSIONS, &count);
   for (GLint i = 0; i < count; i++) {
      const char *extension =
         (const char *)glGetStringi(GL_EXTENSIONS, (GLuint)i);
      if (extension && strcmp(extension, name) == 0)
         return 1;
   }
   return 0;
}

static uint32_t
pixel_value(int source, size_t pixel)
{
   return (uint32_t)(pixel * UINT32_C(2654435761)) ^
          (uint32_t)((source + 1) * UINT32_C(2246822519));
}

static void
initialize_resources(const struct options *options, struct resources *resources)
{
   const size_t pixel_count = (size_t)options->width * (size_t)options->height;
   CHECK(pixel_count <= SIZE_MAX / sizeof(uint32_t));
   const size_t bytes = pixel_count * sizeof(uint32_t);

   resources->src_tex =
      calloc((size_t)options->ring_size, sizeof(*resources->src_tex));
   resources->dst_tex =
      calloc((size_t)options->ring_size, sizeof(*resources->dst_tex));
   resources->src_fbo =
      calloc((size_t)options->ring_size, sizeof(*resources->src_fbo));
   resources->dst_fbo =
      calloc((size_t)options->ring_size, sizeof(*resources->dst_fbo));
   resources->expected_src =
      malloc((size_t)options->ring_size * sizeof(*resources->expected_src));
   resources->pixels = malloc(bytes);
   CHECK(resources->src_tex && resources->dst_tex && resources->src_fbo &&
         resources->dst_fbo && resources->expected_src && resources->pixels);

   glGenTextures(options->ring_size, resources->src_tex);
   glGenTextures(options->ring_size, resources->dst_tex);
   glGenFramebuffers(options->ring_size, resources->src_fbo);
   glGenFramebuffers(options->ring_size, resources->dst_fbo);

   for (int ring = 0; ring < options->ring_size; ring++) {
      for (size_t pixel = 0; pixel < pixel_count; pixel++)
         resources->pixels[pixel] = pixel_value(ring, pixel);

      glBindTexture(GL_TEXTURE_2D, resources->src_tex[ring]);
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_R32UI, options->width,
                     options->height);
      glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, options->width, options->height,
                      GL_RED_INTEGER, GL_UNSIGNED_INT, resources->pixels);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

      glBindTexture(GL_TEXTURE_2D, resources->dst_tex[ring]);
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_R32UI, options->width,
                     options->height);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

      glBindFramebuffer(GL_READ_FRAMEBUFFER, resources->src_fbo[ring]);
      glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                             GL_TEXTURE_2D, resources->src_tex[ring], 0);
      glReadBuffer(GL_COLOR_ATTACHMENT0);
      CHECK(glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) ==
            GL_FRAMEBUFFER_COMPLETE);

      glBindFramebuffer(GL_DRAW_FRAMEBUFFER, resources->dst_fbo[ring]);
      glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                             GL_TEXTURE_2D, resources->dst_tex[ring], 0);
      const GLenum draw_buffer = GL_COLOR_ATTACHMENT0;
      glDrawBuffers(1, &draw_buffer);
      CHECK(glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) ==
            GL_FRAMEBUFFER_COMPLETE);
      resources->expected_src[ring] = -1;
   }
   CHECK(glGetError() == GL_NO_ERROR);
}

static void
issue_blit(const struct options *options, struct resources *resources, int op)
{
   const int source = op % options->ring_size;
   const int destination =
      (op * (options->ring_size > 2 ? options->ring_size - 1 : 1) + 1) %
      options->ring_size;

   glBindFramebuffer(GL_READ_FRAMEBUFFER, resources->src_fbo[source]);
   glBindFramebuffer(GL_DRAW_FRAMEBUFFER, resources->dst_fbo[destination]);
   glBlitFramebuffer(0, 0, options->width, options->height, 0, 0,
                     options->width, options->height, GL_COLOR_BUFFER_BIT,
                     GL_NEAREST);
   resources->expected_src[destination] = source;
}

static void
issue_coalesced_blit(const struct options *options,
                     struct resources *resources, int op)
{
   const int source = op % options->ring_size;
   const int destination = 0;

   glBindFramebuffer(GL_READ_FRAMEBUFFER, resources->src_fbo[source]);
   glBindFramebuffer(GL_DRAW_FRAMEBUFFER, resources->dst_fbo[destination]);
   glBlitFramebuffer(0, 0, options->width, options->height, 0, 0,
                     options->width, options->height, GL_COLOR_BUFFER_BIT,
                     GL_NEAREST);
   resources->expected_src[destination] = source;
}

static struct timing
run_batched(const struct options *options, struct resources *resources,
            GLuint query, int operation_count)
{
   GLint old_disjoint = 0;
   glFinish();
   glGetIntegerv(GL_GPU_DISJOINT_EXT, &old_disjoint);

   /*
    * Panfrost stores time-query markers in the batch for the currently bound
    * FBO. Submit the start marker before creating any measured FBO batches.
    * Likewise, submit every measured batch before appending the end marker.
    * Without both flushes the end marker can execute while other framebuffer
    * batches from this query are still pending in the driver.
    */
   begin_query(GL_TIME_ELAPSED_EXT, query);
   glFlush();
   const double wall_start = now_us();
   const double cpu_start = wall_start;
   for (int op = 0; op < operation_count; op++)
      issue_blit(options, resources, op);
   glFlush();
   const double cpu_end = now_us();
   end_query(GL_TIME_ELAPSED_EXT);
   glFlush();
   glFinish();
   const double wall_end = now_us();

   GLuint64 gpu_ns = 0;
   get_query(query, GL_QUERY_RESULT_EXT, &gpu_ns);
   GLint disjoint = 0;
   glGetIntegerv(GL_GPU_DISJOINT_EXT, &disjoint);
   CHECK(glGetError() == GL_NO_ERROR);
   return (struct timing){
      .cpu_us = cpu_end - cpu_start,
      .gpu_us = (double)gpu_ns / 1000.0,
      .wall_us = wall_end - wall_start,
      .disjoint = old_disjoint != GL_FALSE || disjoint != GL_FALSE,
   };
}

static struct timing
run_isolated(const struct options *options, struct resources *resources,
             GLuint query, int operation_count)
{
   GLint old_disjoint = 0;
   glFinish();
   glGetIntegerv(GL_GPU_DISJOINT_EXT, &old_disjoint);
   const double wall_start = now_us();
   double cpu_us = 0.0;
   double gpu_us = 0.0;

   for (int op = 0; op < operation_count; op++) {
      begin_query(GL_TIME_ELAPSED_EXT, query);
      glFlush();
      const double cpu_start = now_us();
      issue_blit(options, resources, op);
      glFlush();
      const double cpu_end = now_us();
      end_query(GL_TIME_ELAPSED_EXT);
      glFlush();
      glFinish();

      GLuint64 gpu_ns = 0;
      get_query(query, GL_QUERY_RESULT_EXT, &gpu_ns);
      cpu_us += cpu_end - cpu_start;
      gpu_us += (double)gpu_ns / 1000.0;
   }

   const double wall_end = now_us();
   GLint disjoint = 0;
   glGetIntegerv(GL_GPU_DISJOINT_EXT, &disjoint);
   CHECK(glGetError() == GL_NO_ERROR);
   return (struct timing){
      .cpu_us = cpu_us,
      .gpu_us = gpu_us,
      .wall_us = wall_end - wall_start,
      .disjoint = old_disjoint != GL_FALSE || disjoint != GL_FALSE,
   };
}

static struct timing
run_coalesced(const struct options *options, struct resources *resources,
              GLuint query, int operation_count)
{
   GLint old_disjoint = 0;
   glFinish();
   glGetIntegerv(GL_GPU_DISJOINT_EXT, &old_disjoint);

   /*
    * Every measured draw targets dst_fbo[0], so the begin marker, all real
    * internal-blitter draws, and the query-end submission belong to the same
    * Panfrost framebuffer batch. Holding the start marker until query end
    * removes the CPU submission gaps that are unavoidable when the query
    * brackets many independent FBO batches.
    */
   glBindFramebuffer(GL_DRAW_FRAMEBUFFER, resources->dst_fbo[0]);
   begin_query(GL_TIME_ELAPSED_EXT, query);
   const double wall_start = now_us();
   const double cpu_start = wall_start;
   for (int op = 0; op < operation_count; op++)
      issue_coalesced_blit(options, resources, op);
   const double cpu_end = now_us();
   end_query(GL_TIME_ELAPSED_EXT);
   glFinish();
   const double wall_end = now_us();

   GLuint64 gpu_ns = 0;
   get_query(query, GL_QUERY_RESULT_EXT, &gpu_ns);
   GLint disjoint = 0;
   glGetIntegerv(GL_GPU_DISJOINT_EXT, &disjoint);
   CHECK(glGetError() == GL_NO_ERROR);
   return (struct timing){
      .cpu_us = cpu_end - cpu_start,
      .gpu_us = (double)gpu_ns / 1000.0,
      .wall_us = wall_end - wall_start,
      .disjoint = old_disjoint != GL_FALSE || disjoint != GL_FALSE,
   };
}

static int
compare_double(const void *a, const void *b)
{
   const double x = *(const double *)a;
   const double y = *(const double *)b;
   return (x > y) - (x < y);
}

static double
percentile(const double *sorted, int count, double fraction)
{
   const double position = fraction * (count - 1);
   const int low = (int)position;
   const int high = low + 1 < count ? low + 1 : low;
   const double weight = position - low;
   return sorted[low] * (1.0 - weight) + sorted[high] * weight;
}

static struct fit
linear_fit(const struct point *points, int point_count, int metric)
{
   double sum_x = 0.0;
   double sum_y = 0.0;
   for (int i = 0; i < point_count; i++) {
      sum_x += points[i].count;
      sum_y += metric == 0   ? points[i].cpu_median
               : metric == 1 ? points[i].gpu_median
               : metric == 2 ? points[i].wall_median
                             : points[i].tail_median;
   }
   const double mean_x = sum_x / point_count;
   const double mean_y = sum_y / point_count;
   double xx = 0.0;
   double xy = 0.0;
   double total = 0.0;
   for (int i = 0; i < point_count; i++) {
      const double x = points[i].count;
      const double y = metric == 0   ? points[i].cpu_median
                       : metric == 1 ? points[i].gpu_median
                       : metric == 2 ? points[i].wall_median
                                     : points[i].tail_median;
      xx += (x - mean_x) * (x - mean_x);
      xy += (x - mean_x) * (y - mean_y);
      total += (y - mean_y) * (y - mean_y);
   }

   struct fit fit = {
      .slope = xy / xx,
   };
   fit.intercept = mean_y - fit.slope * mean_x;

   double residual_squared = 0.0;
   for (int i = 0; i < point_count; i++) {
      const double y = metric == 0   ? points[i].cpu_median
                       : metric == 1 ? points[i].gpu_median
                       : metric == 2 ? points[i].wall_median
                                     : points[i].tail_median;
      const double residual =
         y - (fit.intercept + fit.slope * points[i].count);
      residual_squared += residual * residual;
      fit.max_abs = fmax(fit.max_abs, fabs(residual));
   }
   fit.rms = sqrt(residual_squared / point_count);
   fit.r2 = total > 0.0 ? 1.0 - residual_squared / total : 1.0;
   return fit;
}

static void
report_fit(const struct options *options, const char *mode,
           const struct point *points, int metric, const char *metric_name)
{
   const struct fit fit = linear_fit(points, options->count_count, metric);
   printf("FIT,%s,%s,%s,%.6f,%.6f,%.9f,%.6f,%.6f,%d\n",
          options->label, mode, metric_name, fit.intercept, fit.slope, fit.r2,
          fit.rms, fit.max_abs, options->count_count);
}

static void
run_mode(const struct options *options, struct resources *resources,
         GLuint query, enum schedule_mode schedule)
{
   const char *mode = schedule == MODE_BATCHED     ? "batched"
                      : schedule == MODE_ISOLATED ? "isolated"
                                                  : "coalesced";
   struct point *points =
      calloc((size_t)options->count_count, sizeof(*points));
   double *cpu = malloc((size_t)options->samples * sizeof(*cpu));
   double *gpu = malloc((size_t)options->samples * sizeof(*gpu));
   double *wall = malloc((size_t)options->samples * sizeof(*wall));
   double *tail = malloc((size_t)options->samples * sizeof(*tail));
   CHECK(points && cpu && gpu && wall && tail);

   for (int iteration = 0; iteration < options->count_count; iteration++) {
      const int point_index =
         options->reverse_counts ? options->count_count - 1 - iteration
                                 : iteration;
      const int operation_count = options->counts[point_index];
      for (int warmup = 0; warmup < options->warmups; warmup++) {
         if (schedule == MODE_BATCHED)
            (void)run_batched(options, resources, query, operation_count);
         else if (schedule == MODE_ISOLATED)
            (void)run_isolated(options, resources, query, operation_count);
         else
            (void)run_coalesced(options, resources, query, operation_count);
      }

      int valid = 0;
      int attempt = 0;
      const int max_attempts = options->samples * 3;
      while (valid < options->samples && attempt < max_attempts) {
         struct timing timing =
            schedule == MODE_BATCHED
               ? run_batched(options, resources, query, operation_count)
             : schedule == MODE_ISOLATED
               ? run_isolated(options, resources, query, operation_count)
               : run_coalesced(options, resources, query, operation_count);
         printf("SAMPLE,%s,%s,%d,%d,%.6f,%.6f,%.6f,%d\n",
                options->label, mode, operation_count, attempt, timing.cpu_us,
                timing.gpu_us, timing.wall_us, timing.disjoint);
         attempt++;
         if (timing.disjoint)
            continue;
         cpu[valid] = timing.cpu_us;
         gpu[valid] = timing.gpu_us;
         wall[valid] = timing.wall_us;
         tail[valid] = timing.wall_us - timing.cpu_us;
         valid++;
      }
      if (valid != options->samples) {
         fprintf(stderr, "too many disjoint samples for %s N=%d\n", mode,
                 operation_count);
         exit(2);
      }

      qsort(cpu, (size_t)valid, sizeof(*cpu), compare_double);
      qsort(gpu, (size_t)valid, sizeof(*gpu), compare_double);
      qsort(wall, (size_t)valid, sizeof(*wall), compare_double);
      qsort(tail, (size_t)valid, sizeof(*tail), compare_double);
      points[point_index] = (struct point){
         .count = operation_count,
         .cpu_median = percentile(cpu, valid, 0.5),
         .gpu_median = percentile(gpu, valid, 0.5),
         .wall_median = percentile(wall, valid, 0.5),
         .tail_median = percentile(tail, valid, 0.5),
      };
      printf("POINT,%s,%s,%d,"
             "%.6f,%.6f,%.6f,"
             "%.6f,%.6f,%.6f,"
             "%.6f,%.6f,%.6f,%d\n",
             options->label, mode, operation_count,
             percentile(cpu, valid, 0.1), percentile(cpu, valid, 0.5),
             percentile(cpu, valid, 0.9), percentile(gpu, valid, 0.1),
             percentile(gpu, valid, 0.5), percentile(gpu, valid, 0.9),
             percentile(wall, valid, 0.1), percentile(wall, valid, 0.5),
             percentile(wall, valid, 0.9), valid);
      printf("TAIL-POINT,%s,%s,%d,%.6f,%.6f,%.6f,%d\n",
             options->label, mode, operation_count,
             percentile(tail, valid, 0.1), percentile(tail, valid, 0.5),
             percentile(tail, valid, 0.9), valid);
   }

   report_fit(options, mode, points, 0, "cpu");
   report_fit(options, mode, points, 1, "gpu");
   report_fit(options, mode, points, 2, "wall");
   report_fit(options, mode, points, 3, "tail");
   free(points);
   free(cpu);
   free(gpu);
   free(wall);
   free(tail);
}

static size_t
verify(const struct options *options, struct resources *resources)
{
   const size_t pixel_count = (size_t)options->width * (size_t)options->height;
   size_t mismatches = 0;
   int checked = 0;

   glPixelStorei(GL_PACK_ALIGNMENT, 4);
   for (int destination = 0; destination < options->ring_size; destination++) {
      const int source = resources->expected_src[destination];
      if (source < 0)
         continue;
      checked++;
      glBindFramebuffer(GL_READ_FRAMEBUFFER,
                        resources->dst_fbo[destination]);
      glReadPixels(0, 0, options->width, options->height, GL_RED_INTEGER,
                   GL_UNSIGNED_INT, resources->pixels);
      CHECK(glGetError() == GL_NO_ERROR);
      for (size_t pixel = 0; pixel < pixel_count; pixel++) {
         if (resources->pixels[pixel] != pixel_value(source, pixel))
            mismatches++;
      }
   }

   printf("CORRECTNESS,%s,%d,%zu,%zu\n", options->label, checked,
          pixel_count * (size_t)checked, mismatches);
   return mismatches;
}

static void
make_current(EGLDisplay display, struct context_state *state)
{
   CHECK(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                        state->context));
}

static void
initialize_context(EGLDisplay display, EGLConfig config,
                   struct options *options, struct context_state *state,
                   const char *label, const char *option_value)
{
   if (option_value)
      CHECK(setenv(options->context_option, option_value, 1) == 0);

   const EGLint context_attributes[] = {
      EGL_CONTEXT_CLIENT_VERSION, 3,
      EGL_NONE,
   };
   state->context =
      eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
   CHECK(state->context != EGL_NO_CONTEXT);
   state->label = label;
   make_current(display, state);

   const char *renderer = (const char *)glGetString(GL_RENDERER);
   const char *version = (const char *)glGetString(GL_VERSION);
   fprintf(stderr, "GL_RENDERER=%s\nGL_VERSION=%s\n", renderer, version);
   printf("META,%s,%d,%d,%d,%d,%s,%s\n", state->label, options->width,
          options->height, options->ring_size, options->samples, renderer,
          version);

   CHECK(has_extension("GL_EXT_disjoint_timer_query"));
   gen_queries(1, &state->query);

   GLint max_size = 0;
   glGetIntegerv(GL_MAX_TEXTURE_SIZE, &max_size);
   CHECK(options->width <= max_size && options->height <= max_size);
   initialize_resources(options, &state->resources);

   /* Force lazy internal blit-shader creation before any timed warm-up. */
   if (options->run_coalesced)
      issue_coalesced_blit(options, &state->resources, 0);
   else
      issue_blit(options, &state->resources, 0);
   glFinish();
}

static void
run_requested_modes(const struct options *options,
                    struct context_state *state)
{
   if (options->run_coalesced)
      run_mode(options, &state->resources, state->query, MODE_COALESCED);

   if (options->isolated_first) {
      if (options->run_isolated)
         run_mode(options, &state->resources, state->query, MODE_ISOLATED);
      if (options->run_batched)
         run_mode(options, &state->resources, state->query, MODE_BATCHED);
   } else {
      if (options->run_batched)
         run_mode(options, &state->resources, state->query, MODE_BATCHED);
      if (options->run_isolated)
         run_mode(options, &state->resources, state->query, MODE_ISOLATED);
   }
}

static size_t
verify_context(EGLDisplay display, struct options *options,
               struct context_state *state)
{
   make_current(display, state);
   options->label = state->label;
   const size_t mismatches = verify(options, &state->resources);
   printf("VERDICT,%s,%s\n", state->label, mismatches ? "FAIL" : "PASS");
   return mismatches;
}

static int
run_in_process(EGLDisplay display, EGLConfig config, struct options *options)
{
   struct context_state states[2] = {0};
   if (options->single_context) {
      CHECK(setenv(options->dynamic_option, options->context_a_value, 1) == 0);
      initialize_context(display, config, options, &states[0], "single",
                         "dynamic");
   } else {
      initialize_context(display, config, options, &states[0], "a",
                         options->context_a_value);
      initialize_context(display, config, options, &states[1], "b",
                         options->context_b_value);
   }

   for (int block = 0; block < options->in_process_blocks; block++) {
      const int abba[4] = {0, 1, 1, 0};
      const int baab[4] = {1, 0, 0, 1};
      const int *order = block % 2 ? baab : abba;
      printf("INPROCESS-BLOCK,%d,%s\n", block,
             block % 2 ? "b-a-a-b" : "a-b-b-a");
      for (int sequence = 0; sequence < 4; sequence++) {
         const int side = order[sequence];
         struct context_state *state =
            &states[options->single_context ? 0 : side];
         const char *label = side ? "b" : "a";
         if (options->single_context) {
            const char *value =
               side ? options->context_b_value : options->context_a_value;
            CHECK(setenv(options->dynamic_option, value, 1) == 0);
         }
         char phase[96];
         CHECK(snprintf(phase, sizeof(phase),
                        "in-process-block-%d-run-%d-pre", block,
                        sequence) > 0);
         verify_gpu_clock(options, phase);
         make_current(display, state);
         options->label = label;
         /*
          * Balance the monotonic within-run warm-up/drift confound: each side
          * gets one ascending and one descending count fit in every block.
          */
         options->reverse_counts = sequence & 1;
         printf("INPROCESS-RUN,%d,%d,%s\n", block, sequence, label);
         printf("COUNT-ORDER,%d,%d,%s\n", block, sequence,
                options->reverse_counts ? "descending" : "ascending");
         run_requested_modes(options, state);
         glFinish();
         CHECK(snprintf(phase, sizeof(phase),
                        "in-process-block-%d-run-%d-post", block,
                        sequence) > 0);
         verify_gpu_clock(options, phase);
      }
   }

   size_t mismatches = 0;
   if (options->single_context) {
      for (int side = 0; side < 2; side++) {
         const char *label = side ? "b" : "a";
         const char *value =
            side ? options->context_b_value : options->context_a_value;
         CHECK(setenv(options->dynamic_option, value, 1) == 0);
         make_current(display, &states[0]);
         options->label = label;
         if (options->run_coalesced)
            issue_coalesced_blit(options, &states[0].resources, 0);
         else
            issue_blit(options, &states[0].resources, 0);
         glFinish();
         const size_t side_mismatches =
            verify(options, &states[0].resources);
         printf("VERDICT,%s,%s\n", label,
                side_mismatches ? "FAIL" : "PASS");
         mismatches += side_mismatches;
      }
   } else {
      mismatches += verify_context(display, options, &states[0]);
      mismatches += verify_context(display, options, &states[1]);
   }
   return mismatches ? 2 : 0;
}

int
main(int argc, char **argv)
{
   struct options options;
   parse_options(argc, argv, &options);

   PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress(
         "eglGetPlatformDisplayEXT");
   CHECK(get_platform_display);
   EGLDisplay display = get_platform_display(EGL_PLATFORM_SURFACELESS_MESA,
                                             EGL_DEFAULT_DISPLAY, NULL);
   CHECK(display != EGL_NO_DISPLAY);
   CHECK(eglInitialize(display, NULL, NULL));
   CHECK(eglBindAPI(EGL_OPENGL_ES_API));

   const EGLint config_attributes[] = {
      EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
      EGL_SURFACE_TYPE, 0,
      EGL_NONE,
   };
   EGLConfig config;
   EGLint config_count = 0;
   CHECK(eglChooseConfig(display, config_attributes, &config, 1,
                         &config_count) &&
         config_count);

   gen_queries = (gen_queries_fn)eglGetProcAddress("glGenQueriesEXT");
   begin_query = (begin_query_fn)eglGetProcAddress("glBeginQueryEXT");
   end_query = (end_query_fn)eglGetProcAddress("glEndQueryEXT");
   get_query = (get_query_fn)eglGetProcAddress("glGetQueryObjectui64vEXT");
   CHECK(gen_queries && begin_query && end_query && get_query);

   if (options.in_process_blocks)
      return run_in_process(display, config, &options);

   struct context_state state = {0};
   initialize_context(display, config, &options, &state, options.label, NULL);
   verify_gpu_clock(&options, "single-process-pre");
   run_requested_modes(&options, &state);
   verify_gpu_clock(&options, "single-process-post");
   return verify_context(display, &options, &state) ? 2 : 0;
}
