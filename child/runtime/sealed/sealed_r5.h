// sealed_r5 — R5 sandbox applied by the child to itself, its self-test, and the
// R4 Metal guard (cache path) for the sealed Splash child.
#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// R4: points Metal's shader and module cache at $TMPDIR/metal-cache (the
// engine-created private, empty directory) before any Metal call, and checks
// that Metal accepted it. _exit(113) on failure.
void sealed_r4_metal_guard(void);

// R5: builds the measured profile (wave-2026-10-01/r5-profile/REPORT.md) with
// one literal parameter slot per manifest path and applies it. The manifest
// paths are absolute (root + relative path). _exit(113) on failure.
void sealed_r5_apply(const char *const *manifest_paths, size_t n);

// R5 self-test: every access the profile must deny, each on a fresh name.
// Any access that is not denied with the expected result -> _exit(113).
// `outside` is a readable file outside the manifest (the executable's own
// directory is allowed by the measured rule, so the canary is elsewhere).
void sealed_r5_self_test(const char *manifest_path_example);

// R4 order: after the sandbox, its self-test and the Metal guard, report
// "sandboxed" to the engine on the channel (fd 1) as the 4 bytes "SLSB".
// The engine re-checks the CD hash and status word, then waits for "loaded".
// _exit(113) on a write failure.
void sealed_r5_report_sandboxed(void);

#ifdef __cplusplus
}
#endif
