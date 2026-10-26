// R2 spawn and channel (v2.28 socketpair: an engine-created AF_UNIX
// socketpair replaces the v2.26 $TMPDIR/rv rendezvous), R3 pinned-code
// checks, and the engine's spawn-time exception-port handler (R1). See
// include/sealed_spawn.h.
// Sources: DESIGN-sealed-backends-v2.28.md R2 (socketpair channel, dup2 spawn
// shape, v2.27 cuts), context/SPEC-R1-R3.md (R1 spawn-time port, R2, R3,
// A-13, A-14), context/EVIDENCE-2026-09-30.md (E1 A-13 SPI, E2 exception
// ports, E3 LOCAL_PEERTOKEN, E4 csops_audittoken, E11 early-death handler
// rule), context/rp3-FINDINGS.md (waitid CLD_STOPPED). libSystem only; the
// private declarations are the ones the probes already use.
#include <sealed_guard.h>
#include <sealed_spawn.h>

#include <bsm/libbsm.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syslimits.h>
#include <sys/un.h>   // SOL_LOCAL / LOCAL_PEERTOKEN live here (was dropped in the socketpair build)
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

_Static_assert((SEALED_GUARD_MASK & SEALED_NULL_MASK) == 0, "guard and null masks overlap");

// Private entry points the SDK does not declare. Their signatures are the
// ones the probes confirmed: amfi_launch_constraint_set_spawnattr by the
// pos/neg matrix (E1, probes/a13spi.c), csops and csops_audittoken by
// probes/peertoken.c and results-round3 (E4). pid_resume is refused with
// EPERM for an unprivileged caller (E1); SIGCONT is the measured resume.
extern int amfi_launch_constraint_set_spawnattr(posix_spawnattr_t *, const void *, size_t);
extern int csops(pid_t, unsigned int, void *, size_t);
extern int csops_audittoken(pid_t, unsigned int, void *, size_t, audit_token_t *);
extern int pid_resume(int);
#include <libproc.h>   // SwiftPM builds C with modules; libproc declares proc_pidinfo with an int flavour

#define CS_OPS_STATUS 0
#define CS_OPS_CDHASH 5

// kern/cs_blobs.h, decoded from the measured status words: a refused child
// reads 0x23000201 where a live suspended child reads 0x22000201 (probes/
// results-round3-2026-09-30.txt). The header omits the name, so it is defined
// here; a KILLED word must never pass, even in record-only mode (measured
// word 0 then still refuses a kernel-killed child).
#define SEALED_CS_KILLED 0x01000000u

// S-5 spike (wave-2026-10-06/code-s5-canary): private proc_info flavor read
// per process on the test Mac (macOS 26.6.2, 2026-10-06 probe runs): the
// struct is 56 bytes and byte offset 16 holds a per-boot, per-process
// uint64 id — 1 for launchd, strictly increasing for every new process;
// ESRCH once the process is gone. Zombie readings are NOT settled yet
// (probe p5 pending; the u2 run read ESRCH for a not-yet-reaped child).
// If a zombie reads ESRCH, a zombie holder classifies GONE; if a later OS
// lets the read succeed, its id distinguishes it — see the entry-kill
// comment.
// The id is the pid "version": a recycled pid never repeats it. Not in the
// SDK header; declared like the other private entry points above.
#define PROC_PIDUNIQIDENTIFIER_SPI 17
#define S5_UNIQINFO_SIZE 56
#define S5_UNIQINFO_ID_OFF 16

#define SPAWN_BEHAVIOR ((exception_behavior_t)(EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES))

// The spawn-time exception message for EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES
// (shape as received by probes/handler.c, S1 arms: id 2405, size 84, no thread
// state, thread and task rights carried as port descriptors).
#define SEALED_EXC_MSG_ID 2405

#pragma pack(push, 4)
typedef struct {
    mach_msg_header_t h;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t thread;
    mach_msg_port_descriptor_t task;
    NDR_record_t ndr;
    exception_type_t exception;
    mach_msg_type_number_t code_count;
    int64_t code[2];
} exc_msg_t;
#pragma pack(pop)
// Mach messages are packed to 4 bytes; without the pack the compiler pads
// `code` to 8 and the size would no longer be the measured 84.
_Static_assert(sizeof(exc_msg_t) == 84, "exception message wire size");

typedef struct {
    mach_msg_header_t h;
    NDR_record_t ndr;
    kern_return_t ret;
} exc_reply_msg_t;

// How long the lifecycle waits for the spawn-port reader to answer a pending
// exception message before falling back to destroying the port, and how long
// the reap loop may run after that fallback. Every stage is bounded so no
// refusal path can block the engine.
#define KILL_GRACE_NS 2000000000ull
#define KILL_REAP_NS 10000000000ull
#define READER_DRAIN_NS 2000000000ull
#define READER_DRAIN_ROUND_MS 200
#define READER_JOIN_NS 2000000000ull

#ifdef SEALED_SPAWN_TEST_HOOKS
// Test seam (see the block at the bottom of this file): the l3 guard arm
// installs this to observe the kill path at the top of its grace loop.
extern void (*sea_test_grace_hook)(void);
#endif

// The lifecycle state the reader thread needs (lifecycle defect 1 fix): a
// module-owned, reference-counted allocation holding the kill-guard mutex
// and the flags the reader's service path touches. The engine's
// sealed_child_t points at it through its opaque `lock` field; the reader
// holds its own pointer to it in its ctx, so the reader's only access to the
// caller's struct is the guarded exception_seen mirror in service_exc_msg
// (off once reaped or dead), never a path to its state.
//
// Reference counting (review round 1, finding 1/2): a life_t is destroyed
// and freed only when its last reference drops. Exactly one reference is
// the struct's (`child->lock` — cleared by life_release); one is taken by
// each in-flight sealed_child_kill call for its whole duration (so a
// concurrent call can never use a life_t another call finished and
// released); one is taken by the reader ctx when the reader is started and
// dropped when the ctx is freed (so a reader leaked on the give-up path
// keeps its life_t alive for as long as it can run — a retry call that
// reaps afterwards therefore cannot free it under the leaked reader).
// On the give-up path the ctx and its life_t are both deliberately
// leaked together — the documented, bounded abnormal-path leak.
typedef struct {
    pthread_mutex_t mu;     // guards this life_t's fields and the caller's
                            // struct fields reached under it (reaped,
                            // exception_seen, pid)
    int reaped;
    int exception_seen;
    pid_t pid;              // written under mu at spawn; the by-value copy
                            // the reader's service path uses
    uint64_t uniq_id;       // S-5: the spawned process's per-boot unique id,
                            // captured at spawn under mu; 0 while unknown
    int uniq_known;         // S-5: the capture above succeeded
    uint8_t cdhash[SEALED_CDHASH_LEN]; // S-5 second check: the pinned CD hash
                                       // of the spawned child (set at spawn)
    int cdhash_known;       // S-5: cdhash above is set
    mach_port_t spawn_port; // the generation's spawn-time port; module-owned
                            // since the cross-family review's B1 fix, so the
                            // kill path never reaches back into the struct
    int refs;               // guarded by life_mu, not by mu
} life_t;

// Guards the `refs` field of every life_t and the `child->lock` field of
// every caller struct (read/clear/hold serialize here). Never held across
// anything slow, and never nested: life_mu, a life_t's own mu and
// readers_mu are always acquired one at a time and released before the
// next is taken, so no lock-order cycle exists.
static pthread_mutex_t life_mu = PTHREAD_MUTEX_INITIALIZER;

// Takes a reference for this caller if the struct's lifecycle state still
// exists (NULL once the lifecycle released it — a finished child).
static life_t *life_hold(sealed_child_t *child) {
    pthread_mutex_lock(&life_mu);
    life_t *life = (life_t *)child->lock;
    if (life != NULL) life->refs++;
    pthread_mutex_unlock(&life_mu);
    return life;
}

// Drops one reference; frees when the last one goes (no thread can be
// using the life_t at that point, by construction of the refs).
static void life_unref(life_t *life) {
    pthread_mutex_lock(&life_mu);
    int left = --life->refs;
    pthread_mutex_unlock(&life_mu);
    if (left == 0) {
        pthread_mutex_destroy(&life->mu);
        free(life);
    }
}

// Drops the struct's reference: clears `child->lock` under life_mu so a
// concurrent hold either sees the state before the clear (and pins the
// life_t with its own reference) or sees NULL. The struct's opaque pointer
// is cleared, so a caller can see the teardown happened (defect 2).
static void life_release(sealed_child_t *child) {
    pthread_mutex_lock(&life_mu);
    life_t *life = (life_t *)child->lock;
    child->lock = NULL;
    pthread_mutex_unlock(&life_mu);
    if (life != NULL) life_unref(life);
}

// The spawn-port reader's context (lifecycle defect 1 fix): the port name
// and the module-owned life_t travel in the ctx, never through the
// sealed_child_t. `dead` is set when the lifecycle stops waiting for the
// reader (reader_wait's give-up path); the caller may free only once
// `reaped == 1` (or `pid <= 0`), and the flag only suppresses — after it
// the reader still services messages (replies, releases carried rights,
// records exception_seen in the life_t) but kills nothing and mirrors
// nothing into the caller's struct. The probe l1_reader_uaf holds exactly
// this line: the reader runs past the give-up bound against a released
// struct and must not touch it.
typedef struct reader_ctx {
    life_t *life;        // module-owned; never NULL while the reader runs
    mach_port_t port;
    sealed_child_t *owner;   // the caller's struct, for the guarded flag mirror
    pthread_t thr;
    atomic_int stop;
    atomic_int done;
    atomic_int dead;     // set when the lifecycle stops waiting for the
                         // reader; the caller may free only once reaped == 1
                         // (or pid <= 0); the flag only suppresses
} reader_ctx_t;

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

// audit_token_t.val[5] is the pid (bsm/libbsm.h); read as a field so the
// module needs no libbsm link.
static pid_t token_pid(const audit_token_t *t) { return (pid_t)t->val[5]; }

// Peeks whether the child is dead without reaping it: the engine does not
// wait on the child during the spawn window, so the pid it verifies is the
// process it spawned (R3). WNOWAIT leaves the child waitable for the later
// reap. ECHILD counts as dead: the engine's own child can only be missing
// from its process table if something else already reaped it (SIGCHLD set to
// SIG_IGN, or another waiter), and without this the kill path's grace and
// reap-window loops mistake "already gone" for "still ours" and run their
// whole budget (the measured 12 s stall, FACTS 8).
// rp3-FINDINGS (measured, probe_waitid_stop, results/c19): macOS does not
// filter waitid by WEXITED here — a SIGSTOP-stopped child reports
// CLD_STOPPED (si_code 5) with WEXITED|WNOWAIT|WNOHANG, and that stop event
// is never consumed by WNOWAIT, so counting any si_pid match as dead made a
// live stopped child read dead (root could force DIED with SIGSTOP on any
// healthy child; availability only). Dead is now only CLD_EXITED, CLD_KILLED
// or CLD_DUMPED.
static int child_dead_unreaped(pid_t pid) {
    siginfo_t si;
    memset(&si, 0, sizeof si);
    si.si_pid = 0;
    if (waitid(P_PID, pid, &si, WEXITED | WNOWAIT | WNOHANG) != 0) return errno == ECHILD;
    if (si.si_pid != (pid_t)pid) return 0;
    return si.si_code == CLD_EXITED || si.si_code == CLD_KILLED || si.si_code == CLD_DUMPED;
}

// ---- S-5: the pre-kill identity gate ---------------------------------------
// Tracked item S5 (cross-family review; lifecycle-fix/TRACKED-S5.md): the
// kill guards on the module's own `reaped` flag alone. When something OTHER
// than the module reaps the child — SIGCHLD set to SIG_IGN (supported, the
// b1_sigign arm) or an engine-wide waitpid(-1) — the flag stays 0 while the
// pid is already recyclable, and the entry SIGKILL can signal an unrelated
// process holding the recycled pid. The gate verifies, immediately before
// every SIGKILL, that the pid still names the spawned process.
//
// Instrument (measured on the test Mac, probes archived in this wave's
// results/): proc_pidinfo flavor 17, a per-boot per-process uint64 at byte
// offset 16 of the 56-byte struct. Chosen over the two alternatives the
// review named because it answers the exact kill-safety question — "is the
// process at this pid the process object I spawned?" — without conflating
// cases: csops_audittoken also refuses after an EXEC (measured E4), which
// would refuse to kill a child that exec'd (still our process, still ours to
// kill — impossible under enforced A-13, but the gate should not widen that
// hole), and a start-time comparison has coarser resolution than a
// kernel-allocated 64-bit counter. The counter never repeats within a boot,
// so a recycled pid always reads a different value; a gone pid reads ESRCH.
// Capture happens at spawn, under the lifecycle mutex where the pid is
// stored; a capture failure records uniq_known = 0 and every later gate
// read then degrades to the committed kill decision (the DESIGN RULE at
// s5_classify) rather than trusting an unverified identity.

// 0 = the pid still names the spawned process (safe to signal); 1 = no
// process at the pid; 2 = a different live process (the recycled-pid shape).
#define S5_OURS 0
#define S5_GONE 1
#define S5_FOREIGN 2

// Returns 0 on success, else the errno-class of the failure: ESRCH for a
// gone pid; EINVAL/ENOMEM/EPERM/EIO for instrument-level failures (a
// private SPI can lose its flavor, change struct size, or be sandboxed).
// errno is captured per call — a short positive read (struct smaller than
// the buffer on a later OS) returns EINVAL without trusting a stale errno.
static int s5_read_uniq(pid_t pid, uint64_t *out) {
    unsigned char buf[S5_UNIQINFO_SIZE];
    errno = 0;
    int n = (int)proc_pidinfo(pid, PROC_PIDUNIQIDENTIFIER_SPI, 0, buf, sizeof buf);
    if (n <= 0) return errno != 0 ? errno : EIO;
    if (n != (int)sizeof buf) return EINVAL;   // struct changed: committed decision
    memcpy(out, buf + S5_UNIQINFO_ID_OFF, sizeof *out);
    return 0;
}

// The classification, in ONE place: the real gate calls it with the read
// result; the test seam calls it with a FORCED errno, so the arm's
// forced-errno legs execute this very code (a mutant that reverts the
// errno rule fails leg B). rc != 0 is an errno; rc == 0 means `now` holds
// the id read from the pid.
static int s5_classify(const life_t *life, int rc, uint64_t now) {
    if (rc != 0) {
        if (rc == ESRCH) return S5_GONE;   // nothing at the pid: skip the doomed signal
        return S5_OURS;                    // instrument unavailable: committed decision
    }
    if (!life->uniq_known) return S5_OURS; // identity never captured: committed decision
    if (now == life->uniq_id) return S5_OURS;
    // The id differs. Before the kill skips its signal, confirm with a second,
    // independent check (cross-family review, SHOULD-FIX 1; verified 2026-10-11
    // as V2): if the process at the pid still carries the pinned CD hash, the id
    // field is not trustworthy on this build (it changed meaning), so the
    // committed decision (signal) applies. Only a readable, different CD hash, or
    // a process with no readable CD hash, confirms FOREIGN. A dead pid (ESRCH)
    // is GONE.
    if (life->cdhash_known && life->pid > 0) {
        uint8_t h[SEALED_CDHASH_LEN];
        errno = 0;
        if (csops(life->pid, CS_OPS_CDHASH, h, sizeof h) == 0) {
            if (memcmp(h, life->cdhash, SEALED_CDHASH_LEN) == 0) return S5_OURS;
        } else if (errno == ESRCH) {
            return S5_GONE;
        }
    }
    return S5_FOREIGN;
}

// Call with life->mu held (proc_pidinfo does not block: it is a bounded

// Call with life->mu held (proc_pidinfo does not block: it is a bounded
// copyin syscall, the same class the loops already hold the mutex across —
// waitid/waitpid WNOHANG and kill).
//
// DESIGN RULE for instrument failure: the gate only ever REFINES the
// committed decision when its instrument works. Any failure degrades to the
// committed decision (signal), so the fix can never leave the module less
// able to kill than before it — a broken instrument restores the shipped
// (pre-fix) kill semantics, including their residual, instead of bricking
// every kill of a live child (a gate that answered GONE on EINVAL/ENOMEM
// would make sealed_child_kill return unreaped forever and would silence
// the reader's fault kill, whose reply-without-kill retry-loops the child).
// A failed CAPTURE therefore never abandons a child either: with
// uniq_known == 0 the gate answers OURS on every later read, i.e. the
// committed decision; FOREIGN requires a capture that SUCCEEDED at spawn
// and a read that now SUCCEEDS with a different id — a true recycle.
static int s5_pid_gate(const life_t *life) {
    uint64_t now = 0;
    int rc = s5_read_uniq(life->pid, &now);
    return s5_classify(life, rc, now);
}

// The lifecycle kill (R1): SIGKILL goes to the pid only while the state says
// the child has not been reaped AND the S-5 gate confirms the pid still
// names the spawned process (a recycled pid is signalled only when the
// instrument fails and the gate degrades to the committed decision — see
// the DESIGN RULE at s5_classify). Used by
// the spawn-port reader and by every kill path in this module. Works on the
// module-owned life_t (lifecycle defect 1 fix): the reader never needs the
// caller's struct for this. `already_dead` (the reader's post-release mode)
// suppresses the kill: the caller that released the struct has finished the
// lifecycle, so the pid is no longer owned and must not be signalled. The
// pid is read from the life_t under its own mutex (no unsynchronized field
// reads anywhere in the reader).
static void kill_if_not_reaped_life(life_t *life, int already_dead) {
    if (life == NULL || already_dead) return;
    pthread_mutex_lock(&life->mu);
    // S-5 gate: signal only while the pid still names the spawned process.
    if (!life->reaped && life->pid > 0 && s5_pid_gate(life) == S5_OURS)
        kill(life->pid, SIGKILL);
    pthread_mutex_unlock(&life->mu);
}

// L07/L08/L56: only the measured exception shape is serviced (id, exact size,
// complex bit, two descriptors, both port descriptors, each carrying a plain
// send right). Everything else the port receives (a sender holding the
// residual send right can mint any message) is discarded without a reply and
// without looking at its body: the overlay fields are only trusted once the
// shape is confirmed, so a sender cannot choose which of the engine's port
// names get deallocated. The disposition test (b2 review D1): service_exc_msg
// releases the two names with mach_port_deallocate, which drops a send right
// but not a receive right, so a well-shaped message carrying a receive right
// would strand that right in the engine; discard_msg destroys it instead.
static int exc_msg_shape_ok(const exc_msg_t *m) {
    if (!(m->h.msgh_bits & MACH_MSGH_BITS_COMPLEX)) return 0;
    if (m->h.msgh_size != sizeof(exc_msg_t)) return 0;
    if (m->h.msgh_id != SEALED_EXC_MSG_ID) return 0;
    if (m->body.msgh_descriptor_count != 2) return 0;
    if (m->thread.type != MACH_MSG_PORT_DESCRIPTOR) return 0;
    if (m->task.type != MACH_MSG_PORT_DESCRIPTOR) return 0;
    if (m->thread.disposition != MACH_MSG_TYPE_PORT_SEND) return 0;
    if (m->task.disposition != MACH_MSG_TYPE_PORT_SEND) return 0;
    return 1;
}

// Destroys a received message that is not serviced: every right and
// out-of-line region it carries is released (mach_msg_destroy), its reply right
// included, and no reply is sent. Measured (b2_reader_shape): destroying such a
// message leaves the receiver's own send right to its port alone.
static void discard_msg(mach_msg_header_t *h) { mach_msg_destroy(h); }

// One exception message serviced per the measured E11 rule (probes/
// results-handler-policy S1/S2 arms): release the thread and task rights the
// message carries without using them; on EXC_CRASH reply KERN_SUCCESS; on any
// other fatal-type exception SIGKILL the child through the lifecycle, then
// reply KERN_SUCCESS. The reply is required: holding the reply right held the
// child unreaped (E11 S1/S2), and replying KERN_FAILURE passes the event on
// to crash reporting. Replying KERN_SUCCESS without the kill retries the
// fault, so the kill is required. It never reads, copies or logs anything
// from the message beyond the exception type that selects the branch.
static void service_exc_msg(reader_ctx_t *ctx, const exc_msg_t *req) {
    (void)mach_port_deallocate(mach_task_self(), req->thread.name);
    (void)mach_port_deallocate(mach_task_self(), req->task.name);
    // Defect 1 fix: the flag and the kill guard live in the module-owned
    // life_t, reached through the ctx, so a reader still draining after the
    // caller released the sealed_child_t touches no freed memory. The struct
    // mirror of the flag is written only while reaped == 0 under the same
    // mutex: the header contract forbids the caller to free the struct while
    // reaped is 0, so that write is always to live memory — and once
    // reaped == 1 (or the caller was told the lifecycle is complete) the
    // engine no longer reads the flag, so the mirror stops there. The
    // spawn-window death checks and the suite's arms read the struct field
    // and keep working; the UAF probe's released struct is never written.
    pthread_mutex_lock(&ctx->life->mu);
    ctx->life->exception_seen = 1;
    // Mirror into the caller's struct only while the struct is contractually
    // alive: not reaped (the header forbids freeing while reaped is 0) and
    // not dead (the lifecycle has stopped waiting for the reader — belt and
    // braces: the !reaped gate alone is what makes the write safe, and the
    // give-up at the first reader_wait can run while reaped is still 0 on
    // the unreapable path, so dead is a second, independent brake; the flag
    // costs nothing and keeps the reader's post-dead behavior uniform).
    // After either, the engine no longer reads the flag.
    if (!ctx->life->reaped && ctx->owner != NULL && !atomic_load(&ctx->dead))
        ctx->owner->exception_seen = 1;
    pthread_mutex_unlock(&ctx->life->mu);
    if (req->exception != EXC_CRASH)
        kill_if_not_reaped_life(ctx->life, atomic_load(&ctx->dead));
    exc_reply_msg_t rep;
    memset(&rep, 0, sizeof rep);
    rep.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    rep.h.msgh_size = sizeof rep;
    rep.h.msgh_remote_port = req->h.msgh_remote_port;
    rep.h.msgh_id = req->h.msgh_id + 100;
    rep.ndr = NDR_record;
    rep.ret = KERN_SUCCESS;
    kern_return_t sr = mach_msg(&rep.h, MACH_SEND_MSG, sizeof rep, 0, MACH_PORT_NULL,
                                MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    // r1-handler F7: a failed reply send leaves the reply's send-once right
    // unconsumed — destroy it or the right leaks per exception message.
    if (sr != KERN_SUCCESS) mach_msg_destroy(&rep.h);
}

// The spawn-port reader: one thread per child generation, started before the
// port is set, distinct from the engine's guard thread (R1). It must be
// running before anything waits to reap: a child killed at spawn while its
// exception message is unanswered is held in exit (measured E1, and the
// 2026-09-30 smoke run), and only the reader's reply or the port's
// destruction releases it. A no-senders notification (simple message) means
// the last send right dropped — the child's guard replaced the port, or the
// child was torn down. The reader does not exit on it: the refused child's
// exception message can be delivered after the notification (teardown drops
// the exception-port right before the message lands), so after a notification
// the reader drains for a bounded time, answering any exception message that
// follows, and only then exits. Otherwise it parks until the lifecycle
// destroys the port.
// The reader's context is the life_t + port block defined at the top of
// this file (lifecycle defect 1 fix): the reader reaches everything through
// its own ctx, so a reader that outlives the caller's sealed_child_t (the
// bounded join can give up while the drain is still open) touches no freed
// memory — its one struct access is the guarded mirror, which is off by
// then; after `dead` it kills nothing either.

static pthread_mutex_t readers_mu = PTHREAD_MUTEX_INITIALIZER;
typedef struct reader_node {
    reader_ctx_t *ctx;
    struct reader_node *next;
} reader_node_t;
static reader_node_t *readers;

// Removes and returns the reader context registered for this lifecycle (NULL
// if none). Keyed on the module-owned life_t: it is the per-generation
// identity both the lifecycle and the reader hold, and it stays valid across
// the caller's free of the sealed_child_t (defect 1).
static reader_ctx_t *reader_take(life_t *life) {
    pthread_mutex_lock(&readers_mu);
    reader_node_t **pp = &readers;
    while (*pp != NULL && (*pp)->ctx->life != life) pp = &(*pp)->next;
    reader_node_t *n = *pp;
    if (n == NULL) {
        pthread_mutex_unlock(&readers_mu);
        return NULL;
    }
    *pp = n->next;
    pthread_mutex_unlock(&readers_mu);
    reader_ctx_t *ctx = n->ctx;
    free(n);
    return ctx;
}

// Bounded wait for the reader to confirm exit. On confirmation the context is
// freed and *ctxp cleared and its life reference dropped — the context is
// the reader's only link to the world, so freeing it while the reader is
// `done` is safe.
// If the bound expires, the detached reader is still finishing: the ctx and
// its life reference are both left in place (a deliberate, bounded leak on
// the abnormal 2 s-overrun path — freeing either would hand the thread a
// dangling pointer), and the ctx is marked `dead`: the lifecycle has stopped
// waiting for the reader. The flag only suppresses — the caller may free
// only once reaped == 1 (or pid <= 0), and until then the struct is live —
// but after `dead` the reader services messages (replies, releases carried
// rights, records the flag in the life_t) without killing anything and
// without mirroring into the caller's struct, so the moment the caller's
// free becomes legal, nothing the reader does can touch freed memory
// (lifecycle defect 1: the old code had no such separation — the reader
// held the struct pointer and could use it after the free).
static void reader_wait(reader_ctx_t **ctxp) {
    reader_ctx_t *ctx = *ctxp;
    if (ctx == NULL) return;
    uint64_t until = now_ns() + READER_JOIN_NS;
    while (atomic_load(&ctx->done) == 0 && now_ns() < until) usleep(10000);
    if (atomic_load(&ctx->done) != 0) {
        life_unref(ctx->life);
        free(ctx);
        *ctxp = NULL;
    } else {
        atomic_store(&ctx->dead, 1);
    }
}

static void *spawn_port_reader(void *arg) {
    reader_ctx_t *ctx = arg;
    union {
        exc_msg_t exc;
        uint8_t raw[4096];
    } msg;
    for (;;) {
        if (atomic_load(&ctx->stop) != 0) break;
        memset(&msg, 0, sizeof msg);
        // Bounded rounds so the reader observes `stop` while parked; a queued
        // exception message is serviced in the round it arrives in.
        kern_return_t kr = mach_msg(&msg.exc.h, MACH_RCV_MSG | MACH_RCV_LARGE | MACH_RCV_TIMEOUT,
                                    0, sizeof msg, ctx->port, READER_DRAIN_ROUND_MS,
                                    MACH_PORT_NULL);
        if (kr == MACH_RCV_TIMED_OUT) continue;
        if (kr != KERN_SUCCESS) break;
        if (exc_msg_shape_ok(&msg.exc)) {
            service_exc_msg(ctx, &msg.exc);
            continue;
        }
        int was_complex = (msg.exc.h.msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0;
        discard_msg(&msg.exc.h);
        if (was_complex) continue;
        // L55: the drain deadline is set once, here, and never moved: a sender
        // holding the residual send right cannot keep the reader alive by
        // streaming messages.
        uint64_t until = now_ns() + READER_DRAIN_NS;
        while (atomic_load(&ctx->stop) == 0 && now_ns() < until) {
            memset(&msg, 0, sizeof msg);
            kr = mach_msg(&msg.exc.h, MACH_RCV_MSG | MACH_RCV_LARGE | MACH_RCV_TIMEOUT,
                          0, sizeof msg, ctx->port, READER_DRAIN_ROUND_MS, MACH_PORT_NULL);
            if (kr == MACH_RCV_TIMED_OUT) continue;
            if (kr != KERN_SUCCESS) break;
            if (exc_msg_shape_ok(&msg.exc)) service_exc_msg(ctx, &msg.exc);
            else discard_msg(&msg.exc.h);
        }
        break;
    }
    atomic_store(&ctx->done, 1);
    return NULL;
}

int sealed_status_ok(uint32_t status, uint32_t measured) {
    if ((status & SEALED_CS_REQUIRED) != SEALED_CS_REQUIRED) return 1;
    if ((status & SEALED_CS_FORBIDDEN) != 0) return 2;
    // L06: a kernel-killed word never passes, record-only (measured == 0) or not.
    if ((status & SEALED_CS_KILLED) != 0) return 2;
    if (measured != 0 && status != measured) return 3;
    return 0;
}

// Takes the spawn port's name out of the module-owned life_t; the caller
// releases the rights exactly once. Since the cross-family review's B1 fix
// the port lives in the life_t, so this touches no caller struct.
static mach_port_t take_spawn_port(life_t *life) {
    if (life == NULL) return MACH_PORT_NULL;
    pthread_mutex_lock(&life->mu);
    mach_port_t p = life->spawn_port;
    life->spawn_port = MACH_PORT_NULL;
    pthread_mutex_unlock(&life->mu);
    return p;
}

// Destroys the engine's rights on a spawn-time port (FACTS 4, measured:
// mach_port_deallocate never destroys a receive right, it only drops a send
// right, so deallocating alone leaks one port name per generation). Any send
// right still held is dropped first, so no dead name is left behind, then the
// receive right is destroyed with mach_port_mod_refs, which also ends a
// reader parked on the port.
static void destroy_spawn_port(mach_port_t p) {
    mach_port_urefs_t sends = 0;
    if (mach_port_get_refs(mach_task_self(), p, MACH_PORT_RIGHT_SEND, &sends) == KERN_SUCCESS)
        while (sends-- > 0) (void)mach_port_deallocate(mach_task_self(), p);
    (void)mach_port_mod_refs(mach_task_self(), p, MACH_PORT_RIGHT_RECEIVE, -1);
}

// Releases the spawn-time port on every teardown path, once (failure-paths F3,
// r2-inheritance F4): destroys the receive right, after dropping a MAKE_SEND
// right still held on pre-spawn failure paths (destroy_spawn_port).
static void release_spawn_port(life_t *life) {
    mach_port_t p = take_spawn_port(life);
    if (MACH_PORT_VALID(p)) destroy_spawn_port(p);
}

// Defect 3 fix, atomic version (cross-family review S2): ownership and the
// liveness peek under ONE lock acquisition, so no thread can reap between
// the check and the waitid. *owned reports whether this thread still owns
// the lifecycle; the return value reports whether the owned child is
// still alive (callers poll while it returns 1). waitid with WNOHANG never
// blocks, so holding the mutex across it is the same pattern the reap
// loop already uses across waitpid(WNOHANG).
static int owned_and_alive(life_t *life, int *owned) {
    pthread_mutex_lock(&life->mu);
    int own = life->pid > 0 && !life->reaped;
    int alive = own && !child_dead_unreaped(life->pid);
    pthread_mutex_unlock(&life->mu);
    if (owned != NULL) *owned = own;
    return alive;
}

// Kills the child if it has not been reaped (so the pid cannot have been
// reused), then reaps it. Order matters: while the child is held in exit
// behind its exception message it is not reapable, so the lifecycle first
// gives the reader its window to answer (the measured release path), and only
// if the child is still not reapable stops the reader, destroys the port (the
// measured fallback) and reaps with a bounded loop. A call on a child that is
// already reaped returns at once (nothing is left to kill, reap or release, and
// its pid may name another process by now). If the child is still not
// reapable after the bounded loop, `reaped` stays 0 and the lifecycle state
// stays valid: the caller must not free the struct, and a later call retries
// the kill and the reap (fast if the child has died since). `reaped` only
// ever goes 0 -> 1.
//
// Lifecycle defect 2 fix: a pid-less child (a spawn failure after the
// lifecycle state exists but before any process did) has nothing to kill or
// reap, so this call completes the lifecycle outright — it performs the
// port/reader teardown it always did, then sets `reaped` (nothing was
// spawned; the flag can never guard a pid that does not exist) and releases
// the module-owned lifecycle allocation. The caller may free the struct
// after one call on such a child; the old code left `reaped` 0 forever, so
// a contract-honoring caller could never free the struct and the mutex
// allocation leaked even for one that did.
//
// Lifecycle defect 3 fix: the grace loop, the reap window and the reap loop
// read the pid and the `reaped` flag under the lifecycle mutex every round
// and stop the moment another thread has completed the lifecycle — the old
// loops polled `child->pid` with no lock and no re-check, so after a
// concurrent reap they handed waitid(P_PID, pid, ...) a pid the engine no
// longer owned, and if the pid was reused by a new child of ours the oracle
// reported that sibling's liveness and the loops rode their whole budget
// (the measured waitid facts: a pid that is not our child returns ECHILD;
// the danger is the reused pid that IS ours).
//
// Every path releases the spawn port's receive right (once) and drains the
// reader with a bound before returning. When the reader confirms exit, the
// module-owned lifecycle allocation is released too (the struct's `lock`
// pointer cleared); when the drain gives up, it is deliberately leaked (see
// reader_wait) — freeing it would hand the still-running reader a dangling
// pointer, which was defect 1.
void sealed_child_kill(sealed_child_t *child) {
    // Cross-family review B1, structural fix: after the entry read below,
    // a call that LOSES touches no caller memory at all — it operates on
    // its pinned life_t reference from end to end. A concurrent call may
    // therefore complete the lifecycle and (once every call on the struct
    // has returned, per the header rule) the caller may free or re-spawn
    // the struct while this call is still finishing; that is safe for
    // THIS call, which reads no struct field after the entry read.
    // The winner is the one exception: it writes the struct twice more,
    // both at its flip (see the flip comment below) — the header rule's
    // "every call returned" half exists precisely because of the winner.
    //
    // Hold the module-owned lifecycle for the whole call (review round 1,
    // findings 1/2): a concurrent call that completes the lifecycle and
    // releases the struct's reference cannot free this life_t while this
    // thread is still using it; the drops below balance this hold. A NULL
    // return means the lifecycle was already completed and released —
    // nothing left to do (the struct's opaque lock pointer is NULL).
    life_t *life = child == NULL ? NULL : life_hold(child);
    if (life == NULL) return;
    // The one guarded struct access of this call's steady state: read the
    // entry state AND send the entry SIGKILL under the life's mutex — the
    // SIGKILL stays inside the lock (L03/R1: the pid cannot have been
    // reaped-and-freed between the read and the signal; the pre-B1 and
    // committed modules both signalled under the lock, and an intermediate
    // version of this fix moved it out — caught by the round's independent
    // verifier and restored). This is legal even though the struct may be
    // freed concurrently once the header rule is satisfied, because this
    // call's own life_hold (taken from this very struct, before the free
    // could become legal) pins the caller's reference, and this call
    // reads no further struct field after this block unless it wins the
    // reap. A call still ENTERING when the caller re-spawns is the other
    // reason the header rule exists: its life_hold could pick up the new
    // generation's half-built state — the rule, not the code, forbids
    // that.
    pthread_mutex_lock(&life->mu);
    int already = life->reaped;
    pid_t pid = life->pid;
    // S-5 gate: verify the pid still names the spawned process immediately
    // before the signal. GONE (nothing at the pid) skips only the doomed
    // signal and keeps the normal flow — the reap loop's waitpid then
    // answers ECHILD (reaped elsewhere) or, if the pid was recycled to a
    // ZOMBIE of another exited engine child (flavor 17 reads ESRCH on any
    // zombie — INFERRED, unmeasured; probe p5 settles it — and a zombie
    // holder classifies as GONE on that reading either way), that waitpid
    // reaps the zombie: the committed module did the same, and the gate
    // does not make it worse — stated residual, engine-wide-reaper
    // configurations only.
    // FOREIGN (a different LIVE process holds the pid) completes the
    // lifecycle below without signalling AND without any wait on that pid.
    int s5gate = S5_OURS;
    if (!already && pid > 0) s5gate = s5_pid_gate(life);
    if (!already && pid > 0 && s5gate == S5_OURS) kill(pid, SIGKILL);
    pthread_mutex_unlock(&life->mu);
    if (already) { life_unref(life); return; }
    reader_ctx_t *ctx = reader_take(life);
    if (pid <= 0 || s5gate == S5_FOREIGN) {
        // Nothing of ours remains at this pid: no process was ever spawned
        // (pid <= 0), or the pid now names a different live process (S-5
        // FOREIGN: reaped elsewhere, then recycled). The teardown is the
        // pid-less one, and the lifecycle completes outright — the flag has
        // no pid of ours left to guard, and no wait ever names that pid.
        if (ctx != NULL) atomic_store(&ctx->stop, 1);
        reader_wait(&ctx);
        release_spawn_port(life);
        // Exactly one caller completes the lifecycle: the one whose store
        // flips life->reaped 0 -> 1 (two concurrent calls on a pid-less
        // struct must not both run the handoff or both drop the struct's
        // reference). The struct's reaped copy is published AT the flip;
        // the lock pointer is cleared under life_mu (the lock a concurrent
        // life_hold reads it under).
        int won = 0;
        pthread_mutex_lock(&life->mu);
        if (!life->reaped) { life->reaped = 1; won = 1; }
        pthread_mutex_unlock(&life->mu);
        if (won) {
            // The pid-less handoff, same order as the reap's (lock first,
            // then the flag — see the reap loop's comment): the struct is
            // freeable after this call returns; nothing module-owned
            // remains.
            pthread_mutex_lock(&life_mu);
            child->lock = NULL;
            pthread_mutex_unlock(&life_mu);
            pthread_mutex_lock(&life->mu);
            child->reaped = 1;
            pthread_mutex_unlock(&life->mu);
            life_unref(life);   // drops the struct's reference
        }
        life_unref(life);   // drops this call's reference
        return;
    }

    // Defect 3 fix (cross-family review S2): ownership and the liveness peek
    // under one lock acquisition each round, so a lifecycle completed
    // concurrently ends the loops at once and no waitid/waitpid ever names
    // a pid this thread does not own — not even within one round.
    uint64_t until = now_ns() + KILL_GRACE_NS;
    int owned = 1, alive = 0;
#ifdef SEALED_SPAWN_TEST_HOOKS
    // Test seam only (the l3_guard arm): a chance to observe this thread
    // inside its grace round before the ownership re-check, so an arm can
    // prove the very next round re-checks ownership instead of waiting on
    // the pid again. NULL in every build that is not the hook arms.
    if (sea_test_grace_hook != NULL) sea_test_grace_hook();
#endif
    while (owned && (alive = owned_and_alive(life, &owned))) {
        if (now_ns() >= until) break;
        usleep(20000);
    }
    if (!owned) {
        ;   // another thread finished the lifecycle: nothing left to wait for
    } else if (alive) {
        // FIXES-2 9: the reader stayed live through the SIGKILL and this
        // grace window, so an exception message arriving in either is
        // answered on the measured answer-first path. Only now is it told to
        // stop (one last round answers anything already queued) and the port
        // destroyed, so the reader is never parked on a destroyed (and
        // potentially reused) port name.
        if (ctx != NULL) atomic_store(&ctx->stop, 1);
        reader_wait(&ctx);
        release_spawn_port(life);
        until = now_ns() + KILL_REAP_NS;
        while (owned && (alive = owned_and_alive(life, &owned)) && now_ns() < until)
            usleep(20000);
    }
    int st;
    int won = 0;
    for (;;) {
        // L03: the reap and the `reaped` store happen under the lifecycle
        // mutex, so no kill can target a pid waitpid has already freed. ECHILD
        // on the engine's own child means it was reaped elsewhere (SIGCHLD
        // ignored, another waiter): reaped = 1 (L01/L02). `reaped` is
        // monotonic: no path stores 0, so a child that stays unreapable
        // (failure-paths F2: still held behind its exception message) keeps
        // the kill guard armed, and L05: a later call retries.
        pthread_mutex_lock(&life->mu);
        // Defect 3, reap loop too: a lifecycle completed by another thread
        // means the pid is no longer ours to wait on — stop before waitpid,
        // or a reused pid naming an exited child of ours would reap that
        // sibling and take its status (review round 1, finding 3).
        if (life->reaped) {
            pthread_mutex_unlock(&life->mu);
            break;
        }
        pid_t w = waitpid(life->pid, &st, WNOHANG);
        int werr = errno;
        // Exactly one caller wins: the one whose store flips life->reaped
        // 0 -> 1. A concurrent call may see the same waitpid result one
        // round later, but the flip is under this mutex so only one caller
        // performs the handoff and drops the struct's reference. The
        // struct's own `reaped` copy is published AT the flip (the
        // committed module published it at the reap too; publishing only
        // after the reader teardown, as an intermediate version did, left a
        // concurrent loser returning while the flag was still 0, so an
        // engine following "repeat while reaped is 0" spun hot for up to
        // the 2 s join bound). Writing child-> here is safe: the caller's
        // reference (pinned by this call) keeps the struct alive, and the
        // engine must still wait for every kill call to return before
        // freeing — the flag only grants the right, it does not end it.
        int won_now = 0;
        if ((w == life->pid || (w < 0 && werr == ECHILD)) && !life->reaped) {
            life->reaped = 1;
            won = 1;
            won_now = 1;
        }
        int reaped_now = life->reaped;
        pthread_mutex_unlock(&life->mu);
        if (won_now) {
            // The winner's final struct accesses happen HERE, immediately
            // after the flip — not after the reader teardown (round-2
            // verification, new finding 1: a later clear left a window in
            // which a rule-breaking engine that re-spawns on seeing
            // reaped == 1 could have its new generation's lock cleared by
            // the old winner's late handoff, permanently disarming the new
            // lifecycle). Order within the handoff (round-3 verification,
            // optional hardening, applied): clear the lock FIRST, then
            // publish child->reaped — so an engine that re-spawns the
            // instant it sees the flag finds the lock pointer already
            // cleared; there is no instant where the flag grants the
            // right while the pointer is still set. No path reads
            // child->reaped for its guard (the guard uses life->reaped),
            // so this order is safe. Clearing under life_mu synchronizes
            // with a concurrent life_hold (hold-or-see-NULL). The
            // winner's own reference keeps the life_t alive for its
            // remaining teardown (reader_wait, port release), which
            // touches no struct.
            pthread_mutex_lock(&life_mu);
            child->lock = NULL;
            pthread_mutex_unlock(&life_mu);
            pthread_mutex_lock(&life->mu);
            child->reaped = 1;
            pthread_mutex_unlock(&life->mu);
        }
        if (reaped_now) break;
        if (w < 0 && werr == EINTR) continue;
        if (w < 0) break;
        if (now_ns() >= until) break;
        usleep(20000);
    }
    // The grace loop can also exit via the child-dead branch, which never set
    // the stop flag; stop the reader here so the wait below stays bounded.
    if (ctx != NULL) atomic_store(&ctx->stop, 1);
    reader_wait(&ctx);
    release_spawn_port(life);
    // The winning reap's handoff already happened at the flip (reaped
    // published, lock cleared); what remains here is dropping the struct's
    // reference, which touches no caller memory. A loser touches nothing:
    // either another call won (whose handoff at ITS flip cleared
    // child->lock and whose reference drop releases the struct's count),
    // or the child is still unreapable (reaped stays 0, the struct's
    // reference stays, and a later call retries through child->lock).
    if (won) {
        life_unref(life);   // drops the struct's reference this call releases
    } else {
        // Either another call won the reap (its flip wrote the struct's
        // last fields and dropped the struct's reference; the caller may
        // still not free this struct until THIS call returns — the header
        // rule), or the child is still unreapable (reaped stays 0, the
        // struct's reference stays, and a later call retries through
        // child->lock, which is why the struct's reference is not dropped
        // here).
    }
    life_unref(life);   // drops this call's own reference
}

// Identity of the per-spawn directory (L40, L14), recorded once right after
// mkdtemp: a descriptor opened O_DIRECTORY|O_NOFOLLOW, and the directory's
// device, inode and owner. Everything the module does inside the directory goes
// through the descriptor (mkdirat, unlinkat, fstatat), so a rename of the
// directory or a different directory planted at its path cannot redirect it;
// the path is only used where the OS offers no descriptor form (bind, the final
// rmdir, the child's chdir) and is checked against the identity first.
typedef struct {
    int fd;
    dev_t dev;
    ino_t ino;
    uid_t uid;
} dir_id_t;

static void dir_id_close(dir_id_t *id) {
    if (id->fd >= 0) close(id->fd);
    id->fd = -1;
}

// Opens `path` (no symlink followed) and records the identity of what was
// opened. Refuses unless it is a directory of the engine's uid with mode 0700
// whose lstat identity equals the opened descriptor's (what mkdtemp creates;
// the window between mkdtemp returning the name and this open cannot be closed
// because mkdtemp offers no descriptor). 0 on success.
static int dir_id_open(dir_id_t *id, const char *path) {
    id->fd = -1;
    struct stat ls, fs;
    if (lstat(path, &ls) != 0 || !S_ISDIR(ls.st_mode)) return -1;
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    if (fstat(fd, &fs) != 0 || !S_ISDIR(fs.st_mode) || fs.st_dev != ls.st_dev ||
        fs.st_ino != ls.st_ino || fs.st_uid != geteuid() || (fs.st_mode & 07777) != 0700) {
        close(fd);
        return -1;
    }
    id->fd = fd;
    id->dev = fs.st_dev;
    id->ino = fs.st_ino;
    id->uid = fs.st_uid;
    return 0;
}

// 1 iff `path` still names the recorded directory: lstat (so a symlink is
// never followed and never matches), a directory, same device and inode, owned
// by the engine's uid.
static int dir_path_is(const dir_id_t *id, const char *path) {
    struct stat st;
    if (id->fd < 0 || lstat(path, &st) != 0) return 0;
    return S_ISDIR(st.st_mode) && st.st_dev == id->dev && st.st_ino == id->ino &&
           st.st_uid == id->uid;
}

// Removes the entry this module created (metal-cache) and then the directory,
// only while the path still names the recorded directory; if it does not,
// nothing is removed (the refusal stays a refusal and a foreign directory is
// left alone). The entry goes by name relative to the descriptor and is never
// followed: metal-cache goes only if it is an empty directory. Any other
// entry is left in place, so a directory that gained extra entries survives
// (L14). Residual: the final rmdir is by path; the identity is checked again
// immediately before it, but a swap between that check and the call can still
// point it at a different directory, which rmdir removes only if it is empty.
static void cleanup_dir(const dir_id_t *id, const char *dir) {
    if (id->fd < 0 || !dir_path_is(id, dir)) return;
    (void)unlinkat(id->fd, "metal-cache", AT_REMOVEDIR);
    if (dir_path_is(id, dir)) (void)rmdir(dir);
}

// Shared failure exit: close the engine's channel end, kill + reap the child
// through the lifecycle, remove the per-spawn directory. `pair_fd` is the
// engine's socketpair end (>= 0 only from the socketpair on; on failure the
// child's end is already closed with the child — a child that did run holds
// its own end on 0/1 or 3 by design, and its death closes it; a child that
// never exec'd held it only in the pre-exec copy, closed with it, and
// CLOEXEC_DEFAULT kept it from holding the engine's end).
static int spawn_fail(sealed_child_t *child, dir_id_t *id, int pair_fd, int code) {
    // Every caller has already closed the parent's copy of the child end
    // (pre-spawn paths before calling, post-spawn paths right after
    // posix_spawn), so pair_fd is the engine's only channel descriptor;
    // closing it gives a live child EOF.
    if (pair_fd >= 0) close(pair_fd);
    sealed_child_kill(child);
    if (child->dir[0]) cleanup_dir(id, child->dir);
    dir_id_close(id);
    return code;
}

// Cross-family review S3: every failure return of sealed_spawn_child before a
// child process existed ends with reaped == 1 — uniformly, whatever the
// internal state. Nothing was spawned, so the flag has no pid to guard, and
// the header's one free rule (`reaped == 1`) holds on every failure path. An
// engine that follows the committed retry text ("repeat the kill only while
// reaped is 0") therefore terminates on every path; before this, the
// validation and direct DIR returns left reaped 0 forever and such a loop
// spun (the kill is a no-op once `lock` is NULL).
static int fail_unspawned(sealed_child_t *child, int code) {
    child->reaped = 1;   // monotonic by construction: nothing else ran
    return code;
}

// ---- R2-T4(m) canary gate (staged spike, wave-2026-10-06/code-s5-canary) ---
// A per-spawn CS_KILLED check observes the kernel's A-13 refusal but cannot
// detect a pair where A-13 has regressed (socketpair-fix REPORT §5.2, review
// C1). The canary measures the enforcement itself: spawn a decoy image under
// a launch requirement naming a WRONG CD hash, in BOTH dup2 channel shapes;
// enforcement is confirmed only when the kernel refuses the decoy pre-resume
// (STATUS + CS_KILLED, decoy never ran). Any other outcome marks the pair
// unproven and every later sealed_spawn_child refuses: fail closed
// (SEALED_SPAWN_REQUIREMENT — the launch requirement cannot be trusted on
// this pair), before any directory or process is created.

// The canary's verdict, per process — the SEALED_A13_* constants in
// include/sealed_spawn.h. UNTESTED until the first run completes; ENFORCED
// when every leg confirmed the kernel's refusal; FAILED otherwise
// (sealed_spawn_child then refuses, fail closed).

static atomic_int a13_canary_state = SEALED_A13_UNTESTED;
static atomic_int a13_canary_running = 0;   // re-entry guard for the run itself

// Seeded test-build mode: ONLY the test seam below writes this. When set,
// the canary's decoy legs skip attaching the launch requirement — the
// measured stand-in for "A-13 not enforced": the kernel admits the decoy
// and it runs. Production code never sets it.
#ifdef SEALED_SPAWN_TEST_HOOKS
static atomic_int a13_canary_unenforced = 0;
#endif

// The skip is applied PER THREAD (not process-global): the canary's own leg
// spawns on THIS thread skip the attach; any other spawn — including a
// concurrent one on another thread — attaches normally. Nothing else may
// set the flag, and the canary clears it around each leg.
static _Thread_local int s5_spawn_skips_requirement;
static _Thread_local int s5_in_canary_leg;   // the canary's own decoy spawn
static atomic_int a13_require_canary = 0; // strict mode, see sealed_a13_require_canary

int sealed_a13_children_allowed(void) {
    int st = atomic_load(&a13_canary_state);
    if (st == SEALED_A13_FAILED) return 0;
    if (atomic_load(&a13_require_canary) && st != SEALED_A13_ENFORCED &&
        !s5_in_canary_leg)
        return 0;
    return 1;
}

// Query for engines that enforce their own must-canary-first contract:
// returns SEALED_A13_UNTESTED / _ENFORCED / _FAILED. UNTESTED means this
// process has no A-13 measurement yet — the gate is open, and an engine
// that promised to canary first can refuse here.
int sealed_a13_canary_verdict(void) {
    return atomic_load(&a13_canary_state);
}

// Strict mode (cross-family review, SHOULD-FIX 2; verified 2026-10-11 as V3):
// once set, sealed spawns are refused until the canary has run and confirmed
// enforcement (state ENFORCED). The canary's own decoy legs pass through
// while it runs. The production engine sets this at start, before its first
// spawn; it cannot be cleared again in a process. Returns the previous value.
int sealed_a13_require_canary(int on) {
    if (!on) return atomic_load(&a13_require_canary);
    return atomic_exchange(&a13_require_canary, 1);
}

#ifdef SEALED_SPAWN_TEST_HOOKS
// Test seam (test-hook builds only): switches the canary's decoy legs into the
// seeded, requirement-less mode described above. Returns the previous mode.
int sealed_test_a13_canary_unenforced(int on) {
    // 0 = off, 1 = every leg; 0x10 | (1 << leg) = one leg only (the
    // one-shape regression model, verified as V4).
    int v = on == 0 ? 0 : ((on & 0x10) ? on : 1);
    return atomic_exchange(&a13_canary_unenforced, v);
}
#endif

// Runs the decoy once per channel shape (STDIO, then FD3 — the two dup2
// shapes the design gates on). Each leg spawns the decoy suspended through
// the module's own spawn path, so the measurement uses the engine's exact
// spawn shape. Enforcement is CONFIRMED only when the kernel refused the
// decoy pre-resume (SEALED_SPAWN_STATUS with CS_KILLED in the suspended
// word, the decoy never verified): then the module allows sealed children.
// A leg where the decoy was ADMITTED (OK — it verified and is serving: kill
// it at once) or any other refusal shape marks the pair unproven:
// sealed_spawn_child then refuses (fail closed) for the rest of this
// process. A failed verdict is not re-runnable in process: this call
// returns SEALED_A13_RUN_BUSY when the state is FAILED or a run is already
// in progress — restart is the only re-measurement (header). A successful
// verdict may be re-run (refresh); the newest verdict wins.
// Returns SEALED_A13_RUN_ENFORCED (0) / _ADMITTED (1) / _INCONCLUSIVE (2) /
// _BUSY (3); -1 bad arguments.
int sealed_a13_canary_run(const sealed_child_spec_t *decoy) {
    if (decoy == NULL || decoy->path == NULL || decoy->argv == NULL ||
        decoy->requirement == NULL || decoy->requirement_len == 0)
        return -1;
    if (atomic_load(&a13_canary_state) == SEALED_A13_FAILED) return SEALED_A13_RUN_BUSY;
    if (atomic_exchange(&a13_canary_running, 1) != 0) return SEALED_A13_RUN_BUSY;
    static const int shapes[2] = { SEALED_CHANNEL_STDIO, SEALED_CHANNEL_FD3 };
    int verdict = 0;
    for (int i = 0; i < 2; i++) {
        sealed_child_spec_t leg = *decoy;
        leg.channel_shape = shapes[i];
        sealed_child_t ch;
        memset(&ch, 0, sizeof ch);
        ch.channel_fd = -1;
#ifdef SEALED_SPAWN_TEST_HOOKS
        {
            // Seeded mode value: 1 = both legs unenforced (all shapes); a
            // value with bit 0x10 set = a per-shape mask: 0x10 | (1 << i)
            // unenforces leg i only (0x12 = the FD3 leg only).
            int sm = atomic_load(&a13_canary_unenforced);
            s5_spawn_skips_requirement = sm == 1 || ((sm & 0x10) && (sm & (1 << i)));
        }
#endif
        s5_in_canary_leg = 1;
        int rc = sealed_spawn_child(&leg, &ch);
        s5_in_canary_leg = 0;
        s5_spawn_skips_requirement = 0;
        uint32_t word = ch.status_seen_suspended;
        int enforced = rc == SEALED_SPAWN_STATUS && (word & SEALED_CS_KILLED) != 0;
        if (!enforced) {
            if (rc == SEALED_SPAWN_OK) {
                // The decoy was admitted and verified: it is running pinned
                // shape code under a requirement that should have refused
                // it. Kill it now (retry while unreapable, per the kill
                // contract); the verdict is already failed.
                if (ch.channel_fd >= 0) close(ch.channel_fd);
                sealed_child_kill(&ch);
                for (int retry = 0; retry < 2 && ch.reaped != 1; retry++)
                    sealed_child_kill(&ch);
                // The engine's duty after a generation (header contract):
                // remove the child's directory. The canary is the engine
                // here (cross-family review SHOULD-FIX 4; verified as V5).
                if (ch.reaped == 1 && ch.dir[0]) {
                    dir_id_t did = {.fd = -1};
                    if (dir_id_open(&did, ch.dir) == 0) {
                        cleanup_dir(&did, ch.dir);
                        dir_id_close(&did);
                    }
                }
                verdict = 1;
            } else if (verdict == 0) {
                verdict = 2;
            }
        }
    }
    atomic_store(&a13_canary_state,
                 verdict == 0 ? SEALED_A13_ENFORCED : SEALED_A13_FAILED);
    atomic_store(&a13_canary_running, 0);
    return verdict;
}

int sealed_spawn_child(const sealed_child_spec_t *spec, sealed_child_t *child) {
    memset(child, 0, sizeof *child);
    dir_id_t did = {.fd = -1};
    child->channel_fd = -1;
    child->spawn_port = MACH_PORT_NULL;
    if (spec == NULL || spec->path == NULL || spec->argv == NULL || spec->argv[0] == NULL)
        return fail_unspawned(child, SEALED_SPAWN_ATTR);
    // The spawn chdirs the child into its fresh directory before exec, so a
    // relative executable path would resolve in the wrong directory (and R2
    // requires absolute, canonical paths): refuse anything not absolute.
    if (spec->path[0] != '/') return fail_unspawned(child, SEALED_SPAWN_ATTR);
    // The channel shape is a required field with no zero value (review M4):
    // refusing it here — before any directory is created — keeps a zeroed or
    // stale spec from silently taking the Splash stdio shape, which would
    // fail far away from the call site (an mlx-serve child missing the field
    // gets fd 0/1 as its channel and reports DIED/113 through its own
    // self-check, a misleading code for an engine bug).
    if (spec->channel_shape != SEALED_CHANNEL_STDIO && spec->channel_shape != SEALED_CHANNEL_FD3)
        return fail_unspawned(child, SEALED_SPAWN_ATTR);
    if (spec->requirement == NULL || spec->requirement_len == 0)
        return fail_unspawned(child, SEALED_SPAWN_REQUIREMENT);
    // R2-T4(m) canary gate: once the A-13 canary has failed on this pair,
    // every sealed spawn refuses before anything is created (no directory,
    // no port, no process). Fail closed — REQUIREMENT is the honest code:
    // the launch requirement cannot be trusted on this pair. The canary's
    // own first run happens while the state is UNTESTED and passes here.
    if (!sealed_a13_children_allowed())
        return fail_unspawned(child, SEALED_SPAWN_REQUIREMENT);

    // The module-owned lifecycle state (defect 1 fix): the mutex and the
    // reader-serviced flags live here, not in the caller's struct. The struct
    // carries it as its opaque `lock` pointer; the reader gets its own
    // pointer through its ctx.
    life_t *life = malloc(sizeof *life);
    if (life == NULL || pthread_mutex_init(&life->mu, NULL) != 0) {
        free(life);
        return fail_unspawned(child, SEALED_SPAWN_PORT);
    }
    life->reaped = 0;
    life->exception_seen = 0;
    life->pid = 0;
    life->uniq_id = 0;      // S-5: identity unknown until captured at pid-set
    life->uniq_known = 0;
    life->cdhash_known = 0;
    life->spawn_port = MACH_PORT_NULL;
    life->refs = 1;   // the struct's reference (cleared by life_release)
    child->lock = life;

    // R2: one fresh empty 0700 directory per spawn, created exclusively
    // (mkdtemp); a collision fails the spawn.
    // Defect 2: every failure return below this point has a live lifecycle
    // allocation behind child->lock. The direct returns release it before
    // returning (nothing was spawned; the header's free-at-once rule for a
    // pid-less failure holds on every path), and the later failures route
    // through spawn_fail, whose sealed_child_kill completes the same way.
    char base[PATH_MAX];
    size_t blen = confstr(_CS_DARWIN_USER_TEMP_DIR, base, sizeof base);
    if (blen == 0 || blen > sizeof base) { life_release(child); return fail_unspawned(child, SEALED_SPAWN_DIR); }
    if (blen > 1 && base[blen - 2] != '/') {
        if (blen + 1 > sizeof base) { life_release(child); return fail_unspawned(child, SEALED_SPAWN_DIR); }
        base[blen - 1] = '/';
        base[blen] = '\0';
    }
    char dirtpl[256];
    if (snprintf(dirtpl, sizeof dirtpl, "%ssealed-child-XXXXXXXX", base) >= (int)sizeof dirtpl) {
        life_release(child);
        return fail_unspawned(child, SEALED_SPAWN_DIR);
    }
    if (mkdtemp(dirtpl) == NULL) { life_release(child); return fail_unspawned(child, SEALED_SPAWN_DIR); }
    // L40/L14: pin the directory's identity now; nothing is removed that was
    // not verified against it (a directory that cannot be pinned is left).
    if (dir_id_open(&did, dirtpl) != 0) { life_release(child); return fail_unspawned(child, SEALED_SPAWN_DIR); }
    // R2 wants canonical paths (r2r3-identity D1): the kernel resolves the
    // chdir target to the /private/var/... form, so realpath the directory
    // once and use that everywhere (dir, HOME/TMPDIR env).
    char canon[PATH_MAX];
    if (realpath(dirtpl, canon) == NULL) {
        cleanup_dir(&did, dirtpl);
        dir_id_close(&did);
        life_release(child);
        return fail_unspawned(child, SEALED_SPAWN_DIR);
    }
    if (snprintf(child->dir, sizeof child->dir, "%s", canon) >= (int)sizeof child->dir) {
        cleanup_dir(&did, canon);
        dir_id_close(&did);
        life_release(child);
        return fail_unspawned(child, SEALED_SPAWN_DIR);
    }
    const char *dir = child->dir;
    // The canonical path must still name the pinned directory (a rename plus
    // a planted symlink between mkdtemp and realpath would not).
    if (!dir_path_is(&did, dir)) return spawn_fail(child, &did, -1, SEALED_SPAWN_DIR);

    if (mkdirat(did.fd, "metal-cache", 0700) != 0)
        return spawn_fail(child, &did, -1, SEALED_SPAWN_DIR);

    // R2 channel (v2.28): the engine creates an AF_UNIX socketpair before
    // spawn and passes the child's end at spawn on the channel's fixed
    // descriptors; its own end stays unnamed and unshared. There is no
    // listener in the directory, nothing to connect to, accept, time out or
    // unlink: the channel's peer is fixed by construction, and root cannot
    // duplicate either end out of a hardened process (A-1) or reach the
    // engine's unnamed end. The engine never sends on the channel before
    // verification (so it never sends to a rogue image: the child's end
    // exists only inside the spawned process; a child the kernel refused at
    // exec under A-13 never runs user code — whether it holds the end until
    // it is killed is unmeasured (file actions likely run before image
    // activation), and the engine sends it nothing either way).
    int chan[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, chan) != 0)
        return spawn_fail(child, &did, -1, SEALED_SPAWN_DIR);
    // Both ends must carry FD_CLOEXEC for their whole life in the engine
    // (review M1): macOS socketpair has no SOCK_CLOEXEC, and F_DUPFD clears
    // FD_CLOEXEC, so set the flag explicitly. POSIX_SPAWN_CLOEXEC_DEFAULT
    // only protects spawns made by this module — any other exec path in the
    // engine process (system, popen, a fork+exec on any thread) would
    // otherwise inherit both ends: an inherited child_end can send the first
    // byte (refusing healthy spawns) and read the consumer stream; an
    // inherited engine_end can read the child's output and pose as the
    // engine. An end that is not moved has a few instructions between
    // socketpair() and F_SETFD where a concurrent fork can still inherit it;
    // macOS has no atomic form, and the operator should confirm the engine
    // has no exec path outside this module regardless.
    // The move threshold is 4, not 3: the file actions open /dev/null onto
    // fds 0-2 and then dup2 the child end onto 0/1 (or 3), so a source at or
    // below any dup2 target must move — and once the source carries
    // FD_CLOEXEC, a same-descriptor adddup2(3, 3) in the FD3 shape would
    // leave the child's fd 3 close-on-exec if XNU does not clear the flag in
    // its no-op path (an ordinary dup2 clears it on the target, but a
    // same-fd dup2 skips the work entirely). Keeping every source above all
    // targets (0, 1, 3) removes the case and also the clobber-by-addopen
    // case (review finding 1: an addopen onto fd n replaces whatever is at
    // n in the child before the dup2 reads it).
    for (int i = 0; i < 2; i++) {
        int fd = chan[i] < 4 ? fcntl(chan[i], F_DUPFD_CLOEXEC, 4) : chan[i];
        if (fd < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) {
            if (fd >= 0 && fd != chan[i]) close(fd);
            close(chan[0]); close(chan[1]);
            return spawn_fail(child, &did, -1, SEALED_SPAWN_DIR);
        }
        if (fd != chan[i]) { close(chan[i]); chan[i] = fd; }
    }
    int engine_end = chan[0], child_end = chan[1];
    // A write to the engine's end after the child dies must fail with EPIPE,
    // not SIGPIPE (review M4): a child killed right after OK would otherwise
    // kill the engine on its first channel write.
    int one = 1;
    (void)setsockopt(engine_end, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);

    // R1 spawn-time port: one receive right per child generation, with a
    // no-senders request so the reader learns when the last send right drops.
    mach_port_t port;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) {
        close(child_end);
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_PORT);
    }
    // FIXES-2 4a, measured (impl/NOTES.md): a no-senders notification
    // registered on a senderless port is delivered immediately (msgh_id 70),
    // which would end the reader before the child even spawns; a held MAKE_SEND
    // right suppresses it. Insert the send right first, register after. The
    // send right is deallocated as soon as the spawn call returns (R1),
    // leaving the child (through the kernel) the only sender. The early
    // failure exits below destroy the receive right (destroy_spawn_port, L16).
    if (mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) !=
        KERN_SUCCESS) {
        destroy_spawn_port(port);
        close(child_end);
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_PORT);
    }
    mach_port_name_t previous = MACH_PORT_NULL;
    kern_return_t kr = mach_port_request_notification(mach_task_self(), port,
                                                      MACH_NOTIFY_NO_SENDERS, 0, port,
                                                      MACH_MSG_TYPE_MAKE_SEND_ONCE,
                                                      &previous);
    if (kr != KERN_SUCCESS) {
        destroy_spawn_port(port);
        close(child_end);
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_PORT);
    }
    if (MACH_PORT_VALID(previous)) mach_port_deallocate(mach_task_self(), previous);
    // B1: the port lives in the module-owned life_t. The struct's field
    // stays (ABI unchanged) and stays NULL — the engine was never documented
    // to read it.
    pthread_mutex_lock(&life->mu);
    life->spawn_port = port;
    pthread_mutex_unlock(&life->mu);
    reader_ctx_t *ctx = malloc(sizeof *ctx);
    if (ctx == NULL) {
        close(child_end);
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_PORT);
    }
    // The ctx holds a life reference from here until it is freed (or leaked
    // with its reader on the give-up path), so the reader can always reach a
    // valid life_t no matter which lifecycle call finishes first (review
    // round 1, findings 1/2).
    ctx->life = life;
    pthread_mutex_lock(&life_mu);
    life->refs++;   // the ctx's own reference (the struct's and each kill call's are separate)
    pthread_mutex_unlock(&life_mu);
    ctx->port = port;
    ctx->owner = child;   // the guarded mirror target (see service_exc_msg)
    atomic_store(&ctx->stop, 0);
    atomic_store(&ctx->done, 0);
    atomic_store(&ctx->dead, 0);
    reader_node_t *node = malloc(sizeof *node);
    if (node == NULL) {
        life_unref(ctx->life);
        free(ctx);
        close(child_end);
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_PORT);
    }
    node->ctx = ctx;
    pthread_mutex_lock(&readers_mu);
    node->next = readers;
    readers = node;
    pthread_mutex_unlock(&readers_mu);
    if (pthread_create(&ctx->thr, NULL, spawn_port_reader, ctx) != 0) {
        // reader_take returns this same ctx (the registry node is freed
        // inside); drop the ctx's one reference and free it. (The else is
        // defensive only: it is reachable just if a kill ran concurrently
        // with this in-progress spawn, which the contract does not allow.)
        reader_ctx_t *gone = reader_take(life);
        if (gone != NULL) {
            life_unref(gone->life);
            free(gone);
        } else {
            life_unref(ctx->life);
            free(ctx);
        }
        close(child_end);
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_PORT);
    }
    pthread_detach(ctx->thr);

    // R2 spawn attributes: cloexec default, start suspended, own process
    // group, all signals default, empty mask.
    posix_spawnattr_t attr;
    posix_spawnattr_t *ap = &attr;
    if (posix_spawnattr_init(ap) != 0) {
        close(child_end);
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_ATTR);
    }
    int failed = 0;
    // Failing stage -> result code (FIXES 1-2): only the requirement attach and
    // the spawn call itself have their own codes; everything else is ATTR.
    int failed_code = 0;
    if (!failed) {
        short flags = (short)(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_START_SUSPENDED |
                              POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF |
                              POSIX_SPAWN_SETSIGMASK);
        sigset_t all, empty;
        failed = posix_spawnattr_setflags(ap, flags) != 0 ||
                 posix_spawnattr_setpgroup(ap, 0) != 0 || sigfillset(&all) != 0 ||
                 sigemptyset(&empty) != 0 || posix_spawnattr_setsigdefault(ap, &all) != 0 ||
                 posix_spawnattr_setsigmask(ap, &empty) != 0;
    }
    // R1: the child's exception ports are set explicitly for the same two
    // masks the guard sets — the spawn-time port on the guard mask, no port
    // on the null mask — so nothing inherited reaches the child (E2: a
    // spawned task inherits its parent's task ports for every unset type).
    // One call per mask.
    if (!failed &&
        posix_spawnattr_setexceptionports_np(ap, SEALED_GUARD_MASK, port, SPAWN_BEHAVIOR,
                                             THREAD_STATE_NONE) != 0)
        failed = 1;
    if (!failed &&
        posix_spawnattr_setexceptionports_np(ap, SEALED_NULL_MASK, MACH_PORT_NULL,
                                             EXCEPTION_DEFAULT, THREAD_STATE_NONE) != 0)
        failed = 1;
    // A-13: the kernel-enforced launch code requirement naming the pinned CD
    // hash, attached with the undeclared libxpc SPI (E1; 82-byte
    // NSTask.launchRequirementData encoding). Failing to attach is fatal
    // (A-14): without it there is no v2 sealed serving.
    // R2-T4(m) canary seam (test builds only): the canary's OWN decoy legs,
    // in the seeded mode only, skip the attach — the measured stand-in for a
    // pair where A-13 is not enforced. The skip flag is thread-local and is
    // set by nothing but the canary's leg loop, so no other spawn — on this
    // or any other thread — ever loses the requirement.
    if (!failed && !s5_spawn_skips_requirement &&
        amfi_launch_constraint_set_spawnattr(ap, spec->requirement,
                                             spec->requirement_len) != 0)
        failed = 1, failed_code = SEALED_SPAWN_REQUIREMENT;

    // R2: fd 0-2 on /dev/null, working directory TMPDIR; with
    // POSIX_SPAWN_CLOEXEC_DEFAULT everything else is closed. The channel's
    // child end is then duplicated onto the channel's fixed descriptors by
    // dup2 file actions, replacing the /dev/null descriptors there — the
    // v2.27/v2.28 socketpair spawn shape (design R2): Splash's stdio shape
    // (one socket on both fd 0 and fd 1) or mlx-serve's fd-3 shape (the
    // socket on fd 3, fds 0-2 on /dev/null). dup2 actions are executed in
    // the child before exec, in order, so fd 0/1/2 exist (the /dev/null
    // opens) before the dup2s replace them; dup2 does not consume its
    // source, so child_end is still open in the child as the source of the
    // second dup2 (STDIO shape), stays open until exec, and is then closed
    // by CLOEXEC_DEFAULT (the dup2 targets carry no close-on-exec — the
    // targets are 0/1/3, all below the moved sources). No other descriptor
    // is inherited.
    posix_spawn_file_actions_t fa;
    // r1-handler F: `fa` is only initialized here when nothing failed before;
    // destroying an uninitialized (stack-garbage) file-actions object is UB.
    int fa_init = 0;
    if (!failed) {
        if (posix_spawn_file_actions_init(&fa) != 0) failed = 1;
        else fa_init = 1;
    }
    if (!failed) {
        failed = posix_spawn_file_actions_addchdir(&fa, dir) != 0 ||
                 posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0) != 0 ||
                 posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0) != 0 ||
                 posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0) != 0;
        // The dup2s: STDIO shape places the end on both fd 0 and fd 1
        // (replacing those /dev/null opens); the FD3 shape leaves fds 0-2
        // on /dev/null and places the end on fd 3.
        if (!failed && spec->channel_shape == SEALED_CHANNEL_STDIO)
            failed = posix_spawn_file_actions_adddup2(&fa, child_end, 0) != 0 ||
                     posix_spawn_file_actions_adddup2(&fa, child_end, 1) != 0;
        else if (!failed)
            failed = posix_spawn_file_actions_adddup2(&fa, child_end, 3) != 0;
    }

    // R2: environment exactly HOME and TMPDIR (no contingency variable is in
    // force on this build); argv the sealed form.
    char envbuf[2][300];
    char *envp[3] = {envbuf[0], envbuf[1], NULL};
    if (!failed &&
        (snprintf(envbuf[0], sizeof envbuf[0], "HOME=%s", dir) >= (int)sizeof envbuf[0] ||
         snprintf(envbuf[1], sizeof envbuf[1], "TMPDIR=%s", dir) >= (int)sizeof envbuf[1]))
        failed = 1;

    pid_t pid = -1;
    if (!failed && posix_spawn(&pid, spec->path, &fa, ap, (char *const *)spec->argv, envp) != 0)
        failed = 1, failed_code = SEALED_SPAWN_EXEC;

    if (fa_init) posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(ap);
    // The parent's copy of the child end: the dup2 actions ran in the child,
    // so this descriptor is now redundant in the parent — close it, or the
    // engine holds both ends and POLLHUP never reports the child leaving.
    close(child_end);
    if (failed) {
        return spawn_fail(child, &did, engine_end,
                          pid >= 0 || failed_code == SEALED_SPAWN_EXEC ? SEALED_SPAWN_EXEC
                          : failed_code != 0 ? failed_code : SEALED_SPAWN_ATTR);
    }

    // R1: deallocate our send right as soon as the spawn call returns; the
    // child (through the kernel's exception-port copy) holds the only senders.
    // Only the send right is dropped (a deallocate never touches the receive
    // right): the receive right stays for the child's whole life so its
    // exceptions are still received, and is destroyed by sealed_child_kill.
    (void)mach_port_deallocate(mach_task_self(), port);
    pthread_mutex_lock(&life->mu);
    child->pid = pid;
    life->pid = pid;   // the by-value copy the reader's service path uses (defect 1)
    // S-5: capture the process identity now — the child is alive (suspended)
    // and verified alive at every later kill by the gate. A failed capture
    // records uniq_known = 0; every later gate read then answers OURS (the
    // committed kill decision, see the DESIGN RULE at s5_classify) instead of
    // trusting an
    // unverified identity.
    life->uniq_known = s5_read_uniq(pid, &life->uniq_id) == 0;
    memcpy(life->cdhash, spec->cdhash, SEALED_CDHASH_LEN);
    life->cdhash_known = 1;
    pthread_mutex_unlock(&life->mu);

    // R3, suspended phase: the kernel's record of the executed image, before
    // resume. Never reap during the spawn window.
    uint8_t hash[SEALED_CDHASH_LEN];
    if (csops(pid, CS_OPS_CDHASH, hash, sizeof hash) != 0) {
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_DIED);
    }
    if (memcmp(hash, spec->cdhash, SEALED_CDHASH_LEN) != 0) {
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_CDHASH);
    }
    uint32_t st = 0;
    if (csops(pid, CS_OPS_STATUS, &st, sizeof st) != 0) {
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_DIED);
    }
    child->status_seen_suspended = st;
    if ((st & SEALED_CS_KILLED) || sealed_status_ok(st, spec->status_suspended) != 0) {
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_STATUS);
    }

    // Resume. pid_resume is refused with EPERM for an unprivileged engine
    // (measured, E1); SIGCONT resumes a START_SUSPENDED child (measured).
    // The pre-resume outside fd listing of v2.26 is cut in v2.27 (design R2,
    // "Removed in v2.27"): the fd table is fixed by the engine's own file
    // actions, root has no injection path (A-1), and the listing caught
    // engine bugs, not the attacker.
    (void)pid_resume(pid);
    kill(pid, SIGCONT);

    // R2 channel (KK3): the child's first byte within the deadline. The
    // channel's peer is fixed by construction — the engine's socketpair end —
    // so there is no accept loop; the deadline covers only the first byte.
    uint64_t deadline = now_ns() + (uint64_t)spec->rendezvous_ms * 1000000ull;
    char byte = 0;
    int hup = 0;   // the child's end closed everywhere: no byte can ever arrive
    for (;;) {
        // Re-check child death each round, so a child that dies before its
        // first byte is refused DIED, not RENDEZVOUS at the deadline (FIXES
        // 10, r2r3-identity D2). An exception the spawn-time port received is
        // death evidence of its own: a crashed child is held in exit behind
        // its exception message (E11), so it is not yet waitable and its
        // socketpair end stays open (no POLLHUP) — the waitid oracle cannot
        // see it, but the handler already SIGKILLed it (non-CRASH types) or
        // answered its EXC_CRASH (it can never send a valid first byte
        // either way), and SEALED_SPAWN_DIED covers "died or raised an
        // exception before verification" (measured: crash children held
        // through the whole deadline otherwise, sp-run-1).
        pthread_mutex_lock(&life->mu);
        int exc = life->exception_seen;
        pthread_mutex_unlock(&life->mu);
        if (exc || child_dead_unreaped(pid)) {
            return spawn_fail(child, &did, engine_end, SEALED_SPAWN_DIED);
        }
        uint64_t left = deadline > now_ns() ? deadline - now_ns() : 0;
        if (left == 0) {
            return spawn_fail(child, &did, engine_end, SEALED_SPAWN_RENDEZVOUS);
        }
        if (hup) {
            // A hang-up was already recorded (review M2): every descriptor
            // for the child's end is closed, so poll would return
            // immediately on every round and the loop would spin at full CPU
            // for the rest of the deadline — competing with the reader
            // thread whose exception message is the evidence that settles
            // DIED. Wait for evidence in bounded slices instead.
            uint64_t slice_ms = left / 1000000ull + 1;
            struct timespec ts = {
                .tv_sec = 0,
                .tv_nsec = (long)(slice_ms < 10 ? slice_ms : 10) * 1000000L,
            };
            nanosleep(&ts, NULL);
            continue;
        }
        struct pollfd pf = {.fd = engine_end, .events = POLLIN, .revents = 0};
        uint64_t slice_ms = left / 1000000ull + 1;
        if (slice_ms > 100) slice_ms = 100;   // re-check child death each slice
        int pr = poll(&pf, 1, (int)slice_ms);
        if (pr < 0 && errno == EINTR) continue;
        if (pr > 0 && (pf.revents & (POLLHUP | POLLERR)) && !(pf.revents & POLLIN)) {
            // The child closed its end without sending. A crashed child is
            // held in exit behind its exception message at this instant (E11):
            // not yet waitable, and the spawn-time reader may not have
            // serviced the message yet. Record the hang-up once and loop
            // back, where the death/exception re-check settles it as DIED;
            // only when the child stays alive and silent does the deadline
            // refuse RENDEZVOUS.
            hup = 1;
            continue;
        }
        if (pr <= 0) continue;
        ssize_t n = read(engine_end, &byte, 1);
        if (n == 1) break;
        if (n < 0 && errno == EINTR) continue;
        // EOF (n == 0) or error: same reasoning as POLLHUP above — the
        // loop-head re-check turns it into DIED for a crashed/dying child,
        // and the deadline turns it into RENDEZVOUS for a live silent one.
        hup = 1;
    }
    if (byte != SEALED_CHANNEL_FIRST_BYTE) {
        // R2: the child's first act on the channel is one fixed byte. In the
        // stdio shape fd 1 is the channel, so any stdout write in the pinned
        // child before its own self-check (a library diagnostic) would
        // otherwise become the "first byte" and desync the protocol stream.
        // Identity still comes from the audit token; this refuses the desync
        // at spawn (review M4).
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_TOKEN);
    }

    // A child that died between its first byte and here (or whose exception
    // the port received) must not be reported OK: the token checks below
    // would still pass for a freshly dead peer (review finding 4).
    // Narrowed, not closed: a death between this re-check and
    // `return SEALED_SPAWN_OK` is still reported OK; harmless — the peer can
    // only be the child, and the engine's first write fails with EPIPE
    // (SO_NOSIGPIPE).
    pthread_mutex_lock(&life->mu);
    int exc_after = life->exception_seen;
    pthread_mutex_unlock(&life->mu);
    if (exc_after || child_dead_unreaped(pid)) {
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_DIED);
    }
    // R2: the token is computed when read, from the process that sent the
    // byte on the child's end of the pair — which only the spawned child
    // holds (E3); csops_audittoken refuses it once that process has exec'd or
    // its pid was reused (E4). On failure the engine never sends anything on
    // the channel.
    audit_token_t token;
    socklen_t tlen = sizeof token;
    if (getsockopt(engine_end, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tlen) != 0 ||
        token_pid(&token) != pid) {
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_TOKEN);
    }
    if (csops_audittoken(pid, CS_OPS_CDHASH, hash, sizeof hash, &token) != 0 ||
        memcmp(hash, spec->cdhash, SEALED_CDHASH_LEN) != 0) {
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_TOKEN);
    }
    uint32_t rst = 0;
    if (csops_audittoken(pid, CS_OPS_STATUS, &rst, sizeof rst, &token) != 0) {
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_TOKEN);
    }
    child->status_seen_running = rst;
    if ((rst & SEALED_CS_KILLED) || sealed_status_ok(rst, spec->status_running) != 0) {
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_STATUS);
    }
    // b2 review D2: the previous identity check ran before the port setup and
    // the spawn; the child's HOME and TMPDIR name the directory by path, so
    // confirm the path still names the pinned directory before reporting OK.
    // A swap after this check is not detected (residual, FIXES-B2).
    if (!dir_path_is(&did, dir)) {
        return spawn_fail(child, &did, engine_end, SEALED_SPAWN_DIR);
    }

    // R3: record the verified audit token in the child struct. LOCAL_PEERTOKEN
    // re-read later would return a token for whoever sent last at that
    // moment, not the token this spawn verified; the engine's later identity
    // checks need the verified one (review M3).
    child->token = token;
    child->channel_fd = engine_end;
    dir_id_close(&did);
    return SEALED_SPAWN_OK;
}

// Test seam, compiled only into the reader-focused test arms by tests/Makefile
// (-DSEALED_SPAWN_TEST_HOOKS); the public header is unchanged and a shipping
// build does not define it. It runs the real spawn-port reader on a
// caller-owned receive right, so an arm can send the reader real Mach messages
// (including malformed ones) and observe what it does with them.
// Lifecycle defect 1 fix, seam side: the reader runs on a module-owned life_t
// the seam allocates for the caller's struct (the struct's own `lock` is left
// alone — the caller owns it and may free the struct while the reader runs,
// which is the whole point of the UAF probe). The seam is production-shaped:
// ctx->owner = child, so the reader's guarded mirror writes
// child->exception_seen exactly as production does — the b2 seam arms assert
// that struct field directly — and the l1 probe can gate the mirror off with
// sealed_test_reader_reap before releasing the struct page.
// l3's guard arm also installs sea_test_grace_hook: a callback the kill path
// runs once, at the top of its grace loop, before the first ownership
// re-check — the point in the timeline where the committed module went on to
// waitid the pid regardless of a concurrent reap. The arm uses it to hold
// one kill thread exactly there while another reaps.
#ifdef SEALED_SPAWN_TEST_HOOKS
// Set by the l3 guard arm (NULL otherwise). Called once per kill call, at
// the top of the grace loop, with no lock held.
void (*sea_test_grace_hook)(void);

void *sealed_test_reader_start(sealed_child_t *child, mach_port_t port);
int sealed_test_reader_done(void *h);
int sealed_test_reader_stop(void *h);
void sealed_test_reader_reap(void *h);

void *sealed_test_reader_start(sealed_child_t *child, mach_port_t port) {
    // A module-owned life_t for the seam's reader (defect 1: the reader must
    // not hold the caller's struct as its only handle). refs is 1 — the
    // ctx's reference — so the life_t is freed exactly when the ctx goes
    // (reader_wait's done path) and leaked together with the ctx on the
    // give-up path, matching the production ownership.
    // owner = child, exactly like the production path, so the seam's reader
    // runs the same guarded mirror code the l1 probe holds to account
    // (review round 1, finding 4): the write is gated on !reaped, and the
    // probe reaps this life_t (sealed_test_reader_reap) before releasing
    // the struct page so the mirror is provably off afterwards.
    life_t *life = malloc(sizeof *life);
    if (life == NULL) return NULL;
    if (pthread_mutex_init(&life->mu, NULL) != 0) {
        free(life);
        return NULL;
    }
    life->reaped = 0;
    life->exception_seen = 0;
    life->pid = 0;
    life->uniq_id = 0;
    life->uniq_known = 0;
    life->cdhash_known = 0;
    life->spawn_port = MACH_PORT_NULL;   // never used by the seam's reader
    life->refs = 1;
    reader_ctx_t *ctx = malloc(sizeof *ctx);
    if (ctx == NULL) {
        pthread_mutex_destroy(&life->mu);
        free(life);
        return NULL;
    }
    ctx->life = life;
    ctx->port = port;
    ctx->owner = child;   // same guarded-mirror shape as production
    atomic_store(&ctx->stop, 0);
    atomic_store(&ctx->done, 0);
    atomic_store(&ctx->dead, 0);
    if (pthread_create(&ctx->thr, NULL, spawn_port_reader, ctx) != 0) {
        pthread_mutex_destroy(&life->mu);
        free(life);
        free(ctx);
        return NULL;
    }
    pthread_detach(ctx->thr);
    return ctx;
}

// 1 once the reader thread has finished.
int sealed_test_reader_done(void *h) { return atomic_load(&((reader_ctx_t *)h)->done) != 0; }

// Marks the seam's life_t reaped (the lifecycle the probe models completed):
// after this, the reader's guarded mirror write into owner->exception_seen is
// off, exactly as in production after a concurrent lifecycle completion.
void sealed_test_reader_reap(void *h) {
    reader_ctx_t *ctx = h;
    pthread_mutex_lock(&ctx->life->mu);
    ctx->life->reaped = 1;
    pthread_mutex_unlock(&ctx->life->mu);
}

// Stops the reader and waits (bounded) for it to finish. Returns 1 and frees
// nothing here if the reader confirmed done — reader_wait already freed the
// ctx and dropped its life reference (which frees the life_t with it, the
// ctx held the only one). Returns 0 when the bound expired: the reader is
// still running, so the ctx and its life_t are both left allocated (the
// deliberate give-up leak — freeing either would hand the thread a dangling
// pointer; review round 1, finding 5).
int sealed_test_reader_stop(void *h) {
    reader_ctx_t *ctx = h;
    atomic_store(&ctx->stop, 1);
    reader_wait(&ctx);
    return ctx == NULL;
}
#endif

#ifdef SEALED_SPAWN_TEST_HOOKS
// ---- staged spike seams (wave-2026-10-06/code-s5-canary) -------------------
// Plain-exported ON PURPOSE: this wave's test rules forbid editing the suite
// Makefile, and its HOOK_ARMS list is what selects the
// SEALED_SPAWN_TEST_HOOKS build. Since 2026-10-11 (cross-family review
// BLOCKER 2, verified as V1) all three seams are compiled only with
// SEALED_SPAWN_TEST_HOOKS, so a production object has none. Before that fix,
// from inside the
// engine process, sealed_test_s5_retarget_pid can point any child's
// lifecycle at an arbitrary pid and thereby disarm (or misdirect) its kill.
// None of the seams signals anything itself.
//
// sealed_test_s5_retarget_pid: the pid-reuse stand-in. macOS's pid allocator
// is sequential and only wraps near the top of its range, so the suite
// cannot force a SPECIFIC freed pid to be reused on demand (measured in this
// wave: the flavor-17 id differs for every new process, and reuse of one
// freed pid needs a full allocator wrap). The seam produces the same
// observable GATE INPUT by hand: the spawned child's lifecycle keeps the
// identity captured at its spawn, but its pid becomes a foreign LIVE pid
// the arm owns — what a recycled pid presents to the gate. Differences from
// a real recycle, stated: the original child stays alive (so the FOREIGN
// path destroys the spawn port of a live process — harmless here, it is a
// test child the arm kills directly); the reader-side kill site is not
// exercised by this stand-in; and identity + pid come from one hand-written
// step, not an external reap followed by a recycle.
int sealed_test_s5_retarget_pid(sealed_child_t *child, pid_t new_pid) {
    if (child == NULL || new_pid <= 0) return -1;
    life_t *life = life_hold(child);
    if (life == NULL) return -1;
    pthread_mutex_lock(&life->mu);
    life->pid = new_pid;
    pthread_mutex_unlock(&life->mu);
    life_unref(life);
    return 0;
}

// sealed_test_s5_gate_probe: the gate's classification for any pid and any
// captured identity (the arm reads the same flavor itself to build its
// expectations). forced_errno < 0 runs the REAL gate (read + classify);
// forced_errno > 0 feeds that errno into s5_classify — the SAME function
// the real gate calls — so the arm's forced-errno legs execute the real
// classification code (a mutant that reverts the errno rule fails leg B).
// forced_errno == 0 is refused (0 means "read succeeded"; there would be no
// id to compare). *state receives S5_OURS / S5_GONE / S5_FOREIGN. Read-only.
int sealed_test_s5_gate_probe(pid_t pid, unsigned long long captured_uniq,
                              int capture_known, int forced_errno, int *state) {
    if (pid <= 0 || state == NULL) return -1;
    if (forced_errno == 0) return -1;
    life_t probe;
    memset(&probe, 0, sizeof probe);
    probe.pid = pid;
    probe.uniq_id = (uint64_t)captured_uniq;
    probe.uniq_known = capture_known;
    if (forced_errno < 0) {
        *state = s5_pid_gate(&probe);
    } else {
        *state = s5_classify(&probe, forced_errno, 0);
    }
    return 0;
}

// sealed_test_s5_gate_probe_cdhash: the real gate (read + classify) for a pid
// with a captured identity AND a pinned CD hash, so an arm can drive the
// second check (verified as V2): a live process whose id differs from the
// capture but whose CD hash equals the pin must classify OURS (signal).
int sealed_test_s5_gate_probe_cdhash(pid_t pid, unsigned long long captured_uniq,
                                     const uint8_t pin[SEALED_CDHASH_LEN], int *state) {
    if (pid <= 0 || state == NULL || pin == NULL) return -1;
    life_t probe;
    memset(&probe, 0, sizeof probe);
    probe.pid = pid;
    probe.uniq_id = (uint64_t)captured_uniq;
    probe.uniq_known = 1;
    memcpy(probe.cdhash, pin, SEALED_CDHASH_LEN);
    probe.cdhash_known = 1;
    *state = s5_pid_gate(&probe);
    return 0;
}
#endif  // SEALED_SPAWN_TEST_HOOKS
