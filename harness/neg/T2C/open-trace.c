// open-trace.c — T2 client-need check (2026-10-23): prints each IOServiceOpen
// with its service class, its result and the caller stack, so a run names the
// call that opens IOSurfaceRootUserClient. DYLD_INSERT_LIBRARIES into an ad hoc
// probe without the hardened runtime.
// build: clang -dynamiclib -O1 -framework IOKit -o open-trace.dylib open-trace.c
#include <IOKit/IOKitLib.h>
#include <execinfo.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#define DYLD_INTERPOSE(_r, _o)                                                  \
  __attribute__((used)) static struct {                                         \
    const void *r;                                                              \
    const void *o;                                                              \
  } _i_##_o __attribute__((section("__DATA,__interpose"))) = {                  \
      (const void *)(unsigned long)&_r, (const void *)(unsigned long)&_o};

static kern_return_t so(io_service_t sv, task_port_t t, uint32_t ty, io_connect_t *c) {
  kern_return_t r = IOServiceOpen(sv, t, ty, c);
  io_name_t n = "?";
  IOObjectGetClass(sv, n);
  fprintf(stderr, "trace open %s type=%u rc=0x%x\n", n, ty, r);
  if (strstr(n, "IOSurface")) {
    void *f[24];
    int k = backtrace(f, 24);
    char **s = backtrace_symbols(f, k);
    for (int i = 1; s && i < k; i++) fprintf(stderr, "trace   %s\n", s[i]);
  }
  return r;
}
DYLD_INTERPOSE(so, IOServiceOpen)
