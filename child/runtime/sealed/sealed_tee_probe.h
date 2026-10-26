// sealed_tee_probe — test-build-only measurements for the TEE evidence set
// (spec R5-T3, A-17, A-20). The production build has no symbol from this
// file: without SEALED_TEST_TEE_PROBES the header makes every call a no-op.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#if defined(SEALED_TEST_TEE_PROBES) || defined(SEALED_TEST_CRASH_CANARY)
// phase: "sandboxed" (after the Metal guard), "loaded" (after SLLD),
// "serving" (first input). Writes "tee-probe <phase> <arm> ..." lines to the
// reason file. The crash builds also use "postload" (after the load, latch and
// self-audit, before SLLD) and "after-request" (the first time the engine
// turns idle after a request); SEALED_TEST_CRASH_PHASE picks one.
void sealed_tee_probe(const char *phase);
#else
static inline void sealed_tee_probe(const char *phase) { (void)phase; }
#endif

#if defined(SEALED_TEST_IOSURFACE_PUBLISH)
// T2: makes a global and a non-global IOSurface filled with a fresh canary,
// sets the canary as a property, records "test: t2 <phase> ..." lines, holds
// both surfaces for SEALED_TEST_T2_HOLD seconds, then releases them.
void sealed_t2_publish(const char *phase);
#else
static inline void sealed_t2_publish(const char *phase) { (void)phase; }
#endif

#if defined(SEALED_TEST_T2F_PROBE)
// T2 follow-up: the T2 surfaces plus a Metal device, command queue, MTL4
// command queue and shared event, each result in a "test: t2f <phase> ..."
// line, then the T2 hold while an outside reader runs.
void sealed_t2f_probe(const char *phase);
#else
static inline void sealed_t2f_probe(const char *phase) { (void)phase; }
#endif

#if defined(SEALED_TEST_S1_SHARE)
// S-1 (2026-10-23): can code in the child share memory with another process
// through the GPU client that the profile allows (IOGPUDeviceUserClient, the
// base class of AGXDeviceUserClient)? The body makes a shared texture and a
// shared event, archives both handles and records them in the reason file,
// then holds while an outside reader runs. See review/S1-IOGPU-2026-10-23.md.
void sealed_s1_share(const char *phase);
#else
static inline void sealed_s1_share(const char *phase) { (void)phase; }
#endif

#if defined(SEALED_TEST_R7_READBACK)
// R7-T3 read-back (review/R7T3-2026-10-22.md). The start state is recorded
// after the R1 guard and the R2 self-check, the sandbox state after the R5
// self-test. Each check compares the current state with it; on a difference
// it writes "r7: CHANGED point=<p> class=<c> ..." and calls _exit(113).
void sealed_r7_start(void);           // after sealed_r2_self_check
void sealed_r7_sandbox_start(void);   // after sealed_r5_self_test
void sealed_r7_check(const char *point);
void sealed_r7_own_signals(void);     // after the child's own shutdown handlers; starts the busy-poll
void sealed_r7_after_load(void);      // after the self-audit, before SLLD
void sealed_r7_input(int idle);       // input arrived; idle = no request was active
void sealed_r7_after_request(void);   // the engine turned idle
#else
static inline void sealed_r7_start(void) {}
static inline void sealed_r7_sandbox_start(void) {}
static inline void sealed_r7_check(const char *point) { (void)point; }
static inline void sealed_r7_own_signals(void) {}
static inline void sealed_r7_after_load(void) {}
static inline void sealed_r7_input(int idle) { (void)idle; }
static inline void sealed_r7_after_request(void) {}
#endif

#ifdef __cplusplus
}
#endif
