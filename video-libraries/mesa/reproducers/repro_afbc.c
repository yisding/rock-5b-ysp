// Pre-existing-path probe: wide AFBC texture CPU readback.
//
// Renders an x-index pattern into a wide RGBA8 texture (AFBC-eligible layout)
// using gl_FragCoord (exact), then reads it back with glReadPixels in the
// MATCHING format. With texture_transfer_modes==0 this takes the CPU fallback,
// which maps the AFBC resource -> pan_resource staging blit (u_blitter TXF).
// Any x shift means the staging blit fetched the wrong texel.

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
   int W = (argc>1)?atoi(argv[1]):4096;
   int H = (argc>2)?atoi(argv[2]):16;

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
   void (*glPixelStorei_)(GLenum,GLint)=GP("glPixelStorei");
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
     "out highp vec4 o;\n"
     "void main(){\n"
     "  int x = int(gl_FragCoord.x);\n"
     "  int y = int(gl_FragCoord.y);\n"
     "  o = vec4(float(x & 255)/255.0, float((x >> 8) & 255)/255.0,\n"
     "           float(y & 255)/255.0, 1.0);\n"
     "}\n";

   GLuint v=glCreateShader_(GL_VERTEX_SHADER); glShaderSource_(v,1,&vs_src,NULL); glCompileShader_(v);
   GLint ok; glGetShaderiv_(v,GL_COMPILE_STATUS,&ok); CHECK(ok);
   GLuint f=glCreateShader_(GL_FRAGMENT_SHADER); glShaderSource_(f,1,&fs_src,NULL); glCompileShader_(f);
   glGetShaderiv_(f,GL_COMPILE_STATUS,&ok); if(!ok){char l[1024];glGetShaderInfoLog_(f,1024,NULL,l);fprintf(stderr,"FS: %s\n",l);return 1;}
   GLuint pr=glCreateProgram_(); glAttachShader_(pr,v); glAttachShader_(pr,f);
   glBindAttribLocation_(pr,0,"pos"); glLinkProgram_(pr);
   glGetProgramiv_(pr,GL_LINK_STATUS,&ok); CHECK(ok);

   GLuint tex; glGenTextures_(1,&tex); glBindTexture_(GL_TEXTURE_2D,tex);
   glTexStorage2D_(GL_TEXTURE_2D,1,GL_RGBA8,W,H);
   GLuint fbo; glGenFramebuffers_(1,&fbo); glBindFramebuffer_(GL_FRAMEBUFFER,fbo);
   glFramebufferTexture2D_(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,tex,0);
   CHECK(glCheckFramebufferStatus_(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE);
   glViewport_(0,0,W,H);

   float verts[] = { -1,-1, 1,-1, 1,1,  -1,-1, 1,1, -1,1 };
   GLuint vao,vbo; glGenVertexArrays_(1,&vao); glBindVertexArray_(vao);
   glGenBuffers_(1,&vbo); glBindBuffer_(GL_ARRAY_BUFFER,vbo);
   glBufferData_(GL_ARRAY_BUFFER,sizeof verts,verts,GL_STATIC_DRAW);
   glVertexAttribPointer_(0,2,GL_FLOAT,GL_FALSE,0,0);
   glEnableVertexAttribArray_(0);

   glUseProgram_(pr);
   glDrawArrays_(GL_TRIANGLES,0,6);
   glFinish_();

   unsigned char *buf=malloc((size_t)W*H*4);
   glReadBuffer_(GL_COLOR_ATTACHMENT0);
   glPixelStorei_(GL_PACK_ALIGNMENT,4);
   glReadPixels_(0,0,W,H,GL_RGBA,GL_UNSIGNED_BYTE,buf);
   fprintf(stderr,"glReadPixels err=0x%x\n",glGetError_());

   long mismatch=0; int first=-1; long shifts[9]={0}; long other=0;
   for(int y=0;y<H;y++) for(int x=0;x<W;x++){
      unsigned char *p=&buf[((size_t)y*W+x)*4];
      int gx = p[0] | (p[1]<<8);
      int gy = p[2];
      if(gx!=(x&0xffff) || gy!=(y&255)){
         mismatch++;
         if(first<0){first=x; fprintf(stderr,"first mismatch at x=%d y=%d: got x=%d y=%d\n",x,y,gx,gy);}
      }
      long s=(long)gx-(long)(x&0xffff);
      if(s>=-4&&s<=4) shifts[s+4]++; else other++;
   }
   printf("W=%d H=%d  mismatches=%ld / %d  (%.2f%%)\n", W,H,mismatch,W*H,100.0*mismatch/((long)W*H));
   printf("x-shift histogram: ");
   for(int s=-4;s<=4;s++) printf("[%+d]=%ld ",s,shifts[s+4]);
   printf("other=%ld\n",other);
   free(buf);
   return mismatch?2:0;
}
