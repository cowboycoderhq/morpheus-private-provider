// p6-scan PID CANARY: get a control or read task port for PID, walk every
// readable region with mach_vm_read, and count "S-"+CANARY and "P-"+CANARY.
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef kern_return_t (*pid_trap_fn)(mach_port_name_t, int, mach_port_name_t *);
static size_t count(const char *b, size_t n, const char *pat, size_t pl) {
  size_t c = 0; for (const char *q = b; n >= pl && (q = memmem(q, n - (q - b), pat, pl)); q++) { c++; if ((size_t)(q - b) + pl > n) break; } return c; }
int main(int argc, char **argv) {
  if (argc != 3) return 64;
  int pid = atoi(argv[1]); const char *can = argv[2];
  char ps[256], pp[256]; snprintf(ps, sizeof ps, "S-%s", can); snprintf(pp, sizeof pp, "P-%s", can);
  mach_port_t t = MACH_PORT_NULL; const char *how = "task_for_pid";
  kern_return_t kr = task_for_pid(mach_task_self(), pid, &t);
  printf("task_for_pid kr=%d\n", kr);
  if (kr != KERN_SUCCESS) {
    pid_trap_fn rd = (pid_trap_fn)dlsym(RTLD_DEFAULT, "task_read_for_pid");
    kr = rd ? rd(mach_task_self(), pid, &t) : -1; how = "task_read_for_pid";
    printf("task_read_for_pid kr=%d\n", kr);
  }
  if (kr != KERN_SUCCESS) { printf("RESULT no-port S=0 P=0 regions=0 bytes=0\n"); return 2; }
  mach_vm_address_t a = 0; size_t S = 0, P = 0, regions = 0, bytes = 0, rfail = 0;
  for (;;) {
    mach_vm_size_t sz = 0; natural_t depth = 1024; vm_region_submap_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
    if (mach_vm_region_recurse(t, &a, &sz, &depth, (vm_region_recurse_info_t)&info, &cnt) != KERN_SUCCESS) break;
    if (info.is_submap) { continue; }
    regions++;
    if ((info.protection & VM_PROT_READ) && sz <= (1ull << 31)) {
      vm_offset_t data = 0; mach_msg_type_number_t dc = 0;
      if (mach_vm_read(t, a, sz, &data, &dc) == KERN_SUCCESS) {
        size_t s = count((char *)data, dc, ps, strlen(ps)), p = count((char *)data, dc, pp, strlen(pp));
        if (s || p) printf("  hit region 0x%llx size=0x%llx tag=%u S=%zu P=%zu\n", a, sz, info.user_tag, s, p);
        S += s; P += p; bytes += dc; mach_vm_deallocate(mach_task_self(), data, dc);
      } else rfail++;
    }
    a += sz;
  }
  printf("RESULT via=%s S=%zu P=%zu regions=%zu bytes=%zu readfail=%zu\n", how, S, P, regions, bytes, rfail);
  return 0;
}
