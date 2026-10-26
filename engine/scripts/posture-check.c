// Unit test for the boot-posture and host-setting gate (sealed_posture.c).
// Checks the live host readings first, then mutates one field at a time and
// requires sealed_posture_eval to refuse with the expected reason substring.
#include "sealed_posture.h"

#include <stdio.h>
#include <string.h>

static int fails = 0;

static void check(const char *name, const sealed_posture_readings_t *r, int want_rc, const char *want_sub) {
    char why[256];
    why[0] = '\0';
    int rc = sealed_posture_eval(r, why, sizeof why);
    if (rc == want_rc && strstr(why, want_sub) != NULL) {
        printf("PASS [%s] %s\n", name, why);
    } else {
        printf("FAIL [%s] rc=%d (want %d) why='%s' (want '%s')\n", name, rc, want_rc, why, want_sub);
        fails++;
    }
}

int main(void) {
    sealed_posture_readings_t base;
    sealed_posture_read(&base);
    check("posture-live-host", &base, 0, "sip=0x0 bootargs=empty swap=encrypted");

    sealed_posture_readings_t m;
    m = base; m.csr_rc = -1; check("posture-refuse-csr-err", &m, -1, "csr_get_active_config failed");
    m = base; m.csr_config = 0x14u; check("posture-refuse-partial-sip", &m, -1, "SIP is not fully enabled (csr config 0x14)");
    m = base; m.csr_config = 0x7fu; check("posture-refuse-sip-off", &m, -1, "SIP is not fully enabled (csr config 0x7f)");
    m = base; snprintf(m.bootargs, sizeof m.bootargs, "debug=0x144"); check("posture-refuse-bootargs", &m, -1, "kern.bootargs is not empty");
    m = base; m.swap_encrypted = 0; check("posture-refuse-swap-unencrypted", &m, -1, "swap is not encrypted");
    m = base; m.hibernatemode = 25; check("posture-refuse-hibernate-25", &m, -1, "kern.hibernatemode is 25");
    m = base; m.hibernatemode = 0; check("posture-allow-hibernate-0", &m, 0, "hibernate=0");
    m = base; m.hibernatemode = 3; check("posture-allow-hibernate-3", &m, 0, "hibernate=3");
    m = base; m.non_apple_kexts = 1; snprintf(m.first_non_apple_kext, sizeof m.first_non_apple_kext, "org.example.kext");
    check("posture-refuse-non-apple-kext", &m, -1, "non-Apple kext loaded (1: org.example.kext)");
    m = base; m.effective_ap = 0; check("posture-refuse-chosen-ap", &m, -1, "chosen security mode");
    m = base; m.cert_mode = 0; check("posture-refuse-chosen-cert", &m, -1, "chosen security mode");
    m = base; m.effective_sep = 0; check("posture-refuse-chosen-sep", &m, -1, "chosen security mode");
    printf("# posture-check: %d failed\n", fails);
    return fails ? 1 : 0;
}
