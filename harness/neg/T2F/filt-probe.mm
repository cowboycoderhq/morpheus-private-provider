// filt-probe.mm — T2 follow-up (2026-10-22). Measures whether an SBPL
// message filter on IOSurfaceRootUserClient can refuse a global IOSurface
// create while the Metal paths Splash needs still work.
//
// usage: filt-probe <extra_sbpl_text|-> [nosandbox]
//
// The base profile is the R5 shape (see r5-extra/probe.mm). argv[1] is
// appended verbatim, so a run can add the method filter under test. With
// "nosandbox" the profile is not applied (control).
//
// Prints one line:
//   probe global=<ok|fail> id=<n> hits=<n> nonglobal=<ok|fail> id=<n>
//         device=<0|1> mtl4queue=<0|1> sharedEvent=<0|1> queue=<0|1>
//         placementHeap=<0|1>
// and the raw profile to stderr when asked (T2F_DUMP_PROFILE=1).
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern "C" int sandbox_init_with_parameters(const char *, uint64_t,
                                            const char *const[], char **);

static const size_t kWidth = 4096, kHeight = 64;   // 256 KiB at 1 byte per pixel

// Fills a surface with the canary and counts matching 32-byte slots.
static long fill_and_count(IOSurfaceRef s, const unsigned char *pat) {
  if (!s) return -1;
  if (IOSurfaceLock(s, 0, NULL) != kIOReturnSuccess) return -2;
  unsigned char *p = (unsigned char *)IOSurfaceGetBaseAddress(s);
  size_t n = IOSurfaceGetAllocSize(s);
  for (size_t o = 0; p && o + 32 <= n; o += 32) memcpy(p + o, pat, 32);
  long hits = 0;
  for (size_t o = 0; p && o + 32 <= n; o += 32)
    if (memcmp(p + o, pat, 32) == 0) hits++;
  IOSurfaceUnlock(s, 0, NULL);
  return hits;
}

static IOSurfaceRef make_surface(bool global, const unsigned char *pat, long *hits) {
  NSDictionary *d = @{
    (id)kIOSurfaceWidth : @(kWidth),
    (id)kIOSurfaceHeight : @(kHeight),
    (id)kIOSurfaceBytesPerElement : @1,
    (id)kIOSurfaceIsGlobal : @(global),
  };
  IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)d);
  *hits = fill_and_count(s, pat);
  return s;
}

int main(int argc, char **argv) {
  static char prof[65536] = "(version 1)(deny default)\n(allow file-read*";
  static const char *firmlinked[] = {"Caches", "Assets",   "AssetsV2", "PreinstalledAssets",
                                     "PreinstalledAssetsV2", "Speech", nullptr};
  DIR *d = opendir("/System/Library");
  if (!d) { perror("opendir /System/Library"); return 2; }
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
  strlcat(prof,
          ")\n(allow file-read*(subpath \"/usr/lib\")(subpath \"/usr/share\")(subpath \"/usr/bin\")"
          "(subpath \"/usr/libexec\"))\n"
          "(allow iokit-open (iokit-user-client-class \"IOGPUDeviceUserClient\"))\n"
          "(allow mach-lookup (global-name \"com.apple.MTLCompilerService\"))\n"
          "(allow sysctl-read (sysctl-name-prefix \"hw.\"))\n",
          sizeof prof);
  char exe[PATH_MAX], real[PATH_MAX];
  uint32_t es = sizeof exe;
  if (_NSGetExecutablePath(exe, &es) != 0 || !realpath(exe, real)) { perror("realpath"); return 2; }
  *strrchr(real, '/') = '\0';
  char own[PATH_MAX + 64];
  snprintf(own, sizeof own, "(allow file-read*(subpath \"%s\"))\n", real);
  strlcat(prof, own, sizeof prof);
  if (argc > 1 && strcmp(argv[1], "-")) strlcat(prof, argv[1], sizeof prof);
  if (getenv("T2F_DUMP_PROFILE")) fputs(prof, stderr);
  bool nosb = argc > 2 && !strcmp(argv[2], "nosandbox");
  if (!nosb) {
    char *err = nullptr;
    if (sandbox_init_with_parameters(prof, 0, (const char *const[]){NULL}, &err)) {
      printf("probe sandbox_init=FAIL %s\n", err ? err : "(no text)");
      return 2;
    }
  }
  unsigned char pat[32];
  arc4random_buf(pat, sizeof pat);
  @autoreleasepool {
    long hits = 0;
    IOSurfaceRef g = make_surface(true, pat, &hits);
    uint32_t gid = g ? IOSurfaceGetID(g) : 0;
    long gHits = hits;
    IOSurfaceRef ng = make_surface(false, pat, &hits);
    uint32_t ngid = ng ? IOSurfaceGetID(ng) : 0;
    long ngHits = hits;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    id<MTL4CommandQueue> q4 = nil;
    id<MTLSharedEvent> ev = nil;
    id<MTLCommandQueue> q1 = nil;
    id<MTLHeap> heap = nil;
    if (dev) {
      if (@available(macOS 26.4, *)) {
        q4 = [dev newMTL4CommandQueue];
        ev = [dev newSharedEvent];
      }
      q1 = [dev newCommandQueue];
      MTLHeapDescriptor *hd = [MTLHeapDescriptor new];
      hd.type = MTLHeapTypePlacement;
      hd.size = 1 << 20;
      hd.storageMode = MTLStorageModePrivate;
      heap = [dev newHeapWithDescriptor:hd];
    }
    printf("probe global=%s id=%u hits=%ld nonglobal=%s id=%u hits=%ld"
           " device=%d mtl4queue=%d sharedEvent=%d queue=%d placementHeap=%d\n",
           g ? "ok" : "fail", gid, gHits, ng ? "ok" : "fail", ngid, ngHits,
           dev != nil, q4 != nil, ev != nil, q1 != nil, heap != nil);
    if (g) CFRelease(g);
    if (ng) CFRelease(ng);
  }
  return 0;
}
