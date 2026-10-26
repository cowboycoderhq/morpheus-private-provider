// r2neg — spawns the reason-file test child with ONE R2 input wrong per case,
// then (for cases that pass the self-check) sends a config frame and reads the
// child's answer. Prints one line per case: the reason the child wrote, or
// LOADED with the manifest hash, or the first bytes it sent.
//
// usage: r2neg <child> <package dir> <case>
// cases: control extra-fd stdout-not-socket extra-env env-differs dir-mode
//        dir-extra-file cwd blocked-signal ignored-signal argv-form argv-nonc
//        frame-truncated frame-magic frame-roots frame-manifest
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static void put16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = v & 0xff; }
static void put32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

int main(int argc, char **argv) {
    if (argc != 4) return 64;
    const char *exe = argv[1], *pkg = argv[2], *cs = argv[3];
    char target[1100], draft[1100];
    snprintf(target, sizeof target, "%s/target", pkg);
    snprintf(draft, sizeof draft, "%s/draft", pkg);

    char dir[] = "/tmp/r2neg-XXXXXX";
    if (!mkdtemp(dir)) return 70;
    char real[1100]; realpath(dir, real);
    char cache[1200]; snprintf(cache, sizeof cache, "%s/metal-cache", real);
    mkdir(cache, 0700);
    if (!strcmp(cs, "dir-mode")) chmod(real, 0755);
    if (!strcmp(cs, "cache-mode")) chmod(cache, 0755);            // S1c
    if (!strcmp(cs, "cache-symlink")) { rmdir(cache); symlink("/tmp", cache); }   // S1c
    if (!strcmp(cs, "dir-extra-file")) { char f[1200]; snprintf(f, sizeof f, "%s/planted", real); close(open(f, O_CREAT | O_WRONLY, 0600)); }

    int sv[2];
    socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    if (!strcmp(cs, "stdout-not-socket")) {
        posix_spawn_file_actions_adddup2(&fa, sv[1], 0);
        posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
    } else {
        posix_spawn_file_actions_adddup2(&fa, sv[1], 0);
        posix_spawn_file_actions_adddup2(&fa, sv[1], 1);
    }
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    if (!strcmp(cs, "extra-fd")) posix_spawn_file_actions_addopen(&fa, 7, "/dev/null", O_RDONLY, 0);
    if (!strcmp(cs, "high-fd")) posix_spawn_file_actions_addopen(&fa, 300, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addchdir_np(&fa, !strcmp(cs, "cwd") ? "/" : real);

    posix_spawnattr_t at;
    posix_spawnattr_init(&at);
    sigset_t all, mask;
    sigfillset(&all);
    sigemptyset(&mask);
    if (!strcmp(cs, "blocked-signal")) sigaddset(&mask, SIGUSR1);
    posix_spawnattr_setsigdefault(&at, &all);
    posix_spawnattr_setsigmask(&at, &mask);
    short fl = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP;
    posix_spawnattr_setflags(&at, fl);
    if (!strcmp(cs, "ignored-signal")) {
        // SETSIGDEF resets all; leave SIGUSR2 out of the default set so the
        // ignored disposition set below survives exec.
        sigdelset(&all, SIGUSR2);
        posix_spawnattr_setsigdefault(&at, &all);
        signal(SIGUSR2, SIG_IGN);
    }

    char e1[1200], e2[1200];
    snprintf(e1, sizeof e1, "HOME=%s", real);
    snprintf(e2, sizeof e2, "TMPDIR=%s", !strcmp(cs, "env-differs") ? "/tmp" : real);
    char *envp[4] = {e1, e2, NULL, NULL};
    if (!strcmp(cs, "extra-env")) envp[2] = "MTL_DEBUG_LAYER=1";

    char *cargv[7] = {(char *)exe, "serve-native", target, draft, "32768", "auto", NULL};
    if (!strcmp(cs, "argv-form")) cargv[5] = "68719476736";
    char nonc[1200];
    if (!strcmp(cs, "argv-nonc")) { snprintf(nonc, sizeof nonc, "%s/../%s/target", pkg, strrchr(pkg, '/') + 1); cargv[2] = nonc; }

    {
        struct rlimit st = {8372224, 67092480}, nf = {1024, 1024}, inf = {RLIM_INFINITY, RLIM_INFINITY};
        setrlimit(RLIMIT_STACK, &st); setrlimit(RLIMIT_NOFILE, &nf);
        setrlimit(RLIMIT_DATA, &inf); setrlimit(RLIMIT_AS, &inf);
        setrlimit(RLIMIT_CPU, &inf); setrlimit(RLIMIT_FSIZE, &inf);
        if (!strcmp(cs, "rlimit-nofile")) { struct rlimit x = {512, 1024}; setrlimit(RLIMIT_NOFILE, &x); }
    }
    pid_t pid;
    if (posix_spawn(&pid, exe, &fa, &at, cargv, envp) != 0) { printf("[%s] spawn failed\n", cs); return 70; }
    close(sv[1]);
    int ch = sv[0];

    // First byte (only if the self-check passes).
    uint8_t b = 0;
    struct pollfd pf = {ch, POLLIN, 0};
    int got = poll(&pf, 1, 15000) > 0 ? (int)read(ch, &b, 1) : 0;
    char result[512] = "";
    if (got == 1 && b == 'S') {
        if (strcmp(cs, "no-probes")) {
            char pp[1300];
            snprintf(pp, sizeof pp, "%s/r5-probe", real); close(open(pp, O_CREAT | O_WRONLY, 0600));
            snprintf(pp, sizeof pp, "%s/r5-probe", cache); close(open(pp, O_CREAT | O_WRONLY, 0600));
        }
        // Config frame.
        char mpath[1200]; snprintf(mpath, sizeof mpath, "%s/sealed-manifest.bin", pkg);
        FILE *f = fopen(mpath, "rb");
        uint8_t m[70000]; size_t ml = f ? fread(m, 1, sizeof m, f) : 0; if (f) fclose(f);
        if (!strcmp(cs, "frame-manifest")) m[20] ^= 0x7f;   // breaks the entry count
        const char *ft = target, *fd = draft;
        if (!strcmp(cs, "frame-roots")) fd = "/tmp";
        size_t lp = strlen(pkg), lt = strlen(ft), ld = strlen(fd);
        // Chunked KV (2026-10-23): version 2 frames carry a u64 KV budget.
        uint64_t kvb = !strcmp(cs, "frame-kv-budget") ? (512ull << 20)
                     : !strcmp(cs, "frame-kv-budget-low") ? 1000ull : 0;
        uint32_t ver = !strcmp(cs, "frame-version") ? 3 : kvb ? 2 : 1;
        size_t total = 8 + 2 + lp + 2 + lt + 2 + ld + 4 + ml + (kvb ? 8 : 0);
        uint8_t *fr = malloc(total), *p = fr;
        memcpy(p, !strcmp(cs, "frame-magic") ? "XLCF" : "SLCF", 4); put32(p + 4, ver); p += 8;
        put16(p, lp); memcpy(p + 2, pkg, lp); p += 2 + lp;
        put16(p, lt); memcpy(p + 2, ft, lt); p += 2 + lt;
        put16(p, ld); memcpy(p + 2, fd, ld); p += 2 + ld;
        put32(p, ml); memcpy(p + 4, m, ml); p += 4 + ml;
        for (int i = 0; kvb && i < 8; i++) p[i] = (uint8_t)(kvb >> (56 - 8 * i));
        size_t send = !strcmp(cs, "frame-truncated") ? total / 2 : total;
        write(ch, fr, send);
        if (!strcmp(cs, "frame-trailing")) write(ch, "EXTRA", 5);   // N3: bytes after the manifest
        if (!strcmp(cs, "frame-truncated")) shutdown(ch, SHUT_WR);
        // R4 order: "SLSB" (sandboxed), then "SLLD" + 32-byte hash (loaded).
        uint8_t msg[40];
        size_t have = 0;
        // R2NEG_POLL_MS: longer wait between reports (T2 holds the child 60 s twice).
        const char *pe = getenv("R2NEG_POLL_MS");
        int pms = pe && atoi(pe) > 0 ? atoi(pe) : 120000;
        while (have < 40) {
            pf.revents = 0;
            if (poll(&pf, 1, pms) <= 0) { snprintf(result, sizeof result, "timeout after %zu bytes", have); break; }
            ssize_t k = read(ch, msg + have, 40 - have);
            if (k <= 0) break;
            have += (size_t)k;
        }
        if (have == 40 && !memcmp(msg, "SLSB", 4) && !memcmp(msg + 4, "SLLD", 4)) {
            char hx[65]; for (int i = 0; i < 32; i++) snprintf(hx + 2 * i, 3, "%02x", msg[8 + i]);
            snprintf(result, sizeof result, "SANDBOXED then LOADED manifest_hash=%.16s...", hx);
        } else if (have >= 36 && !memcmp(msg, "SLLD", 4)) {
            snprintf(result, sizeof result, "LOADED WITHOUT a sandboxed report (engine refuses)");
        } else if (!result[0]) {
            char hx[80] = ""; for (size_t i = 0; i < have && i < 12; i++) snprintf(hx + 2 * i, 3, "%02x", msg[i]);
            snprintf(result, sizeof result, "first byte S, then %zu bytes: %s", have, hx);
        }
    } else snprintf(result, sizeof result, "no first byte");
    kill(pid, SIGKILL);
    int st; waitpid(pid, &st, 0);
    char cmd[1300]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", real); system(cmd);
    printf("[%s] exit=%d %s\n", cs, WIFEXITED(st) ? WEXITSTATUS(st) : -WTERMSIG(st), result);
    return 0;
}
