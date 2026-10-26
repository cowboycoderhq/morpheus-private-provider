// sealed_r2 — see sealed_r2.h.
#include "sealed/sealed_r2.h"

#include <dirent.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

extern char **environ;

static int gReasonFd = -1;

extern "C" void sealed_reason_open(void) {
#ifdef SEALED_TEST_REASON_FILE
  gReasonFd = open(SEALED_TEST_REASON_FILE, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
#endif
}

extern "C" int sealed_reason_fd(void) { return gReasonFd; }

extern "C" void sealed_reason_write(const char *line, size_t n) {
  if (gReasonFd >= 0 && n) (void)!write(gReasonFd, line, n);
}

namespace {

// Compiled-in rlimits the engine sets (R2). RLIMIT_CPU and RLIMIT_FSIZE are
// RLIM_INFINITY (R1); the others are the macOS defaults the spawn inherits,
// measured on the M5 (27.2 beta) on 2026-10-12. RLIMIT_NOFILE below is the
// soft limit the self-check scans to.

[[noreturn]] void refuse(int code, const char *what) {
  char b[512];
  int n = snprintf(b, sizeof b, "sealed-r2: refused code=%d: %s\n", code, what ? what : "");
  if (n > 0) (void)!write(2, b, (size_t)n);
  // Test builds only (R11 switch): the spawn puts fd 2 on /dev/null.
  if (n > 0) sealed_reason_write(b, (size_t)n);
  _exit(113);
}

bool is_dev_null(int fd) {
  struct stat a, b;
  if (fstat(fd, &a) != 0 || !S_ISCHR(a.st_mode)) return false;
  if (stat("/dev/null", &b) != 0) return false;
  return a.st_rdev == b.st_rdev;
}

bool is_unix_socket(int fd) {
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISSOCK(st.st_mode)) return false;
  int type = 0;
  socklen_t l = sizeof type;
  if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &l) != 0) return false;
  struct sockaddr_storage ss;
  socklen_t sl = sizeof ss;
  if (getsockname(fd, (struct sockaddr *)&ss, &sl) != 0) return false;
  return ss.ss_family == AF_UNIX && type == SOCK_STREAM;
}

bool same_object(int a, int b) {
  struct stat x, y;
  return fstat(a, &x) == 0 && fstat(b, &y) == 0 && x.st_dev == y.st_dev && x.st_ino == y.st_ino;
}

void check_fds() {
  if (!is_unix_socket(0) || !is_unix_socket(1) || !same_object(0, 1))
    refuse(SEALED_R2_FDS, "fd 0 and fd 1 must be one unix stream socket");
  if (!is_dev_null(2)) refuse(SEALED_R2_FDS, "fd 2 must be /dev/null");
  // Every open descriptor, from the kernel's own list (PROC_PIDLISTFDS), so a
  // descriptor above any scan bound or above a lowered RLIMIT_NOFILE is seen
  // (review B2, 2026-10-12).
  static struct proc_fdinfo fds[1024];
  int bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, fds, sizeof fds);
  if (bytes <= 0 || bytes >= (int)sizeof fds) refuse(SEALED_R2_FDS, "cannot list descriptors");
  int count = bytes / (int)sizeof fds[0];
  for (int i = 0; i < count; i++) {
    int fd = fds[i].proc_fd;
    if (fd <= 2) continue;
    if (fd == gReasonFd) continue;   // test builds only
    char w[64];
    snprintf(w, sizeof w, "unexpected open descriptor %d", fd);
    refuse(SEALED_R2_FDS, w);
  }
}

// Checks the spawn environment as the kernel delivered it (main's envp).
// `environ` is not used: CoreFoundation adds __CF_USER_TEXT_ENCODING to it
// before main (measured 2026-10-12, spec R2 "environment contingency"); the
// envp array main receives is the exec-time copy and does not change.
const char *tmpdir_checked(char **envp) {
  int n = 0;
  const char *home = nullptr, *tmp = nullptr;
  for (char **e = envp; *e; e++) {
    n++;
    if (strncmp(*e, "HOME=", 5) == 0) home = *e + 5;
    else if (strncmp(*e, "TMPDIR=", 7) == 0) tmp = *e + 7;
    else refuse(SEALED_R2_ENV, *e);
  }
  if (n != 2 || !home || !tmp || strcmp(home, tmp) != 0 || tmp[0] != '/')
    refuse(SEALED_R2_ENV, "environment must be exactly HOME and TMPDIR, the same directory");
  return tmp;
}

void check_dir(const char *dir) {
  struct stat st;
  if (lstat(dir, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != getuid() ||
      (st.st_mode & 07777) != 0700)
    refuse(SEALED_R2_DIR, "TMPDIR must be a 0700 directory owned by the user");
  DIR *d = opendir(dir);
  if (!d) refuse(SEALED_R2_DIR, "cannot list TMPDIR");
  int entries = 0;
  bool cache_ok = false;
  struct dirent *e;
  while ((e = readdir(d))) {
    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
    entries++;
    if (!strcmp(e->d_name, "metal-cache") && e->d_type == DT_DIR) cache_ok = true;
  }
  closedir(d);
  if (entries != 1 || !cache_ok) refuse(SEALED_R2_DIR, "TMPDIR must hold only metal-cache/");
  char sub[1100];
  snprintf(sub, sizeof sub, "%s/metal-cache", dir);
  // Review S1c: the cache directory must be a real directory owned by the
  // user with mode 0700, like TMPDIR (not a symlink, not group-writable).
  struct stat cs;
  if (lstat(sub, &cs) != 0 || !S_ISDIR(cs.st_mode) || cs.st_uid != getuid() ||
      (cs.st_mode & 07777) != 0700)
    refuse(SEALED_R2_DIR, "metal-cache must be a 0700 directory owned by the user");
  DIR *c = opendir(sub);
  if (!c) refuse(SEALED_R2_DIR, "cannot list metal-cache");
  while ((e = readdir(c))) {
    if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) refuse(SEALED_R2_DIR, "metal-cache is not empty");
  }
  closedir(c);
  char cwd[1100];
  if (!getcwd(cwd, sizeof cwd)) refuse(SEALED_R2_CWD, "getcwd failed");
  char real_tmp[1100];
  if (!realpath(dir, real_tmp) || strcmp(cwd, real_tmp) != 0) refuse(SEALED_R2_CWD, cwd);
}

void check_signals() {
  sigset_t cur;
  if (sigprocmask(SIG_BLOCK, nullptr, &cur) != 0) refuse(SEALED_R2_SIG, "sigprocmask");
  for (int s = 1; s < NSIG; s++) {
    if (sigismember(&cur, s) == 1) {
      char w[64];
      snprintf(w, sizeof w, "signal %d is blocked", s);
      refuse(SEALED_R2_SIG, w);
    }
    if (s == SIGKILL || s == SIGSTOP) continue;
    struct sigaction sa;
    if (sigaction(s, nullptr, &sa) == 0 && sa.sa_handler == SIG_IGN) {
      char w[64];
      snprintf(w, sizeof w, "signal %d is ignored", s);
      refuse(SEALED_R2_SIG, w);
    }
  }
}

// The engine sets these before spawning (the spawn module does not), and the
// child compares the soft and hard values (spec R2). Values chosen 2026-10-12:
// the macOS defaults for STACK, unlimited DATA/AS/CPU/FSIZE, NOFILE 1024.
constexpr rlim_t kStackCur = 8372224, kStackMax = 67092480;
constexpr rlim_t kNofile = 1024;

void check_one(int r, rlim_t cur, rlim_t max, const char *name) {
  struct rlimit rl;
  if (getrlimit(r, &rl) != 0 || rl.rlim_cur != cur || rl.rlim_max != max) {
    char w[160];
    snprintf(w, sizeof w, "%s is %llu/%llu, want %llu/%llu", name, (unsigned long long)rl.rlim_cur,
             (unsigned long long)rl.rlim_max, (unsigned long long)cur, (unsigned long long)max);
    refuse(SEALED_R2_RLIMIT, w);
  }
}

void check_rlimits() {
  check_one(RLIMIT_STACK, kStackCur, kStackMax, "RLIMIT_STACK");
  check_one(RLIMIT_NOFILE, kNofile, kNofile, "RLIMIT_NOFILE");
  check_one(RLIMIT_DATA, RLIM_INFINITY, RLIM_INFINITY, "RLIMIT_DATA");
  check_one(RLIMIT_AS, RLIM_INFINITY, RLIM_INFINITY, "RLIMIT_AS");
  struct rlimit rl;
  if (getrlimit(RLIMIT_CPU, &rl) != 0 || rl.rlim_cur != RLIM_INFINITY)
    refuse(SEALED_R2_RLIMIT, "RLIMIT_CPU must be infinity");
  if (getrlimit(RLIMIT_FSIZE, &rl) != 0 || rl.rlim_cur != RLIM_INFINITY)
    refuse(SEALED_R2_RLIMIT, "RLIMIT_FSIZE must be infinity");
  struct rlimit zero = {0, 0};
  if (setrlimit(RLIMIT_CORE, &zero) != 0) refuse(SEALED_R2_RLIMIT, "cannot set RLIMIT_CORE to 0");
}

bool canonical_abs(const char *p) {
  if (!p || p[0] != '/') return false;
  char r[1100];
  if (!realpath(p, r)) return false;
  return strcmp(r, p) == 0;
}

void check_argv(int argc, char **argv) {
  // splash serve-native TARGET DRAFT MAX_CONTEXT MAX_MEMORY
  if (argc != 6 || strcmp(argv[1], "serve-native") != 0) refuse(SEALED_R2_ARGV, "not the sealed argv form");
  if (!canonical_abs(argv[2]) || !canonical_abs(argv[3])) refuse(SEALED_R2_ARGV, "roots must be canonical absolute paths");
  // The R5 own-folder rules name the resolved executable path. A child
  // started through a symlinked path (e.g. /tmp) is then denied its own
  // folder by CF and Metal and dies with no reason line (measured
  // 2026-10-20). Refuse it here, with a reason, before the first byte.
  {
    char exe[1100];
    uint32_t es = sizeof exe;
    if (_NSGetExecutablePath(exe, &es) != 0 || !canonical_abs(exe))
      refuse(SEALED_R2_ARGV, "executable path must be canonical (no symlink)");
  }
  char *end = nullptr;
  unsigned long ctx = strtoul(argv[4], &end, 10);
  if (!end || *end || ctx < 1024 || ctx > 262144) refuse(SEALED_R2_ARGV, "MAX_CONTEXT out of bounds");
  if (strcmp(argv[5], "auto") != 0) refuse(SEALED_R2_ARGV, "MAX_MEMORY must be auto");
}

uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
uint16_t be16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }

void read_exact(void *dst, size_t n) {
  uint8_t *p = (uint8_t *)dst;
  while (n) {
    ssize_t r = read(0, p, n);
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) refuse(SEALED_R2_FRAME, "config frame truncated");
    p += r;
    n -= (size_t)r;
  }
}

char gPackage[1100], gTarget[1100], gDraft[1100];
uint8_t *gManifest = nullptr;
uint64_t gKvBudget = 0;

void read_str(char *out, size_t cap) {
  uint8_t l[2];
  read_exact(l, 2);
  uint16_t n = be16(l);
  if (n == 0 || n >= cap) refuse(SEALED_R2_FRAME, "bad path length");
  read_exact(out, n);
  out[n] = '\0';
  if (memchr(out, '\0', n)) refuse(SEALED_R2_FRAME, "NUL in path");
}

}  // namespace

static char gCheckedTmp[1100];

extern "C" const char *sealed_r2_checked_tmpdir(void) { return gCheckedTmp; }

extern "C" void sealed_r2_self_check(int argc, char **argv, char **envp) {
  check_fds();
  const char *tmp = tmpdir_checked(envp);
  snprintf(gCheckedTmp, sizeof gCheckedTmp, "%s", tmp);
  check_dir(tmp);
  check_signals();
  check_rlimits();
  check_argv(argc, argv);
}

extern "C" uint64_t sealed_r2_kv_budget_bytes(void) { return gKvBudget; }

extern "C" void sealed_r2_first_byte(void) {
  const char b = 'S';
  for (;;) {
    ssize_t n = write(1, &b, 1);
    if (n == 1) return;
    if (n < 0 && errno == EINTR) continue;
    _exit(113);
  }
}

extern "C" void sealed_r2_read_config(const char *argv_target, const char *argv_draft,
                                      const uint8_t **manifest, size_t *len,
                                      const char **package_root) {
  uint8_t head[8];
  read_exact(head, 8);
  const uint32_t version = be32(head + 4);
  if (memcmp(head, "SLCF", 4) != 0 || (version != 1 && version != 2)) refuse(SEALED_R2_FRAME, "bad magic or version");
  read_str(gPackage, sizeof gPackage);
  read_str(gTarget, sizeof gTarget);
  read_str(gDraft, sizeof gDraft);
  if (strcmp(gTarget, argv_target) != 0 || strcmp(gDraft, argv_draft) != 0)
    refuse(SEALED_R2_FRAME, "frame roots differ from argv");
  char t[1200], d[1200];
  snprintf(t, sizeof t, "%s/target", gPackage);
  snprintf(d, sizeof d, "%s/draft", gPackage);
  if (strcmp(t, gTarget) != 0 || strcmp(d, gDraft) != 0) refuse(SEALED_R2_FRAME, "roots are not <package>/target and <package>/draft");
  uint8_t l4[4];
  read_exact(l4, 4);
  uint32_t ml = be32(l4);
  if (ml == 0 || ml > 64 * 1024) refuse(SEALED_R2_FRAME, "bad manifest length");
  gManifest = (uint8_t *)malloc(ml);
  if (!gManifest) _exit(113);
  read_exact(gManifest, ml);
  if (version == 2) {
    uint8_t b8[8];
    read_exact(b8, 8);
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v = v << 8 | b8[i];
    if (v < SEALED_R2_KV_BUDGET_MIN || v > SEALED_R2_KV_BUDGET_MAX) refuse(SEALED_R2_FRAME, "kv budget out of range");
    gKvBudget = v;
  }
  // Review N3: the frame ends here. Bytes after it (before the child's
  // "loaded" report) are refused; the engine sends nothing more until then.
  {
    int avail = 0;
    if (ioctl(0, FIONREAD, &avail) == 0 && avail > 0) refuse(SEALED_R2_FRAME, "bytes after the manifest in the config frame");
  }
  *manifest = gManifest;
  *len = ml;
  *package_root = gPackage;
}
