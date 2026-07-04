// Constant-varying interpolation exactness probe for Panfrost/Mali.
//
// The fragcoord-blit u_blitter fix passes the blit affine (scale, offset) as a
// vertex attribute that is CONSTANT across the quad, but still read through the
// smooth (perspective) LD_VAR path. This probe checks whether Mali's varying
// interpolator returns a constant varying bit-exactly at every pixel, even for
// large magnitudes (e.g. offset ~16000 from a blit source box origin).
//
// Renders W x 1, varying v_k = K at all vertices, writes floatBitsToUint(v_k)
// to R32UI, reads back, and counts pixels where bits != K's bits.

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>
#include <gbm.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "fail line %d egl=0x%x\n", __LINE__, eglGetError()); exit(1);} } while(0)

static void *GP(const char *n){ void *p=(void*)eglGetProcAddress(n); if(!p){fprintf(stderr,"missing %s\n",n);exit(1);} return p; }

int main(int argc, char **argv){
   int W = (argc>1)?atoi(argv[1]):16307;
   float K = (argc>2)?strtof(argv[2],NULL):16000.25f;

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
   void (*glGetProgramInfoLog_)(GLuint,GLsizei,GLsizei*,GLchar*)=GP("glGetProgramInfoLog");
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
   GLenum (*glGetError_)(void)=GP("glGetError");

   fprintf(stderr,"GL_RENDERER=%s\nGL_VERSION=%s\n",
           (const char*)glGetString_(GL_RENDERER),
           (const char*)glGetString_(GL_VERSION));

   const char *vs_src =
     "#version 310 es\n"
     "in vec2 pos;\n"
     "in float k;\n"
     "out highp float v_k;\n"
     "void main(){ v_k = k; gl_Position = vec4(pos,0.0,1.0); }\n";
   const char *fs_src =
     "#version 310 es\n"
     "precision highp float; precision highp int;\n"
     "in highp float v_k;\n"
     "out highp uint o;\n"
     "void main(){ o = floatBitsToUint(v_k); }\n";

   GLuint v=glCreateShader_(GL_VERTEX_SHADER); glShaderSource_(v,1,&vs_src,NULL); glCompileShader_(v);
   GLint ok; glGetShaderiv_(v,GL_COMPILE_STATUS,&ok); if(!ok){char l[1024];glGetShaderInfoLog_(v,1024,NULL,l);fprintf(stderr,"VS: %s\n",l);return 1;}
   GLuint f=glCreateShader_(GL_FRAGMENT_SHADER); glShaderSource_(f,1,&fs_src,NULL); glCompileShader_(f);
   glGetShaderiv_(f,GL_COMPILE_STATUS,&ok); if(!ok){char l[1024];glGetShaderInfoLog_(f,1024,NULL,l);fprintf(stderr,"FS: %s\n",l);return 1;}
   GLuint pr=glCreateProgram_(); glAttachShader_(pr,v); glAttachShader_(pr,f);
   glBindAttribLocation_(pr,0,"pos"); glBindAttribLocation_(pr,1,"k");
   glLinkProgram_(pr); glGetProgramiv_(pr,GL_LINK_STATUS,&ok); if(!ok){char l[1024];glGetProgramInfoLog_(pr,1024,NULL,l);fprintf(stderr,"LINK: %s\n",l);return 1;}

   GLuint tex; glGenTextures_(1,&tex); glBindTexture_(GL_TEXTURE_2D,tex);
   glTexStorage2D_(GL_TEXTURE_2D,1,GL_R32UI,W,1);
   GLuint fbo; glGenFramebuffers_(1,&fbo); glBindFramebuffer_(GL_FRAMEBUFFER,fbo);
   glFramebufferTexture2D_(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,tex,0);
   if(glCheckFramebufferStatus_(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE){fprintf(stderr,"fbo bad\n");return 1;}
   glViewport_(0,0,W,1);

   float verts[] = {
     -1.f,-1.f, K,   1.f,-1.f, K,  1.f, 1.f, K,
     -1.f,-1.f, K,   1.f, 1.f, K, -1.f, 1.f, K,
   };
   GLuint vao,vbo; glGenVertexArrays_(1,&vao); glBindVertexArray_(vao);
   glGenBuffers_(1,&vbo); glBindBuffer_(GL_ARRAY_BUFFER,vbo);
   glBufferData_(GL_ARRAY_BUFFER,sizeof verts,verts,GL_STATIC_DRAW);
   glVertexAttribPointer_(0,2,GL_FLOAT,GL_FALSE,3*sizeof(float),(void*)0);
   glEnableVertexAttribArray_(0);
   glVertexAttribPointer_(1,1,GL_FLOAT,GL_FALSE,3*sizeof(float),(void*)(2*sizeof(float)));
   glEnableVertexAttribArray_(1);

   glUseProgram_(pr);
   glDrawArrays_(GL_TRIANGLES,0,6);
   glFinish_();

   unsigned *buf=malloc((size_t)W*sizeof(unsigned));
   glReadBuffer_(GL_COLOR_ATTACHMENT0);
   glReadPixels_(0,0,W,1,GL_RED_INTEGER,GL_UNSIGNED_INT,buf);
   fprintf(stderr,"glReadPixels err=0x%x\n",glGetError_());

   unsigned kbits; memcpy(&kbits,&K,4);
   long mismatch=0; float worst=0; int worst_i=-1;
   for(int i=0;i<W;i++){
      if(buf[i]!=kbits){
         mismatch++;
         float got; memcpy(&got,&buf[i],4);
         float err=fabsf(got-K);
         if(err>worst){worst=err;worst_i=i;}
      }
   }
   printf("K=%.6f (bits=0x%08x) W=%d  bit_mismatches=%ld / %d\n", K, kbits, W, mismatch, W);
   if(mismatch){
      float got; memcpy(&got,&buf[worst_i],4);
      printf("   worst at i=%d: got=%.6f err=%+.6f rel=%.3e\n", worst_i, got, got-K, (got-K)/K);
   }
   free(buf);
   return 0;
}
