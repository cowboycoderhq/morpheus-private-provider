// sealed_r2 — R2 child self-check and config frame for the sealed Splash child.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Reason codes (test builds print them; every refusal exits 113).
enum {
    SEALED_R2_FDS = 1,        // descriptor table is not exactly the spawn's table
    SEALED_R2_ENV = 2,        // environment is not exactly HOME and TMPDIR (same dir)
    SEALED_R2_DIR = 3,        // TMPDIR: not owned by the user, not 0700, or contents not just metal-cache/
    SEALED_R2_CWD = 4,        // working directory is not TMPDIR
    SEALED_R2_SIG = 5,        // a signal is blocked or ignored
    SEALED_R2_RLIMIT = 6,     // an rlimit differs from the compiled constants
    SEALED_R2_ARGV = 7,       // argv is not the sealed form
    SEALED_R2_FRAME = 8,      // config frame: truncated, does not parse, roots differ from argv
};

// Runs every self-check before the first byte. argv is the process argv.
// Returns only if all checks pass; otherwise _exit(113).
void sealed_r2_self_check(int argc, char **argv, char **envp);

// The TMPDIR value that the self-check verified (from main's envp, not
// environ). Valid after sealed_r2_self_check. Review N8, 2026-10-20.
const char *sealed_r2_checked_tmpdir(void);

// Test builds (SEALED_TEST_REASON_FILE): the reason file is opened once, at
// the start of main, so refusals after the sandbox can still be recorded.
void sealed_reason_open(void);
void sealed_reason_write(const char *line, size_t n);
// The reason file's descriptor (-1 in production), for R6's descriptor check.
int sealed_reason_fd(void);

// Sends the fixed first byte on fd 1. _exit(113) on failure.
void sealed_r2_first_byte(void);

// Reads the config frame from fd 0 (blocking, exact length), checks it against
// argv (target, draft) and returns the manifest file form in *manifest/*len
// (owned by the module, never freed) and the package root in *package_root.
// Frame: "SLCF" | u32 version (1 or 2) | u16 len+bytes package_root | u16
// len+bytes target | u16 len+bytes draft | u32 manifest_len | manifest bytes
// | version 2 only: u64 kv_budget_bytes. Big-endian.
void sealed_r2_read_config(const char *argv_target, const char *argv_draft,
                           const uint8_t **manifest, size_t *len,
                           const char **package_root);

// Chunked KV budget from a version 2 frame (review/CHUNKED-KV-2026-10-23.md),
// or 0 after a version 1 frame (the engine then uses its default). A v2
// value outside [SEALED_R2_KV_BUDGET_MIN, SEALED_R2_KV_BUDGET_MAX] refuses.
#define SEALED_R2_KV_BUDGET_MIN (256ull << 20)
#define SEALED_R2_KV_BUDGET_MAX (1ull << 40)
uint64_t sealed_r2_kv_budget_bytes(void);

#ifdef __cplusplus
}
#endif
