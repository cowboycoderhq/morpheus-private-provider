// taskports PID: asks for each task port flavour of PID and, where one is
// granted, reads one page of its memory. Run as root against the sealed child
// and against an unhardened control.
#include <mach/mach.h>
#include <mach/mach_traps.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
// task_read_for_pid and task_inspect_for_pid are newer than this SDK's
// headers; look them up at run time (as the m5-pair ra_taskport arm does).
typedef kern_return_t (*pid_trap_fn)(mach_port_name_t, int, mach_port_name_t *);
static void tryread(const char *what, mach_port_t t) {
  mach_vm_address_t a = 0; mach_vm_size_t sz = 0; vm_region_basic_info_data_64_t info;
  mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t obj;
  kern_return_t kr = mach_vm_region(t, &a, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj);
  vm_offset_t data = 0; mach_msg_type_number_t dc = 0;
  kern_return_t kr2 = kr == KERN_SUCCESS ? mach_vm_read(t, a, 16, &data, &dc) : kr;
  printf("  %s region kr=%d read kr=%d\n", what, kr, kr2);
}
int main(int argc, char **argv) {
  if (argc != 2) return 64;
  int pid = atoi(argv[1]); mach_port_t t = MACH_PORT_NULL; kern_return_t kr;
  kr = task_for_pid(mach_task_self(), pid, &t); printf("task_for_pid kr=%d\n", kr); if (kr == KERN_SUCCESS) tryread("control-port", t);
  pid_trap_fn rd = (pid_trap_fn)dlsym(RTLD_DEFAULT, "task_read_for_pid");
  pid_trap_fn in = (pid_trap_fn)dlsym(RTLD_DEFAULT, "task_inspect_for_pid");
  t = MACH_PORT_NULL; kr = rd ? rd(mach_task_self(), pid, &t) : -1; printf("task_read_for_pid kr=%d%s\n", kr, rd ? "" : " (symbol not found)"); if (kr == KERN_SUCCESS) tryread("read-port", t);
  t = MACH_PORT_NULL; kr = in ? in(mach_task_self(), pid, &t) : -1; printf("task_inspect_for_pid kr=%d%s\n", kr, in ? "" : " (symbol not found)");
  t = MACH_PORT_NULL; kr = task_name_for_pid(mach_task_self(), pid, &t); printf("task_name_for_pid kr=%d\n", kr);
  return 0;
}
