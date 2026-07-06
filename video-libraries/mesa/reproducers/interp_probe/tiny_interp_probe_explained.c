/*
 * tiny_interp_probe_explained.c
 *
 * This is the heavily documented version of tiny_interp_probe.c.
 *
 * The short version of what this program proves:
 *
 *   We draw one huge triangle over a 1-pixel-tall image. The vertex shader
 *   gives the GPU a number at the left edge and a number at the right edge.
 *   The GPU's interpolation hardware fills in the numbers for every pixel
 *   between those edges. Pixel x should receive exactly x + 0.5.
 *
 *   On Mali-G610/Panfrost, for large non-power-of-two widths, the interpolated
 *   number is slightly too small. When a real blit shader later truncates that
 *   number to an integer texel coordinate, it can fetch the previous texel.
 *
 * Important vocabulary, with no graphics background assumed:
 *
 *   pixel:
 *      One square in an image.
 *
 *   texture:
 *      An image stored by the GPU. Textures can be read by shaders. Here we
 *      also attach one as the place where drawing writes its output.
 *
 *   framebuffer:
 *      The current drawing target. In a normal game or app this might be the
 *      window. Here it is an offscreen 1-pixel-tall texture, because we do not
 *      want any window-system behavior involved.
 *
 *   shader:
 *      A tiny program that runs on the GPU.
 *
 *   vertex shader:
 *      Runs once per vertex of a triangle. It decides where the triangle's
 *      corners are and can attach values to those corners.
 *
 *   fragment shader:
 *      Runs once per covered pixel. It computes the value written to that
 *      pixel.
 *
 *   varying:
 *      A value produced by the vertex shader and consumed by the fragment
 *      shader. The GPU automatically interpolates it across the triangle.
 *      For example, if the left corner says 0 and the right corner says 100,
 *      a pixel halfway across should see about 50.
 *
 *   gl_FragCoord:
 *      A built-in value in the fragment shader. It is the pixel's own screen
 *      coordinate. It does not come through the user varying interpolation
 *      path, so it is a good control test.
 *
 *   R32UI:
 *      A texture format with one unsigned 32-bit integer per pixel. We use it
 *      as a "raw box of 32 bits" so the fragment shader can store the exact
 *      bit pattern of a float. The CPU then reads those exact bits back.
 *
 * Build from this directory:
 *
 *   cc -O2 -o tiny_interp_probe_explained \
 *      tiny_interp_probe_explained.c -lEGL -lGLESv2 -lm
 *
 * Run:
 *
 *   ./tiny_interp_probe_explained
 *   ./tiny_interp_probe_explained 12288 fragcoord
 *   ./tiny_interp_probe_explained 8192
 *   ./tiny_interp_probe_explained 16307 varying
 *
 * Exit codes:
 *
 *   0 = every pixel passed: floor(value) == x
 *   2 = the test ran, but at least one pixel failed
 *   1 = bad command line or setup failure
 */

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * This macro keeps the example compact. Whenever an EGL or GL setup step fails,
 * we print the source line and the last EGL/GL error values, then stop.
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
 * We do not upload any vertex buffer. Instead, gl_VertexID tells the shader
 * which of the three vertices it is currently making:
 *
 *   vertex 0 -> (-1, -1)
 *   vertex 1 -> ( 3, -1)
 *   vertex 2 -> (-1,  3)
 *
 * Those coordinates make one "oversized" triangle that covers the whole
 * framebuffer. This is a common graphics trick: one large triangle covers the
 * rectangle without having a diagonal seam between two smaller triangles.
 *
 * The output variable "v" is our test varying. At the left edge p.x = -1, so:
 *
 *   v = (-1 + 1) * 0.5 * width = 0
 *
 * At the right edge p.x = 1, so:
 *
 *   v = (1 + 1) * 0.5 * width = width
 *
 * Therefore pixel x, whose center is at x + 0.5 in window coordinates, should
 * receive v = x + 0.5 after interpolation.
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
 * It receives the interpolated varying "v". Instead of converting the float
 * to an integer value, it stores the exact 32-bit bit pattern of the float into
 * an unsigned integer output. This is like putting the bytes of the float into
 * a box and reading the same box back on the CPU.
 */
static const char *fs_varying =
   "#version 300 es\n"
   "in highp float v;\n"
   "out highp uint bits;\n"
   "void main() { bits = floatBitsToUint(v); }\n";

/*
 * The control fragment shader.
 *
 * This writes gl_FragCoord.x instead of our varying. If this path is exact
 * while the varying path is not, then rasterization and readback are not the
 * problem. The problem is specifically the varying interpolation path.
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
    * Width 12288 is useful because it shows nearly a 2^-10 relative error on
    * the target Mali-G610 system. Width 8192 is a power-of-two control that
    * passes on that system.
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
    * Create an EGL context.
    *
    * EGL is the glue layer that creates an OpenGL ES context. A context is the
    * GPU-side state needed to call GL functions. We use the "surfaceless" EGL
    * platform because this test draws to an offscreen texture, not to a window.
    */
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

   /*
    * Print the renderer. This matters because systems often have multiple GL
    * drivers installed. The output should say Panfrost/Mali when testing the
    * hardware path.
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
    * Compile and link the GPU program.
    *
    * A GL program is a linked pair of shaders. Both modes use the same vertex
    * shader. The fragment shader changes depending on whether we test the
    * varying or the gl_FragCoord control.
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
    * Create the offscreen render target.
    *
    * tex is a W-by-1 image with one 32-bit unsigned integer per pixel.
    * fbo is a framebuffer object that says "draw into tex".
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

   /*
    * Set the viewport. This tells GL that clip-space coordinates -1..1 map to
    * x coordinates 0..width and y coordinates 0..1 in our target texture.
    */
   glViewport(0, 0, width, 1);

   /*
    * Draw the one big triangle. There is no vertex buffer because the vertex
    * shader invents the three vertices from gl_VertexID.
    */
   glDrawArrays(GL_TRIANGLES, 0, 3);

   /*
    * Read back the raw bits. The format/type pair asks GL for unsigned integer
    * data from the red channel, matching the R32UI target.
    */
   uint32_t *bits = malloc((size_t)width * sizeof(*bits));
   CHECK(bits);
   glReadPixels(0, 0, width, 1, GL_RED_INTEGER, GL_UNSIGNED_INT, bits);
   CHECK(glGetError() == GL_NO_ERROR);

   /*
    * Verify each pixel.
    *
    * bits[x] contains the exact bit pattern of a float. memcpy is used instead
    * of a cast because C's strict aliasing rules make pointer punning unsafe.
    *
    * If the GPU produced v = x + 0.5 exactly, then floor(v) is x. If v is even
    * a little bit below x, floor(v) becomes x - 1, which is exactly the kind of
    * mistake that breaks texelFetch-based blits.
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
