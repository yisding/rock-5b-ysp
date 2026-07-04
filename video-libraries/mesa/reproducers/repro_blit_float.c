// FLOAT variant of repro_blit — the counter-example that disqualifies the
// integer-only state-tracker fallback (branch
// panfrost-transfer-targeted-fallback): the 2^-10 coordinate drift affects
// every wide sampled TXF blit regardless of format, and this readback is
// format-changing but NOT pure-integer, so the fallback's gate does not
// catch it.
// Builds an R32G32_FLOAT texture with source[i] = {i, i}, attaches it to an
// FBO, and does glReadPixels(GL_RGBA, GL_FLOAT) (valid for float color
// buffers under EXT_color_buffer_float), which forces the st_ReadPixels
// staging blit (RG32F -> RGBA32F expansion via u_blitter TXF). Any spatial
// shift shows up as output[i].r != (float)i.
// Observed 2026-07-01 on Mali-G610 at W=16307:
//   targeted-fallback build git-6a29250358: 15672/16307 corrupt (96.1%),
//     first mismatch at x=623 — the exact original bug signature.
//   fragcoord build git-2f6e8a6afc:         0/16307.
//
// GL entrypoints are loaded via eglGetProcAddress to bypass glvnd and guarantee
// we hit the Mesa driver bound by Mesa's EGL. Link only against Mesa libEGL+gbm.

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>
#include <gbm.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK_EGL(x) do { if (!(x)) { fprintf(stderr, "EGL fail line %d: 0x%x\n", __LINE__, eglGetError()); exit(1);} } while(0)

// GL function pointers loaded via eglGetProcAddress.
static const GLubyte* (*p_glGetString)(GLenum);
static GLenum (*p_glGetError)(void);
static void (*p_glGenTextures)(GLsizei, GLuint*);
static void (*p_glBindTexture)(GLenum, GLuint);
static void (*p_glTexParameteri)(GLenum, GLenum, GLint);
static void (*p_glTexImage2D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void*);
static void (*p_glGenFramebuffers)(GLsizei, GLuint*);
static void (*p_glBindFramebuffer)(GLenum, GLuint);
static void (*p_glFramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
static GLenum (*p_glCheckFramebufferStatus)(GLenum);
static void (*p_glReadBuffer)(GLenum);
static void (*p_glReadPixels)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void*);
static void (*p_glPixelStorei)(GLenum, GLint);
static void (*p_glFinish)(void);

#define LOAD(name) do { p_##name = (void*)eglGetProcAddress(#name); \
   if (!p_##name) { fprintf(stderr, "missing GL func %s\n", #name); exit(1);} } while(0)

static void load_gl(void) {
   LOAD(glGetString); LOAD(glGetError); LOAD(glGenTextures); LOAD(glBindTexture);
   LOAD(glTexParameteri); LOAD(glTexImage2D); LOAD(glGenFramebuffers);
   LOAD(glBindFramebuffer); LOAD(glFramebufferTexture2D); LOAD(glCheckFramebufferStatus);
   LOAD(glReadBuffer); LOAD(glReadPixels); LOAD(glPixelStorei); LOAD(glFinish);
}
static void check_gl(const char *where) {
   GLenum e = p_glGetError();
   if (e != GL_NO_ERROR) fprintf(stderr, "GL error 0x%x at %s\n", e, where);
}

int main(int argc, char **argv) {
   int W = (argc > 1) ? atoi(argv[1]) : 16307;
   int H = 1;

   const char *node = getenv("REPRO_NODE");
   if (!node) node = "/dev/dri/renderD128";
   int drmfd = open(node, O_RDWR | O_CLOEXEC);
   if (drmfd < 0) { fprintf(stderr, "cannot open %s\n", node); return 1; }
   struct gbm_device *gbm = gbm_create_device(drmfd);
   CHECK_EGL(gbm != NULL);

   PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplay =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
   CHECK_EGL(getPlatformDisplay != NULL);
   EGLDisplay dpy = getPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
   CHECK_EGL(dpy != EGL_NO_DISPLAY);

   EGLint major, minor;
   CHECK_EGL(eglInitialize(dpy, &major, &minor));
   CHECK_EGL(eglBindAPI(EGL_OPENGL_ES_API));

   EGLint cfg_attribs[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE };
   EGLConfig config; EGLint num_config;
   CHECK_EGL(eglChooseConfig(dpy, cfg_attribs, &config, 1, &num_config) && num_config > 0);

   EGLint ctx_attribs[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 1, EGL_NONE };
   EGLContext ctx = eglCreateContext(dpy, config, EGL_NO_CONTEXT, ctx_attribs);
   CHECK_EGL(ctx != EGL_NO_CONTEXT);
   CHECK_EGL(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx));

   load_gl();
   fprintf(stderr, "GL_RENDERER=%s  GL_VERSION=%s\n",
           (const char*)p_glGetString(GL_RENDERER), (const char*)p_glGetString(GL_VERSION));

   float *src = malloc((size_t)W * H * 2 * sizeof(float));
   for (int i = 0; i < W * H; i++) { src[i*2+0] = (float)i; src[i*2+1] = (float)i; }

   GLuint tex;
   p_glGenTextures(1, &tex);
   p_glBindTexture(GL_TEXTURE_2D, tex);
   p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
   p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
   p_glTexImage2D(GL_TEXTURE_2D, 0, GL_RG32F, W, H, 0, GL_RG, GL_FLOAT, src);
   check_gl("texImage");

   GLuint fbo;
   p_glGenFramebuffers(1, &fbo);
   p_glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   p_glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
   GLenum fbstatus = p_glCheckFramebufferStatus(GL_FRAMEBUFFER);
   if (fbstatus != GL_FRAMEBUFFER_COMPLETE) { fprintf(stderr, "FBO incomplete 0x%x\n", fbstatus); return 1; }

   p_glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
   p_glReadBuffer(GL_COLOR_ATTACHMENT0);
   p_glFinish();

   float *dst = malloc((size_t)W * H * 4 * sizeof(float));
   memset(dst, 0xCD, (size_t)W * H * 4 * sizeof(unsigned));
   p_glPixelStorei(GL_PACK_ALIGNMENT, 4);
   p_glReadPixels(0, 0, W, H, GL_RGBA, GL_FLOAT, dst);
   check_gl("readpixels");

   long mismatches = 0;
   int lo = -4, hi = 4; long hist[9] = {0}; long other = 0, zeros = 0;
   int first_mismatch = -1;
   for (int i = 0; i < W * H; i++) {
      long r = (long)dst[i*4+0];
      if (r != (long)i || dst[i*4+0] != (float)i) { mismatches++; if (first_mismatch < 0) first_mismatch = i; }
      if (r == 0 && i != 0) zeros++;
      long shift = (long)r - (long)i;
      if (shift >= lo && shift <= hi) hist[shift - lo]++; else other++;
   }
   printf("W=%d  mismatches=%ld / %d  (%.1f%%)  first_mismatch=%d  zeros(nonhead)=%ld\n",
          W, mismatches, W*H, 100.0*mismatches/(W*H), first_mismatch, zeros);
   printf("shift histogram (sampled_texel - i):\n");
   for (int s = lo; s <= hi; s++) printf("   shift %+d : %ld\n", s, hist[s - lo]);
   printf("   other    : %ld\n", other);
   printf("i : sampled_r : shift : implied_scale(r/i)\n");
   for (int i = 256; i < W; i *= 2) {
      long r = dst[i*4+0];
      printf("   i=%-7d r=%-7ld shift=%+ld  scale=%.6f\n", i, r, r - i, (double)r / i);
   }
   { int i = W-1; long r = dst[i*4+0];
     printf("   i=%-7d r=%-7ld shift=%+ld  scale=%.6f\n", i, r, r - i, (double)r / i); }

   free(src); free(dst);
   eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
   eglTerminate(dpy);
   return mismatches ? 2 : 0;
}
