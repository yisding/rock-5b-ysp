// RK3588 / proprietary ARM Mali userspace variant of tiny_interp_probe.c, X11
// client edition.
//
// This is the *safe* companion to tiny_interp_probe_arm_blob.c. The shader,
// draw, R32UI readback, and CPU checker are byte-for-byte identical; only the
// EGL display/context setup differs. The GBM variant is unusable on the Radxa
// 5.10 vendor kernel because libmali's GBM/EGL bring-up issues the legacy
// DRM_IOCTL_SET_VERSION on the rockchip-drm primary node, which NULL-derefs the
// kernel (Oops at drm_setversion+0x80) and wedges DRM until reboot -- see
// findings/2026-07-08-arm-mali-blob-gbm-setversion-kernel-oops.md.
//
// The installed blob is the x11-gbm variant and advertises EGL_KHR_platform_x11
// / EGL_EXT_platform_x11 plus eglCreatePbufferSurface. Driving it as a client of
// a *running X server* avoids SET_VERSION entirely: the X server already owns
// DRM master, so the libmali client authenticates through DRI2 rather than
// re-versioning/re-mastering the primary node. We only need an EGL context that
// can be made current; the actual test still renders into an API-created
// GL_R32UI framebuffer object, so a throwaway 1x1 pbuffer surface is enough.
//
// Build from this directory (link libmali directly -- the .../mali libEGL/
// libGLESv2 stubs export zero symbols -- plus libX11 for XOpenDisplay):
//        cc -O2 -o tiny_interp_probe_arm_blob_x11 tiny_interp_probe_arm_blob_x11.c -lmali -lX11 -lm
// Run (needs a reachable X server; set DISPLAY and, over SSH, an XAUTHORITY that
// grants access -- e.g. DISPLAY=:0):
//        DISPLAY=:0 ./tiny_interp_probe_arm_blob_x11 8192 fragcoord
//        DISPLAY=:0 ./tiny_interp_probe_arm_blob_x11 12288 varying
//
// This program does NOT open any DRM node itself and issues no SET_VERSION. It
// still requires that the interpolation number be trusted only when the stderr
// GL_RENDERER names Mali and the `fragcoord` control passes.
//
// Exits 0 when every pixel satisfies floor(v) == x, 2 when any pixel fails,
// 1 on usage, X-connection, or EGL/GL setup errors.

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <X11/Xlib.h>
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

static const char *fs_varying =
   "#version 300 es\n"
   "in highp float v;\n"
   "out highp uint bits;\n"
   "void main() { bits = floatBitsToUint(v); }\n";

static const char *fs_fragcoord =
   "#version 300 es\n"
   "out highp uint bits;\n"
   "void main() { bits = floatBitsToUint(gl_FragCoord.x); }\n";

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

int
main(int argc, char **argv)
{
   int width = 12288;
   const char *mode = "varying";

   if (argc > 1) {
      char *end;
      long w = strtol(argv[1], &end, 10);
      if (*argv[1] == '\0' || *end != '\0' || w < 1 || w > (1 << 23)) {
         fprintf(stderr, "usage: %s [width] [varying|fragcoord]\n", argv[0]);
         return 1;
      }
      width = (int)w;
   }

   if (argc > 2) {
      mode = argv[2];
      if (strcmp(mode, "varying") != 0 && strcmp(mode, "fragcoord") != 0) {
         fprintf(stderr, "usage: %s [width] [varying|fragcoord]\n", argv[0]);
         return 1;
      }
   }

   int use_fragcoord = strcmp(mode, "fragcoord") == 0;

   // Connect to the running X server. libmali authenticates as a DRI2 client of
   // this server, which already holds DRM master -- so no SET_VERSION and no
   // kernel Oops. If this fails there is no X server reachable (wrong/empty
   // DISPLAY, or missing X authority over SSH).
   Display *xdpy = XOpenDisplay(NULL);
   if (!xdpy) {
      const char *d = getenv("DISPLAY");
      fprintf(stderr,
              "cannot open X display '%s': no reachable X server.\n"
              "  This variant renders through libmali as a client of a running\n"
              "  X server (that is what avoids the SET_VERSION kernel Oops). Set\n"
              "  DISPLAY to the active server (e.g. DISPLAY=:0) and make sure your\n"
              "  user is authorized (XAUTHORITY / `xhost`). Do NOT fall back to the\n"
              "  GBM variant on this kernel -- it crashes the box.\n",
              d ? d : "(unset)");
      return 1;
   }

   PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress(
         "eglGetPlatformDisplayEXT");

   EGLDisplay dpy = EGL_NO_DISPLAY;
   if (get_platform_display)
      dpy = get_platform_display(EGL_PLATFORM_X11_KHR, xdpy, NULL);
   if (dpy == EGL_NO_DISPLAY)
      dpy = eglGetDisplay((EGLNativeDisplayType)xdpy);
   CHECK(dpy != EGL_NO_DISPLAY);
   CHECK(eglInitialize(dpy, NULL, NULL));
   CHECK(eglBindAPI(EGL_OPENGL_ES_API));

   EGLint cfg_attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                         EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE};
   EGLConfig cfg;
   EGLint cfg_count = 0;
   CHECK(eglChooseConfig(dpy, cfg_attrs, &cfg, 1, &cfg_count) && cfg_count);

   EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
   EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
   CHECK(ctx != EGL_NO_CONTEXT);

   // A 1x1 pbuffer is only a place to make the context current; the test renders
   // into the GL_R32UI FBO below, exactly as the GBM/Mesa variants do.
   EGLint pbuf_attrs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
   EGLSurface pbuf = eglCreatePbufferSurface(dpy, cfg, pbuf_attrs);
   CHECK(pbuf != EGL_NO_SURFACE);
   CHECK(eglMakeCurrent(dpy, pbuf, pbuf, ctx));

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

   GLuint prog = glCreateProgram();
   glAttachShader(prog, compile(GL_VERTEX_SHADER, vs_src));
   glAttachShader(prog, compile(GL_FRAGMENT_SHADER,
                                use_fragcoord ? fs_fragcoord : fs_varying));
   glLinkProgram(prog);

   GLint ok = 0;
   glGetProgramiv(prog, GL_LINK_STATUS, &ok);
   CHECK(ok);
   glUseProgram(prog);
   glUniform1f(glGetUniformLocation(prog, "width"), (float)width);

   GLuint tex, fbo;
   glGenTextures(1, &tex);
   glBindTexture(GL_TEXTURE_2D, tex);
   glTexStorage2D(GL_TEXTURE_2D, 1, GL_R32UI, width, 1);

   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                          tex, 0);
   CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
   glViewport(0, 0, width, 1);

   glDrawArrays(GL_TRIANGLES, 0, 3);

   // Format-matching readback: R32UI read as RED_INTEGER moves raw bits with
   // no conversion. (Not the ES-mandated RGBA_INTEGER combo, but supported
   // here and error-checked below.)
   uint32_t *bits = malloc((size_t)width * sizeof(*bits));
   CHECK(bits);
   glReadPixels(0, 0, width, 1, GL_RED_INTEGER, GL_UNSIGNED_INT, bits);
   CHECK(glGetError() == GL_NO_ERROR);

   long bad = 0;
   int first_bad = -1;
   for (int x = 0; x < width; x++) {
      float v;
      memcpy(&v, &bits[x], sizeof(v));
      if ((long)floorf(v) != x) {
         if (first_bad < 0)
            first_bad = x;
         bad++;
      }
   }

   float last;
   memcpy(&last, &bits[width - 1], sizeof(last));
   double ideal = (double)width - 0.5;
   double rel_err = (ideal - (double)last) / ideal;

   printf("mode=%s width=%d: floor(v) != x at %ld of %d pixels "
          "(first at x=%d)\n",
          mode, width, bad, width, first_bad);
   printf("last pixel x=%d: v=%.4f expected=%.1f relative_error=%.3e "
          "(%.3f * 2^-10)\n",
          width - 1, last, ideal, rel_err, rel_err * 1024.0);

   free(bits);
   return bad ? 2 : 0;
}
