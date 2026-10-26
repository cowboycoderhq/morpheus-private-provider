// s1-reader.mm — S-1 outside reader. Runs as the same user (uid 501), not
// sandboxed, in a different process from the child. It only opens and reads.
//
// usage: s1-reader <phase> <canary_hex> <reason_file>
//
// Reads the child's "test: s1 <phase> ..." lines from the reason file, then
// tries each path in review/S1-IOGPU-2026-10-23.md:
//  ARM tex      unarchive the MTLSharedTextureHandle, newSharedTextureWithHandle:,
//               blit the texture to a buffer and count the canary
//  ARM ev       unarchive the MTLSharedEventHandle, newSharedEventWithHandle:,
//               read signaledValue and label
//  ARM ios      IOSurfaceLookup of the texture's recorded IOSurface ID
//  ARM sweep    IOSurfaceLookup over IDs 1..(recorded ID + 4096), canary count
//  ARM registry IOKit registry: every IOGPUDeviceUserClient/AGXDeviceUserClient,
//               its creator, its property text scanned for the canary; an
//               IOServiceOpen of the accelerator
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <string>

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

static NSData *unhex(NSString *h) {
  NSUInteger n = h.length / 2;
  NSMutableData *d = [NSMutableData dataWithLength:n];
  unsigned char *p = (unsigned char *)d.mutableBytes;
  for (NSUInteger i = 0; i < n; i++) {
    unsigned v = 0;
    if (sscanf([[h substringWithRange:NSMakeRange(2 * i, 2)] UTF8String], "%2x", &v) != 1) return nil;
    p[i] = (unsigned char)v;
  }
  return d;
}

static long count_canary(const unsigned char *p, size_t n) {
  long hits = 0;
  for (size_t o = 0; p && o + 32 <= n; o += 32)
    if (memcmp(p + o, gCan, 32) == 0) hits++;
  return hits;
}

static long count_surface(IOSurfaceRef s) {
  if (IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL) != kIOReturnSuccess) return -1;
  long hits = count_canary((const unsigned char *)IOSurfaceGetBaseAddress(s),
                           IOSurfaceGetAllocSize(s));
  IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
  return hits;
}

static NSString *field(NSString *line, NSString *key) {
  for (NSString *tok in [line componentsSeparatedByString:@" "]) {
    if ([tok hasPrefix:[key stringByAppendingString:@"="]])
      return [tok substringFromIndex:key.length + 1];
  }
  return nil;
}

static NSString *line_for(NSString *reason, NSString *prefix) {
  for (NSString *l in [reason componentsSeparatedByString:@"\n"])
    if ([l hasPrefix:prefix]) return l;
  return nil;
}

int main(int argc, char **argv) {
  if (argc < 4 || hexcan(argv[2]) != 0) {
    fprintf(stderr, "usage: s1-reader <phase> <canary_hex> <reason_file>\n");
    return 2;
  }
  @autoreleasepool {
    gHex = [NSString stringWithUTF8String:argv[2]];
    NSString *phase = [NSString stringWithUTF8String:argv[1]];
    NSString *reason = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[3]]
                                                encoding:NSUTF8StringEncoding
                                                   error:NULL];
    if (!reason) {
      printf("ARM reason unreadable path=%s\n", argv[3]);
      return 3;
    }
    NSString *pre = [NSString stringWithFormat:@"test: s1 %@ ", phase];
    printf("READER uid=%d pid=%d phase=%s\n", getuid(), getpid(), argv[1]);

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    printf("READER metal device=%d\n", dev != nil);

    // P1: shared texture handle.
    NSString *tl = line_for(reason, [pre stringByAppendingString:@"tex handle="]);
    NSString *tline = line_for(reason, [pre stringByAppendingString:@"tex content="]);
    if (!tl) {
      printf("ARM tex NO-HANDLE encode=%s ios=%s\n", field(tline, @"encode").UTF8String ?: "?",
             field(tline, @"ios").UTF8String ?: "?");
    } else {
      NSData *d = unhex(field(tl, @"handle"));
      NSError *err = nil;
      MTLSharedTextureHandle *h = d ? [NSKeyedUnarchiver unarchivedObjectOfClass:[MTLSharedTextureHandle class]
                                                                        fromData:d
                                                                           error:&err] : nil;
      if (!h) {
        printf("ARM tex handle=present unarchive=FAIL err=%s\n",
               err ? err.localizedDescription.UTF8String : "nil");
      } else {
        printf("ARM tex handle=present unarchive=ok label=%s\n",
               h.label && [h.label isEqualToString:gHex] ? "canary" : (h.label ? "other" : "none"));
        id<MTLTexture> t = dev ? [dev newSharedTextureWithHandle:h] : nil;
        if (!t) {
          printf("ARM tex newSharedTextureWithHandle=REFUSED\n");
        } else {
          id<MTLCommandQueue> q = [dev newCommandQueue];
          const NSUInteger bytes = 4096 * 16;
          id<MTLBuffer> dst = [dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
          id<MTLCommandBuffer> cb = [q commandBuffer];
          id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
          long hits = -1;
          if (b && dst) {
            [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                    sourceSize:MTLSizeMake(4096, 16, 1)
                      toBuffer:dst destinationOffset:0 destinationBytesPerRow:4096
             destinationBytesPerImage:bytes];
            [b endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            hits = count_canary((const unsigned char *)dst.contents, bytes);
          }
          printf("ARM tex newSharedTextureWithHandle=ok width=%lu height=%lu canary_hits=%ld of 2048\n",
                 (unsigned long)t.width, (unsigned long)t.height, hits);
        }
      }
    }

    // P2: shared event handle.
    NSString *el = line_for(reason, [pre stringByAppendingString:@"ev handle="]);
    NSString *eline = line_for(reason, [pre stringByAppendingString:@"ev create="]);
    if (!el) {
      printf("ARM ev NO-HANDLE\n");
    } else {
      NSData *d = unhex(field(el, @"handle"));
      NSError *err = nil;
      MTLSharedEventHandle *h = d ? [NSKeyedUnarchiver unarchivedObjectOfClass:[MTLSharedEventHandle class]
                                                                      fromData:d
                                                                         error:&err] : nil;
      if (!h) {
        printf("ARM ev handle=present unarchive=FAIL err=%s\n",
               err ? err.localizedDescription.UTF8String : "nil");
      } else {
        printf("ARM ev handle=present unarchive=ok label=%s expect=%s\n",
               h.label && [h.label isEqualToString:gHex] ? "canary" : (h.label ? "other" : "none"),
               field(eline, @"value").UTF8String ?: "0");
        id<MTLSharedEvent> e = dev ? [dev newSharedEventWithHandle:h] : nil;
        if (!e) {
          printf("ARM ev newSharedEventWithHandle=REFUSED\n");
        } else {
          unsigned long long want = strtoull(field(eline, @"value").UTF8String ?: "0", NULL, 16);
          printf("ARM ev newSharedEventWithHandle=ok signaledValue=%016llx value_match=%d\n",
                 (unsigned long long)e.signaledValue,
                 (unsigned long long)e.signaledValue == want);
        }
      }
    }

    // P1b/P5: the recorded IOSurfaces by global ID, then a bounded sweep.
    NSString *sl = line_for(reason, [pre stringByAppendingString:@"hold="]);
    unsigned iosid = 0, ngid = 0;
    if (sl) {
      iosid = (unsigned)strtoul((field(sl, @"global") ?: @"0").UTF8String, NULL, 10);
      ngid = (unsigned)strtoul((field(sl, @"nonglobal") ?: @"0").UTF8String, NULL, 10);
    }
    for (unsigned one = 0; one < 2; one++) {
      unsigned id = one ? ngid : iosid;
      const char *kind = one ? "nonglobal" : "global";
      if (id == 0) {
        printf("ARM ios %s id=0 REFUSED no-surface\n", kind);
        continue;
      }
      IOSurfaceRef s = IOSurfaceLookup(id);
      if (!s) {
        printf("ARM ios %s id=%u REFUSED lookup returned NULL\n", kind, id);
        continue;
      }
      CFTypeRef v = IOSurfaceCopyValue(s, CFSTR("sealed.canary"));
      int prop = v && CFGetTypeID(v) == CFStringGetTypeID() &&
             [(__bridge NSString *)v isEqualToString:gHex];
      if (v) CFRelease(v);
      printf("ARM ios %s id=%u FOUND size=%zu canary_hits=%ld prop=%s\n", kind, id,
             IOSurfaceGetAllocSize(s), count_surface(s), prop ? "hit" : "none");
      CFRelease(s);
    }
    {
      uint32_t max = (iosid > ngid ? iosid : ngid) + 4096;
      int opened = 0, canary = 0;
      for (uint32_t i = 1; i <= max; i++) {
        IOSurfaceRef s = IOSurfaceLookup(i);
        if (!s) continue;
        opened++;
        if (count_surface(s) > 0) canary++;
        CFRelease(s);
      }
      printf("ARM sweep ids=1..%u opened=%d with_canary=%d\n", max, opened, canary);
    }

    // P4: registry. No handoff and no child cooperation. User clients are
    // unregistered objects, so IOServiceMatching cannot see them; the
    // accelerator is the registered service and its properties are readable.
    {
      CFMutableDictionaryRef props = NULL;
      int propcan = 0;
      long surfaces = -1;
      io_service_t acc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"));
      if (!acc) {
        printf("ARM registry accelerator=no-service\n");
      } else {
        io_name_t name = {0};
        IORegistryEntryGetName(acc, name);
        if (IORegistryEntryCreateCFProperties(acc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
          NSDictionary *d = (__bridge NSDictionary *)props;
          NSData *pl = [NSPropertyListSerialization dataWithPropertyList:d
                                                                 format:NSPropertyListXMLFormat_v1_0
                                                                options:0
                                                                  error:NULL];
          NSString *text = pl ? [[NSString alloc] initWithData:pl encoding:NSUTF8StringEncoding] : nil;
          if (text && [text rangeOfString:gHex].location != NSNotFound) propcan = 1;
          id sl = d[@"SurfaceList"];
          if ([sl isKindOfClass:[NSArray class]]) surfaces = (long)[sl count];
          printf("ARM registry accelerator=%s props=%lu surfaceList=%ld with_canary=%d\n", name,
                 (unsigned long)d.count, surfaces, propcan);
          CFRelease(props);
        } else {
          printf("ARM registry accelerator=%s props=unreadable\n", name);
        }
        for (uint32_t type = 0; type < 3; type++) {
          io_connect_t c = 0;
          kern_return_t kr = IOServiceOpen(acc, mach_task_self(), type, &c);
          printf("ARM registry open AGXAccelerator type=%u kr=0x%x\n", type, kr);
          if (c) IOServiceClose(c);
        }
        IOObjectRelease(acc);
      }
      for (const char *cls : {"IOGPUDeviceUserClient", "AGXDeviceUserClient", "IOGPUDevice"}) {
        io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(cls));
        printf("ARM registry match %s=%s\n", cls, s ? "found" : "none");
        if (s) IOObjectRelease(s);
      }
    }
  }
  return 0;
}
