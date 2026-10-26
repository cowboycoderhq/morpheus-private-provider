// t2-reader.m — T2 outside reader (from A16/a16-probe.m). Runs as the same
// user, not sandboxed. It only looks up and reads; it never writes a surface.
//
// usage: t2-reader <canary_hex> <sweep_max> <id> [<id> ...]
//
// Prints one line per arm:
//  ARM lookup id=<id> <REFUSED|FOUND|OPENED-NO-CANARY> ... prop=<hit|none|other>
//      IOSurfaceLookup of each recorded ID, canary count, property read
//  ARM sweep ids=1..<max> opened=<n> canary_ids=<..> prop_ids=<..>
//      IOSurfaceLookup over the range, canary count and property read on
//      every surface that opens
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static unsigned char gCan[32];
static NSString *gHex;

static int hexcan(const char *h) {
  if (strlen(h) != 64) return -1;
  for (int i = 0; i < 32; i++) {
    unsigned v;
    if (sscanf(h + 2 * i, "%2x", &v) != 1) return -1;
    gCan[i] = (unsigned char)v;
  }
  return 0;
}

static long count_canary(IOSurfaceRef s) {
  if (IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL) != kIOReturnSuccess) return -1;
  const unsigned char *p = IOSurfaceGetBaseAddress(s);
  size_t n = IOSurfaceGetAllocSize(s);
  long hits = 0;
  for (size_t o = 0; p && o + 32 <= n; o += 32)
    if (memcmp(p + o, gCan, 32) == 0) hits++;
  IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
  return hits;
}

// "hit" if the property equals the canary hex, "other" if it is something
// else, "none" if absent.
static const char *prop(IOSurfaceRef s) {
  CFTypeRef v = IOSurfaceCopyValue(s, CFSTR("sealed.canary"));
  if (!v) return "none";
  int hit = CFGetTypeID(v) == CFStringGetTypeID() && [(__bridge NSString *)v isEqualToString:gHex];
  CFRelease(v);
  return hit ? "hit" : "other";
}

int main(int argc, char **argv) {
  if (argc < 4 || hexcan(argv[1]) != 0) {
    fprintf(stderr, "usage: t2-reader <canary_hex> <sweep_max> <id> [<id> ...]\n");
    return 2;
  }
  @autoreleasepool {
    gHex = [NSString stringWithUTF8String:argv[1]];
    uint32_t sweep = (uint32_t)strtoul(argv[2], NULL, 10);
    printf("READER uid=%d pid=%d\n", getuid(), getpid());
    for (int i = 3; i < argc; i++) {
      uint32_t sid = (uint32_t)strtoul(argv[i], NULL, 10);
      if (sid == 0) { printf("ARM lookup id=0 SKIP no such surface\n"); continue; }
      IOSurfaceRef s = IOSurfaceLookup(sid);
      if (!s) { printf("ARM lookup id=%u REFUSED lookup returned NULL\n", sid); continue; }
      long h = count_canary(s);
      printf("ARM lookup id=%u %s size=%zu canary_hits=%ld prop=%s\n", sid, h > 0 ? "FOUND" : "OPENED-NO-CANARY",
             IOSurfaceGetAllocSize(s), h, prop(s));
      CFRelease(s);
    }
    uint32_t opened = 0, with_canary = 0, with_prop = 0;
    char ids[512] = "", pids[512] = "";
    for (uint32_t id = 1; id <= sweep; id++) {
      IOSurfaceRef s = IOSurfaceLookup(id);
      if (!s) continue;
      opened++;
      char t[16];
      snprintf(t, sizeof t, "%u,", id);
      if (count_canary(s) > 0) {
        with_canary++;
        if (strlen(ids) + strlen(t) < sizeof ids) strcat(ids, t);
      }
      if (!strcmp(prop(s), "hit")) {
        with_prop++;
        if (strlen(pids) + strlen(t) < sizeof pids) strcat(pids, t);
      }
      CFRelease(s);
    }
    printf("ARM sweep ids=1..%u opened=%u with_canary=%u canary_ids=%s with_prop=%u prop_ids=%s\n", sweep, opened,
           with_canary, ids, with_prop, pids);
  }
  return 0;
}
