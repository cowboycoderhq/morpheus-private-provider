// sealed_bringup.c — see include/sealed_bringup.h.
#include <sealed_bringup.h>
#include <sealed_spawn.h>

#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

extern int csops_audittoken(pid_t, unsigned int, void *, size_t, audit_token_t *);
#define BU_CS_OPS_STATUS 0
#define BU_CS_OPS_CDHASH 5

static int g_log = -1;
static void say(const char *fmt, ...) {
    if (g_log < 0) return;
    char b[600];
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(b, sizeof b - 1, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n > (int)sizeof b - 2) n = (int)sizeof b - 2;
    b[n++] = '\n';
    (void)!write(g_log, b, (size_t)n);
}

static void fail(char *why, size_t len, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vsnprintf(why, len, fmt, ap);
    va_end(ap);
    say("refused: %s", why);
}

static int write_all(int fd, const uint8_t *p, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        p += w; n -= (size_t)w;
    }
    return 0;
}

static int read_exact(int fd, void *dst, size_t n, int timeout_ms) {
    uint8_t *p = dst;
    while (n) {
        struct pollfd pf = { fd, POLLIN, 0 };
        int r = poll(&pf, 1, timeout_ms);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        ssize_t k = read(fd, p, n);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) return -1;
        p += k; n -= (size_t)k;
    }
    return 0;
}

static void put16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = v & 0xff; }
static void put32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

// Frame v2 appends u64 kv_budget_bytes (big-endian) after the manifest; the
// child checks it against its [256 MiB, 1 TiB] range. A 0 budget sends v1.
static int send_config(int fd, const char *pkg, const char *target, const char *draft,
                       const uint8_t *m, size_t mlen, uint64_t kv_budget) {
    size_t lp = strlen(pkg), lt = strlen(target), ld = strlen(draft);
    if (lp > 0xffff || lt > 0xffff || ld > 0xffff || mlen > 0xffffffffu) return -1;
    size_t total = 8 + 2 + lp + 2 + lt + 2 + ld + 4 + mlen + (kv_budget ? 8 : 0);
    uint8_t *b = malloc(total), *p = b;
    if (!b) return -1;
    memcpy(p, "SLCF", 4); put32(p + 4, kv_budget ? 2 : 1); p += 8;
    put16(p, (uint16_t)lp); memcpy(p + 2, pkg, lp); p += 2 + lp;
    put16(p, (uint16_t)lt); memcpy(p + 2, target, lt); p += 2 + lt;
    put16(p, (uint16_t)ld); memcpy(p + 2, draft, ld); p += 2 + ld;
    put32(p, (uint32_t)mlen); memcpy(p + 4, m, mlen); p += 4 + mlen;
    if (kv_budget) for (int i = 0; i < 8; i++) p[i] = (uint8_t)(kv_budget >> (56 - 8 * i));
    int rc = write_all(fd, b, total);
    free(b);
    return rc;
}

static int place_probes(const char *dir) {
    const char *rel[2] = {"r5-probe", "metal-cache/r5-probe"};
    for (int i = 0; i < 2; i++) {
        char p[400];
        snprintf(p, sizeof p, "%s/%s", dir, rel[i]);
        int fd = open(p, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (fd < 0) return -1;
        (void)!write(fd, "probe\n", 6);
        close(fd);
    }
    return 0;
}

static void remove_probes(const char *dir) {
    char p[400];
    snprintf(p, sizeof p, "%s/metal-cache/r5-probe", dir); unlink(p);
    snprintf(p, sizeof p, "%s/r5-probe", dir); unlink(p);
}

// quiet = 1: no log line on success (the liveness check runs per request).
static int recheck_q(const sealed_child_t *c, const uint8_t *pin, uint32_t word, const char *phase, int quiet) {
    uint8_t h[SEALED_CDHASH_LEN];
    uint32_t st = 0;
    audit_token_t t = c->token;
    if (csops_audittoken(c->pid, BU_CS_OPS_CDHASH, h, sizeof h, &t) != 0) { say("%s: csops cdhash failed errno=%d", phase, errno); return -1; }
    t = c->token;
    if (csops_audittoken(c->pid, BU_CS_OPS_STATUS, &st, sizeof st, &t) != 0) { say("%s: csops status failed errno=%d", phase, errno); return -1; }
    int ok = memcmp(h, pin, sizeof h) == 0 && sealed_status_ok(st, word) == 0;
    if (!quiet || !ok)
        say("%s: status=0x%08x cdhash %s", phase, st, memcmp(h, pin, sizeof h) == 0 ? "matches the pin" : "DIFFERS");
    return ok ? 0 : -1;
}

static int recheck(sealed_child_t *c, const uint8_t *pin, uint32_t word, const char *phase) {
    return recheck_q(c, pin, word, phase, 0);
}

static void child_cleanup(sealed_child_t *c) {
    if (c->channel_fd >= 0) { close(c->channel_fd); c->channel_fd = -1; }
    for (int i = 0; i < 3 && c->reaped != 1; i++) sealed_child_kill(c);
    if (c->dir[0]) {
        remove_probes(c->dir);
        char m[300]; snprintf(m, sizeof m, "%s/metal-cache", c->dir);
        rmdir(m); rmdir(c->dir);
    }
}

int sealed_bringup_start(const sealed_bringup_config *cfg, sealed_bringup_result *out,
                         char *why, size_t why_len) {
    memset(out, 0, sizeof *out);
    out->channel_fd = -1;
    g_log = cfg->log_fd;
    if (!cfg->child_path || !cfg->package_root || !cfg->manifest || cfg->manifest_len < 22 ||
        memcmp(cfg->manifest, "sealed-manifest-v2", 18) != 0) {
        fail(why, why_len, "bad bring-up configuration or manifest");
        return -1;
    }
    char target[1100], draft[1100];
    snprintf(target, sizeof target, "%s/target", cfg->package_root);
    snprintf(draft, sizeof draft, "%s/draft", cfg->package_root);

    sealed_child_spec_t spec;
    memset(&spec, 0, sizeof spec);
    memcpy(spec.cdhash, cfg->child_cdhash, SEALED_CDHASH_LEN);
    const char *cargv[7] = { cfg->child_path, "serve-native", target, draft, cfg->max_context, "auto", NULL };
    spec.path = cfg->child_path;
    spec.argv = cargv;
    spec.requirement = cfg->requirement;
    spec.requirement_len = cfg->requirement_len;
    spec.status_suspended = cfg->status_word;
    spec.status_running = cfg->status_word;
    spec.rendezvous_ms = 120000;
    spec.channel_shape = SEALED_CHANNEL_STDIO;

    // A-13 canary, always strict in the engine: the decoy's requirement names
    // the CHILD's hash, so the kernel must refuse the decoy in both shapes.
    sealed_a13_require_canary(1);
    {
        sealed_child_spec_t d = spec;
        const char *dargv[2] = { cfg->decoy_path, NULL };
        d.path = cfg->decoy_path; d.argv = dargv; d.rendezvous_ms = 3000;
        memcpy(d.cdhash, cfg->decoy_cdhash, SEALED_CDHASH_LEN);
        int v = sealed_a13_canary_run(&d);
        say("canary verdict=%d (0 = kernel enforced the launch requirement in both shapes)", v);
        if (v != 0) { fail(why, why_len, "A-13 canary failed (verdict %d)", v); return -1; }
    }

    // R2: the child's rlimits are set here and checked by the child. The
    // engine's own limits are restored right after the spawn.
    struct rlimit old[6];
    int which[6] = { RLIMIT_STACK, RLIMIT_NOFILE, RLIMIT_DATA, RLIMIT_AS, RLIMIT_CPU, RLIMIT_FSIZE };
    struct rlimit want[6] = { { 8372224, 67092480 }, { 1024, 1024 }, { RLIM_INFINITY, RLIM_INFINITY },
                              { RLIM_INFINITY, RLIM_INFINITY }, { RLIM_INFINITY, RLIM_INFINITY }, { RLIM_INFINITY, RLIM_INFINITY } };
    for (int i = 0; i < 6; i++) getrlimit(which[i], &old[i]);
    for (int i = 0; i < 6; i++) {
        if (setrlimit(which[i], &want[i]) != 0) {
            for (int j = 0; j < i; j++) setrlimit(which[j], &old[j]);
            fail(why, why_len, "cannot set the child rlimits (%d)", i);
            return -1;
        }
    }
    sealed_child_t *c = calloc(1, sizeof *c);
    if (!c) { for (int i = 0; i < 6; i++) setrlimit(which[i], &old[i]); fail(why, why_len, "out of memory"); return -1; }
    int rc = sealed_spawn_child(&spec, c);
    for (int i = 5; i >= 0; i--) setrlimit(which[i], &old[i]);
    say("spawn rc=%d pid=%d suspended=0x%08x running=0x%08x", rc, (int)c->pid, c->status_seen_suspended, c->status_seen_running);
    if (rc != SEALED_SPAWN_OK) { fail(why, why_len, "sealed spawn refused, code %d", rc); free(c); return -1; }

    uint8_t want_hash[32];
    {
        CC_SHA256_CTX h; CC_SHA256_Init(&h);
        CC_SHA256_Update(&h, cfg->manifest, 18);
        uint8_t kind[4] = { 0, 0, 0, 2 };
        CC_SHA256_Update(&h, kind, 4);
        CC_SHA256_Update(&h, cfg->manifest + 18, (CC_LONG)(cfg->manifest_len - 18));
        CC_SHA256_Final(want_hash, &h);
    }
    if (place_probes(c->dir) != 0) { fail(why, why_len, "cannot place the self-test probes"); goto refuse; }
    if (send_config(c->channel_fd, cfg->package_root, target, draft, cfg->manifest, cfg->manifest_len, cfg->kv_budget_bytes) != 0) {
        fail(why, why_len, "config frame send failed"); goto refuse;
    }
    uint8_t sb[4];
    if (read_exact(c->channel_fd, sb, sizeof sb, 120000) != 0) { fail(why, why_len, "no sandboxed report (channel closed or timed out)"); goto refuse; }
    if (memcmp(sb, "SLSB", 4) != 0) { fail(why, why_len, "got %02x%02x%02x%02x in place of the sandboxed report", sb[0], sb[1], sb[2], sb[3]); goto refuse; }
    if (recheck(c, spec.cdhash, spec.status_running, "sandboxed") != 0) { fail(why, why_len, "re-check after the sandboxed report failed"); goto refuse; }
    remove_probes(c->dir);
    uint8_t msg[36];
    if (read_exact(c->channel_fd, msg, sizeof msg, 600000) != 0 || memcmp(msg, "SLLD", 4) != 0) { fail(why, why_len, "no loaded report"); goto refuse; }
    if (recheck(c, spec.cdhash, spec.status_running, "loaded") != 0) { fail(why, why_len, "re-check after the loaded report failed"); goto refuse; }
    if (memcmp(msg + 4, want_hash, 32) != 0) { fail(why, why_len, "manifest hash from the child differs from the engine's"); goto refuse; }
    say("child loaded; manifest hash matches the engine's");
    out->channel_fd = c->channel_fd;
    out->pid = c->pid;
    memcpy(out->manifest_hash, want_hash, 32);
    out->child = c;
    return 0;
refuse:
    child_cleanup(c);
    free(c);
    return -1;
}

void sealed_bringup_stop(sealed_bringup_result *r) {
    if (!r || !r->child) return;
    sealed_child_t *c = r->child;
    child_cleanup(c);
    free(c);
    r->child = NULL;
    r->channel_fd = -1;
}

int sealed_bringup_recheck(sealed_bringup_result *r, const uint8_t *cdhash, uint32_t status_word) {
    if (!r || !r->child) return -1;
    return recheck(r->child, cdhash, status_word, "serving");
}

int sealed_bringup_alive(const sealed_bringup_result *r, const uint8_t *cdhash, uint32_t status_word,
                         char *why, size_t why_len) {
    if (!r || !r->child || r->channel_fd < 0) { fail(why, why_len, "liveness: no child"); return -1; }
    const sealed_child_t *c = r->child;
    // 1. Exit status, without a reap: the engine reaps only in
    // sealed_child_kill, so a dead child stays a zombie that holds its pid.
    // A stopped child (CLD_STOPPED) is not dead (rp3-FINDINGS, see sealed_spawn.c).
    siginfo_t si;
    int w;
    do {
        memset(&si, 0, sizeof si);
        w = waitid(P_PID, c->pid, &si, WEXITED | WNOWAIT | WNOHANG);
    } while (w != 0 && errno == EINTR);
    if (w != 0) {
        // ECHILD: already reaped elsewhere. Any other error: fail closed.
        fail(why, why_len, "liveness: waitid errno=%d (child pid %d)", errno, (int)c->pid);
        return -1;
    }
    if (si.si_pid == c->pid &&
        (si.si_code == CLD_EXITED || si.si_code == CLD_KILLED || si.si_code == CLD_DUMPED)) {
        fail(why, why_len, "liveness: child pid %d %s %d", (int)c->pid,
             si.si_code == CLD_EXITED ? "exited with status" : "was killed by signal", si.si_status);
        return -1;
    }
    // 2. The channel: the child's end is gone (measured: a dead peer gives
    // POLLIN|POLLHUP on the engine's end). POLLIN alone is not checked, because
    // a generation can have frames in flight; nothing is read here.
    struct pollfd pf = { r->channel_fd, POLLIN, 0 };
    int pr;
    do { pr = poll(&pf, 1, 0); } while (pr < 0 && errno == EINTR);
    if (pr < 0 || (pf.revents & (POLLHUP | POLLERR | POLLNVAL))) {
        fail(why, why_len, "liveness: channel %s (revents=0x%x errno=%d)", pr < 0 ? "poll failed" : "closed",
             pf.revents, pr < 0 ? errno : 0);
        return -1;
    }
    // 3. Identity through the audit token from the first byte: CD hash and
    // status word. The token carries the pid version, so a reused pid fails.
    if (recheck_q(c, cdhash, status_word, "liveness", 1) != 0) {
        fail(why, why_len, "liveness: identity re-check failed (child pid %d)", (int)c->pid);
        return -1;
    }
    return 0;
}
