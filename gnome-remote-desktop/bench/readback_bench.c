// readback_bench.c — measure the GPU→CPU readback cost that dominates GRD's
// software-RFX path on RK3588 (Mali-G610 / panfrost).
//
// This is the harness behind the numbers in ../docs/baseline.md. It reproduces the
// exact operation GRD performs once per frame in its EGL thread
// (grd-egl-thread.c:963, `glReadPixels(0,0,w,h, GL_BGRA, GL_UNSIGNED_BYTE, dst)`)
// and times it three ways:
//
//   1. sync glReadPixels into a client pointer   — what GRD does today
//   2. the same, GL_RGBA instead of GL_BGRA      — isolates the B<->R swizzle
//   3. async: glReadPixels into a PBO + fence + map + memcpy, with per-stage
//      timing (t_issue / t_fence / t_map / t_copy) — the async-PBO route
//
// It uses a *surfaceless* desktop-GL context (EGL_MESA_platform_surfaceless),
// so it touches neither mutter nor any RDP session — safe to run on the live
// box. It reads a plain RGBA8 FBO, NOT mutter's real AFBC/tiled dma-buf, so the
// absolute numbers are a lower bound on the real path (see docs/baseline.md, "What
// this does and doesn't measure").
//
// Build:  cc -O2 -o readback_bench readback_bench.c -lEGL -lGL
// Run:    ./readback_bench [width] [height] [iterations]
//         MESA_COMPUTE_PBO=1 ./readback_bench    # route detile+swizzle to GPU
//
// The env var is the whole point of the experiment -- see docs/baseline.md "levers".

#define _POSIX_C_SOURCE 199309L
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>
#include <GL/glext.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// GL entry points we resolve via eglGetProcAddress (core in GL 3.x, but we
// avoid an extension loader to keep this a single self-contained file).
static void (*p_GenBuffers)(GLsizei, GLuint *);
static void (*p_BindBuffer)(GLenum, GLuint);
static void (*p_BufferData)(GLenum, GLsizeiptr, const void *, GLenum);
static void *(*p_MapBufferRange)(GLenum, GLintptr, GLsizeiptr, GLbitfield);
static GLboolean (*p_UnmapBuffer)(GLenum);
static void (*p_GenFramebuffers)(GLsizei, GLuint *);
static void (*p_BindFramebuffer)(GLenum, GLuint);
static void (*p_FramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
static GLsync (*p_FenceSync)(GLenum, GLbitfield);
static GLenum (*p_ClientWaitSync)(GLsync, GLbitfield, GLuint64);
static void (*p_DeleteSync)(GLsync);

static void *resolve(const char *name)
{
  void *p = (void *) eglGetProcAddress (name);
  if (!p) { fprintf (stderr, "missing GL entry point: %s\n", name); exit (1); }
  return p;
}

static double now_ms (void)
{
  struct timespec ts;
  clock_gettime (CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

// median of an array of doubles (sorts in place)
static int cmp_d (const void *a, const void *b)
{
  double x = *(const double *) a, y = *(const double *) b;
  return (x > y) - (x < y);
}
static double median (double *v, int n)
{
  qsort (v, n, sizeof *v, cmp_d);
  return n & 1 ? v[n / 2] : 0.5 * (v[n / 2 - 1] + v[n / 2]);
}

int main (int argc, char **argv)
{
  int w    = argc > 1 ? atoi (argv[1]) : 1920;
  int h    = argc > 2 ? atoi (argv[2]) : 1080;
  int iter = argc > 3 ? atoi (argv[3]) : 60;
  size_t bytes = (size_t) w * h * 4;

  // --- surfaceless EGL + desktop-GL context (matches GRD's GL 3.1 path) ------
  PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplay =
    (void *) eglGetProcAddress ("eglGetPlatformDisplayEXT");
  EGLDisplay dpy = getPlatformDisplay
    ? getPlatformDisplay (EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL)
    : eglGetDisplay (EGL_DEFAULT_DISPLAY);
  if (dpy == EGL_NO_DISPLAY || !eglInitialize (dpy, NULL, NULL)) {
    fprintf (stderr, "eglInitialize failed — need EGL_MESA_platform_surfaceless\n");
    return 1;
  }
  eglBindAPI (EGL_OPENGL_API);
  EGLint cfg_attrs[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                         EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_NONE };
  EGLConfig cfg; EGLint n;
  eglChooseConfig (dpy, cfg_attrs, &cfg, 1, &n);
  EGLint ctx_attrs[] = { EGL_CONTEXT_MAJOR_VERSION, 3,
                         EGL_CONTEXT_MINOR_VERSION, 1, EGL_NONE };
  EGLContext ctx = eglCreateContext (dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
  if (ctx == EGL_NO_CONTEXT) { fprintf (stderr, "no GL 3.1 context\n"); return 1; }
  eglMakeCurrent (dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx);

  p_GenBuffers        = resolve ("glGenBuffers");
  p_BindBuffer        = resolve ("glBindBuffer");
  p_BufferData        = resolve ("glBufferData");
  p_MapBufferRange    = resolve ("glMapBufferRange");
  p_UnmapBuffer       = resolve ("glUnmapBuffer");
  p_GenFramebuffers   = resolve ("glGenFramebuffers");
  p_BindFramebuffer   = resolve ("glBindFramebuffer");
  p_FramebufferTexture2D = resolve ("glFramebufferTexture2D");
  p_FenceSync         = resolve ("glFenceSync");
  p_ClientWaitSync    = resolve ("glClientWaitSync");
  p_DeleteSync        = resolve ("glDeleteSync");

  // --- a colour texture + FBO to read back from -----------------------------
  GLuint tex; glGenTextures (1, &tex);
  glBindTexture (GL_TEXTURE_2D, tex);
  glTexImage2D (GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA,
                GL_UNSIGNED_BYTE, NULL);
  GLuint fbo; p_GenFramebuffers (1, &fbo);
  p_BindFramebuffer (GL_FRAMEBUFFER, fbo);
  p_FramebufferTexture2D (GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                          GL_TEXTURE_2D, tex, 0);
  glViewport (0, 0, w, h);

  unsigned char *dst = malloc (bytes);
  GLuint pbo; p_GenBuffers (1, &pbo);
  p_BindBuffer (GL_PIXEL_PACK_BUFFER, pbo);
  p_BufferData (GL_PIXEL_PACK_BUFFER, bytes, NULL, GL_STREAM_READ);
  p_BindBuffer (GL_PIXEL_PACK_BUFFER, 0);

  printf ("readback_bench  %dx%d  %zu KB/frame  %d iters  MESA_COMPUTE_PBO=%s\n",
          w, h, bytes / 1024, iter,
          getenv ("MESA_COMPUTE_PBO") ? getenv ("MESA_COMPUTE_PBO") : "(unset)");

  double *t_bgra = malloc (iter * sizeof (double));
  double *t_rgba = malloc (iter * sizeof (double));
  double *a_issue = malloc (iter * sizeof (double));
  double *a_fence = malloc (iter * sizeof (double));
  double *a_map   = malloc (iter * sizeof (double));
  double *a_copy  = malloc (iter * sizeof (double));

  for (int i = 0; i < iter; i++) {
    // dirty the FBO each frame so the driver can't elide work
    glClearColor ((i & 7) / 8.0f, 0.3f, 0.6f, 1.0f);
    glClear (GL_COLOR_BUFFER_BIT);

    // (1) sync BGRA — exactly grd-egl-thread.c:963
    glFinish ();
    double t0 = now_ms ();
    glReadPixels (0, 0, w, h, GL_BGRA, GL_UNSIGNED_BYTE, dst);
    t_bgra[i] = now_ms () - t0;

    // (2) sync RGBA — same but no B<->R swizzle
    glClear (GL_COLOR_BUFFER_BIT);
    glFinish ();
    t0 = now_ms ();
    glReadPixels (0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, dst);
    t_rgba[i] = now_ms () - t0;

    // (3) async: issue into PBO, fence, wait, map, copy out
    glClear (GL_COLOR_BUFFER_BIT);
    glFinish ();
    p_BindBuffer (GL_PIXEL_PACK_BUFFER, pbo);
    t0 = now_ms ();
    glReadPixels (0, 0, w, h, GL_BGRA, GL_UNSIGNED_BYTE, 0); // into PBO
    GLsync fence = p_FenceSync (GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    glFlush ();
    a_issue[i] = now_ms () - t0;

    t0 = now_ms ();
    p_ClientWaitSync (fence, GL_SYNC_FLUSH_COMMANDS_BIT, 1000ull * 1000 * 1000);
    a_fence[i] = now_ms () - t0;
    p_DeleteSync (fence);

    t0 = now_ms ();
    void *m = p_MapBufferRange (GL_PIXEL_PACK_BUFFER, 0, bytes, GL_MAP_READ_BIT);
    a_map[i] = now_ms () - t0;

    t0 = now_ms ();
    if (m) memcpy (dst, m, bytes);
    a_copy[i] = now_ms () - t0;
    p_UnmapBuffer (GL_PIXEL_PACK_BUFFER);
    p_BindBuffer (GL_PIXEL_PACK_BUFFER, 0);
  }

  printf ("\n  sync glReadPixels BGRA : %6.2f ms   (grd today)\n",
          median (t_bgra, iter));
  printf (  "  sync glReadPixels RGBA : %6.2f ms   (delta = B<->R swizzle)\n",
          median (t_rgba, iter));
  printf (  "\n  async PBO+fence total  : %6.2f ms\n",
          median (a_issue, iter) + median (a_fence, iter) +
          median (a_map, iter) + median (a_copy, iter));
  printf (  "    t_issue (readpixels) : %6.2f ms  %s\n", median (a_issue, iter),
          median (a_issue, iter) > 5 ? "<- CPU detile happens HERE (no GPU offload)"
                                     : "<- cheap: work deferred to GPU");
  printf (  "    t_fence (GPU wait)   : %6.2f ms  %s\n", median (a_fence, iter),
          median (a_fence, iter) > 1 ? "<- real GPU work overlapped here"
                                     : "<- ~0: nothing ran on the GPU");
  printf (  "    t_map                : %6.2f ms\n", median (a_map, iter));
  printf (  "    t_copy (memcpy out)  : %6.2f ms\n", median (a_copy, iter));

  eglMakeCurrent (dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  eglTerminate (dpy);
  return 0;
}
