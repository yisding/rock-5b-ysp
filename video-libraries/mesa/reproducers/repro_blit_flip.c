// Flip-blit probe for the fragcoord u_blitter fix: exercises NEGATIVE scale.
//
// glBlitFramebuffer with flipped coordinates is an unscaled nearest blit, so
// u_blitter takes the TXF path with scale = -1 on the flipped axis. The
// fragcoord fix reconstructs src = floor(frag) * scale + offset', so this is
// the one affine case (negative scale) the offset-0 and subregion repros
// never hit. It caught a real bug during development: panfrost's TGSI
// position system value is the INTEGER pixel index (not x+0.5), and without
// the half-texel bias folded into offset', every flipped fetch lands one
// texel off (row/column 0 out of bounds).
//
// IMPORTANT width choice: the varying-interpolation drift this fix addresses
// only occurs for NON-POWER-OF-TWO primitive extents on Mali-G610 (1-row
// identity blits: W=8192/16384 exact; W=5000/8193/12000/16307 drift, e.g.
// W=16307 -> 15672/16307 wrong, first at x=623). The interpolator's
// plane-equation reciprocal is exact for powers of two. Default W=16307.
//
// Renders {x, y} into an RG32UI texture (via gl_FragCoord, exact), then
// glBlitFramebuffer()s it into a second RG32UI texture three ways:
//   mode 0: identity        dst[y][x] == {x, y}
//   mode 1: Y flip          dst[y][x] == {x, H-1-y}
//   mode 2: X flip          dst[y][x] == {W-1-x, y}
//   mode 3: XY flip         dst[y][x] == {W-1-x, H-1-y}
// and verifies every destination texel via glReadPixels in the MATCHING
// format (CPU map path, exact).

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>
#include <gbm.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "fail line %d egl=0x%x\n", __LINE__, eglGetError()); exit(1);} } while(0)
static void *GP(const char *n){ void *p=(void*)eglGetProcAddress(n); if(!p){fprintf(stderr,"missing %s\n",n);exit(1);} return p; }

int main(int argc, char **argv){
   int W = (argc>1)?atoi(argv[1]):16307;
   int H = (argc>2)?atoi(argv[2]):8;

   int drmfd = open("/dev/dri/renderD128", O_RDWR|O_CLOEXEC); CHECK(drmfd>=0);
   struct gbm_device *gbm = gbm_create_device(drmfd); CHECK(gbm);
   PFNEGLGETPLATFORMDISPLAYEXTPROC gpd=(PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
   EGLDisplay dpy=gpd(EGL_PLATFORM_GBM_KHR,gbm,NULL); CHECK(dpy!=EGL_NO_DISPLAY);
   CHECK(eglInitialize(dpy,NULL,NULL)); CHECK(eglBindAPI(EGL_OPENGL_ES_API));
   EGLint ca[]={EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT,EGL_NONE}; EGLConfig cfg; EGLint n;
   CHECK(eglChooseConfig(dpy,ca,&cfg,1,&n)&&n>0);
   EGLint cta[]={EGL_CONTEXT_MAJOR_VERSION,3,EGL_CONTEXT_MINOR_VERSION,1,EGL_NONE};
   EGLContext ctx=eglCreateContext(dpy,cfg,EGL_NO_CONTEXT,cta); CHECK(ctx!=EGL_NO_CONTEXT);
   CHECK(eglMakeCurrent(dpy,EGL_NO_SURFACE,EGL_NO_SURFACE,ctx));

   const GLubyte* (*glGetString_)(GLenum)=GP("glGetString");
   void (*glGenTextures_)(GLsizei,GLuint*)=GP("glGenTextures");
   void (*glBindTexture_)(GLenum,GLuint)=GP("glBindTexture");
   void (*glTexStorage2D_)(GLenum,GLsizei,GLenum,GLsizei,GLsizei)=GP("glTexStorage2D");
   void (*glGenFramebuffers_)(GLsizei,GLuint*)=GP("glGenFramebuffers");
   void (*glBindFramebuffer_)(GLenum,GLuint)=GP("glBindFramebuffer");
   void (*glFramebufferTexture2D_)(GLenum,GLenum,GLenum,GLuint,GLint)=GP("glFramebufferTexture2D");
   GLenum (*glCheckFramebufferStatus_)(GLenum)=GP("glCheckFramebufferStatus");
   void (*glViewport_)(GLint,GLint,GLsizei,GLsizei)=GP("glViewport");
   GLuint (*glCreateShader_)(GLenum)=GP("glCreateShader");
   void (*glShaderSource_)(GLuint,GLsizei,const GLchar*const*,const GLint*)=GP("glShaderSource");
   void (*glCompileShader_)(GLuint)=GP("glCompileShader");
   void (*glGetShaderiv_)(GLuint,GLenum,GLint*)=GP("glGetShaderiv");
   void (*glGetShaderInfoLog_)(GLuint,GLsizei,GLsizei*,GLchar*)=GP("glGetShaderInfoLog");
   GLuint (*glCreateProgram_)(void)=GP("glCreateProgram");
   void (*glAttachShader_)(GLuint,GLuint)=GP("glAttachShader");
   void (*glLinkProgram_)(GLuint)=GP("glLinkProgram");
   void (*glGetProgramiv_)(GLuint,GLenum,GLint*)=GP("glGetProgramiv");
   void (*glUseProgram_)(GLuint)=GP("glUseProgram");
   void (*glGenBuffers_)(GLsizei,GLuint*)=GP("glGenBuffers");
   void (*glBindBuffer_)(GLenum,GLuint)=GP("glBindBuffer");
   void (*glBufferData_)(GLenum,GLsizeiptr,const void*,GLenum)=GP("glBufferData");
   void (*glGenVertexArrays_)(GLsizei,GLuint*)=GP("glGenVertexArrays");
   void (*glBindVertexArray_)(GLuint)=GP("glBindVertexArray");
   void (*glVertexAttribPointer_)(GLuint,GLint,GLenum,GLboolean,GLsizei,const void*)=GP("glVertexAttribPointer");
   void (*glEnableVertexAttribArray_)(GLuint)=GP("glEnableVertexAttribArray");
   void (*glBindAttribLocation_)(GLuint,GLuint,const GLchar*)=GP("glBindAttribLocation");
   void (*glDrawArrays_)(GLenum,GLint,GLsizei)=GP("glDrawArrays");
   void (*glReadPixels_)(GLint,GLint,GLsizei,GLsizei,GLenum,GLenum,void*)=GP("glReadPixels");
   void (*glFinish_)(void)=GP("glFinish");
   void (*glReadBuffer_)(GLenum)=GP("glReadBuffer");
   void (*glBlitFramebuffer_)(GLint,GLint,GLint,GLint,GLint,GLint,GLint,GLint,GLbitfield,GLenum)=GP("glBlitFramebuffer");
   GLenum (*glGetError_)(void)=GP("glGetError");

   fprintf(stderr,"GL_RENDERER=%s\nGL_VERSION=%s\n",
           (const char*)glGetString_(GL_RENDERER),(const char*)glGetString_(GL_VERSION));

   const char *vs_src =
     "#version 310 es\n"
     "in vec2 pos;\n"
     "void main(){ gl_Position = vec4(pos,0.0,1.0); }\n";
   const char *fs_src =
     "#version 310 es\n"
     "precision highp float; precision highp int;\n"
     "out highp uvec2 o;\n"
     "void main(){ o = uvec2(uint(gl_FragCoord.x), uint(gl_FragCoord.y)); }\n";

   GLuint v=glCreateShader_(GL_VERTEX_SHADER); glShaderSource_(v,1,&vs_src,NULL); glCompileShader_(v);
   GLint ok; glGetShaderiv_(v,GL_COMPILE_STATUS,&ok); CHECK(ok);
   GLuint f=glCreateShader_(GL_FRAGMENT_SHADER); glShaderSource_(f,1,&fs_src,NULL); glCompileShader_(f);
   glGetShaderiv_(f,GL_COMPILE_STATUS,&ok); if(!ok){char l[1024];glGetShaderInfoLog_(f,1024,NULL,l);fprintf(stderr,"FS: %s\n",l);return 1;}
   GLuint pr=glCreateProgram_(); glAttachShader_(pr,v); glAttachShader_(pr,f);
   glBindAttribLocation_(pr,0,"pos"); glLinkProgram_(pr);
   glGetProgramiv_(pr,GL_LINK_STATUS,&ok); CHECK(ok);

   GLuint tex[2]; glGenTextures_(2,tex);
   GLuint fbo[2]; glGenFramebuffers_(2,fbo);
   for(int i=0;i<2;i++){
      glBindTexture_(GL_TEXTURE_2D,tex[i]);
      glTexStorage2D_(GL_TEXTURE_2D,1,GL_RG32UI,W,H);
      glBindFramebuffer_(GL_FRAMEBUFFER,fbo[i]);
      glFramebufferTexture2D_(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,tex[i],0);
      CHECK(glCheckFramebufferStatus_(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE);
   }

   float verts[] = { -1,-1, 1,-1, 1,1,  -1,-1, 1,1, -1,1 };
   GLuint vao,vbo; glGenVertexArrays_(1,&vao); glBindVertexArray_(vao);
   glGenBuffers_(1,&vbo); glBindBuffer_(GL_ARRAY_BUFFER,vbo);
   glBufferData_(GL_ARRAY_BUFFER,sizeof verts,verts,GL_STATIC_DRAW);
   glVertexAttribPointer_(0,2,GL_FLOAT,GL_FALSE,0,0);
   glEnableVertexAttribArray_(0);

   glBindFramebuffer_(GL_FRAMEBUFFER,fbo[0]);
   glViewport_(0,0,W,H);
   glUseProgram_(pr);
   glDrawArrays_(GL_TRIANGLES,0,6);
   glFinish_();

   unsigned *buf=malloc((size_t)W*H*2*sizeof(unsigned));
   long total_bad=0;

   for(int mode=0;mode<4;mode++){
      int fx = (mode==2||mode==3), fy = (mode==1||mode==3);

      glBindFramebuffer_(GL_READ_FRAMEBUFFER,fbo[0]);
      glReadBuffer_(GL_COLOR_ATTACHMENT0);
      glBindFramebuffer_(GL_DRAW_FRAMEBUFFER,fbo[1]);
      glBlitFramebuffer_(0,0,W,H,
                         fx?W:0, fy?H:0, fx?0:W, fy?0:H,
                         GL_COLOR_BUFFER_BIT, GL_NEAREST);
      GLenum err=glGetError_();
      if(err){fprintf(stderr,"mode %d blit err=0x%x\n",mode,err);return 1;}

      glBindFramebuffer_(GL_READ_FRAMEBUFFER,fbo[1]);
      glReadBuffer_(GL_COLOR_ATTACHMENT0);
      memset(buf,0xCD,(size_t)W*H*2*sizeof(unsigned));
      glReadPixels_(0,0,W,H,GL_RG_INTEGER,GL_UNSIGNED_INT,buf);
      err=glGetError_();
      if(err){fprintf(stderr,"mode %d readpixels err=0x%x\n",mode,err);return 1;}

      long bad=0; int bx=-1,by=-1;
      for(int y=0;y<H;y++) for(int x=0;x<W;x++){
         unsigned ex = fx ? (unsigned)(W-1-x) : (unsigned)x;
         unsigned ey = fy ? (unsigned)(H-1-y) : (unsigned)y;
         unsigned gx=buf[((size_t)y*W+x)*2], gy=buf[((size_t)y*W+x)*2+1];
         if(gx!=ex||gy!=ey){ bad++; if(bx<0){bx=x;by=y;} }
      }
      const char *name = mode==0?"identity":mode==1?"Y-flip  ":mode==2?"X-flip  ":"XY-flip ";
      printf("mode %s : mismatches=%ld / %d", name, bad, W*H);
      if(bad){
         unsigned gx=buf[((size_t)by*W+bx)*2], gy=buf[((size_t)by*W+bx)*2+1];
         printf("   first at (%d,%d): got {%u,%u}", bx,by,gx,gy);
      }
      printf("\n");
      total_bad+=bad;
   }
   free(buf);
   return total_bad?2:0;
}
