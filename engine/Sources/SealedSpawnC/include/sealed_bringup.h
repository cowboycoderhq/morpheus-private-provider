// sealed_bringup — the engine's sealed start of the Splash child, adapted from
// the tested stand-in launcher (sealed-m5/launcher/sealed-launch.c):
//   rlimits for the child (restored for the engine after the spawn),
//   A-13 canary (strict), sealed spawn (S-5 gate, pinned CD hash and status
//   word, socketpair channel, audit token), R5 self-test probes, R2 config
//   frame with the manifest the engine read itself, the "sandboxed" report
//   with a CD hash and status re-check, probe removal, the "loaded" report
//   with a re-check and the manifest hash compared with the engine's.
// After a 0 return the channel carries the Splash native protocol.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *child_path;            // canonical path of the pinned child
    const char *decoy_path;            // A-13 canary decoy executable
    const uint8_t *child_cdhash;       // 20 bytes, compiled into the engine
    const uint8_t *decoy_cdhash;       // 20 bytes
    const uint8_t *requirement;        // launch requirement naming child_cdhash
    size_t requirement_len;
    uint32_t status_word;              // measured status word for this pair
    const char *package_root;          // model package (holds target/, draft/, sealed-manifest.bin)
    const char *max_context;           // decimal, 1024..262144
    const uint8_t *manifest;           // sealed-manifest.bin bytes the engine read (no follow)
    size_t manifest_len;
    uint64_t kv_budget_bytes;          // chunked-KV budget; 0 = frame v1, child default (16 GiB)
    int log_fd;                        // -1 = no log
} sealed_bringup_config;

typedef struct {
    int channel_fd;                    // Splash native protocol from here on
    pid_t pid;
    uint8_t manifest_hash[32];         // hash form, kind 2 (child == engine)
    void *child;                       // opaque sealed_child_t
} sealed_bringup_result;

// 0 on success. On failure the child is killed and reaped, and `why` holds
// the reason.
int sealed_bringup_start(const sealed_bringup_config *cfg, sealed_bringup_result *out,
                         char *why, size_t why_len);

// Kills and reaps the child and removes its private directory.
void sealed_bringup_stop(sealed_bringup_result *r);

// Re-checks the running child's CD hash and status word through the audit
// token from the first byte. 0 = still the pinned child.
int sealed_bringup_recheck(sealed_bringup_result *r, const uint8_t *cdhash, uint32_t status_word);

// Liveness of the serving child, checked before the engine returns an
// attestation or an assertion. No reap, no signal, no log line on success;
// three non-blocking syscalls in this order:
//   1. waitid(WEXITED|WNOWAIT|WNOHANG): the child exited, was killed or
//      dumped, or is no longer the engine's child (ECHILD);
//   2. poll(channel_fd, 0 ms): POLLHUP/POLLERR = the child's end is closed;
//   3. csops_audittoken with the first-byte token: CD hash and status word
//      are still the pin (a reused pid fails: the token has the pid version).
// Reads `r` only, so it does not need the engine's generation lock.
// 0 = alive and still the pinned child; -1 = not, and `why` names the check.
int sealed_bringup_alive(const sealed_bringup_result *r, const uint8_t *cdhash, uint32_t status_word,
                         char *why, size_t why_len);

#ifdef __cplusplus
}
#endif
