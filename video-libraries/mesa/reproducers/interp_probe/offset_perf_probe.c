// Minimal Mali blit-path benchmark: baseline vs zero polygon offset vs
// gl_FragCoord. Build and run:
//
//   cc -O2 -Wall -Wextra -Werror -o offset_perf_probe offset_perf_probe.c -lEGL -lGLESv2
//   ./offset_perf_probe [width height draws blocks warmup-blocks]
//
// The shaders explicitly use highp float/int coordinates and R32UI texels.
// Lock the GPU frequency first; see README.md. Each timed batch ends with
// glFinish() so deferred tile work stays inside the owning timer query.

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define GL_TIME_ELAPSED_EXT 0x88BF
#define GL_QUERY_RESULT_EXT 0x8866
#define GL_GPU_DISJOINT_EXT 0x8FBB

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

enum path {
   BASELINE,
   WORKAROUND,
   FRAGCOORD,
};

struct result {
   double baseline_ms;
   double test_ms;
   double ratio;
};

static const char *vertex_source =
   "#version 300 es\n"
   "precision highp float;\n"
   "precision highp int;\n"
   "uniform highp vec2 extent;\n"
   "out highp vec2 src_coord;\n"
   "void main() {\n"
   "  highp vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0,\n"
   "                      gl_VertexID == 2 ? 3.0 : -1.0);\n"
   "  src_coord = (p + 1.0) * 0.5 * extent;\n"
   "  gl_Position = vec4(p, 0.0, 1.0);\n"
   "}\n";

static const char *varying_source =
   "#version 300 es\n"
   "precision highp float;\n"
   "precision highp int;\n"
   "uniform highp usampler2D source_tex;\n"
   "in highp vec2 src_coord;\n"
   "layout(location = 0) out highp uint value;\n"
   "void main() {\n"
   "  value = texelFetch(source_tex, ivec2(src_coord), 0).r;\n"
   "}\n";

static const char *fragcoord_source =
   "#version 300 es\n"
   "precision highp float;\n"
   "precision highp int;\n"
   "uniform highp usampler2D source_tex;\n"
   "layout(location = 0) out highp uint value;\n"
   "void main() {\n"
   "  value = texelFetch(source_tex, ivec2(gl_FragCoord.xy), 0).r;\n"
   "}\n";

static GLuint programs[2];
static GLuint query;
static int draw_count;
static begin_query_fn begin_query;
static end_query_fn end_query;
static get_query_fn get_query;

static GLuint
compile(GLenum type, const char *source)
{
   GLuint shader = glCreateShader(type);
   glShaderSource(shader, 1, &source, NULL);
   glCompileShader(shader);

   GLint ok;
   glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
   if (!ok) {
      char log[2048];
      glGetShaderInfoLog(shader, sizeof(log), NULL, log);
      fprintf(stderr, "%s\n", log);
      exit(1);
   }
   return shader;
}

static GLuint
link_program(GLuint vertex, const char *fragment_source)
{
   GLuint program = glCreateProgram();
   glAttachShader(program, vertex);
   glAttachShader(program, compile(GL_FRAGMENT_SHADER, fragment_source));
   glLinkProgram(program);

   GLint ok;
   glGetProgramiv(program, GL_LINK_STATUS, &ok);
   CHECK(ok);
   return program;
}

static int
has_extension(const char *name)
{
   GLint count;
   glGetIntegerv(GL_NUM_EXTENSIONS, &count);
   for (GLint i = 0; i < count; i++) {
      const char *extension =
         (const char *)glGetStringi(GL_EXTENSIONS, (GLuint)i);
      if (extension && strcmp(extension, name) == 0)
         return 1;
   }
   return 0;
}

static double
run_batch(enum path path)
{
   glUseProgram(path == FRAGCOORD ? programs[1] : programs[0]);
   if (path == WORKAROUND) {
      glEnable(GL_POLYGON_OFFSET_FILL);
      glPolygonOffset(0.0f, 0.0f);
   } else {
      glDisable(GL_POLYGON_OFFSET_FILL);
   }

   glFinish();
   begin_query(GL_TIME_ELAPSED_EXT, query);
   for (int i = 0; i < draw_count; i++)
      glDrawArrays(GL_TRIANGLES, 0, 3);
   end_query(GL_TIME_ELAPSED_EXT);
   glFinish();

   GLuint64 nanoseconds;
   get_query(query, GL_QUERY_RESULT_EXT, &nanoseconds);
   CHECK(glGetError() == GL_NO_ERROR);
   return (double)nanoseconds / 1000000.0;
}

static struct result
compare(enum path test, int test_first)
{
   const enum path first = test_first ? test : BASELINE;
   const enum path second = test_first ? BASELINE : test;
   const enum path order[4] = {first, second, second, first};
   double baseline = 0.0;
   double tested = 0.0;

   for (int i = 0; i < 4; i++) {
      const double milliseconds = run_batch(order[i]);
      if (order[i] == BASELINE)
         baseline += milliseconds;
      else
         tested += milliseconds;
   }

   baseline *= 0.5;
   tested *= 0.5;
   return (struct result){
      .baseline_ms = baseline,
      .test_ms = tested,
      .ratio = tested / baseline,
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

static void
report(const char *name, const struct result *results, int count)
{
   double *baseline = malloc((size_t)count * sizeof(*baseline));
   double *tested = malloc((size_t)count * sizeof(*tested));
   double *ratios = malloc((size_t)count * sizeof(*ratios));
   CHECK(baseline && tested && ratios);

   for (int i = 0; i < count; i++) {
      baseline[i] = results[i].baseline_ms;
      tested[i] = results[i].test_ms;
      ratios[i] = results[i].ratio;
   }
   qsort(baseline, (size_t)count, sizeof(*baseline), compare_double);
   qsort(tested, (size_t)count, sizeof(*tested), compare_double);
   qsort(ratios, (size_t)count, sizeof(*ratios), compare_double);

   const double ratio = percentile(ratios, count, 0.5);
   printf("%s baseline_ms=%.6f test_ms=%.6f slowdown_pct=%.3f "
          "p10_pct=%.3f p90_pct=%.3f\n",
          name, percentile(baseline, count, 0.5),
          percentile(tested, count, 0.5), (ratio - 1.0) * 100.0,
          (percentile(ratios, count, 0.1) - 1.0) * 100.0,
          (percentile(ratios, count, 0.9) - 1.0) * 100.0);

   free(baseline);
   free(tested);
   free(ratios);
}

static int
positive_arg(const char *text, const char *program)
{
   char *end;
   long value = strtol(text, &end, 10);
   if (!text[0] || *end || value < 1 || value > (1 << 24)) {
      fprintf(stderr,
              "usage: %s [width height draws blocks warmup-blocks]\n",
              program);
      exit(1);
   }
   return (int)value;
}

int
main(int argc, char **argv)
{
   int width = 1024;
   int height = 1024;
   draw_count = 2048;
   int blocks = 30;
   int warmups = 4;
   int *arguments[] = {&width, &height, &draw_count, &blocks, &warmups};

   if (argc > 6) {
      fprintf(stderr,
              "usage: %s [width height draws blocks warmup-blocks]\n",
              argv[0]);
      return 1;
   }
   for (int i = 1; i < argc; i++)
      *arguments[i - 1] = positive_arg(argv[i], argv[0]);

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
   EGLint config_count;
   CHECK(eglChooseConfig(display, config_attributes, &config, 1,
                         &config_count) &&
         config_count);
   const EGLint context_attributes[] = {
      EGL_CONTEXT_CLIENT_VERSION, 3,
      EGL_NONE,
   };
   EGLContext context =
      eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
   CHECK(context != EGL_NO_CONTEXT);
   CHECK(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context));

   fprintf(stderr, "GL_RENDERER=%s\nGL_VERSION=%s\n",
           (const char *)glGetString(GL_RENDERER),
           (const char *)glGetString(GL_VERSION));
   CHECK(has_extension("GL_EXT_disjoint_timer_query"));

   gen_queries_fn gen_queries =
      (gen_queries_fn)eglGetProcAddress("glGenQueriesEXT");
   begin_query = (begin_query_fn)eglGetProcAddress("glBeginQueryEXT");
   end_query = (end_query_fn)eglGetProcAddress("glEndQueryEXT");
   get_query = (get_query_fn)eglGetProcAddress("glGetQueryObjectui64vEXT");
   CHECK(gen_queries && begin_query && end_query && get_query);
   gen_queries(1, &query);

   GLint max_size;
   glGetIntegerv(GL_MAX_TEXTURE_SIZE, &max_size);
   CHECK(width <= max_size && height <= max_size);

   const GLuint vertex = compile(GL_VERTEX_SHADER, vertex_source);
   programs[0] = link_program(vertex, varying_source);
   programs[1] = link_program(vertex, fragcoord_source);
   for (int i = 0; i < 2; i++) {
      glUseProgram(programs[i]);
      glUniform2f(glGetUniformLocation(programs[i], "extent"),
                  (float)width, (float)height);
      glUniform1i(glGetUniformLocation(programs[i], "source_tex"), 0);
   }

   GLuint textures[2];
   glGenTextures(2, textures);
   for (int i = 0; i < 2; i++) {
      glBindTexture(GL_TEXTURE_2D, textures[i]);
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_R32UI, width, height);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
   }
   glActiveTexture(GL_TEXTURE0);
   glBindTexture(GL_TEXTURE_2D, textures[0]);

   GLuint framebuffer;
   glGenFramebuffers(1, &framebuffer);
   glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
   glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                          textures[1], 0);
   CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
   glViewport(0, 0, width, height);

   struct result *workaround =
      malloc((size_t)blocks * sizeof(*workaround));
   struct result *fragcoord =
      malloc((size_t)blocks * sizeof(*fragcoord));
   CHECK(workaround && fragcoord);

   for (int run = 0; run < warmups + blocks; run++) {
      struct result workaround_result;
      struct result fragcoord_result;
      if (run & 1) {
         fragcoord_result = compare(FRAGCOORD, run & 2);
         workaround_result = compare(WORKAROUND, !(run & 2));
      } else {
         workaround_result = compare(WORKAROUND, run & 2);
         fragcoord_result = compare(FRAGCOORD, !(run & 2));
      }
      if (run >= warmups) {
         workaround[run - warmups] = workaround_result;
         fragcoord[run - warmups] = fragcoord_result;
      }
   }

   GLint disjoint;
   glGetIntegerv(GL_GPU_DISJOINT_EXT, &disjoint);
   CHECK(!disjoint);

   printf("size=%dx%d draws=%d blocks=%d warmups=%d\n",
          width, height, draw_count, blocks, warmups);
   report("workaround", workaround, blocks);
   report("fragcoord", fragcoord, blocks);
   return 0;
}
