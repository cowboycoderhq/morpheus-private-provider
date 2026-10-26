// sel-trace.m — records the IOSurfaceRootUserClient external-method selector
// each IOSurface call uses. Loaded with DYLD_INSERT_LIBRARIES into an ad-hoc
// probe. The interpose section overrides two-level-namespace binds, so the
// IOKit symbols resolve through these replacements.
#include <dlfcn.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdio.h>

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

static void note(const char *fn, uint32_t sel, uint32_t n) {
  fprintf(stderr, "sel-trace %s selector=%u n=%u\n", fn, sel, n);
  fflush(stderr);
}

static kern_return_t repl_method(mach_port_t c, uint32_t sel, const uint64_t *in, uint32_t inCnt,
                                 const void *inS, size_t inSSize, uint64_t *out, uint32_t *outCnt,
                                 void *outS, size_t *outSSize) {
  static kern_return_t (*real)(mach_port_t, uint32_t, const uint64_t *, uint32_t, const void *,
                               size_t, uint64_t *, uint32_t *, void *, size_t *);
  if (!real) real = (void *)orig("IOConnectCallMethod");
  note("IOConnectCallMethod", sel, inCnt);
  return real(c, sel, in, inCnt, inS, inSSize, out, outCnt, outS, outSSize);
}

static kern_return_t repl_struct(mach_port_t c, uint32_t sel, const void *inS, size_t inSSize,
                                 void *outS, size_t *outSSize) {
  static kern_return_t (*real)(mach_port_t, uint32_t, const void *, size_t, void *, size_t *);
  if (!real) real = (void *)orig("IOConnectCallStructMethod");
  note("IOConnectCallStructMethod", sel, (uint32_t)inSSize);
  return real(c, sel, inS, inSSize, outS, outSSize);
}

static kern_return_t repl_scalar(mach_port_t c, uint32_t sel, const uint64_t *in, uint32_t inCnt,
                                 uint64_t *out, uint32_t *outCnt) {
  static kern_return_t (*real)(mach_port_t, uint32_t, const uint64_t *, uint32_t, uint64_t *,
                               uint32_t *);
  if (!real) real = (void *)orig("IOConnectCallScalarMethod");
  note("IOConnectCallScalarMethod", sel, inCnt);
  return real(c, sel, in, inCnt, out, outCnt);
}

DYLD_INTERPOSE(repl_method, IOConnectCallMethod)
DYLD_INTERPOSE(repl_struct, IOConnectCallStructMethod)
DYLD_INTERPOSE(repl_scalar, IOConnectCallScalarMethod)
