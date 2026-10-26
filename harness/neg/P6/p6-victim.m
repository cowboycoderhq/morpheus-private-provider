// p6-victim: ordinary Metal program. Writes a canary into a shared MTLBuffer
// and, by a GPU blit, into a private MTLBuffer. Then waits so an attacker can run.
// Usage: p6-victim CANARY [seconds]
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) return 64;
    const char *can = argv[1]; size_t cl = strlen(can);
    int secs = argc > 2 ? atoi(argv[2]) : 600;
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    if (!d) { printf("no device\n"); return 1; }
    const size_t N = 4 << 20;
    id<MTLBuffer> sh = [d newBufferWithLength:N options:MTLResourceStorageModeShared];
    id<MTLBuffer> pv = [d newBufferWithLength:N options:MTLResourceStorageModePrivate];
    // Shared buffer: canary prefixed "S-"; private buffer gets "P-" copies via blit.
    char *p = (char *)sh.contents; size_t half = N / 2;
    for (size_t o = 0; o + cl + 2 < half; o += 4096) { memcpy(p + o, "P-", 2); memcpy(p + o + 2, can, cl); }
    id<MTLCommandQueue> q = [d newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromBuffer:sh sourceOffset:0 toBuffer:pv destinationOffset:0 size:half];
    [be copyFromBuffer:sh sourceOffset:0 toBuffer:pv destinationOffset:half size:half];
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
    // Overwrite the shared buffer: now "P-" exists only in the private buffer,
    // "S-" exists only in the shared buffer.
    memset(p, 0, N);
    for (size_t o = 0; o + cl + 2 < N; o += 4096) { memcpy(p + o, "S-", 2); memcpy(p + o + 2, can, cl); }
    printf("READY pid=%d shared=%p private_gpu=0x%llx len=%zu\n", getpid(), p, (unsigned long long)pv.gpuAddress, N);
    fflush(stdout);
    sleep(secs);
    (void)pv; (void)sh;
  }
  return 0;
}
