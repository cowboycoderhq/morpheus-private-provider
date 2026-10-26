// Boot-posture and host-setting gate (A-11 / P5a / P5d).
//
// Checked by the engine at start, before the model package or the child is
// touched. The consumer cannot see these settings in the Apple attestation,
// so the engine enforces them on itself and refuses to start if any of them
// is not in the state the v2 claim assumes:
//   1. SIP active config (`csr_get_active_config`) is 0: every SIP protection
//      is enabled.
//   2. `kern.bootargs` is empty.
//   3. `vm.swapusage` has `xsu_encrypted != 0`.
//   4. `kern.hibernatemode` is 0 or 3 (not 25, which forces a disk sleep image
//      on every sleep).
//   5. Every loaded kext (`KextManagerCopyLoadedKextInfo`) is `__kernel__` or
//      has a `com.apple.` bundle ID: no third-party kext is loaded.
//   6. IODeviceTree:/chosen has `effective-security-mode-ap` and
//      `certificate-security-mode` equal to 1 (4-byte little-endian 0x01000000),
//      and `effective-security-mode-sep` equal to 1.
//
// `sealed_posture_eval` is the pure rule over a readings struct, so a test can
// check every refusal arm without weakening the host. `sealed_posture_read`
// fills the readings from the live kernel and IOKit. `sealed_posture_check`
// runs both and writes a short reason on failure.
#ifndef SEALED_POSTURE_H
#define SEALED_POSTURE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int csr_rc;
    uint32_t csr_config;
    int bootargs_rc;
    char bootargs[256];
    int swap_rc;
    int swap_encrypted;
    int hibernate_rc;
    int64_t hibernatemode;
    int kext_rc;
    int non_apple_kexts;
    char first_non_apple_kext[128];
    int dt_rc;
    uint32_t effective_ap;
    uint32_t cert_mode;
    int64_t effective_sep;
} sealed_posture_readings_t;

void sealed_posture_read(sealed_posture_readings_t *out);
int sealed_posture_eval(const sealed_posture_readings_t *r, char *why, size_t why_len);
int sealed_posture_check(char *why, size_t why_len);

// Lightweight runtime check inside the engine's R8 sandbox (csr_get_active_config,
// vm.swapusage and kern.hibernatemode). If an admin changes hibernatemode to 25
// with pmset while the engine is running, or if swap stops being encrypted,
// the next request fails closed.
int sealed_posture_runtime_check(char *why, size_t why_len);

#ifdef __cplusplus
}
#endif

#endif
