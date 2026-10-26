// p6-gpuclient CANARY: opens the GPU device client the normal way (Metal),
// places its own control canary "C-"+CANARY in a shared buffer, runs one blit,
// then walks its own whole address space and counts "C-", "S-" and "P-" hits.
// S-/P- hits would mean the GPU client mapped another process's buffer data here.
#import <Metal/Metal.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <string.h>
static size_t count(const char *b, size_t n, const char *pat) {
  size_t pl = strlen(pat), c = 0; const char *q = b;
  while (n >= pl && (q = memmem(q, n - (size_t)(q - b), pat, pl))) { c++; q++; if ((size_t)(q - b) + pl > n) break; }
  return c; }
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 2) return 64;
    char pc[256], ps[256], pp[256];
    snprintf(pc, sizeof pc, "C-%s", argv[1]); snprintf(ps, sizeof ps, "S-%s", argv[1]); snprintf(pp, sizeof pp, "P-%s", argv[1]);
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    id<MTLBuffer> a = [d newBufferWithLength:1 << 20 options:MTLResourceStorageModeShared];
    id<MTLBuffer> b = [d newBufferWithLength:1 << 20 options:MTLResourceStorageModeShared];
    for (size_t o = 0; o + 300 < (1 << 20); o += 4096) memcpy((char *)a.contents + o, pc, strlen(pc));
    id<MTLCommandQueue> q = [d newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromBuffer:a sourceOffset:0 toBuffer:b destinationOffset:0 size:1 << 20]; [be endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    memset(a.contents, 0, 1 << 20);   // "C-" now exists only in b (written by the GPU)
    mach_vm_address_t addr = 0; size_t C = 0, S = 0, P = 0, bytes = 0, regions = 0, accel = 0;
    for (;;) {
      mach_vm_size_t sz = 0; natural_t depth = 1024; vm_region_submap_info_data_64_t info;
      mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
      if (mach_vm_region_recurse(mach_task_self(), &addr, &sz, &depth, (vm_region_recurse_info_t)&info, &cnt) != KERN_SUCCESS) break;
      if (info.is_submap) continue;
      regions++; if (info.user_tag == VM_MEMORY_IOACCELERATOR) accel++;
      if ((info.protection & VM_PROT_READ) && sz <= (1ull << 31)) {
        vm_offset_t data = 0; mach_msg_type_number_t dc = 0;
        if (mach_vm_read(mach_task_self(), addr, sz, &data, &dc) == KERN_SUCCESS) {
          size_t c = count((char *)data, dc, pc), s = count((char *)data, dc, ps), p = count((char *)data, dc, pp);
          // The pattern strings themselves live in this process; ignore one hit each in non-accelerator regions.
          C += c; S += s; P += p; bytes += dc; mach_vm_deallocate(mach_task_self(), data, dc);
        }
      }
      addr += sz;
    }
    printf("RESULT uid=%d C=%zu S=%zu P=%zu regions=%zu ioaccel_regions=%zu bytes=%zu\n", getuid(), C, S, P, regions, accel, bytes);
    (void)b;
  }
  return 0;
}
