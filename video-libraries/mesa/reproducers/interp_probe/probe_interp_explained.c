// SPDX-License-Identifier: MIT
/*
 * probe_interp_explained.c
 *
 * This is the heavily documented version of probe_interp.c.
 *
 * Why this file exists:
 *
 *   This was the earlier interpolation probe, before tiny_interp_probe.c
 *   reduced the experiment even further. It draws a W-by-1 rectangle and asks:
 *
 *      "If a value goes from 0 at the left edge to W at the right edge,
 *       does the fragment shader receive x + 0.5 at pixel x?"
 *
 *   The answer on Mali-G610/Panfrost is "not always" for smooth varyings at
 *   large non-power-of-two widths. gl_FragCoord.x, the built-in pixel
 *   coordinate, is exact in the same setup.
 *
 * What makes this file more complicated than tiny_interp_probe_explained.c:
 *
 *   1. It uses GBM to open /dev/dri/renderD128 and create an EGL display for
 *      that render node. GBM is a Linux graphics helper library for allocating
 *      buffers and connecting EGL to DRM devices.
 *
 *   2. It loads GL functions with eglGetProcAddress instead of calling them
 *      directly. This was done in older reproducers to make sure the locally
 *      built Mesa driver was the one actually used. Function pointers look
 *      noisy, but the idea is simple: ask EGL for the address of "glDrawArrays",
 *      store that address in a C function pointer, then call through it.
 *
 *   3. It draws a two-triangle quad with real vertex data, rather than one
 *      gl_VertexID-generated triangle.
 *
 * Modes:
 *
 *   0 = smooth/perspective varying. This is the failing path on Mali-G610.
 *   1 = noperspective varying. In GLSL ES this is a reserved word, so shader
 *       compilation fails. That failure is expected and documented.
 *   2 = gl_FragCoord.x. This is the control path and should pass.
 *
 * Build from this directory:
 *
 *   cc -O2 -o probe_interp_explained \
 *      probe_interp_explained.c -lEGL -lGLESv2 -lgbm -lm
 *
 * Run:
 *
 *   ./probe_interp_explained 16307 0
 *   ./probe_interp_explained 16307 2
 */

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>
#include <fcntl.h>
#include <gbm.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CHECK(x)                                                               \
   do {                                                                        \
      if (!(x)) {                                                              \
         fprintf(stderr, "fail line %d egl=0x%x\n", __LINE__, eglGetError()); \
         exit(1);                                                              \
      }                                                                        \
   } while (0)

/*
 * Fetch a GL function pointer.
 *
 * In normal small GL programs you often call glDrawArrays(...) directly. This
 * historical reproducer uses dynamic lookup instead. That means "find the
 * address of a function by name at runtime". It is the graphics equivalent of
 * looking up a phone number before making the call.
 */
static void *
get_gl_proc(const char *name)
{
   void *p = (void *)eglGetProcAddress(name);
   if (!p) {
      fprintf(stderr, "missing GL function %s\n", name);
      exit(1);
   }
   return p;
}

int
main(int argc, char **argv)
{
   /*
    * Width is the number of pixels in the one-row image.
    * Mode chooses which value the fragment shader writes.
    */
   int W = (argc > 1) ? atoi(argv[1]) : 16307;
   int mode = (argc > 2) ? atoi(argv[2]) : 0;

   /*
    * Open the render node. On Linux DRM render nodes are device files used for
    * GPU work that does not require owning the display.
    */
   int drmfd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
   CHECK(drmfd >= 0);

   /*
    * GBM wraps the DRM file descriptor so EGL can create a GL context on that
    * device. We are not creating a visible window.
    */
   struct gbm_device *gbm = gbm_create_device(drmfd);
   CHECK(gbm);

   PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress(
         "eglGetPlatformDisplayEXT");
   CHECK(get_platform_display);

   EGLDisplay dpy = get_platform_display(EGL_PLATFORM_GBM_KHR, gbm, NULL);
   CHECK(dpy != EGL_NO_DISPLAY);
   CHECK(eglInitialize(dpy, NULL, NULL));
   CHECK(eglBindAPI(EGL_OPENGL_ES_API));

   EGLint config_attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE};
   EGLConfig cfg;
   EGLint config_count = 0;
   CHECK(eglChooseConfig(dpy, config_attrs, &cfg, 1, &config_count) &&
         config_count > 0);

   EGLint context_attrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3,
                             EGL_CONTEXT_MINOR_VERSION, 1, EGL_NONE};
   EGLContext ctx =
      eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, context_attrs);
   CHECK(ctx != EGL_NO_CONTEXT);
   CHECK(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx));

   /*
    * Load the GL functions this program uses. The type on the left is "pointer
    * to a function with this signature". The value on the right is the address
    * returned by get_gl_proc().
    */
   const GLubyte *(*glGetString_)(GLenum) = get_gl_proc("glGetString");
   void (*glGenTextures_)(GLsizei, GLuint *) = get_gl_proc("glGenTextures");
   void (*glBindTexture_)(GLenum, GLuint) = get_gl_proc("glBindTexture");
   void (*glTexStorage2D_)(GLenum, GLsizei, GLenum, GLsizei, GLsizei) =
      get_gl_proc("glTexStorage2D");
   void (*glGenFramebuffers_)(GLsizei, GLuint *) =
      get_gl_proc("glGenFramebuffers");
   void (*glBindFramebuffer_)(GLenum, GLuint) =
      get_gl_proc("glBindFramebuffer");
   void (*glFramebufferTexture2D_)(GLenum, GLenum, GLenum, GLuint, GLint) =
      get_gl_proc("glFramebufferTexture2D");
   GLenum (*glCheckFramebufferStatus_)(GLenum) =
      get_gl_proc("glCheckFramebufferStatus");
   void (*glViewport_)(GLint, GLint, GLsizei, GLsizei) =
      get_gl_proc("glViewport");
   GLuint (*glCreateShader_)(GLenum) = get_gl_proc("glCreateShader");
   void (*glShaderSource_)(GLuint, GLsizei, const GLchar *const *,
                           const GLint *) = get_gl_proc("glShaderSource");
   void (*glCompileShader_)(GLuint) = get_gl_proc("glCompileShader");
   void (*glGetShaderiv_)(GLuint, GLenum, GLint *) =
      get_gl_proc("glGetShaderiv");
   void (*glGetShaderInfoLog_)(GLuint, GLsizei, GLsizei *, GLchar *) =
      get_gl_proc("glGetShaderInfoLog");
   GLuint (*glCreateProgram_)(void) = get_gl_proc("glCreateProgram");
   void (*glAttachShader_)(GLuint, GLuint) = get_gl_proc("glAttachShader");
   void (*glLinkProgram_)(GLuint) = get_gl_proc("glLinkProgram");
   void (*glGetProgramiv_)(GLuint, GLenum, GLint *) =
      get_gl_proc("glGetProgramiv");
   void (*glGetProgramInfoLog_)(GLuint, GLsizei, GLsizei *, GLchar *) =
      get_gl_proc("glGetProgramInfoLog");
   void (*glUseProgram_)(GLuint) = get_gl_proc("glUseProgram");
   void (*glGenBuffers_)(GLsizei, GLuint *) = get_gl_proc("glGenBuffers");
   void (*glBindBuffer_)(GLenum, GLuint) = get_gl_proc("glBindBuffer");
   void (*glBufferData_)(GLenum, GLsizeiptr, const void *, GLenum) =
      get_gl_proc("glBufferData");
   void (*glGenVertexArrays_)(GLsizei, GLuint *) =
      get_gl_proc("glGenVertexArrays");
   void (*glBindVertexArray_)(GLuint) = get_gl_proc("glBindVertexArray");
   void (*glVertexAttribPointer_)(GLuint, GLint, GLenum, GLboolean, GLsizei,
                                  const void *) =
      get_gl_proc("glVertexAttribPointer");
   void (*glEnableVertexAttribArray_)(GLuint) =
      get_gl_proc("glEnableVertexAttribArray");
   void (*glBindAttribLocation_)(GLuint, GLuint, const GLchar *) =
      get_gl_proc("glBindAttribLocation");
   void (*glDrawArrays_)(GLenum, GLint, GLsizei) =
      get_gl_proc("glDrawArrays");
   void (*glReadPixels_)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum,
                         void *) = get_gl_proc("glReadPixels");
   void (*glFinish_)(void) = get_gl_proc("glFinish");
   void (*glReadBuffer_)(GLenum) = get_gl_proc("glReadBuffer");
   GLenum (*glGetError_)(void) = get_gl_proc("glGetError");

   fprintf(stderr, "GL_RENDERER=%s\n",
           (const char *)glGetString_(GL_RENDERER));

   /*
    * Build the shader text.
    *
    * "interp" is either an empty string or "noperspective". In GLSL ES,
    * noperspective is not allowed, so mode 1 fails compilation. Keeping that
    * mode here records the historical experiment.
    */
   const char *interp = mode == 1 ? "noperspective" : "";
   char vs[512];
   char fs[512];

   /*
    * Vertex shader:
    *
    *   pos is the 2D clip-space position of each corner of the rectangle.
    *   tc is the test coordinate at that corner.
    *   v_tc is the varying sent to the fragment shader.
    */
   snprintf(vs, sizeof(vs),
            "#version 310 es\n"
            "in vec2 pos;\n"
            "in float tc;\n"
            "%s out highp float v_tc;\n"
            "void main(){ v_tc = tc; gl_Position = vec4(pos,0.0,1.0); }\n",
            interp);

   /*
    * Fragment shader:
    *
    * In mode 2, write gl_FragCoord.x as the control.
    * Otherwise, write the interpolated varying v_tc.
    */
   if (mode == 2) {
      snprintf(fs, sizeof(fs),
               "#version 310 es\n"
               "precision highp float; precision highp int;\n"
               "out highp uint o;\n"
               "void main(){ o = floatBitsToUint(gl_FragCoord.x); }\n");
   } else {
      snprintf(fs, sizeof(fs),
               "#version 310 es\n"
               "precision highp float; precision highp int;\n"
               "%s in highp float v_tc;\n"
               "out highp uint o;\n"
               "void main(){ o = floatBitsToUint(v_tc); }\n",
               interp);
   }

   GLuint vshader = glCreateShader_(GL_VERTEX_SHADER);
   const char *vp = vs;
   glShaderSource_(vshader, 1, &vp, NULL);
   glCompileShader_(vshader);
   GLint ok = 0;
   glGetShaderiv_(vshader, GL_COMPILE_STATUS, &ok);
   if (!ok) {
      char log[1024];
      glGetShaderInfoLog_(vshader, sizeof(log), NULL, log);
      fprintf(stderr, "VS: %s\n", log);
      return 1;
   }

   GLuint fshader = glCreateShader_(GL_FRAGMENT_SHADER);
   const char *fp = fs;
   glShaderSource_(fshader, 1, &fp, NULL);
   glCompileShader_(fshader);
   glGetShaderiv_(fshader, GL_COMPILE_STATUS, &ok);
   if (!ok) {
      char log[1024];
      glGetShaderInfoLog_(fshader, sizeof(log), NULL, log);
      fprintf(stderr, "FS: %s\n", log);
      return 1;
   }

   GLuint prog = glCreateProgram_();
   glAttachShader_(prog, vshader);
   glAttachShader_(prog, fshader);
   glBindAttribLocation_(prog, 0, "pos");
   glBindAttribLocation_(prog, 1, "tc");
   glLinkProgram_(prog);
   glGetProgramiv_(prog, GL_LINK_STATUS, &ok);
   if (!ok) {
      char log[1024];
      glGetProgramInfoLog_(prog, sizeof(log), NULL, log);
      fprintf(stderr, "LINK: %s\n", log);
      return 1;
   }

   /*
    * Render target: one row of W integer pixels. The fragment shader writes
    * one uint per pixel, which is the raw bit pattern of the float we measured.
    */
   GLuint tex;
   glGenTextures_(1, &tex);
   glBindTexture_(GL_TEXTURE_2D, tex);
   glTexStorage2D_(GL_TEXTURE_2D, 1, GL_R32UI, W, 1);

   GLuint fbo;
   glGenFramebuffers_(1, &fbo);
   glBindFramebuffer_(GL_FRAMEBUFFER, fbo);
   glFramebufferTexture2D_(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                           tex, 0);
   if (glCheckFramebufferStatus_(GL_FRAMEBUFFER) !=
       GL_FRAMEBUFFER_COMPLETE) {
      fprintf(stderr, "fbo bad\n");
      return 1;
   }

   glViewport_(0, 0, W, 1);

   /*
    * Vertex data for a rectangle made of two triangles.
    *
    * Each vertex has:
    *
    *   pos.x, pos.y, tc
    *
    * tc is 0 at the left edge and W at the right edge. At pixel center i+0.5,
    * ideal interpolation gives tc = i + 0.5.
    */
   float verts[] = {
      -1.f, -1.f, 0.f,      1.f, -1.f, (float)W,
       1.f,  1.f, (float)W,

      -1.f, -1.f, 0.f,      1.f,  1.f, (float)W,
      -1.f,  1.f, 0.f,
   };

   GLuint vao, vbo;
   glGenVertexArrays_(1, &vao);
   glBindVertexArray_(vao);
   glGenBuffers_(1, &vbo);
   glBindBuffer_(GL_ARRAY_BUFFER, vbo);
   glBufferData_(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);

   /*
    * Attribute 0 reads two floats: pos.x and pos.y.
    * Attribute 1 reads one float: tc.
    * The stride is 3 floats because each vertex stores three floats total.
    */
   glVertexAttribPointer_(0, 2, GL_FLOAT, GL_FALSE, 3 * sizeof(float),
                          (void *)0);
   glEnableVertexAttribArray_(0);
   glVertexAttribPointer_(1, 1, GL_FLOAT, GL_FALSE, 3 * sizeof(float),
                          (void *)(2 * sizeof(float)));
   glEnableVertexAttribArray_(1);

   glUseProgram_(prog);
   glDrawArrays_(GL_TRIANGLES, 0, 6);
   glFinish_();

   /*
    * Read back one uint per pixel. The value is really the bits of a float.
    */
   unsigned *buf = malloc((size_t)W * sizeof(unsigned));
   if (!buf) {
      fprintf(stderr, "malloc failed\n");
      return 1;
   }

   glReadBuffer_(GL_COLOR_ATTACHMENT0);
   glReadPixels_(0, 0, W, 1, GL_RED_INTEGER, GL_UNSIGNED_INT, buf);
   fprintf(stderr, "glReadPixels err=0x%x\n", glGetError_());

   const char *mode_name =
      mode == 0 ? "SMOOTH" : mode == 1 ? "NOPERSPECTIVE" : "FRAGCOORD.x";
   printf("mode=%s W=%d\n", mode_name, W);
   printf("i : interp_tc : ideal(i+0.5) : abs_err : floor(interp) vs i\n");

   long floor_mismatch = 0;
   double maxrel = 0;

   for (int i = 0; i < W; i++) {
      float tc;
      memcpy(&tc, &buf[i], sizeof(tc));

      double ideal = i + 0.5;
      double err = tc - ideal;
      if ((long)floorf(tc) != i)
         floor_mismatch++;

      double rel = fabs(err) / ideal;
      if (rel > maxrel)
         maxrel = rel;
   }

   printf("floor(interp)!=i count = %ld / %d   max_rel_err=%.3e "
          "(log2=%.2f)\n",
          floor_mismatch, W, maxrel, maxrel > 0 ? log2(maxrel) : 0);

   /*
    * Print a few sample points so the reader can see that the error grows with
    * x. A constant half-pixel bug would not grow this way.
    */
   for (int i = 256; i < W; i *= 2) {
      float tc;
      memcpy(&tc, &buf[i], sizeof(tc));
      printf("   i=%-7d interp=%.4f ideal=%.1f err=%+.4f floor=%ld\n",
             i, tc, i + 0.5, tc - (i + 0.5), (long)floorf(tc));
   }

   {
      int i = W - 1;
      float tc;
      memcpy(&tc, &buf[i], sizeof(tc));
      printf("   i=%-7d interp=%.4f ideal=%.1f err=%+.4f floor=%ld\n",
             i, tc, i + 0.5, tc - (i + 0.5), (long)floorf(tc));
   }

   free(buf);
   return 0;
}
