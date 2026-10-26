// client-probe.mm — T2 client-need check (2026-10-23). Measures which Metal
// calls Splash's backend needs IOSurfaceRootUserClient for, under the R5
// profile shape with the class rule removed (the class deny).
//
// usage: client-probe <deny|allow|nosb> [step,step,...]
//   deny  : R5 shape without the IOSurfaceRootUserClient rule
//   allow : R5 shape with the production rule
//   nosb  : no sandbox (control)
// Steps run in the fixed order below; a list selects a subset. Each step
// prints "step <name> <0|1> <detail>" to stderr. With open-trace.dylib
// inserted, each IOServiceOpen line appears between the step lines, so the
// step that opens the client is the one printed after the trace line.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dirent.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <objc/message.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern "C" int sandbox_init_with_parameters(const char *, uint64_t,
                                            const char *const[], char **);

static NSString *const kSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "kernel void fill(device uint *out [[buffer(0)]], constant uint &v [[buffer(1)]],"
     " uint i [[thread_position_in_grid]]) { out[i] = v + i; }\n";

static const char *gSteps = nullptr;
static bool want(const char *s) {
  if (!gSteps) return true;
  size_t n = strlen(s);
  for (const char *p = gSteps; (p = strstr(p, s)); p += n)
    if ((p == gSteps || p[-1] == ',') && (p[n] == ',' || p[n] == 0)) return true;
  return false;
}
static void step(const char *name, bool ok, const char *detail = "") {
  fprintf(stderr, "step %s %d %s\n", name, ok ? 1 : 0, detail);
}

// Encodes one fill dispatch of n uints with value v into a command buffer.
static void encodeFill(id<MTLCommandBuffer> cb, id<MTLComputePipelineState> ps,
                       id<MTLBuffer> out, uint32_t v, NSUInteger n) {
  id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
  [e setComputePipelineState:ps];
  [e setBuffer:out offset:0 atIndex:0];
  [e setBytes:&v length:sizeof v atIndex:1];
  [e dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
  [e endEncoding];
}

static bool checkFill(id<MTLBuffer> b, uint32_t v, NSUInteger n) {
  const uint32_t *p = (const uint32_t *)b.contents;
  if (!p) return false;
  for (NSUInteger i = 0; i < n; i++)
    if (p[i] != v + i) return false;
  return true;
}

int main(int argc, char **argv) {
  setvbuf(stderr, nullptr, _IONBF, 0);
  const char *mode = argc > 1 ? argv[1] : "deny";
  gSteps = argc > 2 ? argv[2] : nullptr;
  static char prof[65536] = "(version 1)(deny default)\n(allow file-read*";
  static const char *firmlinked[] = {"Caches", "Assets", "AssetsV2", "PreinstalledAssets",
                                     "PreinstalledAssetsV2", "Speech", nullptr};
  DIR *d = opendir("/System/Library");
  if (!d) { perror("opendir"); return 2; }
  struct dirent *e;
  while ((e = readdir(d))) {
    if (e->d_name[0] == '.') continue;
    bool skip = false;
    for (int k = 0; firmlinked[k]; k++)
      if (!strcmp(e->d_name, firmlinked[k])) skip = true;
    if (skip) continue;
    char o[300];
    snprintf(o, sizeof o, "(subpath \"/System/Library/%s\")", e->d_name);
    strlcat(prof, o, sizeof prof);
  }
  closedir(d);
  // Same IOKit, mach-lookup and sysctl rules as sealed_r5.mm (production).
  strlcat(prof,
          ")\n(allow file-read*(subpath \"/usr/lib\")(subpath \"/usr/share\"))\n"
          "(allow iokit-open (iokit-user-client-class \"IOGPUDeviceUserClient\"))\n",
          sizeof prof);
  if (!strcmp(mode, "allow"))
    strlcat(prof, "(allow iokit-open (iokit-user-client-class \"IOSurfaceRootUserClient\"))\n",
            sizeof prof);
  strlcat(prof,
          "(allow mach-lookup (global-name \"com.apple.MTLCompilerService\"))\n"
          "(allow sysctl-read (sysctl-name-prefix \"hw.\"))\n"
          "(deny file-read*(subpath \"/System/Volumes/Data\"))"
          "(deny file-read*(subpath \"/usr/share/snmp\"))"
          "(deny file-read*(subpath \"/System/Library/CoreServices/CoreTypes.bundle/Contents/Library\"))\n",
          sizeof prof);
  char exe[PATH_MAX], real[PATH_MAX];
  uint32_t es = sizeof exe;
  if (_NSGetExecutablePath(exe, &es) != 0 || !realpath(exe, real)) { perror("realpath"); return 2; }
  *strrchr(real, '/') = '\0';
  char own[PATH_MAX + 64];
  snprintf(own, sizeof own, "(allow file-read*(subpath \"%s\"))\n", real);
  strlcat(prof, own, sizeof prof);
  if (getenv("T2C_DUMP_PROFILE")) fputs(prof, stderr);
  if (strcmp(mode, "nosb")) {
    char *err = nullptr;
    if (sandbox_init_with_parameters(prof, 0, (const char *const[]){NULL}, &err)) {
      fprintf(stderr, "step sandbox 0 %s\n", err ? err : "(no text)");
      return 2;
    }
  }
  step("sandbox", true, mode);

  @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    step("device", dev != nil);
    if (!dev) return 3;
    const NSUInteger n = 4096;
    id<MTLCommandQueue> q = nil;
    id<MTLEvent> ev = nil;
    id<MTLComputePipelineState> ps = nil;
    id<MTLBuffer> shared = nil, priv = nil;
    if (want("queue")) { q = [dev newCommandQueue]; step("queue", q != nil); }
    if (want("event")) { ev = [dev newEvent]; step("event", ev != nil); }
    if (want("library")) {
      NSError *err = nil;
      id<MTLLibrary> lib = [dev newLibraryWithSource:kSource options:nil error:&err];
      id<MTLFunction> f = [lib newFunctionWithName:@"fill"];
      ps = f ? [dev newComputePipelineStateWithFunction:f error:&err] : nil;
      step("library", ps != nil, err ? err.localizedDescription.UTF8String : "");
    }
    if (want("buffers")) {
      shared = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
      priv = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModePrivate];
      step("buffers", shared && priv);
    }
    if (want("dispatch") && q && ps && shared) {
      id<MTLCommandBuffer> cb = [q commandBuffer];
      encodeFill(cb, ps, shared, 7, n);
      dispatch_semaphore_t done = dispatch_semaphore_create(0);
      [cb addCompletedHandler:^(id<MTLCommandBuffer>) { dispatch_semaphore_signal(done); }];
      [cb commit];
      [cb waitUntilCompleted];
      long w = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
      char det[120];
      snprintf(det, sizeof det, "status=%ld handler=%d", (long)cb.status, w == 0);
      step("dispatch", cb.status == MTLCommandBufferStatusCompleted && w == 0 && checkFill(shared, 7, n), det);
    }
    if (want("eventsync") && q && ps && shared && ev) {
      // Cross-command-buffer ordering with an in-process MTLEvent.
      id<MTLCommandBuffer> waiter = [q commandBuffer];
      [waiter encodeWaitForEvent:ev value:1];
      encodeFill(waiter, ps, shared, 11, n);
      id<MTLCommandQueue> q2 = [dev newCommandQueue];
      id<MTLCommandBuffer> signaler = [q2 commandBuffer];
      [signaler encodeSignalEvent:ev value:1];
      [waiter commit];
      [signaler commit];
      [waiter waitUntilCompleted];
      char det[80];
      snprintf(det, sizeof det, "status=%ld", (long)waiter.status);
      step("eventsync", waiter.status == MTLCommandBufferStatusCompleted && checkFill(shared, 11, n), det);
    }
    id<MTLBuffer> sparse = nil;
    id<MTLHeap> heap = nil;
    if (want("sparsebuf")) {
      if (@available(macOS 26.4, *)) {
        BOOL sup = [dev respondsToSelector:@selector(supportsPlacementSparse)] &&
                   ((BOOL (*)(id, SEL))objc_msgSend)(dev, @selector(supportsPlacementSparse));
        sparse = [dev newBufferWithLength:64 * 1024 * 4
                                  options:MTLResourceStorageModePrivate
                  placementSparsePageSize:MTLSparsePageSize64];
        step("sparsebuf", sparse != nil, sup ? "supportsPlacementSparse=1" : "supportsPlacementSparse=0");
      }
    }
    if (want("heap")) {
      MTLHeapDescriptor *hd = [MTLHeapDescriptor new];
      hd.type = MTLHeapTypePlacement;
      hd.storageMode = MTLStorageModePrivate;
      hd.size = 64 * 1024 * 4;
      hd.maxCompatiblePlacementSparsePageSize = MTLSparsePageSize64;
      heap = [dev newHeapWithDescriptor:hd];
      step("heap", heap != nil);
    }
    id<MTL4CommandQueue> q4 = nil;
    if (want("mtl4queue")) {
      if (@available(macOS 26.4, *)) {
        q4 = [dev newMTL4CommandQueue];
        step("mtl4queue", q4 != nil);
        NSError *err = nil;
        MTL4CommandQueueDescriptor *qd = [MTL4CommandQueueDescriptor new];
        id<MTL4CommandQueue> q4d = [dev newMTL4CommandQueueWithDescriptor:qd error:&err];
        step("mtl4queue-desc", q4d != nil,
             err ? [NSString stringWithFormat:@"%@", err].UTF8String : "");
        if (!q4) q4 = q4d;
      }
    }
    if (want("sharedevent")) {
      id<MTLSharedEvent> se = [dev newSharedEvent];
      step("sharedevent", se != nil);
    }
    if (want("listener")) {
      MTLSharedEventListener *l = [MTLSharedEventListener sharedListener];
      step("listener", l != nil);
    }
    if (want("mtl4map") && q4 && sparse && heap && ev && q && ps) {
      // Map one 64 KiB tile on the MTL4 queue, order the compute queue after
      // it with the in-process MTLEvent, then write through the sparse view.
      MTL4UpdateSparseBufferMappingOperation op{};
      op.mode = MTLSparseTextureMappingModeMap;
      op.bufferRange = NSMakeRange(0, 1);
      op.heapOffset = 0;
      [q4 updateBufferMappings:sparse heap:heap operations:&op count:1];
      [q4 signalEvent:ev value:2];
      id<MTLBuffer> out = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
      id<MTLCommandBuffer> cb = [q commandBuffer];
      [cb encodeWaitForEvent:ev value:2];
      encodeFill(cb, ps, sparse, 21, n);
      id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
      [b copyFromBuffer:sparse sourceOffset:0 toBuffer:out destinationOffset:0 size:n * 4];
      [b endEncoding];
      [cb commit];
      [cb waitUntilCompleted];
      char det[80];
      snprintf(det, sizeof det, "status=%ld", (long)cb.status);
      step("mtl4map", cb.status == MTLCommandBufferStatusCompleted && checkFill(out, 21, n), det);
    }
  }
  step("end", true);
  return 0;
}
