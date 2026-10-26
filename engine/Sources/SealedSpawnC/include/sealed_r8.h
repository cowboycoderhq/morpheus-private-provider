// sealed_r8 — R8: the engine applies a sandbox to itself before it serves,
// and checks it with a self-test. Adapted from the child's R5 module
// (sealed-backends-spike/sealed-m5/splash/runtime/sealed/sealed_r5.{h,mm},
// sha256 e954d280…d722 / c504c804…321c, copied 2026-10-21): the profile
// builder, the parameter slots and the arm patterns are R5's; the Metal guard,
// the manifest slots and the "sandboxed" report are not used here.
//
// The engine enters the sandbox after it has read the package, started the
// child and made its App Attest key, and before it listens: consumer
// plaintext exists in this process only after that point. The sandbox limits
// what the engine process can do (no file writes, no exec or fork, no
// outbound sockets, no listener except its own port). It does not encrypt or
// hide the engine's memory from root.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *package_root;   // model package; read before R8, denied after
    const char *child_path;     // pinned child executable; denied after
    pid_t child_pid;            // the started child: info and signals stay allowed for it
    uint16_t port;              // the engine's loopback port, bound before R8
    int log_fd;                 // -1 = stderr only
} sealed_r8_config;

// After the denials, two "must still work" arms check the child allowances
// (proc_pidinfo and signal 0 on child_pid).
//
// Runs every self-test arm without a sandbox (the control: each access must
// succeed, or fail for a reason other than a policy denial), applies the
// profile, then runs every arm again (each must be denied: EPERM, or 1100 for
// a mach lookup). 0 = sandboxed and all arms held. -1 = refuse to serve
// (`why` names the arm or step); the caller exits.
int sealed_r8_enter(const sealed_r8_config *cfg, char *why, size_t why_len);

#ifdef __cplusplus
}
#endif
