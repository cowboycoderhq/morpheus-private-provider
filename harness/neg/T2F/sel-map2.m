// sel-map2.m — one IOSurface operation per run (argv[1]) with markers.
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#include <stdio.h>
#include <string.h>

static IOSurfaceRef mk(int global) {
  NSMutableDictionary *d = [@{
    (id)kIOSurfaceWidth : @4096, (id)kIOSurfaceHeight : @64, (id)kIOSurfaceBytesPerElement : @1,
  } mutableCopy];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (global) d[(id)kIOSurfaceIsGlobal] = @YES;
#pragma clang diagnostic pop
  return IOSurfaceCreate((__bridge CFDictionaryRef)d);
}

int main(int argc, char **argv) {
  const char *m = argc > 1 ? argv[1] : "g";
  @autoreleasepool {
    fprintf(stderr, "MARK start %s\n", m);
    if (!strcmp(m, "g") || !strcmp(m, "g2")) {
      IOSurfaceRef a = mk(1);
      fprintf(stderr, "MARK created1 id=%u\n", a ? IOSurfaceGetID(a) : 0);
      if (!strcmp(m, "g2")) { IOSurfaceRef b = mk(1); fprintf(stderr, "MARK created2 id=%u\n", b ? IOSurfaceGetID(b) : 0); if (b) CFRelease(b); }
      if (a) CFRelease(a);
    } else if (!strcmp(m, "n")) {
      IOSurfaceRef a = mk(0);
      fprintf(stderr, "MARK created1 id=%u\n", a ? IOSurfaceGetID(a) : 0);
      if (a) CFRelease(a);
    } else if (!strcmp(m, "s")) {
      IOSurfaceRef a = mk(0);
      fprintf(stderr, "MARK set\n");
      IOSurfaceSetValue(a, CFSTR("k"), CFSTR("v"));
      if (a) CFRelease(a);
    } else if (!strcmp(m, "c")) {
      IOSurfaceRef a = mk(0);
      IOSurfaceSetValue(a, CFSTR("k"), CFSTR("v"));
      fprintf(stderr, "MARK copy\n");
      CFTypeRef v = IOSurfaceCopyValue(a, CFSTR("k"));
      if (v) CFRelease(v);
      if (a) CFRelease(a);
    }
    fprintf(stderr, "MARK done\n");
  }
  return 0;
}
