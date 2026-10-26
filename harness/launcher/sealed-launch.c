// sealed-launch: stand-in for the sealed engine's spawn step (milestone 1).
//
// The Splash Python server runs this program as its "--binary". It spawns the
// sealed Splash child through the staged spawn module: suspended, launch
// requirement naming the pinned CD hash (A-13), CD hash and status word
// checked before resume, one socketpair end on the child's fd 0 and fd 1, and
// the first byte 'S' plus the peer audit token checked before anything is
// sent. Then it relays bytes: its own stdin -> channel, channel -> its stdout.
//
// Usage (argv is the Splash native command with the binary replaced):
//   sealed-launch serve-native TARGET DRAFT MAX_CONTEXT MAX_MEMORY
// Environment (set by the operator, not by the Python server):
//   SEALED_CHILD     absolute path of the sealed Splash child
//   SEALED_PIN       its CD hash, 40 hex chars
//   SEALED_REQ       launch-requirement bytes file naming SEALED_PIN
//   SEALED_STRICT    1 = require the A-13 canary before spawning (default 1)
//   SEALED_DECOY     a decoy executable for the canary (pinned to a different hash)
//   SEALED_DECOY_PIN its CD hash
//   SEALED_LOG       optional file for the launcher's own log lines
//   SEALED_KV_BUDGET_BYTES  optional chunked-KV budget in bytes, sent in the
//                    v2 config frame; the child refuses values outside its range
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
#include <sys/stat.h>
#include <unistd.h>
#include <CommonCrypto/CommonDigest.h>
#include "sealed_spawn.h"

static FILE *logf;
static void say(const char *fmt, ...) {
    if (!logf) return;
    va_list ap; va_start(ap, fmt); vfprintf(logf, fmt, ap); va_end(ap);
    fputc('\n', logf); fflush(logf);
}

static int hexpin(const char *hex, uint8_t out[SEALED_CDHASH_LEN]) {
    if (!hex || strlen(hex) != 2 * SEALED_CDHASH_LEN) return -1;
    for (int i = 0; i < SEALED_CDHASH_LEN; i++) {
        unsigned v;
        if (sscanf(hex + 2 * i, "%2x", &v) != 1) return -1;
        out[i] = (uint8_t)v;
    }
    return 0;
}

static uint8_t *readfile(const char *path, size_t *len) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0 || st.st_size > (1 << 20)) { close(fd); return NULL; }
    uint8_t *b = malloc((size_t)st.st_size);
    ssize_t n = b ? read(fd, b, (size_t)st.st_size) : -1;
    close(fd);
    if (n != st.st_size) { free(b); return NULL; }
    *len = (size_t)n;
    return b;
}

static int write_all(int fd, const char *p, size_t n) {
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

// Phase re-check at each report (R4 order): the process that holds the audit
// token from the first byte still has the pinned CD hash and status word.
// csops_audittoken fails if that process has exec'd or its pid was reused.
extern int csops_audittoken(pid_t, unsigned int, void *, size_t, audit_token_t *);
#define LAUNCH_CS_OPS_STATUS 0
#define LAUNCH_CS_OPS_CDHASH 5
static int recheck(sealed_child_t *c, const uint8_t pin[SEALED_CDHASH_LEN], uint32_t word, const char *phase) {
    uint8_t h[SEALED_CDHASH_LEN];
    uint32_t st = 0;
    audit_token_t t = c->token;
    if (csops_audittoken(c->pid, LAUNCH_CS_OPS_CDHASH, h, sizeof h, &t) != 0) { say("%s: csops cdhash failed errno=%d", phase, errno); return -1; }
    t = c->token;
    if (csops_audittoken(c->pid, LAUNCH_CS_OPS_STATUS, &st, sizeof st, &t) != 0) { say("%s: csops status failed errno=%d", phase, errno); return -1; }
    say("%s: status=0x%08x cdhash %s", phase, st, memcmp(h, pin, sizeof h) == 0 ? "matches the pin" : "DIFFERS");
    if (memcmp(h, pin, sizeof h) != 0 || sealed_status_ok(st, word) != 0) return -1;
    return 0;
}

// R2 config frame: "SLCF" | u32 version | str package | str target | str draft | u32 len | manifest
// Version 2 adds u64 kv_budget_bytes (chunked KV, review/CHUNKED-KV-2026-10-23.md);
// kv_budget 0 sends version 1 and the child uses its default.
static int send_config(int fd, const char *pkg, const char *target, const char *draft,
                       const uint8_t *m, size_t mlen, uint64_t kv_budget) {
    size_t lp = strlen(pkg), lt = strlen(target), ld = strlen(draft);
    size_t total = 8 + 2 + lp + 2 + lt + 2 + ld + 4 + mlen + (kv_budget ? 8 : 0);
    uint8_t *b = malloc(total), *p = b;
    if (!b) return -1;
    memcpy(p, "SLCF", 4); put32(p + 4, kv_budget ? 2 : 1); p += 8;
    put16(p, (uint16_t)lp); memcpy(p + 2, pkg, lp); p += 2 + lp;
    put16(p, (uint16_t)lt); memcpy(p + 2, target, lt); p += 2 + lt;
    put16(p, (uint16_t)ld); memcpy(p + 2, draft, ld); p += 2 + ld;
    put32(p, (uint32_t)mlen); memcpy(p + 4, m, mlen); p += 4 + mlen;
    if (kv_budget) {
        for (int i = 0; i < 8; i++) p[i] = (uint8_t)(kv_budget >> (56 - 8 * i));
    }
    int rc = write_all(fd, (const char *)b, total);
    free(b);
    return rc;
}

// R5 self-test probes (spec Y2): one file in TMPDIR outside the cache
// directory, one in metal-cache. The child must be denied a read of each.
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

static sealed_child_t child;
static volatile sig_atomic_t stop_requested;
static void on_stop(int sig) { (void)sig; stop_requested = 1; }

int main(int argc, char **argv) {
    const char *lp = getenv("SEALED_LOG");
    if (lp && *lp) logf = fopen(lp, "a");
    if (argc != 6) { fprintf(stderr, "sealed-launch: expected the serve-native argv (5 args)\n"); return 64; }

    const char *exe = getenv("SEALED_CHILD"), *pin_hex = getenv("SEALED_PIN"), *req_path = getenv("SEALED_REQ");
    if (!exe || !pin_hex || !req_path) { fprintf(stderr, "sealed-launch: SEALED_CHILD, SEALED_PIN and SEALED_REQ are required\n"); return 64; }

    // Chunked KV budget (bytes, decimal) for the config frame; unset = child default.
    uint64_t kv_budget = 0;
    const char *kb = getenv("SEALED_KV_BUDGET_BYTES");
    if (kb && *kb) {
        char *end = NULL;
        errno = 0;
        unsigned long long v = strtoull(kb, &end, 10);
        if (errno || !end || *end || kb[0] < '0' || kb[0] > '9' || v == 0) {
            fprintf(stderr, "sealed-launch: SEALED_KV_BUDGET_BYTES must be a positive decimal byte count\n");
            return 64;
        }
        kv_budget = v;
    }
    say("kv budget: %llu (0 = child default)", (unsigned long long)kv_budget);

    sealed_child_spec_t spec;
    memset(&spec, 0, sizeof spec);
    if (hexpin(pin_hex, spec.cdhash) != 0) { fprintf(stderr, "sealed-launch: bad SEALED_PIN\n"); return 64; }
    size_t rlen = 0;
    uint8_t *req = readfile(req_path, &rlen);
    if (!req) { fprintf(stderr, "sealed-launch: cannot read SEALED_REQ\n"); return 64; }

    // argv for the child: its own path, then the serve-native arguments unchanged.
    const char *cargv[7] = { exe, argv[1], argv[2], argv[3], argv[4], argv[5], NULL };
    spec.path = exe;
    spec.argv = cargv;
    spec.requirement = req;
    spec.requirement_len = rlen;
    // Status words pinned for this pair (M5, Mac17,7, macOS 27.2 beta),
    // measured 2026-10-12 on every sealed Splash spawn: 0x22011311 suspended
    // and running. Another pair needs its own measured words.
    spec.status_suspended = 0x22011311u;
    spec.status_running = 0x22011311u;
    spec.rendezvous_ms = 120000; // Splash inspects the model package (argv) before its first byte
    spec.channel_shape = SEALED_CHANNEL_STDIO;

    // R2: the engine sets the child's rlimits; the child checks them.
    {
        struct rlimit st = { 8372224, 67092480 }, nf = { 1024, 1024 },
                      inf = { RLIM_INFINITY, RLIM_INFINITY };
        if (setrlimit(RLIMIT_STACK, &st) != 0 || setrlimit(RLIMIT_NOFILE, &nf) != 0 ||
            setrlimit(RLIMIT_DATA, &inf) != 0 || setrlimit(RLIMIT_AS, &inf) != 0 ||
            setrlimit(RLIMIT_CPU, &inf) != 0 || setrlimit(RLIMIT_FSIZE, &inf) != 0) {
            fprintf(stderr, "sealed-launch: cannot set the child rlimits\n");
            return 70;
        }
    }

    // A-13 canary, strict by default.
    const char *strict = getenv("SEALED_STRICT");
    if (!strict || strcmp(strict, "0") != 0) {
        sealed_a13_require_canary(1);
        const char *decoy = getenv("SEALED_DECOY"), *dpin = getenv("SEALED_DECOY_PIN");
        if (!decoy || !dpin) { fprintf(stderr, "sealed-launch: strict mode needs SEALED_DECOY and SEALED_DECOY_PIN\n"); return 64; }
        sealed_child_spec_t d = spec;
        const char *dargv[2] = { decoy, NULL };
        d.path = decoy; d.argv = dargv; d.rendezvous_ms = 3000;
        if (hexpin(dpin, d.cdhash) != 0) { fprintf(stderr, "sealed-launch: bad SEALED_DECOY_PIN\n"); return 64; }
        // d.requirement still names the CHILD's hash: the kernel must refuse the decoy.
        int v = sealed_a13_canary_run(&d);
        say("canary verdict=%d (0 = kernel enforced the launch requirement in both shapes)", v);
        if (v != 0) { fprintf(stderr, "sealed-launch: A-13 canary failed (verdict %d); refusing to spawn\n", v); return 70; }
    }

    int rc = sealed_spawn_child(&spec, &child);
    say("spawn rc=%d pid=%d suspended=0x%08x running=0x%08x", rc, (int)child.pid,
        child.status_seen_suspended, child.status_seen_running);
    if (rc != SEALED_SPAWN_OK) {
        fprintf(stderr, "sealed-launch: sealed spawn refused, code %d\n", rc);
        return 70;
    }

    // R2/R6: config frame with the manifest the engine read itself (no
    // follow), then wait for the child's "loaded" report and compare its
    // manifest hash with the hash form computed here.
    char pkg[1100];
    snprintf(pkg, sizeof pkg, "%s", argv[2]);
    char *slash = strrchr(pkg, '/');
    if (!slash || strcmp(slash, "/target") != 0) { fprintf(stderr, "sealed-launch: TARGET must end in /target\n"); goto refuse; }
    *slash = '\0';
    {
        char mpath[1200];
        snprintf(mpath, sizeof mpath, "%s/sealed-manifest.bin", pkg);
        size_t mlen = 0;
        uint8_t *m = readfile(mpath, &mlen);
        if (!m || mlen < 22 || memcmp(m, "sealed-manifest-v2", 18) != 0) { fprintf(stderr, "sealed-launch: cannot read the manifest\n"); goto refuse; }
        // Spec Y2: the self-check saw an empty TMPDIR; the probe files for the
        // R5 self-test are placed now, after the first byte, before the frame.
        if (place_probes(child.dir) != 0) { fprintf(stderr, "sealed-launch: cannot place the self-test probes\n"); goto refuse; }
        if (send_config(child.channel_fd, pkg, argv[2], argv[3], m, mlen, kv_budget) != 0) { fprintf(stderr, "sealed-launch: config frame send failed\n"); goto refuse; }
        uint8_t want[32];
        CC_SHA256_CTX c; CC_SHA256_Init(&c);
        CC_SHA256_Update(&c, m, 18);
        uint8_t kind[4] = {0, 0, 0, 2};
        CC_SHA256_Update(&c, kind, 4);
        CC_SHA256_Update(&c, m + 18, (CC_LONG)(mlen - 18));
        CC_SHA256_Final(want, &c);
        // R4 order: "sandboxed" (4 bytes) comes first, then "loaded". Any
        // other byte, or the reports out of order, refuses.
        uint8_t sb[4];
        if (read_exact(child.channel_fd, sb, sizeof sb, 120000) != 0) {
            say("sandboxed report: the channel closed or timed out");
            fprintf(stderr, "sealed-launch: no sandboxed report from the child\n"); goto refuse;
        }
        if (memcmp(sb, "SLSB", 4) != 0) {
            say("sandboxed report: got %02x%02x%02x%02x instead (out of order or not sandboxed)", sb[0], sb[1], sb[2], sb[3]);
            fprintf(stderr, "sealed-launch: no sandboxed report from the child\n"); goto refuse;
        }
        if (recheck(&child, spec.cdhash, spec.status_running, "sandboxed") != 0) {
            fprintf(stderr, "sealed-launch: re-check after the sandboxed report failed\n"); goto refuse;
        }
        // The self-test is done: remove its probes, so metal-cache is empty
        // while the child serves and any entry in it is a Metal write.
        remove_probes(child.dir);
        uint8_t msg[36];
        if (read_exact(child.channel_fd, msg, sizeof msg, 600000) != 0 || memcmp(msg, "SLLD", 4) != 0) {
            fprintf(stderr, "sealed-launch: no loaded report from the child\n"); goto refuse;
        }
        if (recheck(&child, spec.cdhash, spec.status_running, "loaded") != 0) {
            fprintf(stderr, "sealed-launch: re-check after the loaded report failed\n"); goto refuse;
        }
        char hx[65];
        for (int i = 0; i < 32; i++) snprintf(hx + 2 * i, 3, "%02x", msg[4 + i]);
        say("child loaded: manifest_hash=%s", hx);
        if (memcmp(msg + 4, want, 32) != 0) { fprintf(stderr, "sealed-launch: manifest hash mismatch\n"); say("manifest hash MISMATCH"); goto refuse; }
        say("manifest hash matches the engine's");
        free(m);
    }

    struct sigaction sa; memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_stop; sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL); sigaction(SIGHUP, &sa, NULL); sigaction(SIGALRM, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    // Relay: stdin -> channel, channel -> stdout. Ends when either side closes.
    int ch = child.channel_fd;
    char buf[1 << 16];
    struct pollfd p[2] = { { STDIN_FILENO, POLLIN, 0 }, { ch, POLLIN, 0 } };
    int in_open = 1;
    while (!stop_requested) {
        p[0].fd = in_open ? STDIN_FILENO : -1;
        int n = poll(p, 2, 500);
        if (n < 0) { if (errno == EINTR) continue; break; }
        if (n == 0) continue;
        if (in_open && (p[0].revents & (POLLIN | POLLHUP))) {
            ssize_t r = read(STDIN_FILENO, buf, sizeof buf);
            if (r > 0) { if (write_all(ch, buf, (size_t)r) != 0) break; }
            else if (r == 0) { in_open = 0; shutdown(ch, SHUT_WR); }
            else if (errno != EINTR && errno != EAGAIN) break;
        }
        if (p[1].revents & (POLLIN | POLLHUP)) {
            ssize_t r = read(ch, buf, sizeof buf);
            if (r > 0) { if (write_all(STDOUT_FILENO, buf, (size_t)r) != 0) break; }
            else if (r == 0) break;
            else if (errno != EINTR && errno != EAGAIN) break;
        }
        if (p[1].revents & (POLLERR | POLLNVAL)) break;
    }

    say("relay ended (stop=%d); killing the child", (int)stop_requested);
    goto cleanup;
refuse:
    say("refused after spawn; killing the child");
    if (child.channel_fd >= 0) close(child.channel_fd);
    for (int i = 0; i < 3 && child.reaped != 1; i++) sealed_child_kill(&child);
    if (child.dir[0]) { remove_probes(child.dir); char m[300]; snprintf(m, sizeof m, "%s/metal-cache", child.dir); rmdir(m); rmdir(child.dir); }
    return 70;
cleanup:
    close(ch);
    for (int i = 0; i < 3 && child.reaped != 1; i++) sealed_child_kill(&child);
    say("child reaped=%d exception_seen=%d", child.reaped, child.exception_seen);
    if (child.dir[0]) {
        remove_probes(child.dir);
        char m[300]; snprintf(m, sizeof m, "%s/metal-cache", child.dir);
        rmdir(m); rmdir(child.dir);
    }
    return 0;
}
