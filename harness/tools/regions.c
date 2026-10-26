// regions: walks a process's address space with PROC_PIDREGIONPATHINFO.
// Usage: regions PID          prints every file-backed region's path with
//                             its protection and maximum protection
//        regions --big PID    counts regions >= 64 MiB by protection: the
//                             weight regions must be read-only with a
//                             read-only maximum (review S2)
// Same user only; used by tools/inspect-serving.sh.
#include <libproc.h>
#include <mach/vm_prot.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>

int main(int argc, char **argv) {
    int big = argc == 3 && !strcmp(argv[1], "--big");
    if (argc != 2 && !big) { fprintf(stderr, "usage: regions [--big] PID\n"); return 64; }
    int pid = atoi(argv[argc - 1]);
    uint64_t addr = 0, ro_b = 0, romax_b = 0, rw_b = 0;
    unsigned ro_n = 0, romax_n = 0, rw_n = 0;
    for (;;) {
        struct proc_regionwithpathinfo r;
        int n = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, addr, &r, sizeof r);
        if (n != (int)sizeof r) break;
        uint64_t size = r.prp_prinfo.pri_size;
        int prot = r.prp_prinfo.pri_protection, max = r.prp_prinfo.pri_max_protection;
        if (!big && r.prp_vip.vip_path[0])
            printf("%s prot=%d max=%d\n", r.prp_vip.vip_path, prot, max);
        if (big && size >= (64ull << 20) && (prot & VM_PROT_READ)) {
            if (prot & VM_PROT_WRITE) { rw_n++; rw_b += size; }
            else {
                ro_n++; ro_b += size;
                if (!(max & VM_PROT_WRITE)) { romax_n++; romax_b += size; }
                else printf("  read-only, writable max: %.1f MiB user_tag=%u share_mode=%u path=%s\n",
                            size / 1048576.0, r.prp_prinfo.pri_user_tag, r.prp_prinfo.pri_share_mode,
                            r.prp_vip.vip_path[0] ? r.prp_vip.vip_path : "(anonymous)");
            }
        }
        addr = r.prp_prinfo.pri_address + size;
    }
    if (big)
        printf("regions >= 64 MiB: read-only %u (%.2f GiB), of which max read-only %u (%.2f GiB); writable %u (%.2f GiB)\n",
               ro_n, ro_b / 1073741824.0, romax_n, romax_b / 1073741824.0, rw_n, rw_b / 1073741824.0);
    return 0;
}
