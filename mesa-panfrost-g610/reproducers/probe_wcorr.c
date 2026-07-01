// Probe: can the FS recover the exact interpolated coordinate from gl_FragCoord.w?
// Outputs, per pixel, the perspective-interpolated tc AND gl_FragCoord.w, so we can
// test offline whether interp/w or interp*w (etc.) cancels the ~2^-10 perspective error.
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
#define CHECK(x) do{ if(!(x)){fprintf(stderr,"fail %d egl=0x%x\n",__LINE__,eglGetError());exit(1);} }while(0)
static void *GP(const char*n){void*p=(void*)eglGetProcAddress(n); if(!p){fprintf(stderr,"miss %s\n",n);exit(1);} return p;}
int main(int argc,char**argv){
  int W=(argc>1)?atoi(argv[1]):16307;
  int drmfd=open("/dev/dri/renderD128",O_RDWR|O_CLOEXEC);CHECK(drmfd>=0);
  struct gbm_device*gbm=gbm_create_device(drmfd);CHECK(gbm);
  PFNEGLGETPLATFORMDISPLAYEXTPROC gpd=(PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
  EGLDisplay dpy=gpd(EGL_PLATFORM_GBM_KHR,gbm,NULL);CHECK(dpy!=EGL_NO_DISPLAY);
  CHECK(eglInitialize(dpy,NULL,NULL));CHECK(eglBindAPI(EGL_OPENGL_ES_API));
  EGLint a[]={EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT,EGL_NONE};EGLConfig c;EGLint n;
  CHECK(eglChooseConfig(dpy,a,&c,1,&n)&&n>0);
  EGLint ca[]={EGL_CONTEXT_MAJOR_VERSION,3,EGL_CONTEXT_MINOR_VERSION,1,EGL_NONE};
  EGLContext ctx=eglCreateContext(dpy,c,EGL_NO_CONTEXT,ca);CHECK(ctx!=EGL_NO_CONTEXT);
  CHECK(eglMakeCurrent(dpy,EGL_NO_SURFACE,EGL_NO_SURFACE,ctx));
  void(*GenTex)(GLsizei,GLuint*)=GP("glGenTextures");void(*BindTex)(GLenum,GLuint)=GP("glBindTexture");
  void(*TexStor)(GLenum,GLsizei,GLenum,GLsizei,GLsizei)=GP("glTexStorage2D");
  void(*GenFB)(GLsizei,GLuint*)=GP("glGenFramebuffers");void(*BindFB)(GLenum,GLuint)=GP("glBindFramebuffer");
  void(*FBTex)(GLenum,GLenum,GLenum,GLuint,GLint)=GP("glFramebufferTexture2D");
  void(*VP)(GLint,GLint,GLsizei,GLsizei)=GP("glViewport");
  GLuint(*CrSh)(GLenum)=GP("glCreateShader");void(*ShSrc)(GLuint,GLsizei,const GLchar*const*,const GLint*)=GP("glShaderSource");
  void(*CmpSh)(GLuint)=GP("glCompileShader");void(*GetShiv)(GLuint,GLenum,GLint*)=GP("glGetShaderiv");
  void(*GetShLog)(GLuint,GLsizei,GLsizei*,GLchar*)=GP("glGetShaderInfoLog");
  GLuint(*CrPr)(void)=GP("glCreateProgram");void(*Att)(GLuint,GLuint)=GP("glAttachShader");
  void(*Lnk)(GLuint)=GP("glLinkProgram");void(*GetPriv)(GLuint,GLenum,GLint*)=GP("glGetProgramiv");
  void(*Use)(GLuint)=GP("glUseProgram");void(*GenB)(GLsizei,GLuint*)=GP("glGenBuffers");
  void(*BindB)(GLenum,GLuint)=GP("glBindBuffer");void(*BufD)(GLenum,GLsizeiptr,const void*,GLenum)=GP("glBufferData");
  void(*GenVA)(GLsizei,GLuint*)=GP("glGenVertexArrays");void(*BindVA)(GLuint)=GP("glBindVertexArray");
  void(*VAP)(GLuint,GLint,GLenum,GLboolean,GLsizei,const void*)=GP("glVertexAttribPointer");
  void(*EnVA)(GLuint)=GP("glEnableVertexAttribArray");void(*BindAL)(GLuint,GLuint,const GLchar*)=GP("glBindAttribLocation");
  void(*Draw)(GLenum,GLint,GLsizei)=GP("glDrawArrays");void(*RP)(GLint,GLint,GLsizei,GLsizei,GLenum,GLenum,void*)=GP("glReadPixels");
  void(*Fin)(void)=GP("glFinish");void(*RB)(GLenum)=GP("glReadBuffer");

  const char*vs="#version 310 es\nin vec2 pos;in float tc;out highp float v;void main(){v=tc;gl_Position=vec4(pos,0.,1.);}";
  // Output interp tc and gl_FragCoord.w bit-exactly to RG32UI.
  const char*fs="#version 310 es\nprecision highp float;precision highp int;in highp float v;out highp uvec2 o;"
                "void main(){ o=uvec2(floatBitsToUint(v), floatBitsToUint(dFdx(v))); }";
  GLuint V=CrSh(GL_VERTEX_SHADER);ShSrc(V,1,&vs,0);CmpSh(V);GLint ok;GetShiv(V,GL_COMPILE_STATUS,&ok);
  if(!ok){char l[999];GetShLog(V,999,0,l);fprintf(stderr,"VS %s\n",l);return 1;}
  GLuint F=CrSh(GL_FRAGMENT_SHADER);ShSrc(F,1,&fs,0);CmpSh(F);GetShiv(F,GL_COMPILE_STATUS,&ok);
  if(!ok){char l[999];GetShLog(F,999,0,l);fprintf(stderr,"FS %s\n",l);return 1;}
  GLuint P=CrPr();Att(P,V);Att(P,F);BindAL(P,0,"pos");BindAL(P,1,"tc");Lnk(P);GetPriv(P,GL_LINK_STATUS,&ok);
  if(!ok){char l[999];GetShLog(P,999,0,l);fprintf(stderr,"LNK %s\n",l);return 1;}
  GLuint tex;GenTex(1,&tex);BindTex(GL_TEXTURE_2D,tex);TexStor(GL_TEXTURE_2D,1,GL_RG32UI,W,1);
  GLuint fb;GenFB(1,&fb);BindFB(GL_FRAMEBUFFER,fb);FBTex(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,tex,0);
  VP(0,0,W,1);
  float verts[]={-1,-1,0, 1,-1,(float)W, 1,1,(float)W, -1,-1,0, 1,1,(float)W, -1,1,0};
  GLuint vao,vbo;GenVA(1,&vao);BindVA(vao);GenB(1,&vbo);BindB(GL_ARRAY_BUFFER,vbo);
  BufD(GL_ARRAY_BUFFER,sizeof verts,verts,GL_STATIC_DRAW);
  VAP(0,2,GL_FLOAT,GL_FALSE,12,0);EnVA(0);VAP(1,1,GL_FLOAT,GL_FALSE,12,(void*)8);EnVA(1);
  Use(P);Draw(GL_TRIANGLES,0,6);Fin();
  unsigned*buf=malloc((size_t)W*2*sizeof(unsigned));
  RB(GL_COLOR_ATTACHMENT0);RP(0,0,W,1,GL_RG_INTEGER,GL_UNSIGNED_INT,buf);
  // Evaluate candidate corrections.
  long bad_raw=0,bad_divd=0;
  for(int i=0;i<W;i++){
    float tc,d; memcpy(&tc,&buf[i*2+0],4); memcpy(&d,&buf[i*2+1],4);
    if((long)floorf(tc)!=i) bad_raw++;
    if((long)floor((double)tc/(double)d)!=i) bad_divd++;   // reconstruct via local slope
  }
  printf("W=%d\n",W);
  printf("raw floor(tc)!=i            : %ld\n",bad_raw);
  printf("floor(tc / dFdx(tc))!=i     : %ld\n",bad_divd);
  for(int i=256;i<W;i*=2){
    float tc,d;memcpy(&tc,&buf[i*2],4);memcpy(&d,&buf[i*2+1],4);
    printf("  i=%-7d tc=%.4f dFdx=%.9f  tc/dFdx=%.4f  err=%+.4f\n",i,tc,d,tc/d,tc/d-(i+0.5));
  }
  {int i=W-1;float tc,d;memcpy(&tc,&buf[i*2],4);memcpy(&d,&buf[i*2+1],4);
   printf("  i=%-7d tc=%.4f dFdx=%.9f  tc/dFdx=%.4f  err=%+.4f\n",i,tc,d,tc/d,tc/d-(i+0.5));}
  return 0;
}
