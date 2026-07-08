/*
 * tiny_interp_probe_arm_blob_x11_explained.c
 *
 * This is the heavily documented version of tiny_interp_probe_arm_blob_x11.c.
 *
 * Short version:
 *
 *   The actual interpolation test is the same test as tiny_interp_probe.c.
 *   The shader source, oversized triangle, R32UI render target, raw readback,
 *   and CPU check are intentionally kept the same.
 *
 *   The only reason this file exists is HOW it reaches the proprietary
 *   Rockchip/Arm Mali userspace (libmali) on an RK3588 / Mali-G610 board: it
 *   connects to a running X server and renders as an X client, instead of
 *   opening a DRM device directly through GBM.
 *
 * Why not the GBM variant (this is the important part):
 *
 *   Its sibling tiny_interp_probe_arm_blob.c reaches libmali through GBM
 *   (EGL_PLATFORM_GBM_KHR on a DRM render node). On the Radxa 5.10 vendor
 *   kernel (5.10.110-39-rockchip) that path CRASHES THE KERNEL: libmali's
 *   GBM/EGL bring-up issues the legacy ioctl DRM_IOCTL_SET_VERSION on the
 *   rockchip-drm primary node, and that handler dereferences a NULL pointer
 *   (kernel Oops at drm_setversion+0x80). Worse, the kernel's own teardown of
 *   the faulting process then deadlocks in rockchip_drm_lastclose ->
 *   drm_master_internal_acquire, so the process never finishes dying and holds
 *   drm_global_mutex forever -- every later DRM open hangs, and the board needs
 *   a reboot or power cycle. Because of that, the GBM variant refuses to run by
 *   default. See:
 *     findings/2026-07-08-arm-mali-blob-gbm-setversion-kernel-oops.md
 *
 *   The fix is to never let libmali issue that SET_VERSION. SET_VERSION is a
 *   legacy "I want to be the DRM master" handshake. If a display server (X) is
 *   already running, IT is the DRM master. A libmali *client* of that X server
 *   authenticates through DRI2 (a "please let me render, here is my magic
 *   cookie" flow) and never calls SET_VERSION. So this file starts from an X
 *   connection and stays a well-behaved client. It has been run on hardware
 *   and produces the interpolation drift bit-for-bit identically to Mesa /
 *   Panfrost -- proving the drift is in the Mali hardware, not in either
 *   driver stack. See:
 *     findings/2026-07-08-arm-mali-blob-interp-drift-bit-identical-to-mesa.md
 *
 * How the display setup differs from the other variants:
 *
 *   Mesa tiny path:      EGL_PLATFORM_SURFACELESS_MESA + EGL_DEFAULT_DISPLAY
 *   ARM GBM path:        open /dev/dri/renderD128 -> gbm_device -> GBM platform
 *   ARM X11 path (here): XOpenDisplay() -> EGL_PLATFORM_X11 on that Display*
 *
 *   This file does NOT render to an X window. It creates a throwaway 1x1
 *   pbuffer surface only so the context has something to be "made current"
 *   against, then draws into an offscreen R32UI framebuffer object exactly like
 *   every other variant. (The installed x11-gbm blob does advertise
 *   EGL_KHR_surfaceless_context, so EGL_NO_SURFACE would likely also work; a
 *   1x1 pbuffer is used because it is the most conservative, widely-supported
 *   way to make a context current, and the surface is never drawn to.)
 *
 * Important vocabulary, with no graphics background assumed:
 *
 *   X server:
 *      The process that owns the display hardware on a traditional Linux
 *      desktop (here, Xorg, started by the sddm login manager). Programs that
 *      want to draw talk to it as "clients".
 *
 *   DRM master:
 *      The one process allowed to control a DRM/KMS display device (set video
 *      modes, own the screen). The X server is the master here. The kernel
 *      crash above happens when a second program tries to renegotiate that
 *      role via the old SET_VERSION ioctl. As a plain X client we never try.
 *
 *   DRI2 authentication:
 *      The mechanism by which an X client is granted GPU rendering access
 *      through the X server that already owns the device. No master handshake,
 *      no SET_VERSION.
 *
 *   EGLDisplay:
 *      EGL's handle for a connection to a graphics implementation. Despite the
 *      word "Display", it means "the driver/backend I am using" (here libmali),
 *      not a visible screen.
 *
 *   EGLSurface / pbuffer:
 *      EGL's handle for a drawable. A pbuffer is an offscreen one. We make a
 *      tiny 1x1 pbuffer only to satisfy eglMakeCurrent; the test never draws to
 *      it. The real target is a GL framebuffer object.
 *
 *   framebuffer object, or FBO:
 *      A GL object that says "draw into this texture". Our FBO points at a
 *      one-pixel-tall R32UI texture, so the output is completely offscreen and
 *      easy to read back exactly.
 *
 *   varying:
 *      A value produced by the vertex shader and consumed by the fragment
 *      shader. The GPU automatically interpolates it across the triangle. This
 *      is the thing being tested.
 *
 * Build from this directory (link libmali directly -- the .../mali libEGL /
 * libGLESv2 stubs export zero symbols -- plus libX11 for XOpenDisplay):
 *
 *   cc -O2 -o tiny_interp_probe_arm_blob_x11_explained \
 *      tiny_interp_probe_arm_blob_x11_explained.c -lmali -lX11 -lm
 *
 * Run (needs a reachable X server; set DISPLAY and, over SSH, an X authority
 * that grants access -- e.g. DISPLAY=:0):
 *
 *   DISPLAY=:0 ./tiny_interp_probe_arm_blob_x11_explained 8192  fragcoord
 *   DISPLAY=:0 ./tiny_interp_probe_arm_blob_x11_explained 12288 varying
 *
 * Exit codes:
 *
 *   0 = every pixel passed: floor(value) == x
 *   2 = the test ran, but at least one pixel failed
 *   1 = bad command line, X-connection failure, or EGL/GL setup failure
 */

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <X11/Xlib.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * CHECK is deliberately simple. This file is a reproducer, not a framework.
 * When a setup step fails, print the source line plus the most recent EGL and
 * GL errors, then stop immediately.
 */
#define CHECK(x)                                                               \
   do {                                                                        \
      if (!(x)) {                                                              \
         fprintf(stderr, "check failed at line %d, egl=0x%x gl=0x%x\n",        \
                 __LINE__, eglGetError(), glGetError());                       \
         exit(1);                                                              \
      }                                                                        \
   } while (0)

/*
 * The vertex shader.
 *
 * No vertex buffer is uploaded. gl_VertexID tells the shader which of the
 * three vertices it is currently generating:
 *
 *   vertex 0 -> (-1, -1)
 *   vertex 1 -> ( 3, -1)
 *   vertex 2 -> (-1,  3)
 *
 * Those coordinates make one oversized triangle covering the whole W-by-1
 * framebuffer. At the left edge, p.x is -1 and v becomes 0. At the right edge,
 * p.x is +1 and v becomes width. Therefore the center of pixel x should see:
 *
 *   v = x + 0.5
 */
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

/*
 * The test fragment shader.
 *
 * It receives the interpolated varying and stores the exact float bit pattern
 * into an unsigned integer render target. This avoids any float-to-integer
 * conversion in the shader. The CPU later interprets the same 32 bits as a
 * float and checks whether floor(v) equals the pixel number.
 */
static const char *fs_varying =
   "#version 300 es\n"
   "in highp float v;\n"
   "out highp uint bits;\n"
   "void main() { bits = floatBitsToUint(v); }\n";

/*
 * The control fragment shader.
 *
 * gl_FragCoord.x is the fragment's own x coordinate. It does not use our
 * user-defined varying. If this mode passes but the varying mode fails, the
 * failure is in varying interpolation, not in rasterization or readback. On
 * Mali-G610 the control passes exactly at every width while the varying mode
 * drifts -- that contrast is the whole result.
 */
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
   /*
    * Command line:
    *
    *   argv[1] = width, default 12288
    *   argv[2] = "varying" or "fragcoord", default "varying"
    *
    * Unlike the GBM variant there is no render-node argument: this file does
    * not open a DRM device at all. The X server picks the GPU; we are a client.
    */
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

   /*
    * X11 display setup, step 1: connect to the running X server.
    *
    * XOpenDisplay(NULL) reads $DISPLAY (e.g. ":0") and connects. Success means
    * there is an X server already owning the GPU as DRM master -- which is
    * exactly what keeps libmali from issuing the SET_VERSION that crashes this
    * kernel. Failure means no reachable/authorized server; we stop cleanly
    * here, having touched no GPU state, rather than falling back to the unsafe
    * GBM path.
    */
   Display *xdpy = XOpenDisplay(NULL);
   if (!xdpy) {
      const char *d = getenv("DISPLAY");
      fprintf(stderr,
              "cannot open X display '%s': no reachable X server.\n"
              "  This variant renders through libmali as a client of a running\n"
              "  X server (that is what avoids the SET_VERSION kernel Oops). Set\n"
              "  DISPLAY to the active server (e.g. DISPLAY=:0) and make sure your\n"
              "  user is authorized (XAUTHORITY, or `xhost +SI:localuser:<you>`).\n"
              "  Do NOT fall back to the GBM variant on this kernel -- it crashes\n"
              "  the box.\n",
              d ? d : "(unset)");
      return 1;
   }

   /*
    * X11 display setup, step 2: get an EGLDisplay for the X11 platform.
    *
    * eglGetPlatformDisplayEXT(EGL_PLATFORM_X11_KHR, xdpy, NULL) is the modern,
    * explicit way to say "an EGL connection layered on this X Display". We fetch
    * it through eglGetProcAddress because it is an EGL client extension entry
    * point. If for some reason it is unavailable, fall back to the legacy
    * eglGetDisplay((EGLNativeDisplayType)xdpy), which also accepts an X Display*.
    */
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

   /*
    * Choose an OpenGL ES 3-capable config that can back a pbuffer.
    *
    * The GBM variant sets EGL_SURFACE_TYPE to 0 (surfaceless). Here we ask for
    * EGL_PBUFFER_BIT because step 4 creates a tiny pbuffer to make the context
    * current. Either way the config is just a pixel-format description; the real
    * drawing target is the R32UI texture attached to a GL framebuffer object
    * later in the file.
    */
   EGLint cfg_attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                         EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE};
   EGLConfig cfg;
   EGLint cfg_count = 0;
   CHECK(eglChooseConfig(dpy, cfg_attrs, &cfg, 1, &cfg_count) && cfg_count);

   /*
    * Create the GL ES 3 context.
    */
   EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
   EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
   CHECK(ctx != EGL_NO_CONTEXT);

   /*
    * X11 display setup, step 4: a throwaway 1x1 pbuffer, then make current.
    *
    * The test renders into the R32UI FBO created below, so this pbuffer is never
    * drawn to. It exists only because eglMakeCurrent wants a draw/read surface,
    * and a 1x1 pbuffer is the most conservative, portable way to provide one.
    */
   EGLint pbuf_attrs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
   EGLSurface pbuf = eglCreatePbufferSurface(dpy, cfg, pbuf_attrs);
   CHECK(pbuf != EGL_NO_SURFACE);
   CHECK(eglMakeCurrent(dpy, pbuf, pbuf, ctx));

   /*
    * Print the renderer and GL version. This is important when Mesa and libmali
    * are both installed: the output is the quickest sanity check that the ARM
    * blob, not Panfrost, answered the GL calls. On this board it reads:
    *
    *   GL_RENDERER=Mali-LODX
    *   GL_VERSION=OpenGL ES 3.2 v1.g6p0-01eac0...
    *
    * Do not trust any varying number unless this names Mali and the fragcoord
    * control passed.
    */
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

   /*
    * Build the tiny shader program. This is identical to every other variant:
    * one vertex shader plus one of two fragment shaders.
    */
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

   /*
    * Create the offscreen image and make it the GL framebuffer.
    *
    * GL_R32UI means one unsigned 32-bit integer per pixel. We are not storing
    * colors for humans to look at. We are storing raw float bits for the CPU to
    * check exactly.
    */
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

   /*
    * Draw one oversized triangle. The vertex shader uses gl_VertexID, so no
    * vertex array or buffer object is needed.
    */
   glDrawArrays(GL_TRIANGLES, 0, 3);

   /*
    * Read back raw integer pixels.
    *
    * R32UI plus GL_RED_INTEGER/GL_UNSIGNED_INT means the CPU receives the same
    * 32-bit values the fragment shader wrote. No color conversion is involved.
    */
   uint32_t *bits = malloc((size_t)width * sizeof(*bits));
   CHECK(bits);
   glReadPixels(0, 0, width, 1, GL_RED_INTEGER, GL_UNSIGNED_INT, bits);
   CHECK(glGetError() == GL_NO_ERROR);

   /*
    * Check every pixel.
    *
    * The shader stored a float's bits in an integer slot. memcpy is the safe C
    * way to reinterpret those bits as a float without breaking aliasing rules.
    */
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
