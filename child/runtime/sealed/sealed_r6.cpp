// sealed_r6 — see sealed_r6.h. Plain C++ (no Objective-C), CommonCrypto only.
#include "sealed/sealed_r6.h"
#include "sealed/sealed_r2.h"

#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <mutex>

namespace {

sealed_r6_entry_t gEntries[SEALED_R6_MAX_ENTRIES];
uint32_t gCount = 0;
uint8_t gFileForm[64 * 1024 + 64];
size_t gFileLen = 0;
std::atomic<int> gLatched{0};
std::mutex gMu;

// Root directory descriptors: index 1 target, 2 draft, 3 package root.
int gRootFd[4] = {-1, -1, -1, -1};
char gRootPath[4][1024];
dev_t gRootDev[4];
ino_t gRootIno[4];

// Review S3 (2026-10-21). Per manifest entry: the funnel region, the number of
// Metal no-copy wraps of it, and the open log (the kernel's name for the
// opened file, its device and inode). The log lives in memory only.
struct FunnelRegion {
  uint64_t addr = 0, alloc = 0;
  uint32_t first_seg = 0, nseg = 0;  // VM map entries recorded after the protect
  uint32_t wraps = 0;
};
struct Seg {
  uint64_t start, size, obj;
};
struct OpenLog {
  int opened = 0;
  dev_t dev = 0;
  ino_t ino = 0;
  char kpath[MAXPATHLEN];
};
FunnelRegion gRegion[SEALED_R6_MAX_ENTRIES];
OpenLog gOpenLog[SEALED_R6_MAX_ENTRIES];
uint32_t gOpenCount = 0;
// 64 GiB per entry at most and >= 8 MiB per map entry (measured: 128 MiB).
Seg gSeg[8192];
dev_t gDevNullRdev = 0;
bool gDevNullOk = false;
constexpr int kFunnelTag = VM_MEMORY_APPLICATION_SPECIFIC_1 + 13;
uint32_t gSegCount = 0;

[[noreturn]] void die(const char *why, const char *what) {
  char b[1400];
  int n = snprintf(b, sizeof b, "sealed-r6: %s: %s\n", why, what ? what : "");
  if (n > 0) (void)!write(2, b, (size_t)n);
  if (n > 0) sealed_reason_write(b, (size_t)n);
  _exit(113);
}

uint32_t be32(const uint8_t *p) {
  return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
uint16_t be16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
uint64_t be64(const uint8_t *p) {
  uint64_t v = 0;
  for (int i = 0; i < 8; i++) v = v << 8 | p[i];
  return v;
}

// R6 path rules: non-empty, relative, '/'-separated components of
// [A-Za-z0-9._-], no '.' or '..' component, no empty component.
bool path_ok(const char *p, size_t n) {
  if (n == 0 || n > SEALED_R6_MAX_PATH || p[0] == '/' || p[n - 1] == '/') return false;
  size_t start = 0;
  for (size_t i = 0; i <= n; i++) {
    if (i == n || p[i] == '/') {
      size_t len = i - start;
      if (len == 0) return false;
      if (len == 1 && p[start] == '.') return false;
      if (len == 2 && p[start] == '.' && p[start + 1] == '.') return false;
      start = i + 1;
      continue;
    }
    char c = p[i];
    bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
              c == '.' || c == '_' || c == '-';
    if (!ok) return false;
  }
  return true;
}

// One VM map entry at or after `addr` (depth 0, no submap recursion).
bool region_at(uint64_t addr, uint64_t *start, uint64_t *size, vm_region_submap_info_data_64_t *si) {
  mach_vm_address_t a = addr;
  mach_vm_size_t s = 0;
  natural_t depth = 0;
  mach_msg_type_number_t c = VM_REGION_SUBMAP_INFO_COUNT_64;
  if (mach_vm_region_recurse(mach_task_self(), &a, &s, &depth, (vm_region_recurse_info_t)si, &c) != KERN_SUCCESS)
    return false;
  *start = a;
  *size = s;
  return true;
}

int cmp_entry(const sealed_r6_entry_t &a, const sealed_r6_entry_t &b) {
  if (a.tag != b.tag) return a.tag < b.tag ? -1 : 1;
  return strcmp(a.path, b.path);
}

// Opens `rel` (a/b/c) below dirfd with O_NOFOLLOW at every component.
int open_below(int dirfd, const char *rel, int final_flags) {
  char buf[SEALED_R6_MAX_PATH + 1];
  snprintf(buf, sizeof buf, "%s", rel);
  int cur = dup(dirfd);
  if (cur < 0) return -1;
  char *save = nullptr;
  char *tok = strtok_r(buf, "/", &save);
  while (tok) {
    char *next = strtok_r(nullptr, "/", &save);
    int fl = next ? (O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : (final_flags | O_NOFOLLOW | O_CLOEXEC);
    int fd = openat(cur, tok, fl);
    int e = errno;
    close(cur);
    if (fd < 0) { errno = e; return -1; }
    cur = fd;
    tok = next;
  }
  return cur;
}

int open_dir_nofollow(const char *abs) {
  // Every component below "/" with O_NOFOLLOW, so a symlinked parent fails.
  if (!abs || abs[0] != '/') return -1;
  int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (fd < 0) return -1;
  if (abs[1] == '\0') return fd;
  int r = open_below(fd, abs + 1, O_RDONLY | O_DIRECTORY);
  close(fd);
  return r;
}

// Which root an absolute path is under, and the relative rest.
int split_root(const char *abs, const char **rel) {
  for (int t = 1; t <= 3; t++) {
    if (gRootFd[t] < 0) continue;
    size_t n = strlen(gRootPath[t]);
    if (strncmp(abs, gRootPath[t], n) == 0 && abs[n] == '/') {
      *rel = abs + n + 1;
      return t;
    }
  }
  return 0;
}

}  // namespace

extern "C" int sealed_r6_parse(const uint8_t *buf, size_t len) {
  const size_t pre = sizeof(SEALED_R6_PREFIX) - 1;
  if (!buf || len < pre + 4 || len > sizeof gFileForm) return -1;
  if (memcmp(buf, SEALED_R6_PREFIX, pre) != 0) return -1;
  uint32_t count = be32(buf + pre);
  if (count == 0 || count > SEALED_R6_MAX_ENTRIES) return -1;
  size_t off = pre + 4;
  for (uint32_t i = 0; i < count; i++) {
    if (off + 1 + 2 > len) return -1;
    sealed_r6_entry_t &e = gEntries[i];
    memset(&e, 0, sizeof e);
    e.tag = buf[off];
    uint16_t pl = be16(buf + off + 1);
    off += 3;
    if (e.tag < 1 || e.tag > 3 || off + pl + 8 + 32 > len) return -1;
    if (!path_ok((const char *)buf + off, pl)) return -1;
    memcpy(e.path, buf + off, pl);
    e.path[pl] = '\0';
    off += pl;
    e.size = be64(buf + off);
    off += 8;
    memcpy(e.sha256, buf + off, 32);
    off += 32;
    if (e.size == 0) return -1;
    if (i > 0 && cmp_entry(gEntries[i - 1], e) >= 0) return -1;  // sorted, no duplicates
  }
  if (off != len) return -1;  // trailing bytes
  gCount = count;
  memcpy(gFileForm, buf, len);
  gFileLen = len;
  return 0;
}

extern "C" void sealed_r6_manifest_hash(uint8_t out[32]) {
  const size_t pre = sizeof(SEALED_R6_PREFIX) - 1;
  CC_SHA256_CTX c;
  CC_SHA256_Init(&c);
  CC_SHA256_Update(&c, gFileForm, (CC_LONG)pre);
  uint8_t kind[4] = {0, 0, 0, (uint8_t)SEALED_R6_KIND_SPLASH};
  CC_SHA256_Update(&c, kind, 4);
  CC_SHA256_Update(&c, gFileForm + pre, (CC_LONG)(gFileLen - pre));
  CC_SHA256_Final(out, &c);
}

extern "C" int sealed_r6_open_roots(const char *package_root, const char *target_root,
                                    const char *draft_root) {
  const char *paths[4] = {nullptr, target_root, draft_root, package_root};
  for (int t = 1; t <= 3; t++) {
    if (!paths[t] || strlen(paths[t]) >= sizeof gRootPath[t]) return -1;
    int fd = open_dir_nofollow(paths[t]);
    if (fd < 0) return -1;
    // F_GETPATH must equal the given path (a firmlinked or symlinked parent differs).
    char got[MAXPATHLEN];
    if (fcntl(fd, F_GETPATH, got) != 0 || strcmp(got, paths[t]) != 0) { close(fd); return -1; }
    struct stat st;
    if (fstat(fd, &st) != 0) { close(fd); return -1; }
    gRootDev[t] = st.st_dev;
    gRootIno[t] = st.st_ino;
    gRootFd[t] = fd;
    snprintf(gRootPath[t], sizeof gRootPath[t], "%s", paths[t]);
  }
  return 0;
}

extern "C" int sealed_r6_lookup(const char *abs_path) {
  if (!abs_path) return -1;
  const char *rel = nullptr;
  int tag = split_root(abs_path, &rel);
  if (!tag) return -1;
  for (uint32_t i = 0; i < gCount; i++)
    if (gEntries[i].tag == tag && strcmp(gEntries[i].path, rel) == 0) return (int)i;
  return -1;
}

extern "C" int64_t sealed_r6_size(const char *abs_path) {
  int i = sealed_r6_lookup(abs_path);
  return i < 0 ? -1 : (int64_t)gEntries[i].size;
}

extern "C" void *sealed_r6_read(const char *abs_path, uint64_t *len) {
  if (gLatched.load()) die("open after the latch", abs_path);
  std::lock_guard<std::mutex> lock(gMu);
  // Review N1: the latch closes the root descriptors under gMu, so check it
  // again under the lock; a closed descriptor number can be reused.
  if (gLatched.load()) die("open after the latch", abs_path);
  int i = sealed_r6_lookup(abs_path);
  if (i < 0) die("path not in the manifest", abs_path);
  // Review S3: each manifest file is read once. A second read of a loaded
  // path is refused (the spec's rule; a re-read would be hashed again, but it
  // is also an unexplained file access).
  if (gEntries[i].loaded) die("second read of a loaded path", abs_path);
  sealed_r6_entry_t &e = gEntries[i];
  const char *rel = nullptr;
  int tag = split_root(abs_path, &rel);
  // One openat from the root descriptor: no symlink anywhere in the path
  // (O_NOFOLLOW_ANY), never leaves the root (O_RESOLVE_BENEATH). The R5
  // sandbox allows this form for a literal-listed file and denies opening
  // the intermediate directories (measured 2026-10-12).
  int fd = openat(gRootFd[tag], rel, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH);
  if (fd < 0) die("open failed", abs_path);
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) die("not a regular file", abs_path);
  // Open log (review S3): the name the kernel gives the opened file, compared
  // with the manifest path in the self-audit, and the file's identity, which
  // the descriptor check uses (a hard link elsewhere has the same identity).
  OpenLog &ol = gOpenLog[i];
  if (fcntl(fd, F_GETPATH, ol.kpath) != 0) die("cannot get the opened file's path", abs_path);
  ol.dev = st.st_dev;
  ol.ino = st.st_ino;
  ol.opened++;
  gOpenCount++;
  // Review N2: cap the size before the page rounding (it wraps near 2^64).
  // The largest file of any supported model is far below 64 GiB.
  if (e.size == 0 || e.size > (64ull << 30)) die("manifest size out of bounds", abs_path);
  vm_size_t page = vm_page_size;
  mach_vm_size_t alloc = (e.size + page - 1) / page * page;
  mach_vm_address_t addr = 0;
  // Own VM tag: a fresh allocation is never merged into a neighbouring map
  // entry of other anonymous memory, so the region's object is the funnel's.
  if (mach_vm_allocate(mach_task_self(), &addr, alloc, VM_FLAGS_ANYWHERE | VM_MAKE_TAG(kFunnelTag)) != KERN_SUCCESS)
    die("vm_allocate failed", abs_path);
  uint8_t *p = (uint8_t *)addr;
  uint64_t got = 0;
  const size_t chunk = 64u << 20;  // below INT_MAX
  while (got < e.size) {
    size_t want = (size_t)((e.size - got) < chunk ? (e.size - got) : chunk);
    ssize_t r = read(fd, p + got, want);
    if (r < 0) { if (errno == EINTR) continue; die("read failed", abs_path); }
    if (r == 0) die("end of file before the manifest size", abs_path);
    got += (uint64_t)r;
  }
  uint8_t extra;
  ssize_t r2;
  do { r2 = read(fd, &extra, 1); } while (r2 < 0 && errno == EINTR);
  if (r2 != 0) die("file is larger than the manifest size", abs_path);
  close(fd);
#if defined(SEALED_TEST_RW_ALIAS) || defined(SEALED_TEST_RW_ALIAS_DROP)
  // Test build: a writable memory entry on the funnel memory, made before the
  // protect. RW_ALIAS keeps it, maps it writable and writes through it after
  // the protect; RW_ALIAS_DROP releases it before the protect (control).
  mach_port_t alias = MACH_PORT_NULL;
  memory_object_size_t es = alloc;   // the entry may cover only the first map entry
  if (strcmp(e.path, "head.bin") == 0) {
    kern_return_t kr = mach_make_memory_entry_64(mach_task_self(), &es, addr, VM_PROT_READ | VM_PROT_WRITE, &alias, MACH_PORT_NULL);
    char b[200];
    int m = snprintf(b, sizeof b, "test: rw memory entry on %s kr=%d size=0x%llx\n", e.path, kr, (unsigned long long)es);
    if (m > 0) sealed_reason_write(b, (size_t)m);
#if defined(SEALED_TEST_RW_ALIAS_DROP)
    mach_port_deallocate(mach_task_self(), alias);
    alias = MACH_PORT_NULL;
#endif
  }
#endif
  // The bytes become read-only for the child's life before they are hashed
  // (the original loader mapped weights PROT_READ, so Metal needs no write
  // access), and are never inherited by a fork.
  if (mach_vm_protect(mach_task_self(), addr, alloc, TRUE, VM_PROT_READ) != KERN_SUCCESS ||
      mach_vm_inherit(mach_task_self(), addr, alloc, VM_INHERIT_NONE) != KERN_SUCCESS)
    die("cannot make the weights read-only", abs_path);
#if defined(SEALED_TEST_RW_ALIAS)
  if (alias != MACH_PORT_NULL) {
    mach_vm_address_t w = 0;
    kern_return_t kr = mach_vm_map(mach_task_self(), &w, es, 0, VM_FLAGS_ANYWHERE, alias, 0, FALSE,
                                   VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE);
    // The byte is changed and restored, so the hash still matches: only the
    // share-mode check can refuse. The read-only view shows the change.
    uint8_t before = p[0], seen = before;
    if (kr == KERN_SUCCESS) {
      ((volatile uint8_t *)w)[0] = (uint8_t)(before ^ 0xff);
      seen = ((volatile uint8_t *)p)[0];
      ((volatile uint8_t *)w)[0] = before;
    }
    char b[200];
    int m = snprintf(b, sizeof b, "test: wrote through the alias after the protect kr=%d read-only view changed=%d restored=%d\n",
                     kr, seen != before, p[0] == before);
    if (m > 0) sealed_reason_write(b, (size_t)m);
  }
#endif
  // Review S3 share mode: after the max-read-only protect, no new writable
  // mapping or memory entry of this memory can be made (measured: KERN_
  // PROTECTION_FAILURE). A writable one made before the protect keeps its
  // write access (measured), and it holds a reference on the VM object. So
  // here, before the hash, every map entry of the region must be private with
  // exactly one reference (this mapping), read-only with a read-only maximum.
  FunnelRegion &fr = gRegion[i];
  fr.addr = addr;
  fr.alloc = alloc;
  fr.first_seg = gSegCount;
  for (uint64_t cur = addr; cur < addr + alloc;) {
    uint64_t s0 = 0, sz = 0;
    vm_region_submap_info_data_64_t si;
    if (!region_at(cur, &s0, &sz, &si)) die("cannot read the weights region", abs_path);
    if (s0 != cur || sz == 0 || s0 + sz > addr + alloc) die("weights region layout differs from the allocation", abs_path);
#if !defined(SEALED_TEST_NO_SHAREMODE)
    if (si.share_mode != SM_PRIVATE || si.ref_count != 1 || si.is_submap || si.shadow_depth != 0 || si.user_tag != kFunnelTag ||
        si.protection != VM_PROT_READ || si.max_protection != VM_PROT_READ || si.inheritance != VM_INHERIT_NONE) {
      char w[MAXPATHLEN + 160];
      snprintf(w, sizeof w, "%s sm=%u ref=%u prot=%d/%d inh=%u shadow=%u", abs_path, si.share_mode, si.ref_count,
               si.protection, si.max_protection, si.inheritance, si.shadow_depth);
      die("weights region not private before the hash", w);
    }
#endif
    if (gSegCount >= sizeof gSeg / sizeof gSeg[0]) die("too many weights map entries", abs_path);
    gSeg[gSegCount++] = {s0, sz, si.object_id_full};
    fr.nseg++;
    cur = s0 + sz;
  }
  uint8_t h[32];
  CC_SHA256_CTX c;
  CC_SHA256_Init(&c);
  uint64_t done = 0;
  while (done < e.size) {
    CC_LONG n = (CC_LONG)((e.size - done) < chunk ? (e.size - done) : chunk);
    CC_SHA256_Update(&c, p + done, n);
    done += n;
  }
  CC_SHA256_Final(h, &c);
  if (memcmp(h, e.sha256, 32) != 0) die("SHA-256 mismatch", abs_path);
  e.loaded = 1;
  if (len) *len = e.size;
  return p;
}

extern "C" size_t sealed_r6_abs_paths(const char *const **out) {
  static char *paths[SEALED_R6_MAX_ENTRIES];
  static bool built = false;
  if (!built) {
    for (uint32_t i = 0; i < gCount; i++) {
      char b[2400];
      snprintf(b, sizeof b, "%s/%s", gRootPath[gEntries[i].tag], gEntries[i].path);
      paths[i] = strdup(b);
    }
    built = true;
  }
  *out = paths;
  return gCount;
}

extern "C" void sealed_r6_note_gpu_wrap(const void *address) {
  std::lock_guard<std::mutex> lock(gMu);
  if (gLatched.load()) die("GPU wrap after the latch", nullptr);
  for (uint32_t i = 0; i < gCount; i++)
    if (gEntries[i].loaded && gRegion[i].addr == (uint64_t)(uintptr_t)address) {
      gRegion[i].wraps++;
      return;
    }
  die("GPU wrap of memory outside the funnel", nullptr);
}

extern "C" void sealed_r6_latch(void) {
  std::lock_guard<std::mutex> lock(gMu);
#if defined(SEALED_TEST_SHARE_ENTRY) || defined(SEALED_TEST_SHARE_ENTRY_CTL)
  {
    // Test build: a read-only memory entry (the handle another task would map)
    // on a weights region (SHARE_ENTRY) or on ordinary anonymous memory
    // (SHARE_ENTRY_CTL, control). The port is kept, not sent.
    static mach_port_t entry = MACH_PORT_NULL;
    const char *what = "anonymous control memory";
    mach_vm_address_t a = 0;
    mach_vm_size_t sz = 1 << 20;
#if defined(SEALED_TEST_SHARE_ENTRY)
    for (uint32_t i = 0; i < gCount; i++)
      if (gEntries[i].tag == 1 && strcmp(gEntries[i].path, "head.bin") == 0) {
        a = gRegion[i].addr;
        sz = gRegion[i].alloc;
        what = "target/head.bin";
      }
#else
    mach_vm_allocate(mach_task_self(), &a, sz, VM_FLAGS_ANYWHERE);
    memset((void *)a, 1, sz);
#endif
    uint64_t s0, s1;
    vm_region_submap_info_data_64_t before, after;
    bool ok = a && region_at(a, &s0, &s1, &before);
    memory_object_size_t es = sz;
    kern_return_t kr = ok ? mach_make_memory_entry_64(mach_task_self(), &es, a, VM_PROT_READ, &entry, MACH_PORT_NULL) : -1;
    ok = ok && region_at(a, &s0, &s1, &after);
    char b[300];
    int m = snprintf(b, sizeof b, "test: memory entry on %s kr=%d sm %u->%u ref %u->%u\n", what, kr,
                     ok ? before.share_mode : 0, ok ? after.share_mode : 0, ok ? before.ref_count : 0,
                     ok ? after.ref_count : 0);
    if (m > 0) sealed_reason_write(b, (size_t)m);
  }
#endif
  gLatched.store(1);
  for (int t = 1; t <= 3; t++) {
    if (gRootFd[t] >= 0) close(gRootFd[t]);
    gRootFd[t] = -1;
  }
}

extern "C" int sealed_r6_unloaded(void) {
  int n = 0;
  for (uint32_t i = 0; i < gCount; i++)
    if (!gEntries[i].loaded) n++;
  return n;
}

// Review S4 (2026-10-20): a mapped file is accepted only on the sealed,
// read-only system volume. Region info reports the same device number for
// Data-volume files (measured: /private/tmp and logd files report the root
// device), so the test is by path:
//  - the prefixes below are on the sealed system volume, and
//  - none of the firmlinks to the Data volume (/usr/share/firmlinks on
//    macOS 27) is under them, except the ones refused explicitly here.
bool sealed_volume_path(const char *f) {
  static const char *const kFirmlinked[] = {
      "/System/Library/Caches", "/System/Library/Assets", "/System/Library/AssetsV2",
      "/System/Library/PreinstalledAssets", "/System/Library/PreinstalledAssetsV2",
      "/System/Library/Speech", "/System/Library/CoreServices/CoreTypes.bundle/Contents/Library",
      "/usr/libexec/cups", "/usr/share/snmp", "/usr/local", nullptr};
  for (int i = 0; kFirmlinked[i]; i++) {
    size_t n = strlen(kFirmlinked[i]);
    if (strncmp(f, kFirmlinked[i], n) == 0 && (f[n] == '/' || f[n] == '\0')) return false;
  }
  if (strstr(f, "/../") || strstr(f, "/./")) return false;
  static const char *const kSealed[] = {"/System/Library/", "/System/iOSSupport/", "/usr/lib/",
                                        "/usr/share/", "/usr/libexec/", "/System/Volumes/Preboot/Cryptexes/",
                                        "/private/preboot/Cryptexes/", nullptr};
  for (int i = 0; kSealed[i]; i++)
    if (strncmp(f, kSealed[i], strlen(kSealed[i])) == 0) return true;
  return false;
}

namespace {

const char *entry_abs(uint32_t i) {
  static char b[MAXPATHLEN];
  snprintf(b, sizeof b, "%s/%s", gRootPath[gEntries[i].tag], gEntries[i].path);
  return b;
}

// Share mode, reference count, protection and identity of every funnel map
// entry. Expected (measured 2026-10-21, M5, 27.2 beta): private with one
// reference before any Metal wrap; SM_TRUESHARED with one more reference per
// newBufferWithBytesNoCopy wrap. Any other reference (a memory entry, an
// alias mapping, a fork with shared inheritance) raises the count.
[[maybe_unused]] int audit_share(char *why, size_t why_len) {
  for (uint32_t i = 0; i < gCount; i++) {
    const FunnelRegion &fr = gRegion[i];
    if (!gEntries[i].loaded || fr.nseg == 0) {
      snprintf(why, why_len, "funnel region missing: %s", entry_abs(i));
      return -1;
    }
    unsigned want_sm = fr.wraps ? SM_TRUESHARED : SM_PRIVATE;
    unsigned want_ref = 1 + fr.wraps;
    for (uint32_t k = 0; k < fr.nseg; k++) {
      const Seg &sg = gSeg[fr.first_seg + k];
      uint64_t s0 = 0, sz = 0;
      vm_region_submap_info_data_64_t si;
      if (!region_at(sg.start, &s0, &sz, &si)) {
        snprintf(why, why_len, "weights region walk failed: %s", entry_abs(i));
        return -1;
      }
      if (s0 != sg.start || sz != sg.size || si.object_id_full != sg.obj || si.is_submap || si.user_tag != kFunnelTag) {
        snprintf(why, why_len, "weights region replaced: %s at +0x%llx", entry_abs(i),
                 (unsigned long long)(sg.start - fr.addr));
        return -1;
      }
      if (si.protection != VM_PROT_READ || si.max_protection != VM_PROT_READ || si.inheritance != VM_INHERIT_NONE ||
          si.shadow_depth != 0 || si.share_mode != want_sm || si.ref_count != want_ref) {
        snprintf(why, why_len, "weights region shared: %s sm=%u ref=%u prot=%d/%d inh=%u shadow=%u, want sm=%u ref=%u",
                 entry_abs(i), si.share_mode, si.ref_count, si.protection, si.max_protection, si.inheritance,
                 si.shadow_depth, want_sm, want_ref);
        return -1;
      }
    }
  }
  return 0;
}

// Every descriptor of the child (the kernel's list). A vnode descriptor must
// not be a file the funnel opened (device and inode, so a hard link elsewhere
// is caught), a model root, or a path below a root, and must be /dev/null or
// on the sealed system volume. The walk must see fd 0, 1 and 2.
[[maybe_unused]] int audit_fds(char *why, size_t why_len) {
  static struct proc_fdinfo fds[1024];
  int bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, fds, sizeof fds);
  if (bytes <= 0 || bytes >= (int)sizeof fds) {
    snprintf(why, why_len, "descriptor list failed n=%d errno=%d", bytes, errno);
    return -1;
  }
  int count = bytes / (int)sizeof fds[0], seen = 0;
  for (int k = 0; k < count; k++) {
    int fd = fds[k].proc_fd;
    if (fd <= 2) seen |= 1 << fd;
    if (fds[k].proc_fdtype != PROX_FDTYPE_VNODE) continue;
    if (fd == sealed_reason_fd()) continue;   // test builds only
    // Under the sandbox (measured 2026-10-21): PROC_PIDFDVNODEPATHINFO on
    // self is denied (EPERM) except for profile-allowed literals; F_GETPATH
    // works on every descriptor; fstat is denied on the write-only /dev/null
    // that the spawn puts on fd 2. So the path comes from F_GETPATH, the
    // identity from fstat, and a descriptor fstat cannot read is accepted only
    // if the kernel names it /dev/null (devfs is the file system mounted on
    // /dev). Any other failure is a failure, never a pass.
    char path[MAXPATHLEN];
    if (fcntl(fd, F_GETPATH, path) != 0) {
      if (errno == EBADF) continue;   // closed by another thread since the list
      snprintf(why, why_len, "descriptor path not readable: fd %d errno=%d", fd, errno);
      return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
      if (strcmp(path, "/dev/null") == 0) continue;
      snprintf(why, why_len, "descriptor not readable: fd %d %s errno=%d", fd, path, errno);
      return -1;
    }
    if (S_ISCHR(st.st_mode) && gDevNullOk && st.st_rdev == gDevNullRdev && strcmp(path, "/dev/null") == 0) continue;
    dev_t dev = st.st_dev;
    ino_t ino = st.st_ino;
    for (uint32_t i = 0; i < gCount; i++)
      if (gOpenLog[i].opened && gOpenLog[i].dev == dev && gOpenLog[i].ino == ino) {
        snprintf(why, why_len, "descriptor refers to a funnel-opened file: fd %d %s (manifest %s)", fd, path, entry_abs(i));
        return -1;
      }
    for (int t = 1; t <= 3; t++) {
      size_t rn = strlen(gRootPath[t]);
      if (dev == gRootDev[t] && ino == gRootIno[t]) {
        snprintf(why, why_len, "descriptor refers to a model root: fd %d %s", fd, path);
        return -1;
      }
      if (rn && strncmp(path, gRootPath[t], rn) == 0 && path[rn] == '/') {
        snprintf(why, why_len, "descriptor refers to a path under a model root: fd %d %s", fd, path);
        return -1;
      }
    }
    if (!sealed_volume_path(path)) {
      snprintf(why, why_len, "descriptor refers to a file outside the sealed volume: fd %d %s", fd, path);
      return -1;
    }
  }
  if (seen != 7) {
    snprintf(why, why_len, "the descriptor walk did not see fd 0, 1 and 2 (%d descriptors)", count);
    return -1;
  }
  return 0;
}

// Open log against the manifest: one open per entry, and the kernel's name
// for each opened file equals the manifest path (a case variant or a rename
// on disk differs; the sandbox literal and APFS case folding admit both).
[[maybe_unused]] int audit_open_log(char *why, size_t why_len) {
  uint32_t total = 0;
  for (uint32_t i = 0; i < gCount; i++) {
    const OpenLog &ol = gOpenLog[i];
    if (ol.opened != 1) {
      snprintf(why, why_len, "open log has %d opens of %s", ol.opened, entry_abs(i));
      return -1;
    }
    if (strcmp(ol.kpath, entry_abs(i)) != 0) {
      snprintf(why, why_len, "open log names a path not in the manifest: %s (opened as %s)", ol.kpath, entry_abs(i));
      return -1;
    }
    total++;
  }
  if (total != gOpenCount || total != gCount) {
    snprintf(why, why_len, "open log has %u opens for %u manifest entries", gOpenCount, gCount);
    return -1;
  }
  return 0;
}

}  // namespace

extern "C" int sealed_r6_self_audit(char *why, size_t why_len) {
  // The executable's own path, captured once before the sandbox (realpath is
  // a path lookup the profile may deny later).
  static char exe_real[MAXPATHLEN];
  if (!exe_real[0]) {
    char exe[MAXPATHLEN];
    uint32_t es = sizeof exe;
    if (_NSGetExecutablePath(exe, &es) != 0 || !realpath(exe, exe_real)) {
      if (why && why_len) snprintf(why, why_len, "cannot resolve the executable path");
      exe_real[0] = '\0';
      return -1;
    }
  }
  // Walk the regions with PROC_PIDREGIONPATHINFO, which returns the region at
  // or after `addr` together with its own start and size. A file name counts
  // only for the region it belongs to (proc_regionfilename alone reports the
  // next file-backed region for an anonymous one; measured 2026-10-12).
  uint64_t addr = 0;
  int regions = 0;
  bool saw_exe = false;
  for (;;) {
    struct proc_regionwithpathinfo ri;
    errno = 0;
    int n = proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, addr, &ri, sizeof ri);
    if (n != (int)sizeof ri) {
      // The walk ends with no region at or after `addr` (n == 0, errno
      // ESRCH or EINVAL, measured). Any other result means the audit could
      // not look, and that is a failure, never a pass (review B1, 2026-10-12).
      if (n == 0 && (errno == ESRCH || errno == EINVAL) && regions > 0) break;
      if (why && why_len) snprintf(why, why_len, "region walk failed n=%d errno=%d after %d regions", n, errno, regions);
      return -1;
    }
    regions++;
    uint64_t start = ri.prp_prinfo.pri_address, size = ri.prp_prinfo.pri_size;
    if (size == 0) break;
    const char *f = ri.prp_vip.vip_path;
    if (f[0]) {
      if (strcmp(f, exe_real) == 0) saw_exe = true;
      bool ok = strcmp(f, exe_real) == 0 || sealed_volume_path(f);
#if defined(SEALED_TEST_R7_INTERPOSE)
      // R7-T3 interposer test build only: the interposer library next to the
      // executable (neg/R7/libr7interpose.dylib) is an accepted mapping.
      if (!ok) {
        char lib[MAXPATHLEN];
        snprintf(lib, sizeof lib, "%s", exe_real);
        char *slash = strrchr(lib, '/');
        if (slash) {
          snprintf(slash + 1, sizeof lib - (size_t)(slash + 1 - lib), "libr7interpose.dylib");
          ok = strcmp(f, lib) == 0;
        }
      }
#endif
      // Residual, measured 2026-10-12 (M5, 27.2 beta): MTLCreateSystemDefaultDevice
      // maps logd's preference cache, also under the R5 sandbox. Root can
      // write that file. It is accepted only when mapped read-only and never
      // writable or executable (max protection read); it carries logging
      // preferences, not code or weights.
      if (!ok && strncmp(f, "/private/var/db/diagnostics/logd/.plist-cache.", 46) == 0 &&
          ri.prp_prinfo.pri_protection == VM_PROT_READ &&
          ri.prp_prinfo.pri_max_protection == VM_PROT_READ) {
        static bool noted = false;
        if (!noted) {
          char b[MAXPATHLEN + 64];
          int m = snprintf(b, sizeof b, "sealed-r6: accepted residual mapping (read-only): %s\n", f);
          if (m > 0) sealed_reason_write(b, (size_t)m);
          noted = true;
        }
        ok = true;
      }
      if (!ok) {
        if (why && why_len)
          snprintf(why, why_len, "%s prot=%d max=%d", f, ri.prp_prinfo.pri_protection,
                   ri.prp_prinfo.pri_max_protection);
        return -1;
      }
    }
    addr = start + size;
  }
  if (!saw_exe) {
    if (why && why_len) snprintf(why, why_len, "the walk never saw the executable (%d regions)", regions);
    return -1;
  }
  // Review S3 checks, after the load (the latch fixes the open log).
  if (gLatched.load()) {
    char tmp[16];
    char *w = (why && why_len) ? why : tmp;
    size_t wl = (why && why_len) ? why_len : sizeof tmp;
    std::lock_guard<std::mutex> lock(gMu);
#if !defined(SEALED_TEST_NO_OPENLOG) && !defined(SEALED_TEST_NO_SHAREMODE) && !defined(SEALED_TEST_NO_FDCHECK)
    if (audit_open_log(w, wl) != 0 || audit_share(w, wl) != 0 || audit_fds(w, wl) != 0) return -1;
#else
    // Mutation test builds: each SEALED_TEST_NO_* compiles one check out.
#if !defined(SEALED_TEST_NO_OPENLOG)
    if (audit_open_log(w, wl) != 0) return -1;
#endif
#if !defined(SEALED_TEST_NO_SHAREMODE)
    if (audit_share(w, wl) != 0) return -1;
#endif
#if !defined(SEALED_TEST_NO_FDCHECK)
    if (audit_fds(w, wl) != 0) return -1;
#endif
#endif
  }
  return 0;
}

extern "C" uint64_t sealed_r6_total_bytes(const char *) {
  uint64_t n = 0;
  for (uint32_t i = 0; i < gCount; i++) n += gEntries[i].size;
  return n;
}

extern "C" void sealed_r6_init(const uint8_t *manifest, size_t len, const char *package_root) {
#if defined(SEALED_TEST_NO_SHAREMODE) || defined(SEALED_TEST_NO_FDCHECK) || defined(SEALED_TEST_NO_OPENLOG)
  {
    // Mutation test build: names the S3 checks compiled out of this child.
    static const char m[] = "test: mutant"
#if defined(SEALED_TEST_NO_SHAREMODE)
                            " SEALED_TEST_NO_SHAREMODE"
#endif
#if defined(SEALED_TEST_NO_FDCHECK)
                            " SEALED_TEST_NO_FDCHECK"
#endif
#if defined(SEALED_TEST_NO_OPENLOG)
                            " SEALED_TEST_NO_OPENLOG"
#endif
                            "\n";
    sealed_reason_write(m, sizeof m - 1);
  }
#endif
  { char tmp[64]; (void)sealed_r6_self_audit(tmp, sizeof tmp); }  // caches the executable path before the sandbox
  {
    struct stat dn;
    if (stat("/dev/null", &dn) != 0 || !S_ISCHR(dn.st_mode)) die("cannot stat /dev/null", nullptr);
    gDevNullRdev = dn.st_rdev;
    gDevNullOk = true;
  }
  if (sealed_r6_parse(manifest, len) != 0) die("manifest does not parse", nullptr);
  char t[1100], d[1100];
  snprintf(t, sizeof t, "%s/target", package_root);
  snprintf(d, sizeof d, "%s/draft", package_root);
  if (sealed_r6_open_roots(package_root, t, d) != 0) die("cannot open the model roots", package_root);
#if defined(SEALED_TEST_KEEP_FD_PATH)
  {
    // Test build: a descriptor opened before the sandbox and kept for life.
    int fd = open(SEALED_TEST_KEEP_FD_PATH, O_RDONLY | O_CLOEXEC);
    char b[MAXPATHLEN + 80];
    int m = snprintf(b, sizeof b, "test: kept descriptor of " SEALED_TEST_KEEP_FD_PATH " fd=%d errno=%d\n", fd, fd < 0 ? errno : 0);
    if (m > 0) sealed_reason_write(b, (size_t)m);
  }
#endif
  // Review N6: APFS is case-insensitive here, so two entries whose absolute
  // paths differ only by case name one file. Refuse them (the charset is
  // ASCII, so an ASCII case fold is complete).
  static char abs[SEALED_R6_MAX_ENTRIES][MAXPATHLEN];
  for (uint32_t i = 0; i < gCount; i++) {
    if (snprintf(abs[i], sizeof abs[i], "%s/%s", gRootPath[gEntries[i].tag], gEntries[i].path) >= (int)sizeof abs[i])
      die("manifest path too long", gEntries[i].path);
    for (uint32_t j = 0; j < i; j++)
      if (strcasecmp(abs[i], abs[j]) == 0) die("two manifest entries name one file (case fold)", abs[i]);
  }
}
