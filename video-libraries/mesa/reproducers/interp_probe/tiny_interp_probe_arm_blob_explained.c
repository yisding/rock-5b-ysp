// SPDX-License-Identifier: MIT
/*
 * tiny_interp_probe_arm_blob_explained.c
 *
 * This is the heavily documented version of tiny_interp_probe_arm_blob.c.
 *
 * Short version:
 *
 *   The actual interpolation test is the same test as tiny_interp_probe.c.
 *   The shader source, oversized triangle, R32UI render target, raw readback,
 *   and CPU check are intentionally kept the same.
 *
 *   The only reason this file exists is that the proprietary Rockchip/Arm Mali
 *   userspace stack is reached through different EGL platform plumbing than
 *   Mesa/Panfrost.
 *
 * Why the ARM code is different:
 *
 *   Mesa tiny path:
 *
 *      EGL_PLATFORM_SURFACELESS_MESA + EGL_DEFAULT_DISPLAY
 *
 *   ARM/Rockchip libmali path:
 *
 *      open /dev/dri/renderD128
 *      create a gbm_device from that DRM render node
 *      EGL_PLATFORM_GBM_KHR + that gbm_device
 *
 *   This does not mean the ARM version renders to a window or to a GBM buffer.
 *   It only means the EGL display is found through GBM. After the context is
 *   created, this file still calls:
 *
 *      eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)
 *
 *   That is the cleanest match for the original Mesa test because the public
 *   RK3588/G610 GBM blobs expose EGL_KHR_surfaceless_context and
 *   GL_OES_surfaceless_context. Those extensions exist for exactly this kind
 *   of program: code that renders only to API-created framebuffer objects and
 *   does not need a throw-away window or pbuffer surface.
 *
 * Important vocabulary, with no graphics background assumed:
 *
 *   DRM render node:
 *      A Linux device file such as /dev/dri/renderD128. Opening it gives a
 *      userspace graphics driver access to the GPU for rendering work. It does
 *      not imply that we are displaying anything on a monitor.
 *
 *   GBM:
 *      "Generic Buffer Management". On Linux graphics stacks, GBM is often the
 *      small library used to connect EGL to a DRM device. Here we use it only
 *      to create the EGLDisplay that talks to libmali.
 *
 *   EGLDisplay:
 *      EGL's handle for a connection to a graphics implementation. Despite the
 *      word "Display", this does not have to mean a visible screen. It is more
 *      like "the driver/backend I am using".
 *
 *   EGLSurface:
 *      EGL's handle for a window, pbuffer, or other default drawing surface.
 *      This test does not want one, because a default surface would be another
 *      moving part. We draw to a GL framebuffer object instead.
 *
 *   surfaceless context:
 *      A GL context made current with EGL_NO_SURFACE for both read and draw.
 *      That is allowed when EGL_KHR_surfaceless_context and the matching GL
 *      surfaceless behavior are supported.
 *
 *   framebuffer object, or FBO:
 *      A GL object that says "draw into this texture". Our FBO points at a
 *      one-pixel-tall R32UI texture, so the output is completely offscreen and
 *      easy to read back exactly.
 *
 *   varying:
 *      A value produced by the vertex shader and consumed by the fragment
 *      shader. The GPU automatically interpolates it across the triangle.
 *      This is the thing being tested.
 *
 * Build from this directory, against the proprietary libmali wrappers/headers:
 *
 *   cc -O2 -o tiny_interp_probe_arm_blob_explained \
 *      tiny_interp_probe_arm_blob_explained.c -lEGL -lGLESv2 -lgbm -lm
 *
 * Run:
 *
 *   ./tiny_interp_probe_arm_blob_explained
 *   ./tiny_interp_probe_arm_blob_explained 12288 fragcoord
 *   ./tiny_interp_probe_arm_blob_explained 16307 varying /dev/dri/renderD128
 *
 * Exit codes:
 *
 *   0 = every pixel passed: floor(value) == x
 *   2 = the test ran, but at least one pixel failed
 *   1 = bad command line or EGL/GL setup failure
 */

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <fcntl.h>
#include <gbm.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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
 * failure is in varying interpolation, not in rasterization or readback.
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
    *   argv[3] = DRM render node, default /dev/dri/renderD128
    *
    * The render node argument is ARM-specific because this file creates a GBM
    * display. The Mesa surfaceless version does not open a DRM node directly.
    */
   int width = 12288;
   const char *mode = "varying";
   const char *node = "/dev/dri/renderD128";

   if (argc > 1) {
      char *end;
      long w = strtol(argv[1], &end, 10);
      if (*argv[1] == '\0' || *end != '\0' || w < 1 || w > (1 << 23)) {
         fprintf(stderr, "usage: %s [width] [varying|fragcoord] [render-node]\n",
                 argv[0]);
         return 1;
      }
      width = (int)w;
   }

   if (argc > 2) {
      mode = argv[2];
      if (strcmp(mode, "varying") != 0 && strcmp(mode, "fragcoord") != 0) {
         fprintf(stderr, "usage: %s [width] [varying|fragcoord] [render-node]\n",
                 argv[0]);
         return 1;
      }
   }

   if (argc > 3)
      node = argv[3];

   int use_fragcoord = strcmp(mode, "fragcoord") == 0;

   /*
    * ARM-specific display setup, step 1: open the render node.
    *
    * We use a render node instead of a card node because render nodes are meant
    * for GPU rendering without display-control permissions. The default is the
    * usual first render node on a single-GPU board.
    */
   int drmfd = open(node, O_RDWR | O_CLOEXEC);
   if (drmfd < 0) {
      perror(node);
      return 1;
   }

   /*
    * ARM-specific display setup, step 2: wrap the DRM fd in a gbm_device.
    *
    * This object is not the render target. It is just the native-display object
    * passed to eglGetPlatformDisplayEXT for EGL_PLATFORM_GBM_KHR.
    */
   struct gbm_device *gbm = gbm_create_device(drmfd);
   CHECK(gbm);

   /*
    * ARM-specific display setup, step 3: ask EGL for a GBM platform display.
    *
    * The Mesa tiny version uses EGL_PLATFORM_SURFACELESS_MESA. That is a Mesa
    * platform extension. The proprietary RK3588 stack is packaged as GBM,
    * Wayland+GBM, X11+GBM, and related libmali builds, so GBM is the direct
    * platform route for this board's blob.
    */
   PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress(
         "eglGetPlatformDisplayEXT");
   CHECK(get_platform_display);

   EGLDisplay dpy = get_platform_display(EGL_PLATFORM_GBM_KHR, gbm, NULL);
   CHECK(dpy != EGL_NO_DISPLAY);
   CHECK(eglInitialize(dpy, NULL, NULL));
   CHECK(eglBindAPI(EGL_OPENGL_ES_API));

   /*
    * Choose an OpenGL ES 3-capable config.
    *
    * EGL configs describe possible default surfaces. We set EGL_SURFACE_TYPE
    * to 0 because this program does not create a default EGL surface. The real
    * drawing target is the R32UI texture attached to a GL framebuffer object
    * later in the file.
    */
   EGLint cfg_attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                         EGL_SURFACE_TYPE, 0, EGL_NONE};
   EGLConfig cfg;
   EGLint cfg_count = 0;
   CHECK(eglChooseConfig(dpy, cfg_attrs, &cfg, 1, &cfg_count) && cfg_count);

   /*
    * Create the GL ES context and make it current without an EGLSurface.
    *
    * This is the key reason the ARM file can stay close to the Mesa file:
    * RK3588/G610 libmali exposes EGL_KHR_surfaceless_context, so we do not
    * need to create a tiny pbuffer just to satisfy EGL.
    */
   EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
   EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
   CHECK(ctx != EGL_NO_CONTEXT);
   CHECK(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx));

   /*
    * Print the renderer and GL version. This is important when Mesa and libmali
    * are both installed: the output is the quickest sanity check that the ARM
    * blob, not Panfrost, answered the GL calls.
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
    * Build the tiny shader program. This is identical to the Mesa tiny probe:
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
