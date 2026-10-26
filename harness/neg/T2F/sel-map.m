// sel-map.m — one IOSurface operation at a time, with markers, so the
// selector trace from sel-trace.dylib can be attributed. No sandbox.
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#include <stdio.h>

static IOSurfaceRef mk(int global) {
  NSMutableDictionary *d = [@{
    (id)kIOSurfaceWidth : @4096,
    (id)kIOSurfaceHeight : @64,
    (id)kIOSurfaceBytesPerElement : @1,
  } mutableCopy];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (global) d[(id)kIOSurfaceIsGlobal] = @YES;
#pragma clang diagnostic pop
  return IOSurfaceCreate((__bridge CFDictionaryRef)d);
}

int main(void) {
  @autoreleasepool {
    fprintf(stderr, "MARK create_global\n");
    IOSurfaceRef g = mk(1);
    fprintf(stderr, "MARK create_global done id=%u\n", g ? IOSurfaceGetID(g) : 0);
    fprintf(stderr, "MARK set_value\n");
    IOSurfaceSetValue(g, CFSTR("sealed.canary"), CFSTR("aa"));
    fprintf(stderr, "MARK copy_value\n");
    CFTypeRef v = IOSurfaceCopyValue(g, CFSTR("sealed.canary"));
    if (v) CFRelease(v);
    fprintf(stderr, "MARK lock_unlock\n");
    IOSurfaceLock(g, 0, NULL);
    IOSurfaceUnlock(g, 0, NULL);
    fprintf(stderr, "MARK create_nonglobal\n");
    IOSurfaceRef n = mk(0);
    fprintf(stderr, "MARK lookup\n");
    IOSurfaceRef l = g ? IOSurfaceLookup(IOSurfaceGetID(g)) : NULL;
    if (l) CFRelease(l);
    fprintf(stderr, "MARK release\n");
    if (n) CFRelease(n);
    if (g) CFRelease(g);
    fprintf(stderr, "MARK done\n");
  }
  return 0;
}
