// K-2 freed-KV reader (review/K2-FREED-KV-2026-10-23.md). Same user, no
// sandbox. A sample is a 32-byte window at in-page offset 1024 of a 16 KiB
// page with 12 or more distinct byte values (the rule of the test child).
// A hit is a full 32-byte match at any 8-byte-aligned offset.
//
//   k2-reader scan SAMPLES CANARY PRIV_GIB SHARED_GIB CPU_GIB
//       allocate fresh private MTLBuffers (chunk size, blit to a shared
//       staging buffer), fresh shared MTLBuffers and fresh anonymous pages,
//       write one byte at the end of each 16 KiB page so the page is backed,
//       and scan them; prints the physical footprint growth
//   k2-reader control GIB
//       same process: fill private buffers, heap-placed private buffers and
//       shared buffers with random bytes, take samples, release them without
//       a clear, then allocate fresh ones and scan
//   k2-reader plant SAMPLES_OUT GIB
//       fill private buffers with random bytes, write the samples, release
//       the buffers and exit (the ordinary cross-process target)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <mach/mach.h>

#define CHUNK 17039360ull
#define PAGE 16384ull
#define WOFF 1024ull
#define WLEN 32

typedef struct {
  uint8_t *s;       // n * 32 bytes
  size_t n, cap;
  uint32_t *slot;   // sample index + 1, 0 = empty
  uint64_t mask;
  uint8_t *found;   // per sample
} Set;

typedef struct {
  uint64_t bytes, nonzero, hits, canary;
} Tally;

static uint64_t key8(const uint8_t *p) { uint64_t k; memcpy(&k, p, 8); return k; }
static uint64_t mix(uint64_t k) { k ^= k >> 33; k *= 0xff51afd7ed558ccdull; k ^= k >> 33; return k; }

static void set_add(Set *t, const uint8_t *w) {
  if (t->n == t->cap) {
    t->cap = t->cap ? 2 * t->cap : 4096;
    t->s = realloc(t->s, t->cap * WLEN);
  }
  memcpy(t->s + t->n * WLEN, w, WLEN);
  t->n++;
}

static void set_build(Set *t) {
  uint64_t size = 1;
  while (size < 4 * (uint64_t)t->n + 16) size <<= 1;
  t->mask = size - 1;
  t->slot = calloc(size, sizeof(uint32_t));
  t->found = calloc(t->n + 1, 1);
  for (size_t i = 0; i < t->n; i++) {
    uint64_t h = mix(key8(t->s + i * WLEN)) & t->mask;
    while (t->slot[h]) h = (h + 1) & t->mask;
    t->slot[h] = (uint32_t)(i + 1);
  }
}

static size_t set_distinct(const Set *t) {
  size_t c = 0;
  for (size_t i = 0; i < t->n; i++) c += t->found[i];
  return c;
}

static int window_ok(const uint8_t *w) {
  uint8_t seen[256] = {0};
  int d = 0;
  for (int i = 0; i < WLEN; i++) if (!seen[w[i]]) { seen[w[i]] = 1; d++; }
  return d >= 12;
}

static void take_samples(Set *t, const uint8_t *p, uint64_t len) {
  for (uint64_t pg = 0; pg * PAGE + WOFF + WLEN <= len; pg++) {
    const uint8_t *w = p + pg * PAGE + WOFF;
    if (window_ok(w)) set_add(t, w);
  }
}

static void scan(const Set *t, const char *canary, const uint8_t *p, uint64_t len, Tally *y) {
  y->bytes += len;
  const uint64_t *q = (const uint64_t *)p;
  uint64_t words = len / 8;
  for (uint64_t i = 0; i < words; i++) {
    uint64_t k = q[i];
    if (!k) continue;
    for (int b = 0; b < 8; b++) y->nonzero += ((k >> (8 * b)) & 0xff) != 0;
    if (!t || !t->n || i * 8 + WLEN > len) continue;
    uint64_t h = mix(k) & t->mask;
    while (t->slot[h]) {
      uint32_t s = t->slot[h] - 1;
      if (key8(t->s + (uint64_t)s * WLEN) == k && !memcmp(t->s + (uint64_t)s * WLEN, p + i * 8, WLEN)) {
        y->hits++;
        t->found[s] = 1;
      }
      h = (h + 1) & t->mask;
    }
  }
  if (canary && *canary) {
    size_t cl = strlen(canary);
    const uint8_t *at = p, *end = p + len;
    while (at < end) {
      const uint8_t *m = memmem(at, (size_t)(end - at), canary, cl);
      if (!m) break;
      y->canary++;
      at = m + 1;
    }
  }
}

static void report(const char *tag, const Set *t, const Tally *y, uint64_t count) {
  printf("SCAN %s buffers=%llu bytes=%llu nonzero=%llu hits=%llu distinct=%zu of %zu canary=%llu\n", tag,
         (unsigned long long)count, (unsigned long long)y->bytes, (unsigned long long)y->nonzero,
         (unsigned long long)y->hits, t ? set_distinct(t) : (size_t)0, t ? t->n : (size_t)0,
         (unsigned long long)y->canary);
  fflush(stdout);
}

static void blit(id<MTLCommandQueue> q, id<MTLBuffer> from, id<MTLBuffer> to, uint64_t len) {
  id<MTLCommandBuffer> c = [q commandBuffer];
  id<MTLBlitCommandEncoder> e = [c blitCommandEncoder];
  [e copyFromBuffer:from sourceOffset:0 toBuffer:to destinationOffset:0 size:len];
  [e endEncoding];
  [c commit];
  [c waitUntilCompleted];
  if (c.status != MTLCommandBufferStatusCompleted) { fprintf(stderr, "blit failed\n"); exit(3); }
}

static uint64_t footprint(void) {
  task_vm_info_data_t info;
  mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &n) != KERN_SUCCESS) return 0;
  return info.phys_footprint;
}

static void fill_random(uint8_t *p, uint64_t len) {
  arc4random_buf(p, len);
}

// Fresh private buffers of chunk size, copied out through `staging`.
static uint64_t scan_private(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLBuffer> staging, id<MTLBuffer> touch,
                             const Set *t, const char *canary, uint64_t total, Tally *y, NSMutableArray *keep) {
  uint64_t n = 0;
  for (uint64_t got = 0; got < total; got += CHUNK, n++) {
    id<MTLBuffer> b = [d newBufferWithLength:CHUNK options:MTLResourceStorageModePrivate];
    if (!b) { fprintf(stderr, "private allocation %llu failed\n", (unsigned long long)n); break; }
    [keep addObject:b];
    if (touch) {  // one byte at the end of each page makes the GPU back the page
      id<MTLCommandBuffer> c = [q commandBuffer];
      id<MTLBlitCommandEncoder> e = [c blitCommandEncoder];
      for (uint64_t off = 0; off < CHUNK; off += PAGE)
        [e copyFromBuffer:touch sourceOffset:0 toBuffer:b destinationOffset:off + PAGE - 1 size:1];
      [e endEncoding];
      [c commit];
      [c waitUntilCompleted];
    }
    blit(q, b, staging, CHUNK);
    scan(t, canary, staging.contents, CHUNK, y);
    if (touch) y->nonzero -= CHUNK / PAGE;
  }
  return n;
}

static uint64_t scan_shared(id<MTLDevice> d, int touch, const Set *t, const char *canary, uint64_t total, Tally *y,
                            NSMutableArray *keep) {
  uint64_t n = 0;
  for (uint64_t got = 0; got < total; got += CHUNK, n++) {
    id<MTLBuffer> b = [d newBufferWithLength:CHUNK options:MTLResourceStorageModeShared];
    if (!b) { fprintf(stderr, "shared allocation %llu failed\n", (unsigned long long)n); break; }
    [keep addObject:b];
    uint8_t *p = b.contents;
    if (touch) for (uint64_t off = 0; off < CHUNK; off += PAGE) p[off + PAGE - 1] = 1;
    scan(t, canary, p, CHUNK, y);
    if (touch) y->nonzero -= CHUNK / PAGE;
  }
  return n;
}

static uint64_t scan_cpu(const Set *t, const char *canary, uint64_t total, Tally *y) {
  uint8_t *p = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
  if (p == MAP_FAILED) { fprintf(stderr, "mmap failed\n"); return 0; }
  for (uint64_t off = 0; off < total; off += PAGE) p[off + PAGE - 1] = 1;  // back the page
  scan(t, canary, p, total, y);
  y->nonzero -= total / PAGE;  // the written bytes
  munmap(p, total);
  return total / PAGE;
}

static int load_samples(Set *t, const char *path) {
  FILE *f = fopen(path, "r");
  if (!f) return -1;
  char line[256];
  uint8_t w[WLEN];
  while (fgets(line, sizeof line, f)) {
    if (strlen(line) < 2 * WLEN) continue;
    int ok = 1;
    for (int i = 0; i < WLEN && ok; i++) {
      unsigned v;
      if (sscanf(line + 2 * i, "%2x", &v) != 1) ok = 0;
      w[i] = (uint8_t)v;
    }
    if (ok) set_add(t, w);
  }
  fclose(f);
  return 0;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: see the header\n"); return 2; }
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> q = [d newCommandQueue];
    if (!d || !q) { fprintf(stderr, "no Metal device\n"); return 2; }
    const uint64_t G = 1ull << 30;
    id<MTLBuffer> staging = [d newBufferWithLength:CHUNK options:MTLResourceStorageModeShared];

    if (!strcmp(argv[1], "scan") && argc == 7) {
      Set t = {0};
      if (load_samples(&t, argv[2]) || !t.n) { fprintf(stderr, "no samples in %s\n", argv[2]); return 2; }
      set_build(&t);
      printf("SAMPLES loaded=%zu from=%s canary=%s\n", t.n, argv[2], argv[3]);
      NSMutableArray *keep = [NSMutableArray array];
      Tally a = {0}, b = {0}, c = {0};
      id<MTLBuffer> one = [d newBufferWithLength:16 options:MTLResourceStorageModeShared];
      memset(one.contents, 1, 16);
      uint64_t f0 = footprint();
      uint64_t na = scan_private(d, q, staging, one, &t, argv[3], (uint64_t)(atof(argv[4]) * G), &a, keep);
      report("private", &t, &a, na);
      uint64_t f1 = footprint();
      uint64_t nb = scan_shared(d, 1, &t, argv[3], (uint64_t)(atof(argv[5]) * G), &b, keep);
      report("shared", &t, &b, nb);
      uint64_t f2 = footprint();
      printf("FOOTPRINT start=%llu after_private=%llu after_shared=%llu private_growth=%llu shared_growth=%llu\n",
             (unsigned long long)f0, (unsigned long long)f1, (unsigned long long)f2,
             (unsigned long long)(f1 - f0), (unsigned long long)(f2 - f1));
      uint64_t nc = scan_cpu(&t, argv[3], (uint64_t)(atof(argv[6]) * G), &c);
      report("cpu", &t, &c, nc);
      printf("TOTAL scanned=%llu hits=%llu distinct=%zu canary=%llu\n",
             (unsigned long long)(a.bytes + b.bytes + c.bytes), (unsigned long long)(a.hits + b.hits + c.hits),
             set_distinct(&t), (unsigned long long)(a.canary + b.canary + c.canary));
      return 0;
    }

    if (!strcmp(argv[1], "plant") && argc == 4) {
      uint64_t total = (uint64_t)(atof(argv[3]) * G);
      Set t = {0};
      NSMutableArray *bufs = [NSMutableArray array];
      for (uint64_t got = 0; got < total; got += CHUNK) {
        id<MTLBuffer> b = [d newBufferWithLength:CHUNK options:MTLResourceStorageModePrivate];
        if (!b) break;
        fill_random(staging.contents, CHUNK);
        take_samples(&t, staging.contents, CHUNK);
        blit(q, staging, b, CHUNK);
        [bufs addObject:b];
      }
      memset(staging.contents, 0, CHUNK);
      FILE *f = fopen(argv[2], "w");
      if (!f) return 2;
      for (size_t i = 0; i < t.n; i++) {
        for (int j = 0; j < WLEN; j++) fprintf(f, "%02x", t.s[i * WLEN + j]);
        fputc('\n', f);
      }
      fclose(f);
      printf("PLANT buffers=%lu samples=%zu released\n", (unsigned long)bufs.count, t.n);
      [bufs removeAllObjects];
      return 0;
    }

    if (!strcmp(argv[1], "control") && argc == 3) {
      uint64_t total = (uint64_t)(atof(argv[2]) * G);
      uint64_t count = total / CHUNK;
      // A: plain private buffers, released, then fresh private buffers.
      {
        Set t = {0};
        @autoreleasepool {
          NSMutableArray *bufs = [NSMutableArray array];
          for (uint64_t i = 0; i < count; i++) {
            id<MTLBuffer> b = [d newBufferWithLength:CHUNK options:MTLResourceStorageModePrivate];
            fill_random(staging.contents, CHUNK);
            take_samples(&t, staging.contents, CHUNK);
            blit(q, staging, b, CHUNK);
            [bufs addObject:b];
          }
          [bufs removeAllObjects];
        }
        memset(staging.contents, 0, CHUNK);
        set_build(&t);
        NSMutableArray *keep = [NSMutableArray array];
        Tally y = {0};
        uint64_t n = scan_private(d, q, staging, nil, &t, NULL, 2 * total, &y, keep);
        report("control-private", &t, &y, n);
      }
      // B: private buffers placed in one placement heap, released, then
      // fresh buffers placed at the same offsets.
      {
        Set t = {0};
        MTLHeapDescriptor *hd = [MTLHeapDescriptor new];
        hd.type = MTLHeapTypePlacement;
        hd.storageMode = MTLStorageModePrivate;
        hd.size = count * CHUNK;
        id<MTLHeap> heap = [d newHeapWithDescriptor:hd];
        if (!heap) { fprintf(stderr, "heap failed\n"); return 3; }
        @autoreleasepool {
          NSMutableArray *bufs = [NSMutableArray array];
          for (uint64_t i = 0; i < count; i++) {
            id<MTLBuffer> b = [heap newBufferWithLength:CHUNK options:MTLResourceStorageModePrivate offset:i * CHUNK];
            if (!b) { fprintf(stderr, "heap buffer failed\n"); return 3; }
            fill_random(staging.contents, CHUNK);
            take_samples(&t, staging.contents, CHUNK);
            blit(q, staging, b, CHUNK);
            [bufs addObject:b];
          }
          [bufs removeAllObjects];
        }
        memset(staging.contents, 0, CHUNK);
        set_build(&t);
        Tally y = {0};
        @autoreleasepool {
          for (uint64_t i = 0; i < count; i++) {
            id<MTLBuffer> b = [heap newBufferWithLength:CHUNK options:MTLResourceStorageModePrivate offset:i * CHUNK];
            blit(q, b, staging, CHUNK);
            scan(&t, NULL, staging.contents, CHUNK, &y);
          }
        }
        report("control-heap", &t, &y, count);
      }
      // C: plain shared buffers, released, then fresh shared buffers.
      {
        Set t = {0};
        @autoreleasepool {
          NSMutableArray *bufs = [NSMutableArray array];
          for (uint64_t i = 0; i < count; i++) {
            id<MTLBuffer> b = [d newBufferWithLength:CHUNK options:MTLResourceStorageModeShared];
            fill_random(b.contents, CHUNK);
            take_samples(&t, b.contents, CHUNK);
            [bufs addObject:b];
          }
          [bufs removeAllObjects];
        }
        set_build(&t);
        NSMutableArray *keep = [NSMutableArray array];
        Tally y = {0};
        uint64_t n = scan_shared(d, 0, &t, NULL, 2 * total, &y, keep);
        report("control-shared", &t, &y, n);
      }
      return 0;
    }
    fprintf(stderr, "bad arguments\n");
    return 2;
  }
}
