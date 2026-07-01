// Coordinate-interpolation precision probe for Panfrost/Mali.
// Renders a W x 1 quad with a vertex attribute tc that runs 0..W across the
// quad (exactly like u_blitter's TXF coordinate), and outputs the interpolated
// coordinate bit-exactly to an R32UI target as floatBitsToUint. Then compares
// the read-back interpolated value to the ideal (i + 0.5).
//
// Modes: SMOOTH (perspective), NOPERSPECTIVE, and gl_FragCoord.x.
// This isolates LD_VAR interpolation precision from the blit/f2i machinery.

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

typedef const GLubyte* (*t_gs)(GLenum);
typedef GLuint (*t_cs)(GLenum);
typedef void (*t_ss)(GLuint,GLsizei,const GLchar*const*,const GLint*);
typedef void (*t_cmp)(GLuint);
typedef void (*t_gsiv)(GLuint,GLenum,GLint*);
typedef GLuint (*t_cp)(void);
typedef void (*t_ap)(GLuint,GLuint);
typedef void (*t_lp)(GLuint);
typedef void (*t_use)(GLuint);
typedef void (*t_gsl)(GLuint,GLsizei,GLsizei*,GLchar*);

int main(int argc, char **argv){
   int W = (argc>1)?atoi(argv[1]):16307;
   int mode = (argc>2)?atoi(argv[2]):0; // 0=smooth 1=noperspective 2=fragcoord

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

   t_gs   glGetString_=GP("glGetString");
   void (*glGenTextures_)(GLsizei,GLuint*)=GP("glGenTextures");
   void (*glBindTexture_)(GLenum,GLuint)=GP("glBindTexture");
   void (*glTexStorage2D_)(GLenum,GLsizei,GLenum,GLsizei,GLsizei)=GP("glTexStorage2D");
   void (*glTexParameteri_)(GLenum,GLenum,GLint)=GP("glTexParameteri");
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

   fprintf(stderr,"GL_RENDERER=%s\n",(const char*)glGetString_(GL_RENDERER));

   const char *interp = mode==1?"noperspective":"";
   char vs[512], fs[512];
   snprintf(vs,sizeof vs,
     "#version 310 es\n"
     "in vec2 pos;\n"
     "in float tc;\n"
     "%s out highp float v_tc;\n"
     "void main(){ v_tc = tc; gl_Position = vec4(pos,0.0,1.0); }\n", interp);
   if (mode==2)
     snprintf(fs,sizeof fs,
       "#version 310 es\n"
       "precision highp float; precision highp int;\n"
       "out highp uint o;\n"
       "void main(){ o = floatBitsToUint(gl_FragCoord.x); }\n");
   else
     snprintf(fs,sizeof fs,
       "#version 310 es\n"
       "precision highp float; precision highp int;\n"
       "%s in highp float v_tc;\n"
       "out highp uint o;\n"
       "void main(){ o = floatBitsToUint(v_tc); }\n", interp);

   GLuint v=glCreateShader_(GL_VERTEX_SHADER); const char*vp=vs; glShaderSource_(v,1,&vp,NULL); glCompileShader_(v);
   GLint ok; glGetShaderiv_(v,GL_COMPILE_STATUS,&ok); if(!ok){char l[1024];glGetShaderInfoLog_(v,1024,NULL,l);fprintf(stderr,"VS: %s\n",l);return 1;}
   GLuint f=glCreateShader_(GL_FRAGMENT_SHADER); const char*fp=fs; glShaderSource_(f,1,&fp,NULL); glCompileShader_(f);
   glGetShaderiv_(f,GL_COMPILE_STATUS,&ok); if(!ok){char l[1024];glGetShaderInfoLog_(f,1024,NULL,l);fprintf(stderr,"FS: %s\n",l);return 1;}
   GLuint pr=glCreateProgram_(); glAttachShader_(pr,v); glAttachShader_(pr,f);
   glBindAttribLocation_(pr,0,"pos"); glBindAttribLocation_(pr,1,"tc");
   glLinkProgram_(pr); glGetProgramiv_(pr,GL_LINK_STATUS,&ok); if(!ok){char l[1024];glGetProgramInfoLog_(pr,1024,NULL,l);fprintf(stderr,"LINK: %s\n",l);return 1;}

   GLuint tex; glGenTextures_(1,&tex); glBindTexture_(GL_TEXTURE_2D,tex);
   glTexStorage2D_(GL_TEXTURE_2D,1,GL_R32UI,W,1);
   GLuint fbo; glGenFramebuffers_(1,&fbo); glBindFramebuffer_(GL_FRAMEBUFFER,fbo);
   glFramebufferTexture2D_(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,tex,0);
   if(glCheckFramebufferStatus_(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE){fprintf(stderr,"fbo bad\n");return 1;}
   glViewport_(0,0,W,1);

   // Fullscreen quad (two triangles), tc runs 0 at left edge (x=-1) to W at right edge (x=+1).
   // At pixel center i (window x=i+0.5), ideal interpolated tc = i+0.5.
   float verts[] = {
     -1.f,-1.f, 0.f,   1.f,-1.f, (float)W,  1.f, 1.f, (float)W,
     -1.f,-1.f, 0.f,   1.f, 1.f, (float)W, -1.f, 1.f, 0.f,
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

   const char *mname = mode==0?"SMOOTH":mode==1?"NOPERSPECTIVE":"FRAGCOORD.x";
   printf("mode=%s W=%d\n", mname, W);
   printf("i : interp_tc : ideal(i+0.5) : abs_err : floor(interp) vs i\n");
   long floor_mismatch=0; double maxrel=0;
   for(int i=0;i<W;i++){
      float tc; memcpy(&tc,&buf[i],4);
      double ideal=i+0.5;
      double err=tc-ideal;
      if((long)floorf(tc)!=i) floor_mismatch++;
      double rel = fabs(err)/(ideal);
      if(rel>maxrel) maxrel=rel;
   }
   printf("floor(interp)!=i count = %ld / %d   max_rel_err=%.3e (log2=%.2f)\n",
          floor_mismatch, W, maxrel, maxrel>0?log2(maxrel):0);
   for(int i=256;i<W;i*=2){
      float tc; memcpy(&tc,&buf[i],4);
      printf("   i=%-7d interp=%.4f ideal=%.1f err=%+.4f floor=%ld\n",
             i, tc, i+0.5, tc-(i+0.5), (long)floorf(tc));
   }
   { int i=W-1; float tc; memcpy(&tc,&buf[i],4);
     printf("   i=%-7d interp=%.4f ideal=%.1f err=%+.4f floor=%ld\n",
            i, tc, i+0.5, tc-(i+0.5), (long)floorf(tc)); }
   free(buf);
   return 0;
}
