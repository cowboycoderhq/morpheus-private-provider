// sel-trace.m — records the IOSurfaceRootUserClient external-method selector
// each IOSurface call uses. Loaded with DYLD_INSERT_LIBRARIES into an ad-hoc
// probe. The interpose section overrides two-level-namespace binds, so the
// IOKit symbols resolve through these replacements.
#include <dlfcn.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>

static const void *gIn;

#define DYLD_INTERPOSE(_repl, _orig)                                            \
  __attribute__((used)) static struct {                                         \
    const void *replacement;                                                    \
    const void *replacee;                                                       \
  } _interpose_##_orig __attribute__((section("__DATA,__interpose"))) = {        \
      (const void *)(unsigned long)&_repl, (const void *)(unsigned long)&_orig};

// The handle-scoped lookup skips the interpose override and returns IOKit's
// own implementation.
static void *gIOKit;
static void *orig(const char *name) {
  if (!gIOKit) gIOKit = dlopen("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit",
                               RTLD_LAZY | RTLD_LOCAL);
  return gIOKit ? dlsym(gIOKit, name) : NULL;
}

static void note(const char *fn, uint32_t sel, uint32_t n, long rc) {
  fprintf(stderr, "sel-trace %s selector=%u n=%u rc=0x%x\n", fn, sel, n, (unsigned)rc);
  (void)0;
  fflush(stderr);
}

static kern_return_t repl_method(mach_port_t c, uint32_t sel, const uint64_t *in, uint32_t inCnt,
                                 const void *inS, size_t inSSize, uint64_t *out, uint32_t *outCnt,
                                 void *outS, size_t *outSSize) {
  kern_return_t r = IOConnectCallMethod(c, sel, in, inCnt, inS, inSSize, out, outCnt, outS, outSSize);
  note("IOConnectCallMethod", sel, inCnt, r);
  if (getenv("T2F_DUMP_IN") && sel == 0 && inCnt > 0)
  {
    fprintf(stderr, "sel-trace create in0=0x%llx size=%zu\n", (unsigned long long)in[0], inSSize);
    const unsigned char *b = (const unsigned char *)inS;
    fprintf(stderr, "sel-trace create str:");
    for (size_t i = 0; b && i < inSSize; i++)
      if (b[i] >= 32 && b[i] < 127) fputc(b[i], stderr);
    fprintf(stderr, "\n");
  }
  return r;
}

static kern_return_t repl_struct(mach_port_t c, uint32_t sel, const void *inS, size_t inSSize,
                                 void *outS, size_t *outSSize) {
  gIn = inS;

  kern_return_t r = IOConnectCallStructMethod(c, sel, inS, inSSize, outS, outSSize);
  note("IOConnectCallStructMethod", sel, (uint32_t)inSSize, r);
  return r;
}

static kern_return_t repl_scalar(mach_port_t c, uint32_t sel, const uint64_t *in, uint32_t inCnt,
                                 uint64_t *out, uint32_t *outCnt) {
  kern_return_t r = IOConnectCallScalarMethod(c, sel, in, inCnt, out, outCnt);
  note("IOConnectCallScalarMethod", sel, inCnt, r);
  return r;
}

DYLD_INTERPOSE(repl_method, IOConnectCallMethod)
DYLD_INTERPOSE(repl_struct, IOConnectCallStructMethod)
DYLD_INTERPOSE(repl_scalar, IOConnectCallScalarMethod)
