// sealed_tee_probe — test-build-only measurements for the TEE evidence set.
// Compiled into every build, but empty unless a test switch is set, so the
// production child has no code or symbol from it.
//
// Switches:
//   SEALED_TEST_TEE_PROBES   ports, descriptors and environment per phase
//                            (R5-T3); read sweep of data-volume canaries;
//                            os_log canary; operation-class arms; Mach
//                            service lookups; sandbox-extension arm (A-17)
//   SEALED_TEST_CRASH_CANARY crash with a canary in registers after the
//                            "sandboxed" report (A-20, R1)
#include "sealed/sealed_tee_probe.h"

#if defined(SEALED_TEST_TEE_PROBES) || defined(SEALED_TEST_CRASH_CANARY)
#include "sealed/sealed_r2.h"

#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <bootstrap.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach.h>
#include <os/log.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
// sys/fsctl.h is not in the public SDK; this is FSIOC_SYNC_VOLUME from xnu.
#define TEE_FSIOC_SYNC_VOLUME _IOW('A', 1, uint32_t)
extern "C" char *sandbox_extension_issue_file(const char *extension_class, const char *path, uint32_t flags);
extern "C" int64_t sandbox_extension_consume(const char *token);

#if defined(SEALED_TEST_TEE_PROBES) && !defined(SEALED_TEST_SWEEP_HOME)
#error "SEALED_TEST_SWEEP_HOME must be set (neg/build-all.sh sets it for this user and this Mac)"
#endif
#if defined(SEALED_TEST_TEE_PROBES) && !defined(SEALED_TEST_SWEEP_UTMP)
#error "SEALED_TEST_SWEEP_UTMP must be set (neg/build-all.sh sets it for this user and this Mac)"
#endif
#if defined(SEALED_TEST_TEE_PROBES) && !defined(SEALED_TEST_SWEEP_PKG)
#error "SEALED_TEST_SWEEP_PKG must be set (neg/build-all.sh sets it for this user and this Mac)"
#endif
#ifndef SEALED_TEST_TAG
#define SEALED_TEST_TAG "tee"
#endif

namespace {

void out(const char *fmt, ...) {
  char b[1400];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(b, sizeof b, fmt, ap);
  va_end(ap);
  if (n > 0) sealed_reason_write(b, (size_t)(n < (int)sizeof b ? n : (int)sizeof b - 1));
}

#if defined(SEALED_TEST_TEE_PROBES)
void record_ports(const char *phase) {
  mach_port_name_array_t names = nullptr;
  mach_port_type_array_t types = nullptr;
  mach_msg_type_number_t nn = 0, nt = 0;
  kern_return_t kr = mach_port_names(mach_task_self(), &names, &nn, &types, &nt);
  if (kr != KERN_SUCCESS) { out("tee-probe %s ports error kr=%d\n", phase, kr); return; }
  unsigned send = 0, recv = 0, once = 0, pset = 0, dead = 0;
  for (mach_msg_type_number_t i = 0; i < nn; i++) {
    mach_port_type_t t = types[i];
    if (t & MACH_PORT_TYPE_SEND) send++;
    if (t & MACH_PORT_TYPE_RECEIVE) recv++;
    if (t & MACH_PORT_TYPE_SEND_ONCE) once++;
    if (t & MACH_PORT_TYPE_PORT_SET) pset++;
    if (t & MACH_PORT_TYPE_DEAD_NAME) dead++;
  }
  ipc_info_object_type_t kt{};
  mach_vm_address_t ka = 0;
  kern_return_t kk = nn ? mach_port_kobject(mach_task_self(), names[0], &kt, &ka) : KERN_INVALID_NAME;
  out("tee-probe %s ports total=%u send=%u receive=%u send-once=%u port-set=%u dead=%u kobject-kr=%d type=%u\n",
      phase, nn, send, recv, once, pset, dead, kk, (unsigned)kt);
  // Name-level diff between "loaded" and "serving": a new send right during
  // serving could be a new connection; a removed one is a released right.
  static mach_port_name_t snap[4096];
  static mach_port_type_t snapt[4096];
  static unsigned snapn = 0;
  if (!strcmp(phase, "loaded")) {
    snapn = nn < 4096 ? nn : 4096;
    for (unsigned i = 0; i < snapn; i++) { snap[i] = names[i]; snapt[i] = types[i]; }
  } else if (!strcmp(phase, "serving") && snapn) {
    unsigned addSend = 0, add = 0, rem = 0;
    char a[700] = "", r[700] = "";
    for (mach_msg_type_number_t i = 0; i < nn; i++) {
      bool found = false;
      for (unsigned j = 0; j < snapn; j++) if (snap[j] == names[i]) { found = true; break; }
      if (!found) {
        add++;
        if (types[i] & MACH_PORT_TYPE_SEND) addSend++;
        size_t l = strlen(a);
        if (l < sizeof a - 24) snprintf(a + l, sizeof a - l, " 0x%x:0x%x", names[i], types[i]);
      }
    }
    for (unsigned j = 0; j < snapn; j++) {
      bool found = false;
      for (mach_msg_type_number_t i = 0; i < nn; i++) if (snap[j] == names[i]) { found = true; break; }
      if (!found) {
        rem++;
        size_t l = strlen(r);
        if (l < sizeof r - 24) snprintf(r + l, sizeof r - l, " 0x%x:0x%x", snap[j], snapt[j]);
      }
    }
    out("tee-probe serving ports-diff added=%u added-send=%u removed=%u added:%s removed:%s\n", add, addSend, rem, a, r);
  }
  vm_deallocate(mach_task_self(), (vm_address_t)names, nn * sizeof *names);
  vm_deallocate(mach_task_self(), (vm_address_t)types, nt * sizeof *types);
}

void record_fds(const char *phase) {
  struct proc_fdinfo fds[512];
  int bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, fds, sizeof fds);
  if (bytes <= 0) { out("tee-probe %s fds error errno=%d\n", phase, errno); return; }
  char line[1200];
  int off = snprintf(line, sizeof line, "tee-probe %s fds", phase);
  for (int i = 0; i < bytes / (int)sizeof fds[0] && off < (int)sizeof line - 32; i++)
    off += snprintf(line + off, sizeof line - off, " %d:%u", fds[i].proc_fd, fds[i].proc_fdtype);
  out("%s\n", line);
}

void record_env(const char *phase) {
  char line[1200];
  int off = snprintf(line, sizeof line, "tee-probe %s environ", phase);
  for (char **e = environ; e && *e && off < (int)sizeof line - 64; e++) {
    const char *eq = strchr(*e, '=');
    int keylen = eq ? (int)(eq - *e) : (int)strlen(*e);
    off += snprintf(line + off, sizeof line - off, " %.*s", keylen, *e);
  }
  out("%s\n", line);
}

void sweep() {
  // Canary files the runner plants before the spawn (R5-T3 read sweep).
  const char *paths[] = {
      "/Users/Shared/tee-canary.txt",
      SEALED_TEST_SWEEP_HOME "/tee-canary.txt",
      SEALED_TEST_SWEEP_HOME "/Library/tee-canary.txt",
      SEALED_TEST_SWEEP_HOME "/Library/Caches/tee-canary.txt",
      SEALED_TEST_SWEEP_HOME "/Library/Application Support/Splash/tee-canary.txt",
      SEALED_TEST_SWEEP_HOME "/.cache/huggingface/tee-canary.txt",
      SEALED_TEST_SWEEP_PKG "/tee-canary.txt",
      SEALED_TEST_SWEEP_UTMP "/tee-canary.txt",
      "/private/tmp/tee-canary.txt",
      "/Library/Caches/tee-canary.txt",
      "/System/Volumes/Data/Users/Shared/tee-canary.txt",
      "/System/Volumes/Data" SEALED_TEST_SWEEP_HOME "/tee-canary.txt",
      "/System/Volumes/Data/private/tmp/tee-canary.txt",
      "/System/Volumes/Data" SEALED_TEST_SWEEP_PKG "/tee-canary.txt",
      nullptr};
  for (int i = 0; paths[i]; i++) {
    int fd = open(paths[i], O_RDONLY);
    int e = errno;
    out("tee-probe sweep rc=%d errno=%d %s\n", fd >= 0 ? 0 : -1, fd >= 0 ? 0 : e, paths[i]);
    if (fd >= 0) close(fd);
  }
}

void oslog_canary() {
  char c[96];
  snprintf(c, sizeof c, "TEE-OSLOG-CANARY-%s-%d", SEALED_TEST_TAG, getpid());
  os_log(OS_LOG_DEFAULT, "%{public}s", c);
  os_log_error(OS_LOG_DEFAULT, "%{public}s-error", c);
  out("tee-probe oslog emitted %s\n", c);
}

void op_arms() {
  // shm_open
  int f = shm_open("/tee-probe-shm", O_CREAT | O_RDWR, 0600);
  int e = errno;
  out("tee-probe op shm_open rc=%d errno=%d\n", f >= 0 ? 0 : -1, f >= 0 ? 0 : e);
  if (f >= 0) { close(f); shm_unlink("/tee-probe-shm"); }
  // process creation
  pid_t p = 0;
  const char *av[] = {"/usr/bin/true", nullptr};
  int rc = posix_spawn(&p, "/usr/bin/true", nullptr, nullptr, (char *const *)av, nullptr);
  out("tee-probe op posix_spawn rc=%d\n", rc);
  if (rc == 0) { int st; waitpid(p, &st, 0); }
  p = fork();
  if (p == 0) _exit(0);
  e = errno;
  out("tee-probe op fork rc=%d errno=%d\n", p > 0 ? 0 : -1, p > 0 ? 0 : e);
  if (p > 0) { int st; waitpid(p, &st, 0); }
  // signalling another process (signal 0: no effect even if allowed)
  rc = kill(getppid(), 0);
  e = errno;
  out("tee-probe op kill-parent-sig0 rc=%d errno=%d\n", rc, rc == 0 ? 0 : e);
  // IOKit opens of unlisted classes
  const char *classes[] = {"AppleSMC", "IOHIDSystem", "AppleKeyStore", "IOFramebuffer", nullptr};
  for (int i = 0; classes[i]; i++) {
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(classes[i]));
    io_connect_t c = 0;
    kern_return_t k = s ? IOServiceOpen(s, mach_task_self(), 0, &c) : (kern_return_t)-1;
    out("tee-probe op iokit-open %s service=%s kr=0x%x\n", classes[i], s ? "found" : "none", k);
    if (c) IOServiceClose(c);
    if (s) IOObjectRelease(s);
  }
  // sysctl write (EPERM is also the non-root answer; recorded only)
  int v = 0;
  rc = sysctlbyname("kern.coredump", nullptr, nullptr, &v, sizeof v);
  e = errno;
  out("tee-probe op sysctl-write rc=%d errno=%d\n", rc, rc == 0 ? 0 : e);
  // ioctl on the /dev/null descriptor (recorded)
  int t = 0;
  rc = ioctl(2, FIODTYPE, &t);
  e = errno;
  out("tee-probe op ioctl-fiodtype rc=%d errno=%d\n", rc, rc == 0 ? 0 : e);
  // fsctl on the root volume (recorded)
  uint32_t fl = 0;
  rc = fsctl("/", TEE_FSIOC_SYNC_VOLUME, &fl, 0);
  e = errno;
  out("tee-probe op fsctl-sync rc=%d errno=%d\n", rc, rc == 0 ? 0 : e);
}

void lookups() {
  const char *svc[] = {"com.apple.pasteboard.1", "com.apple.windowserver.active",
                       "com.apple.coreservices.launchservicesd", "com.apple.SecurityServer",
                       "com.apple.securityd.xpc", "com.apple.tccd", "com.apple.cfprefsd.daemon",
                       "com.apple.cfprefsd.agent", "com.apple.logd", "com.apple.diagnosticd",
                       "com.apple.ReportCrash", "com.apple.analyticsd", "com.apple.nsurlsessiond",
                       "com.apple.system.notification_center", "com.apple.distributed_notifications@1v3",
                       "com.apple.MTLCompilerService", nullptr};
  mach_port_t bs = MACH_PORT_NULL;
  task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bs);
  for (int i = 0; svc[i]; i++) {
    mach_port_t s = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bs, svc[i], &s);
    out("tee-probe lookup kr=%d %s\n", kr, svc[i]);
    if (kr == KERN_SUCCESS) mach_port_deallocate(mach_task_self(), s);
  }
}

char gExtToken[2048];
char gExtPath[1024];
#endif  // SEALED_TEST_TEE_PROBES

#if defined(SEALED_TEST_CRASH_CANARY)
[[noreturn]] void crash_with_canary() {
  out("tee-probe crash canary=5445454341524159 now\n");
  const uint64_t k = 0x5445454341524159ull;  // "TEECARAY"
  __asm__ volatile(
      "mov x19, %0\n mov x20, %0\n mov x21, %0\n mov x22, %0\n mov x23, %0\n"
      "mov x24, %0\n mov x25, %0\n mov x26, %0\n mov x27, %0\n mov x28, %0\n"
      "brk #1\n"
      :
      : "r"(k)
      : "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28");
  __builtin_unreachable();
}
#endif

}  // namespace

extern "C" void sealed_tee_probe(const char *phase) {
#if defined(SEALED_TEST_TEE_PROBES)
  static bool servingDone = false;
  // The R7-T3 crash phases ("postload", "after-request") record nothing here.
  const bool teePhase = !strcmp(phase, "presandbox") || !strcmp(phase, "sandboxed") ||
                        !strcmp(phase, "loaded") || !strcmp(phase, "serving");
  if (!teePhase) goto crash;
  if (!strcmp(phase, "presandbox")) {
    // A-17: issue a read extension for a canary before the sandbox, consume
    // it after. The profile has no (extension ...) filter, so the token must
    // grant nothing.
    // The token names the resolved path (/var is a symlink to /private/var).
    char raw[1024], res[1024];
    snprintf(raw, sizeof raw, "%s/tee-canary.txt", SEALED_TEST_SWEEP_UTMP);
    snprintf(gExtPath, sizeof gExtPath, "%s", realpath(raw, res) ? res : raw);
    char *tok = sandbox_extension_issue_file("com.apple.app-sandbox.read", gExtPath, 0);
    snprintf(gExtToken, sizeof gExtToken, "%s", tok ? tok : "");
    out("tee-probe ext issued=%s path=%s\n", tok ? "yes" : "no", gExtPath);
    if (tok) free(tok);
    return;
  }
  if (!strcmp(phase, "serving")) {
    if (servingDone) return;
    servingDone = true;
  }
  record_ports(phase);
  record_fds(phase);
  record_env(phase);
  if (!strcmp(phase, "sandboxed")) {
    sweep();
    oslog_canary();
    op_arms();
    lookups();
    if (gExtToken[0]) {
      int64_t h = sandbox_extension_consume(gExtToken);
      int fd = open(gExtPath, O_RDONLY);
      int e = errno;
      out("tee-probe ext consume=%lld read rc=%d errno=%d\n", (long long)h, fd >= 0 ? 0 : -1, fd >= 0 ? 0 : e);
      if (fd >= 0) close(fd);
    }
    out("tee-probe sandboxed done\n");
  }
crash:;
#endif
#if defined(SEALED_TEST_CRASH_CANARY)
  // Default: right after the "sandboxed" report, while the test spawner still
  // waits for "loaded", so its SIGKILL cannot pre-empt the crash. R7-T3 moves
  // it to "postload" (Metal device made, model loaded, before SLLD) and to
  // "after-request" (the first request done, through the launcher).
#ifndef SEALED_TEST_CRASH_PHASE
#define SEALED_TEST_CRASH_PHASE "sandboxed"
#endif
  if (!strcmp(phase, SEALED_TEST_CRASH_PHASE)) crash_with_canary();
#endif
}

#endif

#if defined(SEALED_TEST_IOSURFACE_PUBLISH)
// T2 (2026-10-22): can the sandboxed child publish an IOSurface that another
// process of the same user reads? See review/T2-IOSURFACE-2026-10-22.md.
#include "sealed/sealed_r2.h"

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// IOSurface.framework is linked into this test build only (no Makefile change).
__asm__(".linker_option \"-framework\", \"IOSurface\"");

#ifndef SEALED_TEST_T2_HOLD
#define SEALED_TEST_T2_HOLD 60
#endif

namespace {

void t2_out(const char *fmt, ...) {
  char b[512];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(b, sizeof b, fmt, ap);
  va_end(ap);
  if (n > 0) sealed_reason_write(b, (size_t)(n < (int)sizeof b ? n : (int)sizeof b - 1));
}

long t2_count(IOSurfaceRef s, const unsigned char *can) {
  if (IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL) != kIOReturnSuccess) return -1;
  const unsigned char *p = (const unsigned char *)IOSurfaceGetBaseAddress(s);
  size_t n = IOSurfaceGetAllocSize(s);
  long hits = 0;
  for (size_t o = 0; p && o + 32 <= n; o += 32)
    if (memcmp(p + o, can, 32) == 0) hits++;
  IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
  return hits;
}

// 4096 x 64 x 1 byte = 256 KiB, filled with the canary, canary as a property.
IOSurfaceRef t2_make(const char *phase, const char *kind, int global, const unsigned char *can,
                     NSString *hex) {
  NSMutableDictionary *d = [@{
    (id)kIOSurfaceWidth : @4096,
    (id)kIOSurfaceHeight : @64,
    (id)kIOSurfaceBytesPerElement : @1,
  } mutableCopy];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (global) d[(id)kIOSurfaceIsGlobal] = @YES;
#pragma clang diagnostic pop
  IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)d);
  if (!s) {
    t2_out("test: t2 %s %s create=NULL\n", phase, kind);
    return NULL;
  }
  kern_return_t lk = IOSurfaceLock(s, 0, NULL);
  unsigned char *p = (unsigned char *)IOSurfaceGetBaseAddress(s);
  size_t n = IOSurfaceGetAllocSize(s);
  for (size_t o = 0; lk == kIOReturnSuccess && p && o + 32 <= n; o += 32) memcpy(p + o, can, 32);
  if (lk == kIOReturnSuccess) IOSurfaceUnlock(s, 0, NULL);
  long hits = t2_count(s, can);
  IOSurfaceSetValue(s, CFSTR("sealed.canary"), (__bridge CFStringRef)hex);
  CFTypeRef v = IOSurfaceCopyValue(s, CFSTR("sealed.canary"));
  int prop = v && CFGetTypeID(v) == CFStringGetTypeID() && [(__bridge NSString *)v isEqualToString:hex];
  if (v) CFRelease(v);
  t2_out("test: t2 %s %s create=ok id=%u size=%zu lock=0x%x canary_written=%ld prop_set=%d\n", phase, kind,
         IOSurfaceGetID(s), n, lk, hits, prop);
  return s;
}

}  // namespace

void sealed_t2_publish(const char *phase) {
  @autoreleasepool {
    unsigned char can[32];
    arc4random_buf(can, sizeof can);
    char hx[65];
    for (int i = 0; i < 32; i++) snprintf(hx + 2 * i, 3, "%02x", can[i]);
    NSString *hex = [NSString stringWithUTF8String:hx];
    IOSurfaceRef gl = t2_make(phase, "global", 1, can, hex);
    IOSurfaceRef ng = t2_make(phase, "nonglobal", 0, can, hex);
    t2_out("test: t2 %s hold=%d pid=%d global=%u nonglobal=%u canary=%s\n", phase, SEALED_TEST_T2_HOLD,
           getpid(), gl ? IOSurfaceGetID(gl) : 0, ng ? IOSurfaceGetID(ng) : 0, hx);
    for (int t = 0; t < SEALED_TEST_T2_HOLD; t++) sleep(1);
    if (gl) CFRelease(gl);
    if (ng) CFRelease(ng);
    t2_out("test: t2 %s released\n", phase);
  }
}
#endif

#if defined(SEALED_TEST_T2F_PROBE)
// T2 follow-up (2026-10-22): under a profile with an IOSurfaceRootUserClient
// method filter, does a global create fail while the Metal paths still work?
// See review/T2-FILTER-2026-10-22.md. Same reason-file shape as T2 so the
// reader can reuse the recorded IDs.
#include "sealed/sealed_r2.h"

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// IOSurface.framework is linked into this test build only (no Makefile change).
__asm__(".linker_option \"-framework\", \"IOSurface\"");

#ifndef SEALED_TEST_T2F_HOLD
#define SEALED_TEST_T2F_HOLD 60
#endif

namespace {

void t2f_out(const char *fmt, ...) {
  char b[512];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(b, sizeof b, fmt, ap);
  va_end(ap);
  if (n > 0) sealed_reason_write(b, (size_t)(n < (int)sizeof b ? n : (int)sizeof b - 1));
}

long t2f_count(IOSurfaceRef s, const unsigned char *can) {
  if (IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL) != kIOReturnSuccess) return -1;
  const unsigned char *p = (const unsigned char *)IOSurfaceGetBaseAddress(s);
  size_t n = IOSurfaceGetAllocSize(s);
  long hits = 0;
  for (size_t o = 0; p && o + 32 <= n; o += 32)
    if (memcmp(p + o, can, 32) == 0) hits++;
  IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
  return hits;
}

IOSurfaceRef t2f_make(const char *phase, const char *kind, int global, const unsigned char *can,
                      NSString *hex) {
  NSMutableDictionary *d = [@{
    (id)kIOSurfaceWidth : @4096,
    (id)kIOSurfaceHeight : @64,
    (id)kIOSurfaceBytesPerElement : @1,
  } mutableCopy];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (global) d[(id)kIOSurfaceIsGlobal] = @YES;
#pragma clang diagnostic pop
  IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)d);
  if (!s) {
    t2f_out("test: t2f %s surface %s create=NULL\n", phase, kind);
    return NULL;
  }
  if (IOSurfaceLock(s, 0, NULL) == kIOReturnSuccess) {
    unsigned char *p = (unsigned char *)IOSurfaceGetBaseAddress(s);
    size_t n = IOSurfaceGetAllocSize(s);
    for (size_t o = 0; p && o + 32 <= n; o += 32) memcpy(p + o, can, 32);
    IOSurfaceUnlock(s, 0, NULL);
  }
  IOSurfaceSetValue(s, CFSTR("sealed.canary"), (__bridge CFStringRef)hex);
  t2f_out("test: t2f %s surface %s create=ok id=%u canary_written=%ld\n", phase, kind,
          IOSurfaceGetID(s), t2f_count(s, can));
  return s;
}

}  // namespace

void sealed_t2f_probe(const char *phase) {
  @autoreleasepool {
    unsigned char can[32];
    arc4random_buf(can, sizeof can);
    char hx[65];
    for (int i = 0; i < 32; i++) snprintf(hx + 2 * i, 3, "%02x", can[i]);
    NSString *hex = [NSString stringWithUTF8String:hx];
    IOSurfaceRef gl = t2f_make(phase, "global", 1, can, hex);
    IOSurfaceRef ng = t2f_make(phase, "nonglobal", 0, can, hex);

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> q1 = nil;
    id<MTL4CommandQueue> q4 = nil;
    id<MTLSharedEvent> ev = nil;
    if (dev) {
      q1 = [dev newCommandQueue];
      if (@available(macOS 26.4, *)) {
        q4 = [dev newMTL4CommandQueue];
        ev = [dev newSharedEvent];
      }
    }
    t2f_out("test: t2f %s metal device=%d commandQueue=%d mtl4Queue=%d sharedEvent=%d\n", phase,
            dev != nil, q1 != nil, q4 != nil, ev != nil);

    t2f_out("test: t2f %s hold=%d pid=%d global=%u nonglobal=%u canary=%s\n", phase,
            SEALED_TEST_T2F_HOLD, getpid(), gl ? IOSurfaceGetID(gl) : 0,
            ng ? IOSurfaceGetID(ng) : 0, hx);
    for (int t = 0; t < SEALED_TEST_T2F_HOLD; t++) sleep(1);
    if (gl) CFRelease(gl);
    if (ng) CFRelease(ng);
    t2f_out("test: t2f %s released\n", phase);
  }
}
#endif

#if defined(SEALED_TEST_R7_READBACK)
// R7-T3 (2026-10-22): can framework code change the exception ports, the
// signal dispositions or the sandbox after Metal device creation and the
// model load? See review/R7T3-2026-10-22.md and
// review/TRACKED-ITEMS-CLOSURE-2026-10-22.md, R7-T3.4.
//
// The start state is read after the R1 guard and the R2 self-check: every
// signal disposition, the main thread's signal mask, the rlimits, the task
// exception-port table, the credentials and the code-signing status word.
// The sandbox state is read after the R5 self-test: sandbox_check() answers
// for the self-test's operations, and three real probes. Each check reads
// the state again and compares. A difference writes one reason line and ends
// the child with _exit(113).
//
// Switches (each implies SEALED_TEST_R7_READBACK):
//   SEALED_TEST_R7_SEED=1..5       seeded change: 1 SIGSEGV handler, 2 task
//                                  exception port, 3 thread exception port,
//                                  4 consume of a sandbox read extension,
//                                  5 set-ID calls (setuid(0), then setgid(rgid))
//   SEALED_TEST_R7_SEED_AT_REQUEST seed during the first request (port 2:
//                                  after it) instead of after the load
//   SEALED_TEST_R7_STATIC_INIT     a static initializer sets a task port
//                                  before main; the guard must replace it
//   SEALED_TEST_R7_INTERPOSE       neg/R7/libr7interpose.dylib is linked;
//                                  its hits are written to the reason file
#include "sealed/sealed_r2.h"
#include "sealed/sealed_r5.h"
#include "sealed/sealed_r6.h"
#include "sealed_guard.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <atomic>
#include <bootstrap.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/param.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#if defined(SEALED_TEST_R7_INTERPOSE)
#include "sealed/sealed_r7_interpose.h"
#endif

extern "C" int sandbox_check(pid_t pid, const char *operation, int type, ...);
extern "C" int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#if SEALED_TEST_R7_SEED == 4
extern "C" char *sandbox_extension_issue_file(const char *extension_class, const char *path, uint32_t flags);
extern "C" int64_t sandbox_extension_consume(const char *token);
#endif
#if defined(SEALED_TEST_R7_INTERPOSE)
extern "C" int64_t sandbox_extension_consume(const char *token);
#endif

#ifndef SEALED_TEST_SWEEP_UTMP
#error "SEALED_TEST_SWEEP_UTMP must be set (neg/build-all.sh sets it for this user and this Mac)"
#endif
#ifndef SEALED_TEST_R7_SEED
#define SEALED_TEST_R7_SEED 0
#endif

namespace {

const int kNoReport = 0x40000000;   // SANDBOX_CHECK_NO_REPORT
const int kFilterNone = 0, kFilterPath = 1, kFilterGlobalName = 2;

void r7_out(const char *fmt, ...) {
  char b[1400];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(b, sizeof b, fmt, ap);
  va_end(ap);
  if (n > 0) sealed_reason_write(b, (size_t)(n < (int)sizeof b ? n : (int)sizeof b - 1));
}

uint64_t now_us() {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC_RAW, &t);
  return (uint64_t)t.tv_sec * 1000000ull + (uint64_t)t.tv_nsec / 1000ull;
}

struct Ports {
  mach_msg_type_number_t n;
  exception_mask_t masks[EXC_TYPES_COUNT];
  mach_port_t ports[EXC_TYPES_COUNT];
  exception_behavior_t beh[EXC_TYPES_COUNT];
  thread_state_flavor_t fl[EXC_TYPES_COUNT];
};

struct Creds {
  uid_t uid, euid, svuid;
  gid_t gid, egid, svgid;
  int sugid, ngroups, bsdinfo;
  gid_t groups[64];
  uint32_t cs;
  int csrc;
};

const int kSbArms = 13;
struct State {
  struct sigaction sig[NSIG];
  sigset_t mask;
  struct rlimit rl[RLIM_NLIMITS];
  Ports ports;
  Creds creds;
  int sb[kSbArms];
  int probe[3];
};

State gStart;                      // expected values (own shutdown handlers folded in)
bool gSandbox = false;             // the sandbox arms are recorded
std::atomic<bool> gPoll{false};
std::atomic<unsigned long long> gChecks{0}, gPolls{0}, gMaxGap{0};
pthread_t gPollThread;
uint64_t gSeedAt = 0;              // time of the seeded change (0 = none)

char gCanary[MAXPATHLEN];          // the runner's canary file (resolved before the sandbox)
char gOwnDir[MAXPATHLEN];
char gEndPath[MAXPATHLEN];         // <own dir>/en.lproj: the runner makes it to ask for the end check
char gSbPath[6][MAXPATHLEN];
const char *const kSbOps[kSbArms] = {
    nullptr,             "file-read-data",    "file-read-data",   "file-write-create", "file-write-create",
    "file-write-create", "file-write-data",   "file-read-data",   "mach-lookup",       "mach-lookup",
    "process-fork",      "mach-lookup",       "file-read-data"};

const char *const kSigName[NSIG] = {"0",    "HUP",  "INT",    "QUIT", "ILL",   "TRAP", "ABRT",  "EMT",
                                    "FPE",  "KILL", "BUS",    "SEGV", "SYS",   "PIPE", "ALRM",  "TERM",
                                    "URG",  "STOP", "TSTP",   "CONT", "CHLD",  "TTIN", "TTOU",  "IO",
                                    "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "INFO", "USR1",  "USR2"};

[[noreturn]] void changed(const char *point, const char *cls, const char *fmt, ...) {
  char d[1000];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(d, sizeof d, fmt, ap);
  va_end(ap);
  if (gSeedAt)
    r7_out("r7: CHANGED point=%s class=%s %s since_seed_us=%llu\n", point, cls, d,
           (unsigned long long)(now_us() - gSeedAt));
  else
    r7_out("r7: CHANGED point=%s class=%s %s\n", point, cls, d);
  _exit(113);
}

void read_sigs(struct sigaction *s) {
  for (int i = 1; i < NSIG; i++) {
    memset(&s[i], 0, sizeof s[i]);
    sigaction(i, nullptr, &s[i]);
  }
}

bool same_sig(const struct sigaction &a, const struct sigaction &b) {
  return a.__sigaction_u.__sa_handler == b.__sigaction_u.__sa_handler && a.sa_mask == b.sa_mask &&
         a.sa_flags == b.sa_flags;
}

kern_return_t read_ports(Ports *p) {
  p->n = EXC_TYPES_COUNT;
  kern_return_t kr =
      task_get_exception_ports(mach_task_self(), SEALED_VALID_MASK, p->masks, &p->n, p->ports, p->beh, p->fl);
  if (kr != KERN_SUCCESS) return kr;
  for (mach_msg_type_number_t i = 0; i < p->n; i++)
    if (MACH_PORT_VALID(p->ports[i])) mach_port_deallocate(mach_task_self(), p->ports[i]);
  return KERN_SUCCESS;
}

void read_creds(Creds *c) {
  memset(c, 0, sizeof *c);
  c->uid = getuid(); c->euid = geteuid(); c->gid = getgid(); c->egid = getegid();
  c->sugid = issetugid();
  struct proc_bsdinfo bi;
  c->bsdinfo = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &bi, sizeof bi) == (int)sizeof bi;
  if (c->bsdinfo) { c->svuid = bi.pbi_svuid; c->svgid = bi.pbi_svgid; }
  c->ngroups = getgroups(64, c->groups);
  c->csrc = csops(getpid(), 0, &c->cs, sizeof c->cs);
}

bool same_creds(const Creds &a, const Creds &b) {
  if (a.uid != b.uid || a.euid != b.euid || a.svuid != b.svuid || a.gid != b.gid || a.egid != b.egid ||
      a.svgid != b.svgid || a.sugid != b.sugid || a.ngroups != b.ngroups || a.bsdinfo != b.bsdinfo ||
      a.cs != b.cs || a.csrc != b.csrc)
    return false;
  for (int i = 0; i < a.ngroups && i < 64; i++) if (a.groups[i] != b.groups[i]) return false;
  return true;
}

void read_sb(int *v) {
  pid_t me = getpid();
  v[0] = sandbox_check(me, nullptr, kFilterNone);
  v[1] = sandbox_check(me, kSbOps[1], kFilterPath | kNoReport, "/private/etc/hosts");
  v[2] = sandbox_check(me, kSbOps[2], kFilterPath | kNoReport, gCanary);
  for (int i = 3; i <= 7; i++) v[i] = sandbox_check(me, kSbOps[i], kFilterPath | kNoReport, gSbPath[i - 3]);
  v[8] = sandbox_check(me, kSbOps[8], kFilterGlobalName | kNoReport, "com.apple.system.logger");
  v[9] = sandbox_check(me, kSbOps[9], kFilterGlobalName | kNoReport, "com.apple.dnssd.service");
  v[10] = sandbox_check(me, kSbOps[10], kFilterNone | kNoReport);
  v[11] = sandbox_check(me, kSbOps[11], kFilterGlobalName | kNoReport, "com.apple.MTLCompilerService");
  v[12] = sandbox_check(me, kSbOps[12], kFilterPath | kNoReport, "/usr/lib/dyld");
}

// Real accesses (the self-test's oracle form): 0 = allowed, else errno / kr.
void read_probes(int *v) {
  int fd = open("/private/etc/hosts", O_RDONLY);
  v[0] = fd >= 0 ? 0 : errno;
  if (fd >= 0) close(fd);
  fd = open(gCanary, O_RDONLY);
  v[1] = fd >= 0 ? 0 : errno;
  if (fd >= 0) close(fd);
  mach_port_t bs = MACH_PORT_NULL, svc = MACH_PORT_NULL;
  task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bs);
  v[2] = bootstrap_look_up(bs, "com.apple.system.logger", &svc);
  if (v[2] == KERN_SUCCESS) mach_port_deallocate(mach_task_self(), svc);
  if (MACH_PORT_VALID(bs)) mach_port_deallocate(mach_task_self(), bs);
}

// Thread exception ports, read directly. sealed_guard_threads_clear (SG:177)
// counts every error other than KERN_TERMINATED and MACH_SEND_INVALID_DEST as
// a failure; a thread that is ending returns KERN_FAILURE (inactive thread),
// so that call alone cannot tell a set port from a thread exit. This scan
// ends the child only for a valid port. A query error on a thread that
// thread_info still reports alive is retried once, then counted as a change.
std::atomic<unsigned long long> gThreadGone{0}, gGuardDisagree{0};
int thread_scan(char *d, size_t len) {
  thread_act_array_t th;
  mach_msg_type_number_t n = 0;
  if (task_threads(mach_task_self(), &th, &n) != KERN_SUCCESS) { snprintf(d, len, "task_threads failed"); return 1; }
  int bad = 0;
  for (mach_msg_type_number_t t = 0; t < n; t++) {
    for (int attempt = 0; attempt < 2; attempt++) {
      Ports p;
      p.n = EXC_TYPES_COUNT;
      kern_return_t kr = thread_get_exception_ports(th[t], SEALED_VALID_MASK, p.masks, &p.n, p.ports, p.beh, p.fl);
      if (kr == KERN_SUCCESS) {
        for (mach_msg_type_number_t i = 0; i < p.n; i++) {
          if (MACH_PORT_VALID(p.ports[i]) && !bad) {
            thread_identifier_info_data_t id;
            mach_msg_type_number_t c = THREAD_IDENTIFIER_INFO_COUNT;
            uint64_t tid = thread_info(th[t], THREAD_IDENTIFIER_INFO, (thread_info_t)&id, &c) == KERN_SUCCESS ? id.thread_id : 0;
            snprintf(d, len, "thread %u/%u tid=%llu mask=0x%x port=0x%x behavior=0x%x", t, n, (unsigned long long)tid,
                     p.masks[i], p.ports[i], p.beh[i]);
            bad = 1;
          }
        }
        for (mach_msg_type_number_t i = 0; i < p.n; i++)
          if (MACH_PORT_VALID(p.ports[i])) mach_port_deallocate(mach_task_self(), p.ports[i]);
        break;
      }
      thread_basic_info_data_t bi;
      mach_msg_type_number_t c = THREAD_BASIC_INFO_COUNT;
      kern_return_t ik = thread_info(th[t], THREAD_BASIC_INFO, (thread_info_t)&bi, &c);
      if (kr == KERN_TERMINATED || kr == MACH_SEND_INVALID_DEST || ik != KERN_SUCCESS) {
        gThreadGone++;
        break;
      }
      if (attempt == 1 && !bad) {
        snprintf(d, len, "thread %u/%u query kr=%d on a live thread (thread_info kr=%d)", t, n, kr, ik);
        bad = 1;
      }
    }
    mach_port_deallocate(mach_task_self(), th[t]);
  }
  vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof(thread_act_t));
  return bad;
}

// One check. `full` adds what only the main thread can read (its signal
// mask) and the real probes, which write sandbox deny reports.
void compare(const char *point, bool full) {
  int rb = sealed_guard_readback();
  if (rb != 0) {
    Ports p;
    read_ports(&p);
    char d[600] = "";
    size_t o = 0;
    for (mach_msg_type_number_t i = 0; i < p.n && o < sizeof d - 64; i++)
      o += snprintf(d + o, sizeof d - o, " [mask=0x%x port=0x%x behavior=0x%x]", p.masks[i], p.ports[i], p.beh[i]);
    changed(point, "exception-ports", "task: sealed_guard_readback=%d table:%s", rb, d);
  }
  {
    Ports p;
    kern_return_t kr = read_ports(&p);
    if (kr != KERN_SUCCESS) changed(point, "exception-ports", "task_get_exception_ports kr=%d", kr);
    bool same = p.n == gStart.ports.n;
    for (mach_msg_type_number_t i = 0; same && i < p.n; i++)
      same = p.masks[i] == gStart.ports.masks[i] && p.ports[i] == gStart.ports.ports[i] &&
             p.beh[i] == gStart.ports.beh[i] && p.fl[i] == gStart.ports.fl[i];
    if (!same) changed(point, "exception-ports", "task table differs from the start (n=%u, start n=%u)", p.n, gStart.ports.n);
  }
  {
    char d[300] = "";
    if (thread_scan(d, sizeof d) != 0) changed(point, "exception-ports", "thread-ports: %s", d);
    // The shipped helper too; a disagreement (helper 1, scan clean) is counted.
    if (sealed_guard_threads_clear() != 0) {
      char d2[300] = "";
      if (thread_scan(d2, sizeof d2) != 0) changed(point, "exception-ports", "thread-ports: %s", d2);
      gGuardDisagree++;
    }
  }
  {
    struct sigaction s[NSIG];
    read_sigs(s);
    for (int i = 1; i < NSIG; i++)
      if (!same_sig(s[i], gStart.sig[i]))
        changed(point, "signal-disposition", "SIG%s(%d) handler=%p flags=0x%x mask=0x%x, start handler=%p flags=0x%x mask=0x%x",
                kSigName[i], i, (void *)s[i].__sigaction_u.__sa_handler, s[i].sa_flags, s[i].sa_mask,
                (void *)gStart.sig[i].__sigaction_u.__sa_handler, gStart.sig[i].sa_flags, gStart.sig[i].sa_mask);
  }
  if (full && pthread_main_np()) {
    sigset_t m;
    pthread_sigmask(SIG_BLOCK, nullptr, &m);
    if (m != gStart.mask) changed(point, "signal-mask", "main thread mask=0x%x start=0x%x", m, gStart.mask);
  }
  for (int r = 0; r < RLIM_NLIMITS; r++) {
    struct rlimit l;
    getrlimit(r, &l);
    if (l.rlim_cur != gStart.rl[r].rlim_cur || l.rlim_max != gStart.rl[r].rlim_max)
      changed(point, "rlimit", "resource %d cur=%llu max=%llu, start cur=%llu max=%llu", r, (unsigned long long)l.rlim_cur,
              (unsigned long long)l.rlim_max, (unsigned long long)gStart.rl[r].rlim_cur, (unsigned long long)gStart.rl[r].rlim_max);
  }
  {
    Creds c;
    read_creds(&c);
    if (!same_creds(c, gStart.creds))
      changed(point, "credentials", "uid=%u/%u/%u gid=%u/%u/%u issetugid=%d groups=%d cs=0x%08x, start uid=%u/%u/%u gid=%u/%u/%u issetugid=%d groups=%d cs=0x%08x",
              c.uid, c.euid, c.svuid, c.gid, c.egid, c.svgid, c.sugid, c.ngroups, c.cs, gStart.creds.uid, gStart.creds.euid,
              gStart.creds.svuid, gStart.creds.gid, gStart.creds.egid, gStart.creds.svgid, gStart.creds.sugid,
              gStart.creds.ngroups, gStart.creds.cs);
  }
  if (gSandbox) {
    int v[kSbArms];
    read_sb(v);
    for (int i = 0; i < kSbArms; i++)
      if (v[i] != gStart.sb[i])
        changed(point, "sandbox", "sandbox_check arm %d (%s) = %d, start %d", i, kSbOps[i] ? kSbOps[i] : "sandboxed", v[i],
                gStart.sb[i]);
    if (full) {
      int pr[3];
      read_probes(pr);
      static const char *const kProbe[3] = {"open /private/etc/hosts", "open canary", "mach-lookup com.apple.system.logger"};
      for (int i = 0; i < 3; i++)
        if (pr[i] != gStart.probe[i]) changed(point, "sandbox", "%s = %d, start %d", kProbe[i], pr[i], gStart.probe[i]);
    }
  }
  gChecks++;
}

#if defined(SEALED_TEST_R7_INTERPOSE)
// Writes the interposer's records made since the last flush.
void flush_hits() {
  static int done = 0;
  static pthread_mutex_t lk = PTHREAD_MUTEX_INITIALIZER;
  pthread_mutex_lock(&lk);
  int dropped = 0, n = r7i_count(&dropped);
  for (; done < n; done++) {
    r7i_hit_t h;
    if (!r7i_get(done, &h)) break;
    r7_out("r7i: hit seq=%d name=%s kind=%d arg=%ld ret=%ld errno=%d cache=%d caller=%s+0x%lx\n", done, h.name, h.kind,
           h.arg, h.ret, h.err, h.cache, h.image, (unsigned long)h.offset);
  }
  if (dropped) r7_out("r7i: dropped=%d\n", dropped);
  pthread_mutex_unlock(&lk);
}

// Control (iii), seeded calls: one of each watched kind from the child's own
// image, each leaving the state as it was (same SIGSEGV action, null thread
// ports, an invalid token).
void interposer_seed() {
  r7i_mark("seed-begin");
  struct sigaction cur;
  sigaction(SIGSEGV, nullptr, &cur);
  sigaction(SIGSEGV, &cur, nullptr);
  mach_port_t self = mach_thread_self();
  thread_set_exception_ports(self, SEALED_VALID_MASK, MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE);
  mach_port_deallocate(mach_task_self(), self);
  (void)sandbox_extension_consume("r7-invalid-token");
  r7i_mark("seed-end");
  flush_hits();
}

// Control (i), reach: a Metal library compiled from source. Metal sets up its
// compiler connection with sandbox_extension_issue_file, a call from the
// shared cache into libsystem_sandbox (measured: verify-r7b Q2, Q4).
void interposer_reach() {
  r7i_mark("reach-begin");
  @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    NSError *e = nil;
    id<MTLLibrary> l = [d newLibraryWithSource:@"kernel void r7k(device float *a [[buffer(0)]], uint i [[thread_position_in_grid]]) { a[i] = a[i] * 3.0f + 1.0f; }"
                                       options:nil
                                         error:&e];
    id<MTLComputePipelineState> ps = l ? [d newComputePipelineStateWithFunction:[l newFunctionWithName:@"r7k"] error:&e] : nil;
    r7_out("test: r7i reach compile device=%d library=%d pipeline=%d\n", d != nil, l != nil, ps != nil);
  }
  r7i_mark("reach-end");
  flush_hits();
}
#endif

void *poll_main(void *) {
  pthread_setname_np("r7-busy-poll");
  uint64_t last = now_us(), report = last, gapWin = 0;
  unsigned long long n = 0;
  while (gPoll.load()) {
    compare("busy-poll", false);
    n++;
    gPolls = n;
    uint64_t t = now_us(), gap = t - last;
    last = t;
    if (gap > gapWin) gapWin = gap;
    if (gap > gMaxGap) gMaxGap = gap;
    if (t - report >= 10000000ull) {
      r7_out("r7: busy-poll n=%llu max_gap_us(10s)=%llu threads_gone=%llu guard_threads_clear_without_port=%llu\n", n,
             (unsigned long long)gapWin, (unsigned long long)gThreadGone.load(), (unsigned long long)gGuardDisagree.load());
      report = t;
      gapWin = 0;
    }
    usleep(1000);
  }
  return nullptr;
}

#if SEALED_TEST_R7_SEED != 0
#if SEALED_TEST_R7_SEED == 2 || SEALED_TEST_R7_SEED == 3
mach_port_t new_port() {
  mach_port_t p = MACH_PORT_NULL;
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &p);
  mach_port_insert_right(mach_task_self(), p, p, MACH_MSG_TYPE_MAKE_SEND);
  return p;
}
#endif
#if SEALED_TEST_R7_SEED == 1
void seed_handler(int) {}
#endif
#if SEALED_TEST_R7_SEED == 4
char gExtToken[2048];
#endif
#if SEALED_TEST_R7_SEED == 3
dispatch_semaphore_t gSeedSem;
void *seed_thread(void *) {
  pthread_setname_np("r7-seed-worker");
  mach_port_t self = mach_thread_self();
  kern_return_t kr = thread_set_exception_ports(self, EXC_MASK_BAD_ACCESS, new_port(),
                                                (exception_behavior_t)(EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES),
                                                THREAD_STATE_NONE);
  r7_out("test: r7 seed thread-port set kr=%d\n", kr);
  dispatch_semaphore_signal(gSeedSem);
  for (;;) pause();
  return nullptr;
}
#endif

// The seeded change. The line comes first: a busy-poll check can end the
// child before the call returns.
void seed(const char *where) {
  static bool done = false;
  if (done) return;
  done = true;
  static const char *const kKind[6] = {"", "signal-handler", "task-port", "thread-port", "extension-consume", "set-id"};
  r7_out("test: r7 seed %s at %s now\n", kKind[SEALED_TEST_R7_SEED], where);
  gSeedAt = now_us();
#if SEALED_TEST_R7_SEED == 1
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = seed_handler;
  sigemptyset(&sa.sa_mask);
  int rc = sigaction(SIGSEGV, &sa, nullptr);
  r7_out("test: r7 seed signal-handler rc=%d\n", rc);
#elif SEALED_TEST_R7_SEED == 2
  kern_return_t kr = task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, new_port(),
                                              (exception_behavior_t)(EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES),
                                              THREAD_STATE_NONE);
  r7_out("test: r7 seed task-port kr=%d\n", kr);
#elif SEALED_TEST_R7_SEED == 3
  gSeedSem = dispatch_semaphore_create(0);
  pthread_t t;
  pthread_create(&t, nullptr, seed_thread, nullptr);
  pthread_detach(t);
  dispatch_semaphore_wait(gSeedSem, DISPATCH_TIME_FOREVER);
#elif SEALED_TEST_R7_SEED == 4
  int64_t h = gExtToken[0] ? sandbox_extension_consume(gExtToken) : -2;
  r7_out("test: r7 seed extension-consume handle=%lld\n", (long long)h);
#elif SEALED_TEST_R7_SEED == 5
  int rc = setuid(0);
  int e = errno;
  r7_out("test: r7 seed set-id setuid(0) rc=%d errno=%d\n", rc, rc ? e : 0);
  rc = setgid(getgid());
  e = errno;
  r7_out("test: r7 seed set-id setgid(%u) rc=%d errno=%d\n", getgid(), rc, rc ? e : 0);
#endif
}

#if defined(SEALED_TEST_R7_SEED_AT_REQUEST) && SEALED_TEST_R7_SEED != 2
void *seed_worker(void *) {
  pthread_setname_np("r7-seed-request");
  seed("request");
  return nullptr;
}
#endif
#endif  // SEALED_TEST_R7_SEED

#if defined(SEALED_TEST_R7_STATIC_INIT)
// Control: a task exception port set by a static initializer, before main
// and so before the guard. The guard must replace it.
mach_port_t gStaticPort = MACH_PORT_NULL;
kern_return_t gStaticKr = -1;
__attribute__((constructor)) void r7_static_init() {
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &gStaticPort);
  mach_port_insert_right(mach_task_self(), gStaticPort, gStaticPort, MACH_MSG_TYPE_MAKE_SEND);
  gStaticKr = task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, gStaticPort,
                                       (exception_behavior_t)(EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES), THREAD_STATE_NONE);
}
#endif

void end_check() {
  r7_out("r7: end requested\n");
  gPoll = false;
  pthread_join(gPollThread, nullptr);
  compare("end", true);
  r7_out("r7: check end PASS\n");
  const char *const *paths = nullptr;
  size_t n = sealed_r6_abs_paths(&paths);
  r7_out("r7: end self-test start\n");
  sealed_r5_self_test(n > 0 ? paths[0] : "/nonexistent");   // _exit(113) with its own reason on any change
  compare("end-after-self-test", true);
#if defined(SEALED_TEST_R7_INTERPOSE)
  interposer_reach();
#endif
  r7_out("r7: END PASS checks=%llu busy_iterations=%llu busy_max_gap_us=%llu threads_gone=%llu "
         "guard_threads_clear_without_port=%llu\n",
         (unsigned long long)gChecks.load(), (unsigned long long)gPolls.load(), (unsigned long long)gMaxGap.load(),
         (unsigned long long)gThreadGone.load(), (unsigned long long)gGuardDisagree.load());
}

}  // namespace

extern "C" void sealed_r7_start(void) {
  char exe[MAXPATHLEN], real[MAXPATHLEN];
  uint32_t es = sizeof exe;
  if (_NSGetExecutablePath(exe, &es) == 0 && realpath(exe, real)) {
    char *slash = strrchr(real, '/');
    if (slash) *slash = '\0';
    snprintf(gOwnDir, sizeof gOwnDir, "%s", real);
  }
  snprintf(gEndPath, sizeof gEndPath, "%s/en.lproj", gOwnDir);
  char raw[MAXPATHLEN], res[MAXPATHLEN];
  snprintf(raw, sizeof raw, "%s/r7-canary.txt", SEALED_TEST_SWEEP_UTMP);
  snprintf(gCanary, sizeof gCanary, "%s", realpath(raw, res) ? res : raw);
  const char *tmp = sealed_r2_checked_tmpdir();
  snprintf(gSbPath[0], sizeof gSbPath[0], "%s/r7-sb-x", tmp ? tmp : "/nonexistent");
  snprintf(gSbPath[1], sizeof gSbPath[1], "/private/tmp/r7-sb-x");
  snprintf(gSbPath[2], sizeof gSbPath[2], "%s/metal-cache/r7-sb-x", tmp ? tmp : "/nonexistent");
  // gSbPath[3] (a manifest path) is set in sealed_r7_sandbox_start.
  snprintf(gSbPath[4], sizeof gSbPath[4], "%s/r5-owndir-probe", gOwnDir);
#if SEALED_TEST_R7_SEED == 4
  // A read extension for the canary, issued before the sandbox (A-17 shape).
  char *tok = sandbox_extension_issue_file("com.apple.app-sandbox.read", gCanary, 0);
  snprintf(gExtToken, sizeof gExtToken, "%s", tok ? tok : "");
  r7_out("test: r7 extension issued=%s path=%s\n", tok ? "yes" : "no", gCanary);
  if (tok) free(tok);
#endif
  read_sigs(gStart.sig);
  pthread_sigmask(SIG_BLOCK, nullptr, &gStart.mask);
  for (int r = 0; r < RLIM_NLIMITS; r++) getrlimit(r, &gStart.rl[r]);
  kern_return_t kr = read_ports(&gStart.ports);
  read_creds(&gStart.creds);
  const Creds &c = gStart.creds;
  r7_out("r7: start recorded ports-kr=%d task-entries=%u guard-readback=%d threads-clear=%d uid=%u/%u/%u gid=%u/%u/%u "
         "issetugid=%d bsdinfo=%d cs=0x%08x csops-rc=%d mask=0x%x\n",
         kr, gStart.ports.n, sealed_guard_readback(), sealed_guard_threads_clear(), c.uid, c.euid, c.svuid, c.gid,
         c.egid, c.svgid, c.sugid, c.bsdinfo, c.cs, c.csrc, gStart.mask);
  {
    char line[1200];
    int o = snprintf(line, sizeof line, "r7: start dispositions");
    for (int i = 1; i < NSIG && o < (int)sizeof line - 40; i++) {
      void *h = (void *)gStart.sig[i].__sigaction_u.__sa_handler;
      o += snprintf(line + o, sizeof line - o, " %s=%s", kSigName[i],
                    h == (void *)SIG_DFL ? "DFL" : h == (void *)SIG_IGN ? "IGN" : "handler");
    }
    r7_out("%s\n", line);
  }
#if defined(SEALED_TEST_R7_STATIC_INIT)
  {
    bool present = false;
    for (mach_msg_type_number_t i = 0; i < gStart.ports.n; i++)
      if (gStart.ports.ports[i] == gStaticPort) present = true;
    r7_out("test: r7 static initializer set task port kr=%d port=0x%x; present after the guard=%d\n", gStaticKr,
           gStaticPort, present ? 1 : 0);
  }
#endif
#if defined(SEALED_TEST_R7_INTERPOSE)
  r7i_arm();
  r7_out("test: r7i armed after the guard and the R2 self-check\n");
#endif
}

extern "C" void sealed_r7_sandbox_start(void) {
  const char *const *paths = nullptr;
  size_t n = sealed_r6_abs_paths(&paths);
  snprintf(gSbPath[3], sizeof gSbPath[3], "%s", n > 0 ? paths[0] : "/nonexistent");
  read_sb(gStart.sb);
  read_probes(gStart.probe);
  gSandbox = true;
  char line[400];
  int o = snprintf(line, sizeof line, "r7: sandbox recorded sandbox_check");
  for (int i = 0; i < kSbArms; i++) o += snprintf(line + o, sizeof line - o, " %d", gStart.sb[i]);
  r7_out("%s probes hosts=%d canary=%d logger=%d\n", line, gStart.probe[0], gStart.probe[1], gStart.probe[2]);
}

extern "C" void sealed_r7_check(const char *point) {
  compare(point, true);
  r7_out("r7: check %s PASS\n", point);
#if defined(SEALED_TEST_R7_INTERPOSE)
  if (!strcmp(point, "sandboxed")) interposer_seed();
  flush_hits();
#endif
}

extern "C" void sealed_r7_own_signals(void) {
  // The child's own handlers (main.mm ShutdownSignals): SIGTERM, SIGINT and
  // SIGHUP get a handler, SIGPIPE is ignored. Only these four may differ
  // from the start; their new values become the expected ones.
  struct sigaction s[NSIG];
  read_sigs(s);
  for (int i = 1; i < NSIG; i++) {
    if (i == SIGTERM || i == SIGINT || i == SIGHUP || i == SIGPIPE) {
      gStart.sig[i] = s[i];
      continue;
    }
    if (!same_sig(s[i], gStart.sig[i]))
      changed("own-signals", "signal-disposition", "SIG%s(%d) changed before the child's own handlers", kSigName[i], i);
  }
  r7_out("r7: own handlers folded in: TERM/INT/HUP handler, PIPE=%s\n",
         s[SIGPIPE].__sigaction_u.__sa_handler == SIG_IGN ? "IGN" : "other");
  sealed_r7_check("own-signals");
  gPoll = true;
  if (pthread_create(&gPollThread, nullptr, poll_main, nullptr) != 0) changed("own-signals", "harness", "busy-poll thread not started");
  r7_out("r7: busy-poll started (1 ms period) before Metal device creation\n");
}

extern "C" void sealed_r7_after_load(void) {
#if SEALED_TEST_R7_SEED != 0 && !defined(SEALED_TEST_R7_SEED_AT_REQUEST)
  seed("load");
#endif
  sealed_r7_check("after-load");
}

extern "C" void sealed_r7_input(int idle) {
  static unsigned n = 0;
  char pt[48];
  if (idle) {
    n++;
    struct stat st;
    if (gPoll.load() && lstat(gEndPath, &st) == 0) {
      end_check();
      return;
    }
    snprintf(pt, sizeof pt, "request-%u-before", n);
    compare(pt, true);
    r7_out("r7: check %s PASS\n", pt);
#if SEALED_TEST_R7_SEED != 0 && SEALED_TEST_R7_SEED != 2 && defined(SEALED_TEST_R7_SEED_AT_REQUEST)
    if (n == 1) {
      pthread_t t;
      pthread_create(&t, nullptr, seed_worker, nullptr);
      pthread_detach(t);
    }
#endif
  } else {
    snprintf(pt, sizeof pt, "request-%u-input", n);
    compare(pt, false);
  }
#if defined(SEALED_TEST_R7_INTERPOSE)
  flush_hits();
#endif
}

extern "C" void sealed_r7_after_request(void) {
  static unsigned n = 0;
  char pt[48];
  snprintf(pt, sizeof pt, "request-%u-after", ++n);
  compare(pt, true);
  r7_out("r7: check %s PASS\n", pt);
#if SEALED_TEST_R7_SEED == 2 && defined(SEALED_TEST_R7_SEED_AT_REQUEST)
  if (n == 1) seed("after-request");
#endif
#if defined(SEALED_TEST_R7_INTERPOSE)
  flush_hits();
#endif
}
#endif  // SEALED_TEST_R7_READBACK

#if defined(SEALED_TEST_S1_SHARE)
// S-1 (2026-10-23): can code in the child share memory with another process
// through the GPU client the profile allows? Shared texture and shared event,
// their handle encodings, the two XPC transport directions, and the T2 global
// surface as the reader's positive control. See review/S1-IOGPU-2026-10-23.md.
#include "sealed/sealed_r2.h"

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#include <servers/bootstrap.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <string>

// IOSurface.framework is linked into this test build only (no Makefile change).
__asm__(".linker_option \"-framework\", \"IOSurface\"");

#ifndef SEALED_TEST_S1_HOLD
#define SEALED_TEST_S1_HOLD 60
#endif
#ifndef SEALED_TEST_S1_SERVICE
#define SEALED_TEST_S1_SERVICE "com.sealed.s1.host"   // registered by the child
#endif
#ifndef SEALED_TEST_S1_LOOKUP
#define SEALED_TEST_S1_LOOKUP "com.apple.system.logger"   // an existing service
#endif

namespace {

constexpr NSUInteger kS1W = 4096;   // R8Uint, 4096 x 16 = 64 KiB, row 256-aligned
constexpr NSUInteger kS1H = 16;

void s1_out(const char *fmt, ...) {
  char b[1024];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(b, sizeof b, fmt, ap);
  va_end(ap);
  if (n > 0) sealed_reason_write(b, (size_t)(n < (int)sizeof b ? n : (int)sizeof b - 1));
}

std::string s1_hex(NSData *d) {
  static const char *k = "0123456789abcdef";
  const unsigned char *p = (const unsigned char *)d.bytes;
  std::string s;
  s.reserve(d.length * 2);
  for (NSUInteger i = 0; i < d.length; i++) {
    s.push_back(k[p[i] >> 4]);
    s.push_back(k[p[i] & 15]);
  }
  return s;
}

// Encode a handle for a non-XPC transport. Both Metal handles carry IOKit
// objects; IOSurface's encoder refuses every coder but NSXPCCoder, so this is
// where a file or socket transport would have to work. The exception is
// caught and recorded: an uncaught one would take the child down.
const char *s1_encode(id obj, NSData **out) {
  *out = nil;
  if (!obj) return "no-handle";
  @try {
    NSError *err = nil;
    NSData *d = [NSKeyedArchiver archivedDataWithRootObject:obj requiringSecureCoding:YES error:&err];
    if (d) {
      *out = d;
      return "ok";
    }
  } @catch (NSException *e) {
    s1_out("test: s1 encode threw: %s\n", e.reason.UTF8String ?: "?");
    return "XPC-only";
  }
  @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSData *d = [NSKeyedArchiver archivedDataWithRootObject:obj];
#pragma clang diagnostic pop
    if (d) {
      *out = d;
      return "ok";
    }
  } @catch (NSException *e) {
    s1_out("test: s1 encode threw on the plain coder: %s\n", e.reason.UTF8String ?: "?");
    return "XPC-only";
  }
  return "fail";
}

long s1_fill(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLTexture> t,
             const unsigned char *can) {
  const NSUInteger bytes = kS1W * kS1H;
  id<MTLBuffer> src = [dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
  id<MTLBuffer> dst = [dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
  if (!src || !dst) return -2;
  unsigned char *p = (unsigned char *)src.contents;
  for (NSUInteger o = 0; o + 32 <= bytes; o += 32) memcpy(p + o, can, 32);
  id<MTLCommandBuffer> cb = [q commandBuffer];
  id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
  if (!b) return -3;
  [b copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:kS1W sourceBytesPerImage:bytes
            sourceSize:MTLSizeMake(kS1W, kS1H, 1) toTexture:t destinationSlice:0
     destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
  [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
          sourceSize:MTLSizeMake(kS1W, kS1H, 1)
            toBuffer:dst destinationOffset:0 destinationBytesPerRow:kS1W
 destinationBytesPerImage:bytes];
  [b endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  long hits = 0;
  const unsigned char *rp = (const unsigned char *)dst.contents;
  for (NSUInteger o = 0; o + 32 <= bytes; o += 32)
    if (memcmp(rp + o, can, 32) == 0) hits++;
  return hits;
}

// P5 control target: the T2 global surface. Only this build has the rule.
IOSurfaceRef s1_surface(const char *phase, const char *kind, int global,
                        const unsigned char *can, NSString *hex) {
  NSMutableDictionary *d = [@{
    (id)kIOSurfaceWidth : @4096,
    (id)kIOSurfaceHeight : @64,
    (id)kIOSurfaceBytesPerElement : @1,
  } mutableCopy];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (global) d[(id)kIOSurfaceIsGlobal] = @YES;
#pragma clang diagnostic pop
  IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)d);
  if (!s) {
    s1_out("test: s1 %s surf %s create=NULL\n", phase, kind);
    return NULL;
  }
  if (IOSurfaceLock(s, 0, NULL) == kIOReturnSuccess) {
    unsigned char *p = (unsigned char *)IOSurfaceGetBaseAddress(s);
    size_t n = IOSurfaceGetAllocSize(s);
    for (size_t o = 0; p && o + 32 <= n; o += 32) memcpy(p + o, can, 32);
    IOSurfaceUnlock(s, 0, NULL);
  }
  IOSurfaceSetValue(s, CFSTR("sealed.canary"), (__bridge CFStringRef)hex);
  s1_out("test: s1 %s surf %s create=ok id=%u\n", phase, kind, IOSurfaceGetID(s));
  return s;
}

}  // namespace

void sealed_s1_share(const char *phase) {
  @autoreleasepool {
    unsigned char can[32];
    arc4random_buf(can, sizeof can);
    char hx[65];
    for (int i = 0; i < 32; i++) snprintf(hx + 2 * i, 3, "%02x", can[i]);
    NSString *hex = [NSString stringWithUTF8String:hx];

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> q = dev ? [dev newCommandQueue] : nil;
    s1_out("test: s1 %s metal device=%d commandQueue=%d\n", phase, dev != nil, q != nil);

    // P1: shared texture. Both storage modes; the handle is encoded for a
    // transport and the result is recorded.
    id<MTLTexture> tex = nil;
    const char *smode = "none";
    for (int i = 0; dev && i < 2 && !tex; i++) {
      MTLTextureDescriptor *d = [MTLTextureDescriptor
          texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Uint
                                       width:kS1W
                                      height:kS1H
                                    mipmapped:NO];
      d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
      d.storageMode = i == 0 ? MTLStorageModePrivate : MTLStorageModeShared;
      tex = [dev newSharedTextureWithDescriptor:d];
      smode = i == 0 ? "private" : "shared";
      s1_out("test: s1 %s tex create=%s storage=%s\n", phase, tex ? "ok" : "NULL", smode);
    }
    if (tex) {
      tex.label = hex;
      long fill = q ? s1_fill(dev, q, tex, can) : -1;
      MTLSharedTextureHandle *th = [tex newSharedTextureHandle];
      NSData *ta = nil;
      const char *enc = s1_encode(th, &ta);
      IOSurfaceRef io = tex.iosurface;
      s1_out("test: s1 %s tex content=%ld handle=%s encode=%s ios=%u\n", phase, fill,
             th ? "ok" : "NULL", enc, io ? IOSurfaceGetID(io) : 0);
      if (ta) {
        std::string line = std::string("test: s1 ") + phase + " tex handle=" + s1_hex(ta) + "\n";
        sealed_reason_write(line.data(), line.size());
      }
    }

    // P2: shared event.
    id<MTLSharedEvent> ev = dev ? [dev newSharedEvent] : nil;
    uint64_t evv = 0x5310000000000000ull | (arc4random() & 0xffffffffull);
    if (ev) {
      ev.label = hex;
      ev.signaledValue = evv;
    }
    NSData *ea = nil;
    const char *eenc = ev ? s1_encode([ev newSharedEventHandle], &ea) : "no-handle";
    s1_out("test: s1 %s ev create=%s value=%016llx encode=%s\n", phase, ev ? "ok" : "NULL",
           (unsigned long long)evv, eenc);
    if (ea) {
      std::string line = std::string("test: s1 ") + phase + " ev handle=" + s1_hex(ea) + "\n";
      sealed_reason_write(line.data(), line.size());
    }

    // Transport: the two directions a handle would need. The control build
    // (no sandbox) must succeed at both, or the arm is void.
    mach_port_t svc = MACH_PORT_NULL;
    kern_return_t kin = bootstrap_check_in(bootstrap_port, SEALED_TEST_S1_SERVICE, &svc);
    mach_port_t lk = MACH_PORT_NULL;
    kern_return_t kl = bootstrap_look_up(bootstrap_port, SEALED_TEST_S1_LOOKUP, &lk);
    s1_out("test: s1 %s xpc register=%s kr=0x%x lookup=%s kr=0x%x\n", phase,
           kin == KERN_SUCCESS ? "ok" : "REFUSED", kin,
           kl == KERN_SUCCESS ? "ok" : "REFUSED", kl);
    if (svc != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), svc);
    if (lk != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), lk);

    // P5 control target for the reader.
    IOSurfaceRef gl = s1_surface(phase, "global", 1, can, hex);
    IOSurfaceRef ng = s1_surface(phase, "nonglobal", 0, can, hex);

    s1_out("test: s1 %s hold=%d pid=%d global=%u nonglobal=%u canary=%s\n", phase,
           SEALED_TEST_S1_HOLD, getpid(), gl ? IOSurfaceGetID(gl) : 0,
           ng ? IOSurfaceGetID(ng) : 0, hx);
    for (int t = 0; t < SEALED_TEST_S1_HOLD; t++) sleep(1);
    if (gl) CFRelease(gl);
    if (ng) CFRelease(ng);
    s1_out("test: s1 %s released\n", phase);
  }
}
#endif  // SEALED_TEST_S1_SHARE
