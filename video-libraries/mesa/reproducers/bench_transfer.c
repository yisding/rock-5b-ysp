// Microbenchmark Panfrost texture-transfer readback paths.
//
// Creates an RG32UI texture, attaches it to an FBO, and repeatedly reads it as
// RGBA32UI. With Panfrost advertising BLIT|COMPUTE, the default state-tracker
// path uses the sampled blit, while MESA_COMPUTE_PBO=1 forces the compute path.

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>
#include <gbm.h>

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define CHECK_EGL(x)                                                          \
   do {                                                                       \
      if (!(x)) {                                                             \
         fprintf(stderr, "EGL fail line %d: 0x%x\n", __LINE__, eglGetError()); \
         exit(1);                                                             \
      }                                                                       \
   } while (0)

#define LOAD(name)                                                            \
   do {                                                                       \
      p_##name = (void *)eglGetProcAddress(#name);                            \
      if (!p_##name) {                                                        \
         fprintf(stderr, "missing GL func %s\n", #name);                     \
         exit(1);                                                             \
      }                                                                       \
   } while (0)

static const GLubyte *(*p_glGetString)(GLenum);
static GLenum (*p_glGetError)(void);
static void (*p_glGenTextures)(GLsizei, GLuint *);
static void (*p_glBindTexture)(GLenum, GLuint);
static void (*p_glTexParameteri)(GLenum, GLenum, GLint);
static void (*p_glTexImage2D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint,
                              GLenum, GLenum, const void *);
static void (*p_glGenFramebuffers)(GLsizei, GLuint *);
static void (*p_glBindFramebuffer)(GLenum, GLuint);
static void (*p_glFramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
static GLenum (*p_glCheckFramebufferStatus)(GLenum);
static void (*p_glReadBuffer)(GLenum);
static void (*p_glReadPixels)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum,
                              void *);
static void (*p_glPixelStorei)(GLenum, GLint);
static void (*p_glFinish)(void);

static void
load_gl(void)
{
   LOAD(glGetString);
   LOAD(glGetError);
   LOAD(glGenTextures);
   LOAD(glBindTexture);
   LOAD(glTexParameteri);
   LOAD(glTexImage2D);
   LOAD(glGenFramebuffers);
   LOAD(glBindFramebuffer);
   LOAD(glFramebufferTexture2D);
   LOAD(glCheckFramebufferStatus);
   LOAD(glReadBuffer);
   LOAD(glReadPixels);
   LOAD(glPixelStorei);
   LOAD(glFinish);
}

static double
now_ms(void)
{
   struct timespec ts;
   clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
   return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static int
cmp_double(const void *a, const void *b)
{
   double da = *(const double *)a;
   double db = *(const double *)b;
   return (da > db) - (da < db);
}

int
main(int argc, char **argv)
{
   int width = argc > 1 ? atoi(argv[1]) : 16307;
   int height = argc > 2 ? atoi(argv[2]) : 1;
   int iterations = argc > 3 ? atoi(argv[3]) : 80;
   int warmup = argc > 4 ? atoi(argv[4]) : 10;
   const char *node = getenv("REPRO_NODE");
   if (!node)
      node = "/dev/dri/renderD128";

   if (width <= 0 || height <= 0 || iterations <= 0 || warmup < 0) {
      fprintf(stderr, "usage: %s [width height iterations warmup]\n", argv[0]);
      return 1;
   }

   int drmfd = open(node, O_RDWR | O_CLOEXEC);
   if (drmfd < 0) {
      perror(node);
      return 1;
   }

   struct gbm_device *gbm = gbm_create_device(drmfd);
   CHECK_EGL(gbm != NULL);

   PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress(
         "eglGetPlatformDisplayEXT");
   CHECK_EGL(get_platform_display != NULL);
   EGLDisplay dpy = get_platform_display(EGL_PLATFORM_GBM_KHR, gbm, NULL);
   CHECK_EGL(dpy != EGL_NO_DISPLAY);

   EGLint major, minor;
   CHECK_EGL(eglInitialize(dpy, &major, &minor));
   CHECK_EGL(eglBindAPI(EGL_OPENGL_ES_API));

   EGLint cfg_attribs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE};
   EGLConfig config;
   EGLint num_config;
   CHECK_EGL(eglChooseConfig(dpy, cfg_attribs, &config, 1, &num_config) &&
             num_config > 0);

   EGLint ctx_attribs[] = {EGL_CONTEXT_MAJOR_VERSION, 3,
                           EGL_CONTEXT_MINOR_VERSION, 1, EGL_NONE};
   EGLContext ctx = eglCreateContext(dpy, config, EGL_NO_CONTEXT, ctx_attribs);
   CHECK_EGL(ctx != EGL_NO_CONTEXT);
   CHECK_EGL(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx));

   load_gl();
   fprintf(stderr, "GL_RENDERER=%s  GL_VERSION=%s\n",
           (const char *)p_glGetString(GL_RENDERER),
           (const char *)p_glGetString(GL_VERSION));

   size_t pixels = (size_t)width * (size_t)height;
   uint32_t *src = malloc(pixels * 2 * sizeof(uint32_t));
   uint32_t *dst = malloc(pixels * 4 * sizeof(uint32_t));
   double *times = malloc((size_t)iterations * sizeof(double));
   if (!src || !dst || !times) {
      fprintf(stderr, "allocation failed\n");
      return 1;
   }

   for (size_t i = 0; i < pixels; ++i) {
      src[i * 2 + 0] = (uint32_t)i;
      src[i * 2 + 1] = (uint32_t)i;
   }

   GLuint tex;
   p_glGenTextures(1, &tex);
   p_glBindTexture(GL_TEXTURE_2D, tex);
   p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
   p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
   p_glTexImage2D(GL_TEXTURE_2D, 0, GL_RG32UI, width, height, 0,
                  GL_RG_INTEGER, GL_UNSIGNED_INT, src);

   GLuint fbo;
   p_glGenFramebuffers(1, &fbo);
   p_glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   p_glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                            tex, 0);
   if (p_glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
      fprintf(stderr, "FBO incomplete\n");
      return 1;
   }

   p_glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
   p_glReadBuffer(GL_COLOR_ATTACHMENT0);
   p_glPixelStorei(GL_PACK_ALIGNMENT, 4);
   p_glFinish();

   long mismatches = 0;
   int first_mismatch = -1;

   for (int i = 0; i < warmup + iterations; ++i) {
      memset(dst, 0xcd, pixels * 4 * sizeof(uint32_t));
      p_glFinish();
      double start = now_ms();
      p_glReadPixels(0, 0, width, height, GL_RGBA_INTEGER, GL_UNSIGNED_INT,
                     dst);
      double end = now_ms();

      GLenum err = p_glGetError();
      if (err != GL_NO_ERROR) {
         fprintf(stderr, "glReadPixels error 0x%x\n", err);
         return 1;
      }

      if (i == warmup) {
         for (size_t p = 0; p < pixels; ++p) {
            if (dst[p * 4] != (uint32_t)p) {
               if (first_mismatch < 0)
                  first_mismatch = (int)p;
               ++mismatches;
            }
         }
      }

      if (i >= warmup)
         times[i - warmup] = end - start;
   }

   double sum = 0.0, min = times[0], max = times[0];
   for (int i = 0; i < iterations; ++i) {
      sum += times[i];
      if (times[i] < min)
         min = times[i];
      if (times[i] > max)
         max = times[i];
   }
   qsort(times, (size_t)iterations, sizeof(double), cmp_double);
   double median = iterations & 1 ? times[iterations / 2]
                                 : (times[iterations / 2 - 1] +
                                    times[iterations / 2]) /
                                      2.0;
   size_t dst_bytes = pixels * 4 * sizeof(uint32_t);
   double mib = (double)dst_bytes / (1024.0 * 1024.0);

   printf("size=%dx%d pixels=%zu dst_bytes=%zu iterations=%d warmup=%d\n",
          width, height, pixels, dst_bytes, iterations, warmup);
   printf("mismatches=%ld/%zu first_mismatch=%d\n", mismatches, pixels,
          first_mismatch);
   printf("readpixels_ms min=%.4f median=%.4f mean=%.4f max=%.4f\n", min,
          median, sum / iterations, max);
   printf("throughput_mib_s median=%.2f mean=%.2f\n", mib / (median / 1000.0),
          mib / ((sum / iterations) / 1000.0));

   free(src);
   free(dst);
   free(times);
   eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
   eglTerminate(dpy);
   close(drmfd);
   return 0;
}
