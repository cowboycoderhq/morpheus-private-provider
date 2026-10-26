// R2 spawn and channel, R3 pinned-code checks (DESIGN-sealed-backends v2.28:
// the v2.27/v2.28 socketpair channel replaces the v2.26 rv rendezvous).
#ifndef SEALED_SPAWN_H
#define SEALED_SPAWN_H

#include <bsm/libbsm.h>
#include <mach/mach.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SEALED_CDHASH_LEN 20

// Code-signing status flags (kern/cs_blobs.h; values checked against the SDK).
#define SEALED_CS_VALID 0x00000001u
#define SEALED_CS_GET_TASK_ALLOW 0x00000004u
#define SEALED_CS_INSTALLER 0x00000008u
#define SEALED_CS_FORCED_LV 0x00000010u
#define SEALED_CS_INVALID_ALLOWED 0x00000020u
#define SEALED_CS_HARD 0x00000100u
#define SEALED_CS_KILL 0x00000200u
#define SEALED_CS_ENFORCEMENT 0x00001000u
#define SEALED_CS_RUNTIME 0x00010000u
#define SEALED_CS_PLATFORM_BINARY 0x04000000u
#define SEALED_CS_DEBUGGED 0x10000000u

#define SEALED_CS_REQUIRED \
    (SEALED_CS_VALID | SEALED_CS_HARD | SEALED_CS_KILL | SEALED_CS_RUNTIME | SEALED_CS_ENFORCEMENT | SEALED_CS_FORCED_LV)
#define SEALED_CS_FORBIDDEN                                                                          \
    (SEALED_CS_GET_TASK_ALLOW | SEALED_CS_DEBUGGED | SEALED_CS_INVALID_ALLOWED | SEALED_CS_PLATFORM_BINARY | \
     SEALED_CS_INSTALLER)

// Which descriptors the channel's child end lands on (R2, v2.28): the two
// backend shapes the design names. SEALED_CHANNEL_STDIO is the Splash shape
// (one socketpair end duplicated onto both fd 0 and fd 1, fd 2 on /dev/null);
// SEALED_CHANNEL_FD3 is the mlx-serve shape (the end on fd 3, fds 0-2 on
// /dev/null). There is deliberately no zero value: `channel_shape` is a
// required spec field, and a zeroed or unset spec is refused with
// SEALED_SPAWN_ATTR instead of silently taking a default shape.
enum {
    SEALED_CHANNEL_STDIO = 1,
    SEALED_CHANNEL_FD3 = 2,
};

// The fixed byte a child sends as its first act on the channel (R2: "the
// child's first act on the channel is to send one fixed byte"). The module
// refuses a spawn whose first byte is anything else.
#define SEALED_CHANNEL_FIRST_BYTE 'S'

// What the engine knows about one pinned child before spawning it.
typedef struct {
    const char *path;                       // the child executable
    const char *const *argv;                // the sealed argv form (argv[0] first), NULL-terminated
    uint8_t cdhash[SEALED_CDHASH_LEN];      // pinned CD hash
    const uint8_t *requirement;             // LaunchCodeRequirement bytes naming `cdhash` (A-13)
    size_t requirement_len;
    uint32_t status_suspended;              // measured full status word, suspended phase (0 = record only)
    uint32_t status_running;                // measured full status word after the first byte (0 = record only)
    unsigned rendezvous_ms;                 // deadline for the child's first byte on the channel (KK3)
    int channel_shape;                      // SEALED_CHANNEL_* (the fixed descriptors the end lands on)
} sealed_child_spec_t;

// Lifecycle state shared by the spawn path, the spawn-time exception handler
// and every kill the engine addresses to the child (R1, R3): SIGKILL goes to
// the pid only while `reaped` is 0 AND (the S-5 gate) the pid still names
// the spawned process, so a recycled pid is never signalled.
typedef struct sealed_child {
    pid_t pid;
    int reaped;
    int exception_seen;                     // the spawn-time port received a message
    mach_port_t spawn_port;                 // reserved ABI slot; always MACH_PORT_NULL (the port lives in the module-owned lifecycle state)
    int channel_fd;                         // verified channel (the engine's socketpair end), -1 until verified
    char dir[256];                          // the child's fresh HOME/TMPDIR
    uint32_t status_seen_suspended;         // recorded for R3-T1's phase recording
    uint32_t status_seen_running;
    audit_token_t token;                    // audit token verified at the first byte (R2/R3 identity record)
    void *lock;                             // module-owned lifecycle state (opaque)
} sealed_child_t;

// Result codes: 0 = verified and serving; anything else = refused, child killed.
enum {
    SEALED_SPAWN_OK = 0,
    SEALED_SPAWN_DIR = 10,          // fresh directory, metal-cache or the channel socketpair
    SEALED_SPAWN_PORT = 11,         // spawn-time port or its handler thread
    SEALED_SPAWN_ATTR = 12,         // spawn attributes, exception ports or file actions
    SEALED_SPAWN_REQUIREMENT = 13,  // launch requirement could not be attached (A-13);
                                    // also: the A-13 canary failed on this pair and the
                                    // module refuses sealed children (fail closed)
    SEALED_SPAWN_EXEC = 14,         // posix_spawn failed
    SEALED_SPAWN_CDHASH = 15,       // suspended child's CD hash is not the pin
    SEALED_SPAWN_STATUS = 16,       // status word: required/forbidden flags or measured word
    SEALED_SPAWN_FDS = 17,          // reserved (the v2.26 pre-resume fd listing was cut in v2.27)
    SEALED_SPAWN_RENDEZVOUS = 18,   // no first byte on the channel within the deadline
    SEALED_SPAWN_TOKEN = 19,        // audit token: wrong pid, stale, or wrong code identity;
                                    // also a first byte that is not SEALED_CHANNEL_FIRST_BYTE
    SEALED_SPAWN_DIED = 20,         // the child died or raised an exception before verification
};

// Spawns and verifies one child generation. On success `child` holds the
// verified channel (the engine's end of the socketpair, after the child's
// first byte and the token checks). On failure the child has been killed
// through its lifecycle state. EVERY failure return of this function
// BEFORE ANY CHILD PROCESS EXISTED (the validation, and the directory,
// channel, port, reader and exec failures that precede the first
// successful posix_spawn — `pid` <= 0 throughout; note the DIR code is
// also returned after a successful spawn when the path check fails then,
// and that path follows the kill contract) ends with
// `reaped == 1` (cross-family review S3): nothing was spawned, at worst a
// spawn-port reader thread is still draining its bounded window (see
// sealed_child_kill), the flag is set outright, so no kill call is needed
// and the struct may be freed at once (once any concurrent kill calls on
// it have returned, per the lifetime rule below) — and a caller that
// follows the retry text ("repeat sealed_child_kill only while `reaped`
// is 0") terminates on every such failure path instead of spinning. A
// failure AFTER a child process existed follows the sealed_child_kill
// contract instead: the flag is 1 when the child was reaped within the
// kill's bounds and 0 while it stays unreapable (see that function).
// The struct's lifetime rule across both functions is: free or reuse the
// struct only when `reaped == 1` is observed AND every sealed_child_kill
// call on that struct has returned (join, or count, the engine's own
// callers — see sealed_child_kill for why the second half exists).
// On failure, and
// only while `dir` still names the directory it created, the module removes
// metal-cache if it is an empty directory, by name through the pinned
// directory descriptor, and then removes the directory if it is empty. The
// directory is left in place when it holds any other entry, when the path now
// names a different directory, and when the failure came before the directory
// could be pinned (creation, identity or canonical-path checks); the return
// code does not say which. After a successful spawn the engine must end the
// generation with sealed_child_kill calls (repeating while `reaped` is 0)
// (each kills and reaps the child, destroys the spawn-time port's receive
// right and drains the reader thread); the engine closes `channel_fd` and
// removes `dir` itself once the generation is done.
// The exec-failure code means posix_spawn itself failed — measured here for
// a nonexistent executable path, where no process is ever created; the
// module does not expect posix_spawn to report failure after creating a
// process, and it would not track such a process if one existed.
int sealed_spawn_child(const sealed_child_spec_t *spec, sealed_child_t *child);

// Kills the child if (and only if) it has not been reaped, then reaps it.
// Calling it on NULL or on a child that is already reaped (`reaped` == 1
// and the lifecycle released) returns at once.
// `reaped` only ever goes 0 -> 1: it is set to 1 when waitpid reports
// ECHILD for the engine's own child (reaped elsewhere, e.g. SIGCHLD
// ignored), by the winning kill call's reap, and — on a failure before any
// child process existed — by sealed_spawn_child itself. A fourth way exists
// with the S-5 pre-kill identity gate: when the gate classifies the pid as
// FOREIGN (a different live process holds it — the recycled-pid shape), the
// call completes the lifecycle with `reaped == 1` WITHOUT signalling and
// WITHOUT any wait on that pid; see sealed_child_kill below.
//
// CONCURRENCY AND THE STRUCT'S LIFETIME (cross-family review B1). The
// design routes the crash handler and two engine timeouts through one
// lifecycle, so two engine threads may call this on the same struct, and
// that pattern is SAFE: the calls coordinate through the module-owned,
// reference-counted lifecycle state; each call holds its own reference for
// its whole duration; the kill path dereferences the caller's struct only
// at two points: the entry, whose only struct access is the opaque lock
// pointer read in the reference hold (under the module's reference
// mutex), followed by the reaped/pid pair and the entry SIGKILL read
// under the lifecycle mutex from the module's own state; and the winning
// reap's handoff at the flip (publishing the caller's reaped copy and
// clearing the opaque lock pointer, immediately after the flip). THE
// CALLER'S RULE: the engine may free or reuse the struct only after
// observing `reaped == 1` AND after every sealed_child_kill call on that
// struct has returned (join or count the engine's own callers). The rule
// has two concrete reasons in the code: (1) the WINNING call writes the
// struct's final fields at its flip and only then finishes its reader and
// port teardown — between the flip and that call's return the struct is
// still being finalized; (2) a kill call that has not yet passed its
// entry would pick up whatever state the struct then holds — re-spawning
// under a live call can attach it to the new generation's half-built
// lifecycle. Observing `reaped == 1` alone grants neither.
// A struct that stays unreapable keeps `reaped` 0 and the caller must not
// free it (a later call retries; the retry is fast once the child has
// died). There is no background reaper.
//
// The reap and the `reaped` store happen under the lifecycle mutex, so a
// kill never targets a pid that has been freed; the kill path's bounded
// loops check ownership and liveness under one lock acquisition per round
// (including the non-consuming waitid peek), so a lifecycle completed by
// another engine thread ends them at once and no wait ever names a pid the
// caller does not own — not even within a round. The spawn-port reader
// thread the module started touches no engine-owned memory after the
// generation ends: it services late messages through the module's own
// reference-counted state. On the abnormal give-up path (the reader
// outlives its join bound) the reader's context and its state allocation
// are deliberately leaked together (two small allocations, once per
// overrun) — that leak is the price of never handing a live thread a
// dangling pointer.
void sealed_child_kill(sealed_child_t *child);

// Checks a status word against the required and forbidden flags and, when
// `measured` is nonzero, against the measured word for the phase. 0 if it passes.
int sealed_status_ok(uint32_t status, uint32_t measured);

// ---- staged spike additions (wave-2026-10-06/code-s5-canary) ----------------
// R2-T4(m) A-13 canary (socketpair-fix REPORT §5.2; review C1). A per-spawn
// CS_KILLED check observes the kernel's A-13 refusal but cannot detect a
// pair where enforcement has regressed. The canary measures enforcement
// itself: the engine calls sealed_a13_canary_run ONCE per engine start
// (a per-boot policy is the engine re-running it at every start after a
// boot; the module keeps no cross-boot state), BEFORE serving children,
// passing a decoy spec —
// a small executable the engine ships, with `cdhash` = the decoy's OWN pin,
// and `requirement` bytes naming a DIFFERENT (wrong) CD hash. The module
// spawns the decoy suspended through its own spawn path in BOTH dup2
// channel shapes (STDIO, FD3); kernel enforcement is confirmed only when
// every leg is refused pre-resume with CS_KILLED in the suspended word (the
// decoy never verifies, never runs).
//
// Verdict: SEALED_A13_RUN_* below. RUN_ENFORCED = enforcement confirmed
// (children allowed). RUN_ADMITTED and RUN_INCONCLUSIVE set the state to
// FAILED: from then on the module refuses every sealed_spawn_child on this
// pair for the rest of the process, before any directory, port or process
// is created, with SEALED_SPAWN_REQUIREMENT — fail closed. RUN_BUSY (a run
// in progress, or the state already FAILED) and -1 (bad arguments) change
// NOTHING: the state stays as it was, so the engine must treat them as
// "not measured" and decide itself (a FAILED state is final for the
// process; restart re-measures). A RUN_ENFORCED verdict may be re-run
// (refresh); the newest verdict wins. Not thread-safe with concurrent
// spawns: run it at engine start, before any child.
//
// SCOPE OF THE STATE (decided this wave): the verdict lives for the PROCESS
// (an engine start). "Per boot" is a POLICY the engine implements by calling
// this once at every start; the module keeps no cross-boot state (nowhere to
// put one without a store). UNTIL THE CANARY HAS RUN in this process the
// gate is OPEN: children spawn as before, because the module cannot know
// whether the engine intends to canary at all, and refusing would break
// every existing caller. THE ENGINE MUST CALL sealed_a13_canary_run BEFORE
// SERVING — an engine that skips it gets no A-13-regression protection
// (install-checklist item, like the channel_shape requirement).
//
// `decoy->rendezvous_ms` bounds each leg (the FD3 leg rides the deadline
// when the decoy is admitted and sends nothing on fd 3); 1200 is a workable
// value. The marker-oracle convention (argv[1] = a marker path the decoy
// creates as its first act) is the ENGINE'S/ARM'S oracle, not the module's:
// the module's verdict uses only the spawn result and the status word.
//
// RUN RESULTS of sealed_a13_canary_run (deliberately NOT the state names:
// 1 as a run result means a decoy was ADMITTED — the regression case —
// while SEALED_A13_ENFORCED = 1 as a STATE means the pair is good):
enum {
    SEALED_A13_RUN_ENFORCED = 0,      // every leg confirmed the kernel's refusal
    SEALED_A13_RUN_ADMITTED = 1,      // a decoy was admitted and ran: REGRESSION-shaped
    SEALED_A13_RUN_INCONCLUSIVE = 2,  // a leg refused another way; treat as unproven
    SEALED_A13_RUN_BUSY = 3,          // a run is in progress, or the state is FAILED
};
int sealed_a13_canary_run(const sealed_child_spec_t *decoy);

// 1 while sealed children may spawn (canary untested or enforced), 0 after
// a failed canary verdict. sealed_spawn_child consults the same state.
int sealed_a13_children_allowed(void);

// The PROCESS state behind both gates above — named constants, a DIFFERENT
// numbering from the run results (UNTESTED = 0 is not a run result):
enum {
    SEALED_A13_UNTESTED = 0,   // no measurement yet in this process
    SEALED_A13_ENFORCED = 1,   // every leg confirmed the kernel's refusal
    SEALED_A13_FAILED = 2,     // unproven or regressed: children refused
};
int sealed_a13_canary_verdict(void);

// Strict mode: after sealed_a13_require_canary(1), every sealed spawn is
// refused with SEALED_SPAWN_REQUIREMENT until sealed_a13_canary_run has
// confirmed enforcement (verdict SEALED_A13_ENFORCED). The production engine
// calls it once at start, before its first spawn. It cannot be switched off
// again in a process; calling it with 0 only returns the current value.
int sealed_a13_require_canary(int on);

#ifdef __cplusplus
}
#endif

#endif
