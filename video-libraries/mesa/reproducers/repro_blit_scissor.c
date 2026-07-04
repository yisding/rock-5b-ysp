// Scissored wide-blit probe for the fragcoord u_blitter fix.
//
// glScissor applies to glBlitFramebuffer. u_blitter forwards it as scissor
// state while the fragcoord path derives the source texel purely from the
// fragment position, so clipping must not shift the mapping. This probe does
// an identity blit of a wide non-pow2 RG32UI texture with a scissor rect,
// then verifies texels inside the scissor are exactly mapped and texels
// outside are untouched (sentinel from a pre-blit clear).

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
   void (*glScissor_)(GLint,GLint,GLsizei,GLsizei)=GP("glScissor");
   void (*glEnable_)(GLenum)=GP("glEnable");
   void (*glDisable_)(GLenum)=GP("glDisable");
   void (*glClearBufferuiv_)(GLenum,GLint,const GLuint*)=GP("glClearBufferuiv");
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

   int sx = W/3, sw = W/2;      // scissor x range [sx, sx+sw)
   int sy = H/4, sh = H/2;      // scissor y range [sy, sy+sh)

   // pre-fill dst with a sentinel
   glBindFramebuffer_(GL_FRAMEBUFFER,fbo[1]);
   const GLuint sent[4] = {0xDEADBEEFu, 0xCAFEF00Du, 0, 0};
   glClearBufferuiv_(GL_COLOR, 0, sent);

   glBindFramebuffer_(GL_READ_FRAMEBUFFER,fbo[0]);
   glReadBuffer_(GL_COLOR_ATTACHMENT0);
   glBindFramebuffer_(GL_DRAW_FRAMEBUFFER,fbo[1]);
   glEnable_(GL_SCISSOR_TEST);
   glScissor_(sx, sy, sw, sh);
   glBlitFramebuffer_(0,0,W,H, 0,0,W,H, GL_COLOR_BUFFER_BIT, GL_NEAREST);
   glDisable_(GL_SCISSOR_TEST);
   GLenum err=glGetError_();
   if(err){fprintf(stderr,"blit err=0x%x\n",err);return 1;}

   glBindFramebuffer_(GL_READ_FRAMEBUFFER,fbo[1]);
   glReadBuffer_(GL_COLOR_ATTACHMENT0);
   memset(buf,0,(size_t)W*H*2*sizeof(unsigned));
   glReadPixels_(0,0,W,H,GL_RG_INTEGER,GL_UNSIGNED_INT,buf);
   err=glGetError_();
   if(err){fprintf(stderr,"readpixels err=0x%x\n",err);return 1;}

   long bad_in=0, bad_out=0; int bx=-1,by=-1;
   for(int y=0;y<H;y++) for(int x=0;x<W;x++){
      unsigned gx=buf[((size_t)y*W+x)*2], gy=buf[((size_t)y*W+x)*2+1];
      int inside = x>=sx && x<sx+sw && y>=sy && y<sy+sh;
      if(inside){
         if(gx!=(unsigned)x||gy!=(unsigned)y){ bad_in++; if(bx<0){bx=x;by=y;} }
      } else {
         if(gx!=sent[0]||gy!=sent[1]) bad_out++;
      }
   }
   printf("W=%d H=%d scissor=(%d,%d %dx%d)\n", W,H,sx,sy,sw,sh);
   printf("inside scissor : mismatches=%ld / %ld", bad_in, (long)sw*sh);
   if(bad_in){
      unsigned gx=buf[((size_t)by*W+bx)*2], gy=buf[((size_t)by*W+bx)*2+1];
      printf("   first at (%d,%d): got {%u,%u}", bx,by,gx,gy);
   }
   printf("\noutside scissor: overwritten=%ld / %ld\n", bad_out, (long)W*H-(long)sw*sh);
   long total_bad = bad_in + bad_out;
   free(buf);
   return total_bad?2:0;
}
