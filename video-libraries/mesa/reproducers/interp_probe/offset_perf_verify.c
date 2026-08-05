// SPDX-License-Identifier: MIT
// Correctness companion for offset_perf_probe.c.
//
// On the affected Mali-G610, the default 12288x1 case passes only when:
//   baseline has mismatches, workaround has none, fragcoord has none.
//
// Build and run:
//   cc -O2 -Wall -Wextra -Werror -o offset_perf_verify offset_perf_verify.c -lEGL -lGLESv2
//   ./offset_perf_verify [width height]

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(x)                                                               \
   do {                                                                        \
      if (!(x)) {                                                              \
         fprintf(stderr, "failure at line %d (EGL 0x%x, GL 0x%x)\n",           \
                 __LINE__, eglGetError(), glGetError());                       \
         exit(1);                                                              \
      }                                                                        \
   } while (0)

enum path {
   BASELINE,
   WORKAROUND,
   FRAGCOORD,
};

struct result {
   size_t mismatches;
   size_t first;
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

static struct result
run(GLuint program, int use_workaround, uint32_t *pixels, int width, int height)
{
   const size_t count = (size_t)width * (size_t)height;
   glUseProgram(program);
   if (use_workaround) {
      glEnable(GL_POLYGON_OFFSET_FILL);
      glPolygonOffset(0.0f, 0.0f);
   } else {
      glDisable(GL_POLYGON_OFFSET_FILL);
   }

   glDrawArrays(GL_TRIANGLES, 0, 3);
   glReadPixels(0, 0, width, height, GL_RED_INTEGER, GL_UNSIGNED_INT,
                pixels);
   CHECK(glGetError() == GL_NO_ERROR);

   struct result result = {
      .first = count,
   };
   for (size_t i = 0; i < count; i++) {
      if (pixels[i] == (uint32_t)i)
         continue;
      if (result.first == count)
         result.first = i;
      result.mismatches++;
   }
   return result;
}

static int
positive_arg(const char *text, const char *program)
{
   char *end;
   long value = strtol(text, &end, 10);
   if (!text[0] || *end || value < 1 || value > (1 << 24)) {
      fprintf(stderr, "usage: %s [width height]\n", program);
      exit(1);
   }
   return (int)value;
}

static void
print_result(const char *name, struct result result, int width)
{
   if (!result.mismatches) {
      printf("%s mismatches=0\n", name);
      return;
   }
   printf("%s mismatches=%zu first=(%zu,%zu)\n", name, result.mismatches,
          result.first % (size_t)width, result.first / (size_t)width);
}

int
main(int argc, char **argv)
{
   int width = 12288;
   int height = 1;
   if (argc > 3) {
      fprintf(stderr, "usage: %s [width height]\n", argv[0]);
      return 1;
   }
   if (argc > 1)
      width = positive_arg(argv[1], argv[0]);
   if (argc > 2)
      height = positive_arg(argv[2], argv[0]);

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

   GLint max_size;
   glGetIntegerv(GL_MAX_TEXTURE_SIZE, &max_size);
   CHECK(width <= max_size && height <= max_size);

   const GLuint vertex = compile(GL_VERTEX_SHADER, vertex_source);
   GLuint programs[2] = {
      link_program(vertex, varying_source),
      link_program(vertex, fragcoord_source),
   };
   for (int i = 0; i < 2; i++) {
      glUseProgram(programs[i]);
      glUniform2f(glGetUniformLocation(programs[i], "extent"),
                  (float)width, (float)height);
      glUniform1i(glGetUniformLocation(programs[i], "source_tex"), 0);
   }

   const size_t count = (size_t)width * (size_t)height;
   uint32_t *source = malloc(count * sizeof(*source));
   uint32_t *pixels = malloc(count * sizeof(*pixels));
   CHECK(source && pixels);
   for (size_t i = 0; i < count; i++)
      source[i] = (uint32_t)i;

   GLuint textures[2];
   glGenTextures(2, textures);
   glBindTexture(GL_TEXTURE_2D, textures[0]);
   glTexStorage2D(GL_TEXTURE_2D, 1, GL_R32UI, width, height);
   glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RED_INTEGER,
                   GL_UNSIGNED_INT, source);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

   glBindTexture(GL_TEXTURE_2D, textures[1]);
   glTexStorage2D(GL_TEXTURE_2D, 1, GL_R32UI, width, height);
   glActiveTexture(GL_TEXTURE0);
   glBindTexture(GL_TEXTURE_2D, textures[0]);

   GLuint framebuffer;
   glGenFramebuffers(1, &framebuffer);
   glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
   glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                          textures[1], 0);
   CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
   glViewport(0, 0, width, height);

   struct result baseline = run(programs[0], 0, pixels, width, height);
   struct result workaround = run(programs[0], 1, pixels, width, height);
   struct result fragcoord = run(programs[1], 0, pixels, width, height);
   print_result("baseline", baseline, width);
   print_result("workaround", workaround, width);
   print_result("fragcoord", fragcoord, width);

   const int pass =
      baseline.mismatches && !workaround.mismatches && !fragcoord.mismatches;
   printf("verdict=%s\n", pass ? "PASS" : "FAIL");
   return pass ? 0 : 2;
}
