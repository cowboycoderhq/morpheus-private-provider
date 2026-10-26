// sel-trace-cls.c — T2 follow-up (2026-10-22): the IOKit external-method selectors per
// user-client service class (IOServiceOpen port map). DYLD_INSERT_LIBRARIES into an
// ad hoc probe without the hardened runtime.
// build: clang -dynamiclib -O1 -framework IOKit -o sel-trace-cls.dylib sel-trace-cls.c
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#define DYLD_INTERPOSE(_r,_o) __attribute__((used)) static struct{const void*r;const void*o;} _i_##_o __attribute__((section("__DATA,__interpose")))={(const void*)(unsigned long)&_r,(const void*)(unsigned long)&_o};
static mach_port_t P[64];static char N[64][128];static int np;
static const char*cn(mach_port_t c){for(int i=0;i<np;i++)if(P[i]==c)return N[i];return "?";}
static void note(mach_port_t c,const char*f,uint32_t s,kern_return_t r){fprintf(stderr,"cls %s %s sel=%u rc=0x%x port=%u\n",cn(c),f,s,r,c);}
static kern_return_t so(io_service_t sv,task_port_t t,uint32_t ty,io_connect_t*c){kern_return_t r=IOServiceOpen(sv,t,ty,c);if(r==0&&np<64){io_name_t n;IOObjectGetClass(sv,n);P[np]=*c;snprintf(N[np],128,"%s/type%u",n,ty);np++;fprintf(stderr,"cls open %s type=%u port=%u\n",n,ty,*c);}return r;}
static kern_return_t m(mach_port_t c,uint32_t s,const uint64_t*i,uint32_t ic,const void*is,size_t iss,uint64_t*o,uint32_t*oc,void*os,size_t*oss){kern_return_t r=IOConnectCallMethod(c,s,i,ic,is,iss,o,oc,os,oss);note(c,"M",s,r);return r;}
static kern_return_t st(mach_port_t c,uint32_t s,const void*is,size_t iss,void*os,size_t*oss){kern_return_t r=IOConnectCallStructMethod(c,s,is,iss,os,oss);note(c,"S",s,r);return r;}
static kern_return_t sc(mach_port_t c,uint32_t s,const uint64_t*i,uint32_t ic,uint64_t*o,uint32_t*oc){kern_return_t r=IOConnectCallScalarMethod(c,s,i,ic,o,oc);note(c,"C",s,r);return r;}
static kern_return_t am(mach_port_t c,uint32_t s,mach_port_t w,uint64_t*a,uint32_t ac,const uint64_t*i,uint32_t ic,const void*is,size_t iss,uint64_t*o,uint32_t*oc,void*os,size_t*oss){kern_return_t r=IOConnectCallAsyncMethod(c,s,w,a,ac,i,ic,is,iss,o,oc,os,oss);note(c,"A",s,r);return r;}
DYLD_INTERPOSE(so,IOServiceOpen) DYLD_INTERPOSE(m,IOConnectCallMethod) DYLD_INTERPOSE(st,IOConnectCallStructMethod) DYLD_INTERPOSE(sc,IOConnectCallScalarMethod) DYLD_INTERPOSE(am,IOConnectCallAsyncMethod)
