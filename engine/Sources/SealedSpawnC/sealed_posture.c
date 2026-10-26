// Boot-posture and host-setting gate. See include/sealed_posture.h.
#include "sealed_posture.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/kext/KextManager.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

typedef uint32_t csr_config_t;
extern int csr_get_active_config(csr_config_t *config);

static int read_dt_u32(io_registry_entry_t entry, CFStringRef key, uint32_t *out) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!v) return -1;
    int rc = -1;
    if (CFGetTypeID(v) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)v) == 4) {
        memcpy(out, CFDataGetBytePtr((CFDataRef)v), 4);
        rc = 0;
    }
    CFRelease(v);
    return rc;
}

static int read_dt_s64(io_registry_entry_t entry, CFStringRef key, int64_t *out) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!v) return -1;
    int rc = -1;
    if (CFGetTypeID(v) == CFNumberGetTypeID() &&
        CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, out)) {
        rc = 0;
    } else if (CFGetTypeID(v) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)v) == 4) {
        uint32_t u = 0;
        memcpy(&u, CFDataGetBytePtr((CFDataRef)v), 4);
        *out = (int64_t)u;
        rc = 0;
    }
    CFRelease(v);
    return rc;
}

void sealed_posture_read(sealed_posture_readings_t *o) {
    memset(o, 0, sizeof *o);
    csr_config_t cfg = 0xffffffffu;
    o->csr_rc = csr_get_active_config(&cfg);
    o->csr_config = cfg;

    size_t len = sizeof o->bootargs - 1;
    o->bootargs_rc = sysctlbyname("kern.bootargs", o->bootargs, &len, NULL, 0);
    o->bootargs[sizeof o->bootargs - 1] = '\0';

    struct xsw_usage sw;
    memset(&sw, 0, sizeof sw);
    len = sizeof sw;
    o->swap_rc = sysctlbyname("vm.swapusage", &sw, &len, NULL, 0);
    o->swap_encrypted = sw.xsu_encrypted ? 1 : 0;

    uint32_t hm32 = 0;
    int64_t hm64 = 0;
    len = sizeof hm64;
    if (sysctlbyname("kern.hibernatemode", &hm64, &len, NULL, 0) == 0) {
        o->hibernate_rc = 0;
        o->hibernatemode = (len == 4) ? *(uint32_t *)&hm64 : hm64;
    } else {
        len = sizeof hm32;
        o->hibernate_rc = sysctlbyname("kern.hibernatemode", &hm32, &len, NULL, 0);
        o->hibernatemode = hm32;
    }

    CFDictionaryRef kexts = KextManagerCopyLoadedKextInfo(NULL, NULL);
    if (!kexts) {
        o->kext_rc = -1;
    } else {
        CFIndex n = CFDictionaryGetCount(kexts);
        const void **keys = n > 0 ? (const void **)calloc((size_t)n, sizeof *keys) : NULL;
        if (n > 0 && !keys) {
            o->kext_rc = -1;
        } else {
            if (n > 0) CFDictionaryGetKeysAndValues(kexts, keys, NULL);
            for (CFIndex i = 0; i < n; i++) {
                char b[256];
                b[0] = '\0';
                if (!CFStringGetCString((CFStringRef)keys[i], b, sizeof b, kCFStringEncodingUTF8)) {
                    o->kext_rc = -1;
                    break;
                }
                if (strcmp(b, "__kernel__") == 0 || strncmp(b, "com.apple.", 10) == 0) continue;
                if (o->non_apple_kexts == 0) {
                    snprintf(o->first_non_apple_kext, sizeof o->first_non_apple_kext, "%s", b);
                }
                o->non_apple_kexts++;
            }
            free(keys);
        }
        CFRelease(kexts);
    }

    io_registry_entry_t ch = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen");
    if (ch == MACH_PORT_NULL) {
        o->dt_rc = -1;
    } else {
        int a = read_dt_u32(ch, CFSTR("effective-security-mode-ap"), &o->effective_ap);
        int c = read_dt_u32(ch, CFSTR("certificate-security-mode"), &o->cert_mode);
        int s = read_dt_s64(ch, CFSTR("effective-security-mode-sep"), &o->effective_sep);
        o->dt_rc = (a == 0 && c == 0 && s == 0) ? 0 : -1;
        IOObjectRelease(ch);
    }
}

static int fail(char *why, size_t n, const char *fmt, ...) {
    if (why && n > 0) {
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(why, n, fmt, ap);
        va_end(ap);
    }
    return -1;
}

int sealed_posture_eval(const sealed_posture_readings_t *r, char *why, size_t n) {
    if (!r) return fail(why, n, "null readings");
    if (r->csr_rc != 0) return fail(why, n, "csr_get_active_config failed (rc=%d)", r->csr_rc);
    if (r->csr_config != 0) return fail(why, n, "SIP is not fully enabled (csr config 0x%x)", r->csr_config);
    if (r->bootargs_rc != 0) return fail(why, n, "kern.bootargs read failed (rc=%d)", r->bootargs_rc);
    for (size_t i = 0; i < sizeof r->bootargs && r->bootargs[i]; i++) {
        if (r->bootargs[i] != ' ' && r->bootargs[i] != '\t' && r->bootargs[i] != '\n') {
            return fail(why, n, "kern.bootargs is not empty");
        }
    }
    if (r->swap_rc != 0) return fail(why, n, "vm.swapusage read failed (rc=%d)", r->swap_rc);
    if (!r->swap_encrypted) return fail(why, n, "swap is not encrypted");
    if (r->hibernate_rc != 0) return fail(why, n, "kern.hibernatemode read failed (rc=%d)", r->hibernate_rc);
    if (r->hibernatemode != 0 && r->hibernatemode != 3) {
        return fail(why, n, "kern.hibernatemode is %lld (want 0 or 3)", (long long)r->hibernatemode);
    }
    if (r->kext_rc != 0) return fail(why, n, "loaded-kext query failed");
    if (r->non_apple_kexts != 0) {
        return fail(why, n, "non-Apple kext loaded (%d: %s)", r->non_apple_kexts, r->first_non_apple_kext);
    }
    if (r->dt_rc != 0) return fail(why, n, "IODeviceTree:/chosen security properties missing");
    if (r->effective_ap != 1 || r->cert_mode != 1 || r->effective_sep != 1) {
        return fail(why, n, "chosen security mode is ap=%u cert=%u sep=%lld (want 1,1,1)",
                    r->effective_ap, r->cert_mode, (long long)r->effective_sep);
    }
    if (why && n > 0) snprintf(why, n, "sip=0x0 bootargs=empty swap=encrypted hibernate=%lld kexts=apple-only ap=1 cert=1 sep=1",
                               (long long)r->hibernatemode);
    return 0;
}

int sealed_posture_check(char *why, size_t why_len) {
    sealed_posture_readings_t r;
    sealed_posture_read(&r);
#if defined(SEALED_POSTURE_TEST_BAD_CSR)
    r.csr_config = 0x14u;
#endif
    return sealed_posture_eval(&r, why, why_len);
}

int sealed_posture_runtime_check(char *why, size_t n) {
    csr_config_t cfg = 0xffffffffu;
    int rc = csr_get_active_config(&cfg);
    if (rc != 0) return fail(why, n, "csr_get_active_config failed (rc=%d)", rc);
    if (cfg != 0) return fail(why, n, "SIP is not fully enabled (csr config 0x%x)", cfg);

    struct xsw_usage sw;
    memset(&sw, 0, sizeof sw);
    size_t len = sizeof sw;
    if (sysctlbyname("vm.swapusage", &sw, &len, NULL, 0) != 0) return fail(why, n, "vm.swapusage read failed");
    if (!sw.xsu_encrypted) return fail(why, n, "swap is not encrypted");

    int64_t hm64 = 0;
    uint32_t hm32 = 0;
    len = sizeof hm64;
    int64_t hm = 0;
    if (sysctlbyname("kern.hibernatemode", &hm64, &len, NULL, 0) == 0) {
        hm = (len == 4) ? *(uint32_t *)&hm64 : hm64;
    } else {
        len = sizeof hm32;
        if (sysctlbyname("kern.hibernatemode", &hm32, &len, NULL, 0) != 0) {
            return fail(why, n, "kern.hibernatemode read failed");
        }
        hm = hm32;
    }
    if (hm != 0 && hm != 3) return fail(why, n, "kern.hibernatemode is %lld (want 0 or 3)", (long long)hm);
    return 0;
}
