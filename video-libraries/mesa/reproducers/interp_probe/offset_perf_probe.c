// Paired Mali interpolation-path performance probe.
//
// The draw is a fullscreen texelFetch blit. Each sample performs a batch of
// identical draws using baseline varyings, varyings with zero polygon offset,
// or gl_FragCoord. Alternating ABBA/BAAB blocks reduce frequency and thermal
// bias, and every timer batch is completed separately for correct tile-work
// ownership on Mali.

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef GL_TIME_ELAPSED_EXT
#define GL_TIME_ELAPSED_EXT 0x88BF
#endif
#ifndef GL_QUERY_RESULT_EXT
#define GL_QUERY_RESULT_EXT 0x8866
#endif
#ifndef GL_GPU_DISJOINT_EXT
#define GL_GPU_DISJOINT_EXT 0x8FBB
#endif

#define CHECK(x)                                                               \
   do {                                                                        \
      if (!(x)) {                                                              \
         fprintf(stderr, "check failed at line %d, egl=0x%x gl=0x%x\n",        \
                 __LINE__, eglGetError(), glGetError());                       \
         exit(1);                                                              \
      }                                                                        \
   } while (0)

typedef void (*PFNGLGENQUERIESEXTPROC)(GLsizei, GLuint *);
typedef void (*PFNGLDELETEQUERIESEXTPROC)(GLsizei, const GLuint *);
typedef void (*PFNGLBEGINQUERYEXTPROC)(GLenum, GLuint);
typedef void (*PFNGLENDQUERYEXTPROC)(GLenum);
typedef void (*PFNGLGETQUERYOBJECTUI64VEXTPROC)(GLuint, GLenum, GLuint64 *);

static const char *vs_src =
   "#version 300 es\n"
   "uniform vec2 extent;\n"
   "out highp vec2 src_coord;\n"
   "void main() {\n"
   "   vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0,\n"
   "                 gl_VertexID == 2 ? 3.0 : -1.0);\n"
   "   src_coord = (p + 1.0) * 0.5 * extent;\n"
   "   gl_Position = vec4(p, 0.0, 1.0);\n"
   "}\n";

static const char *fs_varying =
   "#version 300 es\n"
   "uniform highp usampler2D source_tex;\n"
   "in highp vec2 src_coord;\n"
   "layout(location = 0) out highp uint value;\n"
   "void main() {\n"
   "   value = texelFetch(source_tex, ivec2(src_coord), 0).r;\n"
   "}\n";

static const char *fs_fragcoord =
   "#version 300 es\n"
   "uniform highp usampler2D source_tex;\n"
   "layout(location = 0) out highp uint value;\n"
   "void main() {\n"
   "   value = texelFetch(source_tex, ivec2(gl_FragCoord.xy), 0).r;\n"
   "}\n";

enum path {
   PATH_BASELINE,
   PATH_WORKAROUND,
   PATH_FRAGCOORD,
   PATH_COUNT,
};

struct sample {
   double wall_ms;
   double gpu_ms;
};

static double
now_ms(void)
{
   struct timespec ts;
   CHECK(clock_gettime(CLOCK_MONOTONIC_RAW, &ts) == 0);
   return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static int
cmp_double(const void *a, const void *b)
{
   const double da = *(const double *)a;
   const double db = *(const double *)b;
   return (da > db) - (da < db);
}

static double
median(const double *values, int count)
{
   double *copy = malloc((size_t)count * sizeof(*copy));
   CHECK(copy);
   memcpy(copy, values, (size_t)count * sizeof(*copy));
   qsort(copy, (size_t)count, sizeof(*copy), cmp_double);
   const double result =
      count & 1 ? copy[count / 2]
                : (copy[count / 2 - 1] + copy[count / 2]) * 0.5;
   free(copy);
   return result;
}

static double
percentile(const double *values, int count, double fraction)
{
   double *copy = malloc((size_t)count * sizeof(*copy));
   CHECK(copy);
   memcpy(copy, values, (size_t)count * sizeof(*copy));
   qsort(copy, (size_t)count, sizeof(*copy), cmp_double);
   const double position = fraction * (double)(count - 1);
   const int lower = (int)position;
   const int upper = lower + 1 < count ? lower + 1 : lower;
   const double weight = position - (double)lower;
   const double result = copy[lower] * (1.0 - weight) + copy[upper] * weight;
   free(copy);
   return result;
}

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

static int
has_extension(const char *name)
{
   GLint count = 0;
   glGetIntegerv(GL_NUM_EXTENSIONS, &count);
   for (GLint i = 0; i < count; i++) {
      const char *ext = (const char *)glGetStringi(GL_EXTENSIONS, (GLuint)i);
      if (ext && strcmp(ext, name) == 0)
         return 1;
   }
   return 0;
}

static void
select_path(enum path path, const GLuint programs[2])
{
   glUseProgram(path == PATH_FRAGCOORD ? programs[1] : programs[0]);
   if (path == PATH_WORKAROUND) {
      glEnable(GL_POLYGON_OFFSET_FILL);
      glPolygonOffset(0.0f, 0.0f);
   } else {
      glDisable(GL_POLYGON_OFFSET_FILL);
   }
}

static struct sample
run_sample(enum path path, const GLuint programs[2], int draws, int have_timer,
           PFNGLBEGINQUERYEXTPROC begin_query,
           PFNGLENDQUERYEXTPROC end_query,
           PFNGLGETQUERYOBJECTUI64VEXTPROC get_query_result, GLuint query)
{
   select_path(path, programs);

   glFinish();
   const double start = now_ms();
   if (have_timer)
      begin_query(GL_TIME_ELAPSED_EXT, query);
   for (int i = 0; i < draws; i++)
      glDrawArrays(GL_TRIANGLES, 0, 3);
   if (have_timer)
      end_query(GL_TIME_ELAPSED_EXT);
   glFinish();
   const double end = now_ms();

   GLuint64 gpu_ns = 0;
   if (have_timer)
      get_query_result(query, GL_QUERY_RESULT_EXT, &gpu_ns);

   CHECK(glGetError() == GL_NO_ERROR);
   return (struct sample){
      .wall_ms = end - start,
      .gpu_ms = have_timer ? (double)gpu_ns / 1000000.0 : 0.0,
   };
}

int
main(int argc, char **argv)
{
   int width = 12288;
   int height = 1;
   int draws = 4096;
   int pairs = 30;
   int warmup_pairs = 4;

   if (argc > 6) {
      fprintf(stderr,
              "usage: %s [width height draws blocks warmup_blocks]\n", argv[0]);
      return 1;
   }
   int *args[] = {&width, &height, &draws, &pairs, &warmup_pairs};
   for (int i = 1; i < argc; i++) {
      char *end = NULL;
      long value = strtol(argv[i], &end, 10);
      if (!argv[i][0] || *end || value <= 0 || value > (1 << 24)) {
         fprintf(stderr,
                 "usage: %s [width height draws blocks warmup_blocks]\n",
                 argv[0]);
         return 1;
      }
      *args[i - 1] = (int)value;
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
   if (width > max_size || height > max_size) {
      fprintf(stderr, "size %dx%d exceeds GL_MAX_TEXTURE_SIZE %d\n", width,
              height, max_size);
      return 1;
   }

   GLuint programs[2];
   const char *fragment_sources[2] = {fs_varying, fs_fragcoord};
   const GLuint vertex_shader = compile(GL_VERTEX_SHADER, vs_src);
   for (int i = 0; i < 2; i++) {
      programs[i] = glCreateProgram();
      glAttachShader(programs[i], vertex_shader);
      glAttachShader(programs[i],
                     compile(GL_FRAGMENT_SHADER, fragment_sources[i]));
      glLinkProgram(programs[i]);
      GLint linked = 0;
      glGetProgramiv(programs[i], GL_LINK_STATUS, &linked);
      CHECK(linked);
      glUseProgram(programs[i]);
      glUniform2f(glGetUniformLocation(programs[i], "extent"), (float)width,
                  (float)height);
      glUniform1i(glGetUniformLocation(programs[i], "source_tex"), 0);
   }

   GLuint textures[2], fbo;
   glGenTextures(2, textures);
   for (int i = 0; i < 2; i++) {
      glBindTexture(GL_TEXTURE_2D, textures[i]);
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_R32UI, width, height);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
   }
   glActiveTexture(GL_TEXTURE0);
   glBindTexture(GL_TEXTURE_2D, textures[0]);
   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                          textures[1], 0);
   CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
   glViewport(0, 0, width, height);
   CHECK(glGetError() == GL_NO_ERROR);

   const int have_timer = has_extension("GL_EXT_disjoint_timer_query");
   PFNGLGENQUERIESEXTPROC gen_queries =
      (PFNGLGENQUERIESEXTPROC)eglGetProcAddress("glGenQueriesEXT");
   PFNGLDELETEQUERIESEXTPROC delete_queries =
      (PFNGLDELETEQUERIESEXTPROC)eglGetProcAddress("glDeleteQueriesEXT");
   PFNGLBEGINQUERYEXTPROC begin_query =
      (PFNGLBEGINQUERYEXTPROC)eglGetProcAddress("glBeginQueryEXT");
   PFNGLENDQUERYEXTPROC end_query =
      (PFNGLENDQUERYEXTPROC)eglGetProcAddress("glEndQueryEXT");
   PFNGLGETQUERYOBJECTUI64VEXTPROC get_query_result =
      (PFNGLGETQUERYOBJECTUI64VEXTPROC)eglGetProcAddress(
         "glGetQueryObjectui64vEXT");
   const int usable_timer = have_timer && gen_queries && delete_queries &&
                            begin_query && end_query && get_query_result;
   enum comparison {
      COMPARE_WORKAROUND,
      COMPARE_FRAGCOORD,
      COMPARE_COUNT,
   };
   const enum path compared_path[COMPARE_COUNT] = {
      PATH_WORKAROUND,
      PATH_FRAGCOORD,
   };

   GLuint queries[8] = {0};
   if (usable_timer)
      gen_queries(8, queries);

   double *baseline_wall[COMPARE_COUNT], *compared_wall[COMPARE_COUNT];
   double *baseline_gpu[COMPARE_COUNT], *compared_gpu[COMPARE_COUNT];
   double *wall_ratios[COMPARE_COUNT], *gpu_ratios[COMPARE_COUNT];
   for (int comparison = 0; comparison < COMPARE_COUNT; comparison++) {
      baseline_wall[comparison] =
         malloc((size_t)pairs * sizeof(**baseline_wall));
      compared_wall[comparison] =
         malloc((size_t)pairs * sizeof(**compared_wall));
      baseline_gpu[comparison] =
         malloc((size_t)pairs * sizeof(**baseline_gpu));
      compared_gpu[comparison] =
         malloc((size_t)pairs * sizeof(**compared_gpu));
      wall_ratios[comparison] =
         malloc((size_t)pairs * sizeof(**wall_ratios));
      gpu_ratios[comparison] =
         malloc((size_t)pairs * sizeof(**gpu_ratios));
      CHECK(baseline_wall[comparison] && compared_wall[comparison] &&
            baseline_gpu[comparison] && compared_gpu[comparison] &&
            wall_ratios[comparison] && gpu_ratios[comparison]);
   }

   for (int block = -warmup_pairs; block < pairs; block++) {
      const int first_comparison = block & 1;
      const int comparison_order[2] = {
         first_comparison,
         !first_comparison,
      };
      int query_comparison[8], query_is_compared[8];
      int query_count = 0;
      for (int c = 0; c < COMPARE_COUNT; c++) {
         const int comparison = comparison_order[c];
         const int compared_first = (block + comparison) & 1;
         const enum path first =
            compared_first ? compared_path[comparison] : PATH_BASELINE;
         const enum path second =
            compared_first ? PATH_BASELINE : compared_path[comparison];
         const enum path order[4] = {first, second, second, first};
         for (int i = 0; i < 4; i++) {
            query_comparison[query_count] = comparison;
            query_is_compared[query_count] = order[i] != PATH_BASELINE;
            query_count++;
         }
      }

      struct sample baseline_sums[COMPARE_COUNT] = {{0}};
      struct sample compared_sums[COMPARE_COUNT] = {{0}};
      // Mali is a tile-based deferred renderer. Complete each query's
      // framebuffer work before starting the next one so timer ownership
      // cannot cross path boundaries; the palindromic order handles devfreq.
      for (int i = 0; i < query_count; i++) {
         const int comparison = query_comparison[i];
         const enum path path = query_is_compared[i]
                                   ? compared_path[comparison]
                                   : PATH_BASELINE;
         const struct sample result =
            run_sample(path, programs, draws, usable_timer, begin_query,
                       end_query, get_query_result, queries[i]);
         struct sample *sum = query_is_compared[i]
                                 ? &compared_sums[comparison]
                                 : &baseline_sums[comparison];
         sum->wall_ms += result.wall_ms;
         sum->gpu_ms += result.gpu_ms;
      }

      if (block >= 0) {
         for (int comparison = 0; comparison < COMPARE_COUNT; comparison++) {
            baseline_wall[comparison][block] =
               baseline_sums[comparison].wall_ms * 0.5;
            compared_wall[comparison][block] =
               compared_sums[comparison].wall_ms * 0.5;
            baseline_gpu[comparison][block] =
               baseline_sums[comparison].gpu_ms * 0.5;
            compared_gpu[comparison][block] =
               compared_sums[comparison].gpu_ms * 0.5;
            wall_ratios[comparison][block] =
               compared_sums[comparison].wall_ms /
               baseline_sums[comparison].wall_ms;
            gpu_ratios[comparison][block] =
               usable_timer
                  ? compared_sums[comparison].gpu_ms /
                       baseline_sums[comparison].gpu_ms
                  : 0.0;
         }
         if (getenv("PERF_VERBOSE")) {
            printf("block=%d workaround_ratio=%.6f fragcoord_ratio=%.6f\n",
                   block, gpu_ratios[COMPARE_WORKAROUND][block],
                   gpu_ratios[COMPARE_FRAGCOORD][block]);
         }
      }
   }

   GLint disjoint = 0;
   if (usable_timer)
      glGetIntegerv(GL_GPU_DISJOINT_EXT, &disjoint);

   printf("size=%dx%d draws=%d blocks=%d warmup_blocks=%d fragments=%" PRIu64
          "\n",
          width, height, draws, pairs, warmup_pairs,
          (uint64_t)width * (uint64_t)height * (uint64_t)draws);
   printf("timer_query=%s disjoint=%d\n", usable_timer ? "yes" : "no",
          disjoint);

   const char *comparison_names[COMPARE_COUNT] = {
      "workaround",
      "fragcoord",
   };
   for (int comparison = 0; comparison < COMPARE_COUNT; comparison++) {
      const double baseline_median =
         median(usable_timer ? baseline_gpu[comparison]
                             : baseline_wall[comparison],
                pairs);
      const double compared_median =
         median(usable_timer ? compared_gpu[comparison]
                             : compared_wall[comparison],
                pairs);
      const double ratio =
         median(usable_timer ? gpu_ratios[comparison]
                             : wall_ratios[comparison],
                pairs);
      const double *ratios =
         usable_timer ? gpu_ratios[comparison] : wall_ratios[comparison];
      printf("%s_vs_baseline %s_baseline_median_ms=%.6f "
             "%s_median_ms=%.6f median_block_ratio=%.6f "
             "slowdown_pct=%.3f ratio_p10=%.6f ratio_p90=%.6f\n",
             comparison_names[comparison],
             usable_timer ? "gpu" : "wall", baseline_median,
             comparison_names[comparison], compared_median, ratio,
             (ratio - 1.0) * 100.0, percentile(ratios, pairs, 0.1),
             percentile(ratios, pairs, 0.9));
      if (usable_timer) {
         const double wall_baseline_median =
            median(baseline_wall[comparison], pairs);
         const double wall_compared_median =
            median(compared_wall[comparison], pairs);
         const double wall_ratio = median(wall_ratios[comparison], pairs);
         printf("%s_vs_baseline wall_baseline_median_ms=%.6f "
                "%s_median_ms=%.6f median_block_ratio=%.6f "
                "slowdown_pct=%.3f ratio_p10=%.6f ratio_p90=%.6f\n",
                comparison_names[comparison], wall_baseline_median,
                comparison_names[comparison], wall_compared_median,
                wall_ratio, (wall_ratio - 1.0) * 100.0,
                percentile(wall_ratios[comparison], pairs, 0.1),
                percentile(wall_ratios[comparison], pairs, 0.9));
      }
   }

   if (usable_timer)
      delete_queries(8, queries);
   for (int comparison = 0; comparison < COMPARE_COUNT; comparison++) {
      free(baseline_wall[comparison]);
      free(compared_wall[comparison]);
      free(baseline_gpu[comparison]);
      free(compared_gpu[comparison]);
      free(wall_ratios[comparison]);
      free(gpu_ratios[comparison]);
   }
   return 0;
}
