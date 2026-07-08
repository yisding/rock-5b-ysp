// RK3588 / proprietary ARM Mali userspace variant of tiny_interp_probe.c.
//
// This keeps the shader, draw, R32UI readback, and CPU checker identical to
// tiny_interp_probe.c. The only behavioral change is EGL setup: Rockchip's
// libmali G610 package is GBM-oriented and exposes EGL_KHR_surfaceless_context,
// while tiny_interp_probe.c asks for Mesa's EGL_PLATFORM_SURFACELESS_MESA. See
// README-arm-blob.md for the exact source-backed capability notes and patch
// rationale.
//
// Build from this directory (the Radxa vendor libmali ships libEGL/libGLESv2/
// libgbm as zero-symbol forwarding stubs under .../mali, so link libmali
// directly -- linking the stubs fails with undefined references):
//        cc -O2 -o tiny_interp_probe_arm_blob tiny_interp_probe_arm_blob.c -lmali -lm
// Run:   ./tiny_interp_probe_arm_blob
//        ./tiny_interp_probe_arm_blob 12288 fragcoord
//        ./tiny_interp_probe_arm_blob 16307 varying /dev/dri/renderD128
//
// DANGER (RK3588 Radxa vendor 5.10 kernel): this GBM path CRASHES THE KERNEL.
// The render node this passes to gbm_create_device is backed by the rockchip-drm
// *display* controller (the Mali GPU itself is /dev/mali0, proprietary kbase, no
// DRM node). libmali's GBM/EGL bring-up opens the primary card node and issues
// the legacy DRM_IOCTL_SET_VERSION on it. On kernel 5.10.110-39-rockchip that
// ioctl handler NULL-derefs:
//
//     Unable to handle kernel NULL pointer dereference at ... 0x10
//     pc : drm_setversion+0x80/0x18c
//     Call trace: drm_setversion / drm_ioctl_kernel / drm_ioctl / __arm64_sys_ioctl
//
// With a compositor holding DRM master the same call instead deadlocks
// uninterruptibly (task in D state, wchan drm_setversion). Either way it wedges
// the GPU/DRM subsystem -- observed cascade includes rk806 PMIC SPI timeouts --
// and requires a reboot or power cycle. This blob has NO surfaceless EGL
// platform (only EGL_KHR_platform_gbm / EGL_KHR_platform_x11), so the crashing
// SET_VERSION is not avoidable from the GBM path. The recommended way to drive
// libmali here is instead as a client under a running X server (the installed
// blob is the x11-gbm variant); see README-arm-blob.md.
//
// Because of the kernel Oops, this program REFUSES TO RUN BY DEFAULT. Only set
// MALI_PROBE_FORCE_SETVERSION=1 if you are on a kernel whose drm_setversion is
// known fixed. See findings/2026-07-08-arm-mali-blob-gbm-setversion-kernel-oops.md.
//
// Exits 0 when every pixel satisfies floor(v) == x, 2 when any pixel fails,
// 1 on usage or EGL/GL setup errors (including the safety gate below).

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <dirent.h>
#include <fcntl.h>
#include <gbm.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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

// Print which DRM driver backs the render node, so the log records that this is
// the rockchip-drm display controller (not a Mali render node -- Mali is
// /dev/mali0). Purely informational; reads sysfs only.
static void
report_drm_driver(const char *node)
{
   const char *base = strrchr(node, '/');
   base = base ? base + 1 : node;

   char link[256], target[256];
   snprintf(link, sizeof(link), "/sys/class/drm/%s/device/driver", base);
   ssize_t n = readlink(link, target, sizeof(target) - 1);
   if (n <= 0)
      return;

   target[n] = '\0';
   const char *drv = strrchr(target, '/');
   drv = drv ? drv + 1 : target;
   fprintf(stderr, "render node %s is backed by DRM driver '%s'\n", node, drv);
}

// Best-effort detection of a running display server. libmali's SET_VERSION on
// the primary card node blocks uninterruptibly when a compositor holds it as
// DRM master, so refusing here turns an unkillable kernel hang into a clean
// exit. Returns the matched process name, or NULL if none is found. Reads
// /proc/<pid>/comm only -- no ioctls, so it cannot itself block on the driver.
static const char *
compositor_running(void)
{
   static const char *const servers[] = {
      "Xorg",      "X",         "weston",       "sway",
      "kwin_wayland", "kwin_x11", "gnome-shell", "labwc",
      "cage",      "wayfire",   "mutter",       "sddm-greeter",
      "Hyprland",  "gamescope", NULL};

   DIR *proc = opendir("/proc");
   if (!proc)
      return NULL;

   static char found[64];
   const char *hit = NULL;
   struct dirent *de;
   while ((de = readdir(proc)) != NULL) {
      if (de->d_name[0] < '0' || de->d_name[0] > '9')
         continue;

      char path[300], comm[64];
      snprintf(path, sizeof(path), "/proc/%s/comm", de->d_name);
      FILE *f = fopen(path, "r");
      if (!f)
         continue;
      if (fgets(comm, sizeof(comm), f)) {
         comm[strcspn(comm, "\n")] = '\0';
         for (int i = 0; servers[i]; i++) {
            if (strcmp(comm, servers[i]) == 0) {
               snprintf(found, sizeof(found), "%s", comm);
               hit = found;
               break;
            }
         }
      }
      fclose(f);
      if (hit)
         break;
   }
   closedir(proc);
   return hit;
}

int
main(int argc, char **argv)
{
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

   report_drm_driver(node);

   // HARD SAFETY GATE. On the RK3588 Radxa vendor kernel (5.10.110-39-rockchip)
   // libmali's GBM/EGL bring-up issues the legacy DRM_IOCTL_SET_VERSION on the
   // rockchip-drm primary node backing this render node, and that ioctl handler
   // NULL-derefs the kernel (Oops at drm_setversion+0x80). Worse, the kernel's
   // own teardown of the faulting task then deadlocks in rockchip_drm_lastclose
   // -> drm_master_internal_acquire, so the task never finishes dying and holds
   // drm_global_mutex forever -- every later DRM open hangs and the box needs a
   // reboot / power cycle. There is no surfaceless EGL platform in this blob to
   // sidestep GBM, so this path is refused by default. Only override if you are
   // on a kernel whose drm_setversion is known fixed. See the header comment and
   // findings/2026-07-08-arm-mali-blob-gbm-setversion-kernel-oops.md.
   if (!getenv("MALI_PROBE_FORCE_SETVERSION")) {
      fprintf(stderr,
              "refusing to run: libmali's GBM/EGL setup calls the legacy\n"
              "  DRM_IOCTL_SET_VERSION on the primary card node backing %s. On the\n"
              "  RK3588 vendor 5.10 kernel that NULL-derefs the kernel (Oops in\n"
              "  drm_setversion) and then deadlocks the Oops teardown in\n"
              "  rockchip_drm_lastclose, wedging DRM until a reboot / power cycle.\n"
              "  Driving libmali as an X11 client avoids SET_VERSION; see\n"
              "  README-arm-blob.md. If your kernel's drm_setversion is fixed,\n"
              "  re-run with MALI_PROBE_FORCE_SETVERSION=1.\n",
              node);
      return 1;
   }

   // Even when forced, refuse if a display server holds DRM master: SET_VERSION
   // then deadlocks uninterruptibly instead of Oopsing. Override separately.
   const char *comp = compositor_running();
   if (comp && !getenv("MALI_PROBE_ALLOW_DRM_MASTER")) {
      fprintf(stderr,
              "refusing to run: display server '%s' is running and likely holds\n"
              "  DRM master on the primary node backing %s; libmali's SET_VERSION\n"
              "  will deadlock uninterruptibly (D state, wchan drm_setversion).\n"
              "  Stop the display manager (e.g. `sudo systemctl stop sddm`) or boot\n"
              "  a non-graphical target, then re-run. Override with\n"
              "  MALI_PROBE_ALLOW_DRM_MASTER=1 if you are sure nothing holds it.\n",
              comp, node);
      return 1;
   }

   int drmfd = open(node, O_RDWR | O_CLOEXEC);
   if (drmfd < 0) {
      perror(node);
      return 1;
   }

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

   EGLint cfg_attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                         EGL_SURFACE_TYPE, 0, EGL_NONE};
   EGLConfig cfg;
   EGLint cfg_count = 0;
   CHECK(eglChooseConfig(dpy, cfg_attrs, &cfg, 1, &cfg_count) && cfg_count);

   EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
   EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
   CHECK(ctx != EGL_NO_CONTEXT);
   CHECK(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx));

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
