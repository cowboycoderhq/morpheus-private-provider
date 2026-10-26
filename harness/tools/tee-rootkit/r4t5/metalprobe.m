// metalprobe: a normal, unsandboxed Metal client. It builds one fresh
// compute pipeline. When it runs from inside an app bundle, the bundle's
// Contents/XPCServices is part of the caller's pid-domain lookup path.
#import <Metal/Metal.h>
#include <stdio.h>

int main(void) {
  @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    if (!d) { printf("metal: no device\n"); return 1; }
    NSString *src = [NSString stringWithFormat:
        @"kernel void k%u(device float *a [[buffer(0)]]) { a[0] = %u.0; }",
        arc4random(), arc4random()];
    NSError *e = nil;
    id<MTLLibrary> l = [d newLibraryWithSource:src options:nil error:&e];
    id<MTLComputePipelineState> p = l
        ? [d newComputePipelineStateWithFunction:[l newFunctionWithName:[l functionNames][0]] error:&e]
        : nil;
    printf("metal: library=%s pipeline=%s err=%s\n",
           l ? "ok" : "nil", p ? "ok" : "nil",
           e ? e.localizedDescription.UTF8String : "-");
  }
  return 0;
}
