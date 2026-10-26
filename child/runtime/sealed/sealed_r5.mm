// sealed_r5 — see sealed_r5.h. Objective-C++ (Metal SPI for the cache path).
#include "sealed/sealed_r5.h"
#include "sealed/sealed_r2.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOKit/IOKitLib.h>
#include <bootstrap.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <unistd.h>

extern "C" int sandbox_init_with_parameters(const char *profile, uint64_t flags,
                                            const char *const parameters[], char **errorbuf);
extern "C" void MTLSetShaderCachePath(NSString *path);
extern "C" NSString *MTLGetShaderCachePath(void);
extern "C" NSString *MTLGetModulesCachePath(void);

namespace {

[[noreturn]] void refuse(const char *why, const char *what) {
  char b[700];
  int n = snprintf(b, sizeof b, "sealed-r5: %s: %s\n", why, what ? what : "");
  if (n > 0) (void)!write(2, b, (size_t)n);
  if (n > 0) sealed_reason_write(b, (size_t)n);
  _exit(113);
}

// Review N4: the profile text is built at run time; a truncated text refuses.
void pcat(char *dst, const char *s, size_t cap) {
  if (strlcat(dst, s, cap) >= cap) refuse("profile text truncated", nullptr);
}

void note(const char *line) {
  sealed_reason_write(line, strlen(line));
}

char gCache[1100];
char gOwnDir[MAXPATHLEN];   // the executable's folder, set in sealed_r5_apply

// R4 order, checked in the child: 1 = sandbox applied, 2 = self-test passed,
// 3 = Metal guard done after both. The "sandboxed" report needs 3.
int gStage = 0;

// Paths of the Data-volume arms that do not exist on this Mac, recorded
// before the sandbox (review N5).
const char *const kDataArms[] = {"/System/Volumes/Data/private/etc/hosts", "/usr/local", "/System/Library/Caches",
                                 "/System/Volumes/Data/usr/local", nullptr};
bool gAbsent[8];

void expect_eperm(const char *arm, int rc, int err) {
  char b[200];
  snprintf(b, sizeof b, "sealed-r5 selftest %s rc=%d errno=%d\n", arm, rc, err);
  note(b);
  if (!(rc != 0 && err == EPERM)) refuse("self-test access was not denied", arm);
}

}  // namespace

extern "C" void sealed_r4_metal_guard(void) {
  const char *tmp = sealed_r2_checked_tmpdir();   // review N8: the envp value R2 checked
  if (!tmp || !tmp[0]) refuse("no checked TMPDIR", nullptr);
  snprintf(gCache, sizeof gCache, "%s/metal-cache", tmp);
  // R4 (v1 RuntimeGuard): the shader cache is off and every Metal cache path
  // names the private directory, set in pinned code before Metal is used.
  if (setenv("MTL_SHADER_CACHE_SIZE", "0", 1) != 0) refuse("cannot disable the shader cache", nullptr);
  @autoreleasepool {
    NSString *dir = [NSString stringWithUTF8String:gCache];
    MTLSetShaderCachePath(dir);
    NSString *s = MTLGetShaderCachePath();
    NSString *m = MTLGetModulesCachePath();
    if (!s || !m || ![s isEqualToString:dir] || ![m isEqualToString:dir])
      refuse("Metal did not accept the private cache directory", gCache);
  }
  if (gStage == 2) gStage = 3;
}

bool sealed_r5_absent(const char *p) {
  for (int i = 0; kDataArms[i]; i++) if (!strcmp(kDataArms[i], p)) return gAbsent[i];
  return false;
}

extern "C" void sealed_r5_apply(const char *const *paths, size_t n) {
  // Record which Data-volume probe paths exist, before the sandbox can hide them.
  for (int i = 0; kDataArms[i]; i++) {
    struct stat st;
    gAbsent[i] = lstat(kDataArms[i], &st) != 0 && errno == ENOENT;
  }
#if defined(SEALED_TEST_PROFILE_CAP)
  static char profile[SEALED_TEST_PROFILE_CAP];   // test build: forces truncation (N4)
#else
  static char profile[64 * 1024];
#endif
  snprintf(profile, sizeof profile, "(version 1)(deny default)\n");
  // /System/Library per directory, without the six firmlinked Data-volume dirs.
  static const char *kFirmlinked[] = {"Caches", "Assets", "AssetsV2", "PreinstalledAssets",
                                      "PreinstalledAssetsV2", "Speech", nullptr};
  pcat(profile, "(allow file-read*", sizeof profile);
  DIR *dp = opendir("/System/Library");
  if (!dp) refuse("cannot list /System/Library", nullptr);
  struct dirent *de;
  while ((de = readdir(dp))) {
    if (de->d_name[0] == '.') continue;
    bool skip = false;
    for (int k = 0; kFirmlinked[k]; k++)
      if (!strcmp(de->d_name, kFirmlinked[k])) skip = true;
    if (skip) continue;
    char one[300];
    if (snprintf(one, sizeof one, "(subpath \"/System/Library/%s\")", de->d_name) >= (int)sizeof one)
      refuse("profile text truncated", de->d_name);
    pcat(profile, one, sizeof profile);
  }
  closedir(dp);
  pcat(profile, ")\n", sizeof profile);
  pcat(profile,
          // Review S6 (2026-10-20): the /usr/bin and /usr/libexec rules were
          // removed. Without them the child loads and serves a request
          // (measured on the M5, 27.2 beta). Each remaining rule has a
          // measurement; /usr/share keeps its firmlink deny below.
          "(allow file-read*(subpath \"/usr/lib\")(subpath \"/usr/share\"))\n"
          "(allow iokit-open (iokit-user-client-class \"IOGPUDeviceUserClient\"))\n"
          // IOSurfaceRootUserClient has no rule, so (deny default) refuses it
          // (T2, review/DENSE-KV-2026-10-23.md). Only the MTL4 command queue
          // and MTLSharedEvent needed the class (measured 2026-10-12,
          // r5-extra/probe.mm; 2026-10-23, review/T2-CLIENT-NEED-2026-10-23.md).
          // The sealed child uses neither: dense KV on the legacy queue.
          // Metal's device setup still tries one open and continues without
          // it. The self-test arm iosurface-open checks the refusal.
#if defined(SEALED_TEST_PROFILE_IOSURFACE_FILTER)
          // T2 follow-up (2026-10-22), test only: the method-filter form Apple
          // uses in com.apple.CoreGraphics.CGPDFService.sb, with selector 0
          // (create) denied. The child has no
          // com.apple.private.security.message-filter entitlement, so
          // sandbox_init must refuse the whole profile; the reason line
          // records that. Measured form: neg/T2F/filt-probe.
          "(allow iokit-open-user-client (iokit-user-client-class \"IOSurfaceRootUserClient\")"
          "(apply-message-filter (deny iokit-external-method (iokit-method-number 0))"
          "(allow iokit-external-method)))\n"
#elif defined(SEALED_TEST_PROFILE_ALLOW_IOSURFACE)
          // Test only (mutant): the class rule production had before
          // 2026-10-23. The self-test arm iosurface-open must refuse it.
          "(allow iokit-open (iokit-user-client-class \"IOSurfaceRootUserClient\"))\n"
#endif
#if !defined(SEALED_TEST_NO_COMPILER_LOOKUP)
          "(allow mach-lookup (global-name \"com.apple.MTLCompilerService\"))\n"
#endif
          "(allow sysctl-read (sysctl-name-prefix \"hw.\"))\n",
          sizeof profile);
  // Later rules win: deny the Data-volume firmlinks that sit inside the
  // allowed subpaths (r5-profile "nodata" set plus CoreTypes, review 2026-10-12).
  pcat(profile,
          "(deny file-read*(subpath \"/System/Volumes/Data\"))"
          "(deny file-read*(subpath \"/usr/share/snmp\"))"
          "(deny file-read*(subpath \"/System/Library/CoreServices/CoreTypes.bundle/Contents/Library\"))\n",
          sizeof profile);
  // The executable's own directory (measured: CF/Metal walk the bundle).
  char exe[MAXPATHLEN], real[MAXPATHLEN];
  uint32_t es = sizeof exe;
  if (_NSGetExecutablePath(exe, &es) != 0 || !realpath(exe, real)) refuse("executable path", nullptr);
  static char exe_real[MAXPATHLEN];
  snprintf(exe_real, sizeof exe_real, "%s", real);   // the executable, resolved
  char *slash = strrchr(real, '/');
  if (!slash) refuse("executable path", real);
  *slash = '\0';
  snprintf(gOwnDir, sizeof gOwnDir, "%s", real);
  static char ownrule[1024];
#if defined(SEALED_TEST_LOG_OWNDIR)
  // Test build: log each allowed access under the executable's directory, so
  // the exact files can be measured (review S5, 2026-10-20).
  snprintf(ownrule, sizeof ownrule, "(allow file-read* (with report) (subpath (param \"SEALED_OWNDIR\")))\n");
#elif defined(SEALED_TEST_NO_OWNDIR)
  ownrule[0] = '\0';   // test build: no rule for the executable's directory
#else
  // Review S5 (2026-10-20): the exact accesses CF and Metal make in the
  // executable's folder, from the record-mode trace (record/opens-pkg.log):
  // the folder itself (stat, open, opendir), Info.plist, en.lproj and
  // Base.lproj (opendir), and the executable. Every other file in the folder
  // (a planted data file) is denied. Metadata on the folder is enough for
  // the lookups that find nothing.
  snprintf(ownrule, sizeof ownrule,
           "(allow file-read* (literal (param \"SEALED_OWNDIR\")))\n"
           "(allow file-read* (literal (param \"SEALED_OWN_EXE\")))\n"
           "(allow file-read-metadata (literal (param \"SEALED_OWN_INFO\")))\n"
           "(allow file-read-metadata (literal (param \"SEALED_OWN_EN\")))\n"
           "(allow file-read-metadata (literal (param \"SEALED_OWN_BASE\")))\n");
#endif
  pcat(profile, ownrule, sizeof profile);
  // One literal parameter slot per manifest path (never spliced into the text).
  static const char *params[2 * 600 + 11];
  static char keys[600][24];
  size_t pi = 0;
  params[pi++] = "SEALED_OWNDIR";
  params[pi++] = strdup(real);
  {
    char b[MAXPATHLEN + 32];
    params[pi++] = "SEALED_OWN_EXE";  params[pi++] = strdup(exe_real);
    snprintf(b, sizeof b, "%s/Info.plist", real);  params[pi++] = "SEALED_OWN_INFO"; params[pi++] = strdup(b);
    snprintf(b, sizeof b, "%s/en.lproj", real);    params[pi++] = "SEALED_OWN_EN";   params[pi++] = strdup(b);
    snprintf(b, sizeof b, "%s/Base.lproj", real);  params[pi++] = "SEALED_OWN_BASE"; params[pi++] = strdup(b);
  }
  if (n > 600) refuse("too many manifest paths for the slots", nullptr);
  for (size_t i = 0; i < n; i++) {
    snprintf(keys[i], sizeof keys[i], "SEALED_M%zu", i);
    char rule[64];
    if (snprintf(rule, sizeof rule, "(allow file-read* (literal (param \"%s\")))\n", keys[i]) >= (int)sizeof rule)
      refuse("profile text truncated", keys[i]);
    pcat(profile, rule, sizeof profile);
    params[pi++] = keys[i];
    params[pi++] = paths[i];
  }
  params[pi] = nullptr;
#if defined(SEALED_TEST_PROFILE_ALLOW_WRITE)
  pcat(profile, "(allow file-write*)\n", sizeof profile);
#endif
#if defined(SEALED_TEST_PROFILE_ALLOW_NET)
  pcat(profile, "(allow network*)\n", sizeof profile);
#endif
#if defined(SEALED_TEST_PROFILE_ALLOW_EXTENSION)
  // Test build: control for A-17 (a consumed read extension then grants).
  pcat(profile, "(allow file-read* (extension \"com.apple.app-sandbox.read\"))\n", sizeof profile);
#endif
#if defined(SEALED_TEST_PROFILE_ALLOW_LOOKUP)
  pcat(profile, "(allow mach-lookup)\n", sizeof profile);
#endif
  char *err = nullptr;
  if (sandbox_init_with_parameters(profile, 0, params, &err) != 0) refuse("sandbox_init failed", err);
  gStage = 1;
}

extern "C" void sealed_r5_self_test(const char *manifest_path_example) {
  char p[1200];
  if (!gCache[0]) {
    const char *t = sealed_r2_checked_tmpdir();
    snprintf(gCache, sizeof gCache, "%s/metal-cache", (t && t[0]) ? t : "/nonexistent");
  }
  const char *home = sealed_r2_checked_tmpdir();   // HOME == TMPDIR, checked by R2
  // 1 create a file in HOME outside the Metal cache directory
  snprintf(p, sizeof p, "%s/r5-%u", home ? home : "/nonexistent", arc4random());
  int fd = open(p, O_CREAT | O_WRONLY | O_EXCL, 0600);
  expect_eperm("write-home", fd >= 0 ? 0 : -1, errno);
  // 2 create a file outside HOME
  snprintf(p, sizeof p, "/private/tmp/r5-%u", arc4random());
  fd = open(p, O_CREAT | O_WRONLY | O_EXCL, 0600);
  expect_eperm("write-outside-home", fd >= 0 ? 0 : -1, errno);
  // 3 create a file in the Metal cache directory (the profile has no write rule)
  snprintf(p, sizeof p, "%s/r5-%u", gCache, arc4random());
  fd = open(p, O_CREAT | O_WRONLY | O_EXCL, 0600);
  expect_eperm("write-metal-cache", fd >= 0 ? 0 : -1, errno);
  // 4 read a file outside the manifest (a system-readable Data-volume file)
  fd = open("/private/etc/hosts", O_RDONLY);
  expect_eperm("read-outside-manifest", fd >= 0 ? 0 : -1, errno);
  // 5 open a manifest path for writing (no O_CREAT/O_TRUNC; nothing is written)
  fd = open(manifest_path_example, O_WRONLY);
  expect_eperm("open-manifest-write", fd >= 0 ? 0 : -1, errno);
  if (fd >= 0) close(fd);
  // 6-8 network
  int s = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in a = {};
  a.sin_family = AF_INET; a.sin_port = htons(9); a.sin_addr.s_addr = htonl(0x7f000001);
  int rc = s >= 0 ? connect(s, (struct sockaddr *)&a, sizeof a) : -1;
  expect_eperm("connect-loopback", rc, errno);
  if (s >= 0) close(s);
  s = socket(AF_INET, SOCK_STREAM, 0);
  a.sin_port = htons(80); a.sin_addr.s_addr = htonl(0x08080808);
  rc = s >= 0 ? connect(s, (struct sockaddr *)&a, sizeof a) : -1;
  expect_eperm("connect-ipv4", rc, errno);
  if (s >= 0) close(s);
  int s6 = socket(AF_INET6, SOCK_STREAM, 0);
  struct sockaddr_in6 a6 = {};
  a6.sin6_family = AF_INET6; a6.sin6_port = htons(80);
  a6.sin6_addr.s6_addr[0] = 0x20; a6.sin6_addr.s6_addr[1] = 0x01; a6.sin6_addr.s6_addr[2] = 0x0d;
  a6.sin6_addr.s6_addr[3] = 0xb8; a6.sin6_addr.s6_addr[15] = 1;
  rc = s6 >= 0 ? connect(s6, (struct sockaddr *)&a6, sizeof a6) : -1;
  expect_eperm("connect-ipv6", rc, errno);
  if (s6 >= 0) close(s6);
  // 9 connect an AF_UNIX socket to a path (the launchd socket exists on every Mac)
  s = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un u = {};
  u.sun_family = AF_UNIX;
  strlcpy(u.sun_path, "/private/var/run/syslog", sizeof u.sun_path);
  rc = s >= 0 ? connect(s, (struct sockaddr *)&u, sizeof u) : -1;
  expect_eperm("connect-af-unix", rc, errno);
  if (s >= 0) close(s);
  // 10 bind AF_UNIX, 11 bind+listen TCP
  s = socket(AF_UNIX, SOCK_STREAM, 0);
  snprintf(u.sun_path, sizeof u.sun_path, "%s/r5b-%u", gCache, arc4random());
  rc = s >= 0 ? bind(s, (struct sockaddr *)&u, sizeof u) : -1;
  expect_eperm("bind-af-unix", rc, errno);
  if (s >= 0) close(s);
  s = socket(AF_INET, SOCK_STREAM, 0);
  a.sin_port = 0; a.sin_addr.s_addr = htonl(0x7f000001);
  rc = s >= 0 ? bind(s, (struct sockaddr *)&a, sizeof a) : -1;
  if (rc == 0) rc = listen(s, 1);
  expect_eperm("bind-listen-tcp", rc, errno);
  if (s >= 0) close(s);
  // 12 mach-lookup of a global name not in the allowlist (must not succeed)
  mach_port_t bs = MACH_PORT_NULL, svc = MACH_PORT_NULL;
  task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bs);
  kern_return_t kr = bootstrap_look_up(bs, "com.apple.system.logger", &svc);
  {
    char b[120]; snprintf(b, sizeof b, "sealed-r5 selftest mach-lookup kr=%d\n", kr); note(b);
  }
  // Review S7 (measured 2026-10-20, M5 27.2 beta): a sandbox denial returns
  // 1100 (BOOTSTRAP_NOT_PRIVILEGED); an unknown name returns 1102 and the
  // logger without a sandbox returns 0. Only 1100 proves the denial.
  if (kr != 1100) refuse("self-test mach-lookup did not return the recorded denial 1100", "mach-lookup");
  // 13 a sysctl outside the measured hw.* set
  char buf[256]; size_t len = sizeof buf;
  rc = sysctlbyname("kern.bootargs", buf, &len, nullptr, 0);
  expect_eperm("sysctl-kern", rc, errno);
  // 14-17 Data-volume reads through /System and firmlinks
  const char *const *dv = kDataArms;
  for (int i = 0; dv[i]; i++) {
    // Review N5: a Mac without /usr/local has nothing there to read. The
    // existence check (lstat of the parent's entry) is itself a metadata read
    // the profile may deny, so a path that lstat reports ENOENT for before the
    // sandbox was recorded in gAbsent and is skipped; a path that exists must
    // be refused with EPERM.
    if (sealed_r5_absent(dv[i])) { char b[160]; snprintf(b, sizeof b, "sealed-r5 selftest %s absent on this Mac: skipped\n", dv[i]); note(b); continue; }
    fd = open(dv[i], O_RDONLY);
    expect_eperm(dv[i], fd >= 0 ? 0 : -1, errno);
  }
  // 18 DNS. The oracle is the denied access to the resolver itself, not
  // getaddrinfo's result (review S7): the resolver's mach service must be
  // denied with 1100, and its socket with EPERM (both measured 2026-10-20;
  // without a sandbox the lookup returns 0 and the connect succeeds).
  {
    mach_port_t dns = MACH_PORT_NULL;
    kern_return_t dkr = bootstrap_look_up(bs, "com.apple.dnssd.service", &dns);
    char b[120]; snprintf(b, sizeof b, "sealed-r5 selftest dns-lookup kr=%d\n", dkr); note(b);
    if (dkr != 1100) refuse("self-test resolver lookup did not return the recorded denial 1100", "dns");
    int ds = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un du = {};
    du.sun_family = AF_UNIX;
    strlcpy(du.sun_path, "/var/run/mDNSResponder", sizeof du.sun_path);
    int drc = ds >= 0 ? connect(ds, (struct sockaddr *)&du, sizeof du) : -1;
    expect_eperm("dns-socket", drc, errno);
    if (ds >= 0) close(ds);
  }
  // 22 IOSurfaceRootUserClient (T2, review/DENSE-KV-2026-10-23.md): the
  // profile has no rule for the class, so the open must be refused. The
  // sandbox answers kIOReturnNotPermitted (0xe00002e2, measured 2026-10-23);
  // a missing service or any other result is a failure.
  {
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault,
                                                    IOServiceMatching("IOSurfaceRoot"));
    if (!root) refuse("self-test found no IOSurfaceRoot service", "iosurface-open");
    io_connect_t conn = IO_OBJECT_NULL;
    kern_return_t okr = IOServiceOpen(root, mach_task_self(), 0, &conn);
    if (conn != IO_OBJECT_NULL) IOServiceClose(conn);
    IOObjectRelease(root);
    char b[120];
    snprintf(b, sizeof b, "sealed-r5 selftest iosurface-open rc=0x%08x\n", (unsigned)okr);
    note(b);
    if (okr != kIOReturnNotPermitted) refuse("self-test access was not denied", "iosurface-open");
  }
  // 21 a data file in the executable's own folder that the profile does not
  // name (review S5): the folder is writable by the operator, so a planted
  // file must not be readable. Measured 2026-10-20: the sandbox answers
  // ENOENT for a name that does not exist and EPERM only for one that does,
  // so the release folder ships this probe file (stage-child.sh), and only
  // EPERM is accepted.
  {
    char ow[MAXPATHLEN + 32];
    snprintf(ow, sizeof ow, "%s/r5-owndir-probe", gOwnDir);
    int ofd = open(ow, O_RDONLY);
    expect_eperm("read-owndir-file", ofd >= 0 ? 0 : -1, errno);
  }
  // 19-20 probe files the engine placed after the first byte (spec Y2): one in
  // $TMPDIR outside the cache directory, one in metal-cache. Reading each must
  // be denied with EPERM. A missing probe is a failure, not a pass: the
  // engine always places them before it sends the config frame.
  {
    const char *t = sealed_r2_checked_tmpdir();
    char pp[1200];
    snprintf(pp, sizeof pp, "%s/r5-probe", t);
    int pfd = open(pp, O_RDONLY);
    expect_eperm("read-tmpdir-probe", pfd >= 0 ? 0 : -1, errno);
    snprintf(pp, sizeof pp, "%s/r5-probe", gCache);
    pfd = open(pp, O_RDONLY);
    expect_eperm("read-metal-cache-probe", pfd >= 0 ? 0 : -1, errno);
  }
  note("sealed-r5 selftest done: all denials held\n");
  if (gStage == 1) gStage = 2;
}

extern "C" void sealed_r5_report_sandboxed(void) {
  if (gStage != 3) refuse("sandboxed report out of order", nullptr);
  static const char msg[4] = {'S', 'L', 'S', 'B'};
  size_t off = 0;
  while (off < sizeof msg) {
    ssize_t w = write(1, msg + off, sizeof msg - off);
    if (w < 0 && errno == EINTR) continue;
    if (w <= 0) refuse("cannot write the sandboxed report", nullptr);
    off += (size_t)w;
  }
  gStage = 4;
  note("sealed-r5 reported sandboxed\n");
}
