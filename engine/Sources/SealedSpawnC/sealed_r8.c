// sealed_r8 — see include/sealed_r8.h. Profile builder and arm patterns
// adapted from the child's sealed_r5.mm (R5); plain C, no Metal.
#include <sealed_r8.h>

#include <bootstrap.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <libproc.h>
#include <net/if.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <netinet/in.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/param.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

extern int sandbox_init_with_parameters(const char *profile, uint64_t flags,
                                        const char *const parameters[], char **errorbuf);
extern int sandbox_check(pid_t pid, const char *operation, int type, ...);
extern char **environ;

// R5 S7 (measured 2026-10-20, M5 27.2 beta): a sandbox denial of a mach
// lookup returns 1100 (BOOTSTRAP_NOT_PRIVILEGED); an unknown name returns 1102.
#define R8_MACH_DENIED 1100

static int g_log = -1;
static char g_why[600];

static void say(const char *fmt, ...) {
    char b[700];
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(b, sizeof b - 1, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n > (int)sizeof b - 2) n = (int)sizeof b - 2;
    b[n++] = '\n';
    (void)!write(2, b, (size_t)n);
    if (g_log >= 0) (void)!write(g_log, b, (size_t)n);
}

static int set_why(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vsnprintf(g_why, sizeof g_why, fmt, ap);
    va_end(ap);
    say("sealed-r8: refused: %s", g_why);
    return -1;
}

// R5 N4: the profile text is built at run time; a truncated text refuses.
static int pcat(char *dst, const char *s, size_t cap) {
    if (strlcat(dst, s, cap) >= cap) return set_why("profile text truncated");
    return 0;
}

// ---- self-test arms -------------------------------------------------------
//
// Each arm makes one access and returns its result as (rc, err, kr). The same
// arm runs twice: once before the sandbox (control) and once inside it. The
// control passes when the access is not refused by a policy (rc == 0, or an
// error other than EPERM; for a mach lookup, kr == 0). The in-sandbox run
// passes only with EPERM (kr == 1100 for a mach lookup).

typedef struct {
    int rc;
    int err;
    int kr;       // mach arms only; -1 otherwise
} arm_result;

typedef struct {
    const char *name;
    arm_result (*fn)(const void *ctx);
    const void *ctx;
    int skip;     // 1 = not applicable on this Mac (recorded before the sandbox)
} arm;

static char g_home[MAXPATHLEN], g_tmpdir[MAXPATHLEN], g_pkg_file[MAXPATHLEN], g_child[MAXPATHLEN];
static char g_ownprobe[MAXPATHLEN], g_info[MAXPATHLEN];
static uint16_t g_port;

static arm_result res(int rc, int err) { arm_result r = { rc, err, -1 }; return r; }

static arm_result create_in(const char *dir) {
    char p[MAXPATHLEN + 40];
    snprintf(p, sizeof p, "%s/r8-%u", dir, arc4random());
    int fd = open(p, O_CREAT | O_WRONLY | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    int e = errno;
    if (fd >= 0) { close(fd); unlink(p); return res(0, 0); }
    return res(-1, e);
}
static arm_result a_write_home(const void *c) { (void)c; return create_in(g_home); }
static arm_result a_write_tmpdir(const void *c) { (void)c; return create_in(g_tmpdir); }
static arm_result a_write_tmp(const void *c) { (void)c; return create_in("/private/tmp"); }

static arm_result read_path(const char *p) {
    int fd = open(p, O_RDONLY | O_CLOEXEC);
    int e = errno;
    if (fd >= 0) { close(fd); return res(0, 0); }
    return res(-1, e);
}
static arm_result a_read_path(const void *c) { return read_path((const char *)c); }
static arm_result a_read_pkg(const void *c) { (void)c; return read_path(g_pkg_file); }
static arm_result a_read_child(const void *c) { (void)c; return read_path(g_child); }
static arm_result a_read_ownprobe(const void *c) { (void)c; return read_path(g_ownprobe); }

// Write to the engine's own Info.plist (no O_CREAT/O_TRUNC; nothing is written).
static arm_result a_write_info(const void *c) {
    (void)c;
    int fd = open(g_info, O_WRONLY | O_CLOEXEC);
    int e = errno;
    if (fd >= 0) { close(fd); return res(0, 0); }
    return res(-1, e);
}

// Start a helper process (any debug or exfiltration helper goes through exec).
static arm_result a_spawn(const void *c) {
    (void)c;
    pid_t pid = 0;
    char *argv[] = { "/usr/bin/true", NULL };
    char *envp[] = { NULL };
    int rc = posix_spawn(&pid, "/usr/bin/true", NULL, NULL, argv, envp);
    if (rc == 0) { int st; while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {} return res(0, 0); }
    return res(-1, rc);
}

static arm_result a_fork(const void *c) {
    (void)c;
    pid_t pid = fork();
    if (pid == 0) _exit(0);
    if (pid > 0) { int st; while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {} return res(0, 0); }
    return res(-1, errno);
}

// Non-blocking connect: the sandbox check is synchronous; the control gets
// EINPROGRESS or ECONNREFUSED, never EPERM.
static arm_result connect_nb(int family, const struct sockaddr *sa, socklen_t len) {
    int s = socket(family, SOCK_STREAM, 0);
    if (s < 0) return res(-1, errno);
    fcntl(s, F_SETFL, O_NONBLOCK);
    int rc = connect(s, sa, len);
    int e = errno;
    close(s);
    return res(rc, rc == 0 ? 0 : e);
}
static arm_result a_connect_loopback(const void *c) {
    (void)c;
    struct sockaddr_in a = { .sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(9) };
    a.sin_addr.s_addr = htonl(0x7f000001);
    return connect_nb(AF_INET, (struct sockaddr *)&a, sizeof a);
}
// TEST-NET-1 (RFC 5737): an arbitrary outside host that carries no traffic.
static arm_result a_connect_ipv4(const void *c) {
    (void)c;
    struct sockaddr_in a = { .sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(443) };
    a.sin_addr.s_addr = htonl(0xc0000201);
    return connect_nb(AF_INET, (struct sockaddr *)&a, sizeof a);
}
static arm_result a_connect_ipv6(const void *c) {
    (void)c;
    struct sockaddr_in6 a6 = { .sin6_len = sizeof a6, .sin6_family = AF_INET6, .sin6_port = htons(443) };
    a6.sin6_addr.s6_addr[0] = 0x20; a6.sin6_addr.s6_addr[1] = 0x01; a6.sin6_addr.s6_addr[2] = 0x0d;
    a6.sin6_addr.s6_addr[3] = 0xb8; a6.sin6_addr.s6_addr[15] = 1;
    return connect_nb(AF_INET6, (struct sockaddr *)&a6, sizeof a6);
}
static arm_result connect_unix(const char *path) {
    struct sockaddr_un u = { .sun_family = AF_UNIX };
    strlcpy(u.sun_path, path, sizeof u.sun_path);
    return connect_nb(AF_UNIX, (struct sockaddr *)&u, sizeof u);
}
static arm_result a_connect_syslog(const void *c) { (void)c; return connect_unix("/private/var/run/syslog"); }
static arm_result a_dns_socket(const void *c) { (void)c; return connect_unix("/private/var/run/mDNSResponder"); }

static arm_result a_bind_unix(const void *c) {
    (void)c;
    struct sockaddr_un u = { .sun_family = AF_UNIX };
    snprintf(u.sun_path, sizeof u.sun_path, "%s/r8b-%u", g_tmpdir, arc4random());
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0) return res(-1, errno);
    int rc = bind(s, (struct sockaddr *)&u, sizeof u);
    int e = errno;
    close(s);
    if (rc == 0) unlink(u.sun_path);
    return res(rc, rc == 0 ? 0 : e);
}

static arm_result bind_listen(uint32_t addr, uint16_t port, int do_listen) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return res(-1, errno);
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = { .sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(port) };
    a.sin_addr.s_addr = htonl(addr);
    int rc = bind(s, (struct sockaddr *)&a, sizeof a);
    if (rc == 0 && do_listen) rc = listen(s, 1);
    int e = errno;
    close(s);
    return res(rc, rc == 0 ? 0 : e);
}
// A loopback listener on any port other than the engine's.
static arm_result a_listen_other(const void *c) { (void)c; return bind_listen(0x7f000001, 0, 1); }
// The engine's port on this Mac's own non-loopback address and on every
// interface. Bind only: the sandbox decides at bind, and a listen would ask
// the application firewall in the control run. Measured 2026-10-21: an SBPL
// bind rule (local tcp "localhost:N") also admits 0.0.0.0:N and the LAN
// address, so the profile has no bind rule; the engine binds 127.0.0.1
// before it enters the sandbox (main.swift), and these arms check that no
// second listener can appear.
static uint32_t g_lan_addr;
static void pick_lan_addr(void) {
    struct ifaddrs *ifs = NULL;
    if (getifaddrs(&ifs) != 0) return;
    for (struct ifaddrs *i = ifs; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || (i->ifa_flags & IFF_LOOPBACK) || !(i->ifa_flags & IFF_UP)) continue;
        g_lan_addr = ntohl(((struct sockaddr_in *)i->ifa_addr)->sin_addr.s_addr);
        break;
    }
    freeifaddrs(ifs);
}
static arm_result a_bind_lan(const void *c) { (void)c; return bind_listen(g_lan_addr, g_port, 0); }
static arm_result a_bind_any(const void *c) { (void)c; return bind_listen(0, g_port, 0); }

static arm_result a_udp_send(const void *c) {
    (void)c;
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return res(-1, errno);
    struct sockaddr_in a = { .sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(53) };
    a.sin_addr.s_addr = htonl(0xc0000201);
    ssize_t n = sendto(s, "x", 1, 0, (struct sockaddr *)&a, sizeof a);
    int e = errno;
    close(s);
    return res(n == 1 ? 0 : -1, n == 1 ? 0 : e);
}

static arm_result a_mach(const void *c) {
    mach_port_t bs = MACH_PORT_NULL, svc = MACH_PORT_NULL;
    task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bs);
    kern_return_t kr = bootstrap_look_up(bs, (const char *)c, &svc);
    if (kr == KERN_SUCCESS && svc != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), svc);
    arm_result r = { kr == KERN_SUCCESS ? 0 : -1, 0, kr };
    return r;
}

static arm_result a_sysctl(const void *c) {
    (void)c;
    char buf[1024]; size_t len = sizeof buf;
    int rc = sysctlbyname("kern.bootargs", buf, &len, NULL, 0);
    return res(rc, rc == 0 ? 0 : errno);
}

// Information about another process of the same user that is not the
// engine's child (chosen before the sandbox; launchd is root's, so its info
// is refused without a sandbox too).
static pid_t g_other_pid;
static void pick_other_pid(void) {
    static pid_t pids[8192];
    int n = proc_listpids(PROC_UID_ONLY, getuid(), pids, sizeof pids) / (int)sizeof(pid_t);
    uint64_t best = 0;
    for (int i = 0; i < n; i++) {
        if (pids[i] <= 1 || pids[i] == getpid()) continue;
        struct proc_bsdinfo bi;
        if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &bi, sizeof bi) != (int)sizeof bi) continue;
        if ((pid_t)bi.pbi_ppid == getpid()) continue;
        if (kill(pids[i], 0) != 0) continue;   // the control must be able to signal it
        // The oldest one (a session process): it must still exist when the
        // arm runs again in the sandbox (a short-lived pick gave ESRCH).
        if (g_other_pid == 0 || bi.pbi_start_tvsec < best) { g_other_pid = pids[i]; best = bi.pbi_start_tvsec; }
    }
}
static arm_result a_pidinfo(const void *c) {
    static int logged;
    if (!logged++) say("sealed-r8 other-process arms use pid %d", (int)g_other_pid);
    (void)c;
    struct proc_bsdinfo bi;
    errno = 0;
    int n = proc_pidinfo(g_other_pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi);
    int e = errno;
    if (n == (int)sizeof bi) return res(0, 0);
    return res(-1, e ? e : EPERM);
}

static arm_result a_procargs(const void *c) {
    (void)c;
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, g_other_pid };
    static char buf[16384]; size_t len = sizeof buf;
    int rc = sysctl(mib, 3, buf, &len, NULL, 0);
    return res(rc, rc == 0 ? 0 : errno);
}

static arm_result a_signal_other(const void *c) {
    (void)c;
    int rc = kill(g_other_pid, 0);
    return res(rc, rc == 0 ? 0 : errno);
}

// Data-volume probe paths (R5 kDataArms), recorded before the sandbox (R5 N5).
static const char *const kDataArms[] = { "/System/Volumes/Data/private/etc/hosts", "/usr/local",
                                         "/System/Library/Caches", "/System/Volumes/Data/usr/local", NULL };

static arm g_arms[40];
static int g_narms;

static void add(const char *name, arm_result (*fn)(const void *), const void *ctx, int skip) {
    arm a = { name, fn, ctx, skip };
    g_arms[g_narms++] = a;
}

static void build_arms(void) {
    g_narms = 0;
    add("write-home", a_write_home, NULL, 0);
    add("write-tmpdir", a_write_tmpdir, NULL, 0);
    add("write-private-tmp", a_write_tmp, NULL, 0);
    add("write-own-info-plist", a_write_info, NULL, 0);
    add("read-etc-hosts", a_read_path, "/private/etc/hosts", 0);
    add("read-package-after-load", a_read_pkg, NULL, 0);
    add("read-child-executable", a_read_child, NULL, 0);
    add("read-owndir-file", a_read_ownprobe, NULL, 0);
    add("spawn-process", a_spawn, NULL, 0);
    add("fork", a_fork, NULL, 0);
    add("connect-loopback", a_connect_loopback, NULL, 0);
    add("connect-ipv4-outside", a_connect_ipv4, NULL, 0);
    add("connect-ipv6-outside", a_connect_ipv6, NULL, 0);
    add("udp-send-outside", a_udp_send, NULL, 0);
    add("connect-af-unix", a_connect_syslog, NULL, 0);
    add("bind-af-unix", a_bind_unix, NULL, 0);
    add("listen-other-port", a_listen_other, NULL, 0);
    pick_lan_addr();
    add("bind-port-lan-address", a_bind_lan, NULL, g_lan_addr == 0);
    add("bind-port-all-interfaces", a_bind_any, NULL, 0);
    add("mach-lookup-logger", a_mach, "com.apple.system.logger", 0);
    add("mach-lookup-dns", a_mach, "com.apple.dnssd.service", 0);
    add("dns-socket", a_dns_socket, NULL, 0);
    add("sysctl-kern-bootargs", a_sysctl, NULL, 0);
    pick_other_pid();
    add("pidinfo-other-process", a_pidinfo, NULL, g_other_pid <= 0);
    add("procargs-other-process", a_procargs, NULL, g_other_pid <= 0);
    add("signal-other-process", a_signal_other, NULL, g_other_pid <= 0);
    for (int i = 0; kDataArms[i]; i++) {
        struct stat st;
        int absent = lstat(kDataArms[i], &st) != 0 && errno == ENOENT;
        add(kDataArms[i], a_read_path, kDataArms[i], absent);
    }
}

static int is_mach(const arm *a) { return a->fn == a_mach; }

// Control: the access must not be refused by a policy.
static int run_controls(void) {
    for (int i = 0; i < g_narms; i++) {
        const arm *a = &g_arms[i];
        if (a->skip) { say("sealed-r8 control %s: absent on this Mac, skipped", a->name); continue; }
        arm_result r = a->fn(a->ctx);
        int ok = is_mach(a) ? r.kr == 0 : !(r.rc != 0 && r.err == EPERM);
        if (is_mach(a)) say("sealed-r8 control %s kr=%d %s", a->name, r.kr, ok ? "ok" : "FAIL");
        else say("sealed-r8 control %s rc=%d errno=%d %s", a->name, r.rc, r.err, ok ? "ok" : "FAIL");
        if (!ok) return set_why("control arm %s was refused before the sandbox", a->name);
    }
    return 0;
}

// In the sandbox: every access must be denied by the policy.
static int run_denials(void) {
    for (int i = 0; i < g_narms; i++) {
        const arm *a = &g_arms[i];
        if (a->skip) { say("sealed-r8 selftest %s: absent on this Mac, skipped", a->name); continue; }
        arm_result r = a->fn(a->ctx);
        int ok = is_mach(a) ? r.kr == R8_MACH_DENIED : (r.rc != 0 && r.err == EPERM);
        if (is_mach(a)) say("sealed-r8 selftest %s kr=%d %s", a->name, r.kr, ok ? "denied" : "NOT DENIED");
        else say("sealed-r8 selftest %s rc=%d errno=%d %s", a->name, r.rc, r.err, ok ? "denied" : "NOT DENIED");
        if (!ok) return set_why("self-test access was not denied: %s", a->name);
    }
    return 0;
}

// ---- profile --------------------------------------------------------------

static int build_profile(char *profile, size_t cap, const char *const **params_out) {
    snprintf(profile, cap, "(version 1)(deny default)\n");
    // /System/Library per directory, without the six firmlinked Data-volume
    // dirs (R5, measured on the child; the engine's frameworks and their
    // resources live there).
    static const char *kFirmlinked[] = { "Caches", "Assets", "AssetsV2", "PreinstalledAssets",
                                         "PreinstalledAssetsV2", "Speech", NULL };
    if (pcat(profile, "(allow file-read*", cap)) return -1;
    DIR *dp = opendir("/System/Library");
    if (!dp) return set_why("cannot list /System/Library");
    struct dirent *de;
    while ((de = readdir(dp))) {
        if (de->d_name[0] == '.') continue;
        int skip = 0;
        for (int k = 0; kFirmlinked[k]; k++) if (!strcmp(de->d_name, kFirmlinked[k])) skip = 1;
        if (skip) continue;
        char one[300];
        if (snprintf(one, sizeof one, "(subpath \"/System/Library/%s\")", de->d_name) >= (int)sizeof one) {
            closedir(dp);
            return set_why("profile text truncated");
        }
        if (pcat(profile, one, cap)) { closedir(dp); return -1; }
    }
    closedir(dp);
    if (pcat(profile, ")\n", cap)) return -1;
    if (pcat(profile, "(allow file-read*(subpath \"/usr/lib\")(subpath \"/usr/share\"))\n", cap)) return -1;
    // R8 allowances (each one measured; see R8-SANDBOX-2026-10-21.md). There
    // is no network rule: the loopback listener is bound before the sandbox,
    // and accept and I/O on it need none (measured 2026-10-21). Any SBPL
    // network-bind or network-inbound rule with a local port also admits a
    // bind of that port on every interface (measured), so none is added.
    if (pcat(profile,
             // Measured 2026-10-21: (deny default) does not cover
             // process-info*; without this deny, proc_pidinfo, proc_pidpath and
             // KERN_PROCARGS2 on any process of the user succeed.
             "(deny process-info*)\n"
             // Child management: the per-request CD hash/status re-check
             // (csops_audittoken), the reap (waitid/proc_pidinfo) and the kill.
#if !defined(SEALED_R8_TEST_NO_CHILD_RULES)
             "(allow process-info* (target children))\n"
             "(allow signal (target children))\n"
#endif
             // App Attest: generateAssertion for /session and /probe goes to
             // devicecheckd (measured: denied -> "assertion refused", 503).
             "(allow mach-lookup (global-name \"com.apple.devicecheckd\"))\n",
             cap)) return -1;
    // Later rules win: the Data-volume firmlinks inside the allowed subpaths (R5).
    if (pcat(profile,
             "(deny file-read*(subpath \"/System/Volumes/Data\"))"
             "(deny file-read*(subpath \"/usr/share/snmp\"))"
             "(deny file-read*(subpath \"/System/Library/CoreServices/CoreTypes.bundle/Contents/Library\"))\n",
             cap)) return -1;
#if defined(SEALED_R8_TEST_ALLOW_WRITE)
    if (pcat(profile, "(allow file-write*)\n", cap)) return -1;
#endif
#if defined(SEALED_R8_TEST_ALLOW_NET)
    if (pcat(profile, "(allow network*)\n", cap)) return -1;
#endif
#if defined(SEALED_R8_TEST_ALLOW_LOOKUP)
    if (pcat(profile, "(allow mach-lookup)\n", cap)) return -1;
#endif
#if defined(SEALED_R8_TEST_ALLOW_EXEC)
    if (pcat(profile, "(allow process-exec* process-fork)\n", cap)) return -1;
#endif
#if defined(SEALED_R8_TEST_RECORD)
    // Test build: allow and log every operation after the R8 point, so the
    // engine's real accesses can be measured (the R5 S5 record method).
    snprintf(profile, cap, "(version 1)(allow default (with report))\n");
#endif
    static const char *params[3];
    params[0] = NULL;
    *params_out = params;
    return 0;
}

int sealed_r8_enter(const sealed_r8_config *cfg, char *why, size_t why_len) {
    g_why[0] = '\0';
    g_log = cfg->log_fd;
    int rc = -1;
    if (!cfg->package_root || !cfg->package_root[0] || !cfg->child_path || !cfg->child_path[0] || cfg->port == 0 ||
        cfg->child_pid <= 1) {
        set_why("bad R8 configuration");
        goto out;
    }
    g_port = cfg->port;
    {
        const char *h = getenv("HOME");
        const char *t = getenv("TMPDIR");
        if (!h || !h[0] || !t || !t[0]) { set_why("HOME or TMPDIR not set"); goto out; }
        if (!realpath(h, g_home) || !realpath(t, g_tmpdir)) { set_why("HOME or TMPDIR does not resolve"); goto out; }
        snprintf(g_pkg_file, sizeof g_pkg_file, "%s/sealed-manifest.bin", cfg->package_root);
        snprintf(g_child, sizeof g_child, "%s", cfg->child_path);
        char exe[MAXPATHLEN], real[MAXPATHLEN];
        uint32_t es = sizeof exe;
        if (_NSGetExecutablePath(exe, &es) != 0 || !realpath(exe, real)) { set_why("executable path"); goto out; }
        char *slash = strrchr(real, '/');
        if (!slash) { set_why("executable path"); goto out; }
        *slash = '\0';
        snprintf(g_ownprobe, sizeof g_ownprobe, "%s/../Info.plist", real);   // Contents/Info.plist
        if (!realpath(g_ownprobe, g_info)) { set_why("Info.plist path"); goto out; }
        // A readable file in the bundle that the profile does not name.
        snprintf(g_ownprobe, sizeof g_ownprobe, "%s/../PkgInfo", real);
    }
    build_arms();
    if (run_controls() != 0) goto out;
    say("sealed-r8 controls done: every arm reached its target without a sandbox");
    {
        static char profile[64 * 1024];
        const char *const *params = NULL;
        if (build_profile(profile, sizeof profile, &params) != 0) goto out;
        if (cfg->log_fd >= 0) {
            (void)!write(cfg->log_fd, "sealed-r8 profile:\n", 19);
            (void)!write(cfg->log_fd, profile, strlen(profile));
        }
        char *err = NULL;
        if (sandbox_init_with_parameters(profile, 0, params, &err) != 0) {
            set_why("sandbox_init failed: %s", err ? err : "?");
            goto out;
        }
    }
    if (sandbox_check(getpid(), NULL, 0) != 1) { set_why("sandbox_check does not report a sandbox"); goto out; }
    say("sealed-r8 sandbox applied");
#if defined(SEALED_R8_TEST_RECORD)
    say("sealed-r8 RECORD build: profile allows everything; self-test skipped");
#else
    if (run_denials() != 0) goto out;
#endif
    {
        // The allowances the engine needs while serving must still work.
        struct proc_bsdinfo bi;
        errno = 0;
        int n = proc_pidinfo(cfg->child_pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi);
        say("sealed-r8 selftest child-pidinfo n=%d errno=%d %s", n, errno, n == (int)sizeof bi ? "allowed" : "REFUSED");
        if (n != (int)sizeof bi) { set_why("child-pidinfo is refused in the sandbox"); goto out; }
        int k = kill(cfg->child_pid, 0);
        say("sealed-r8 selftest child-signal0 rc=%d errno=%d %s", k, k ? errno : 0, k == 0 ? "allowed" : "REFUSED");
        if (k != 0) { set_why("child-signal0 is refused in the sandbox"); goto out; }
    }
    say("sealed-r8 selftest done: all denials held");
    rc = 0;
out:
    if (rc != 0 && why && why_len) snprintf(why, why_len, "%s", g_why);
    return rc;
}
