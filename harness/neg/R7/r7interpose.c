// R7-T3 interposer arm (test builds only; linked into build-r7-interpose).
// Counts every call that sets or swaps an exception port, every call that
// sets a signal disposition, and every call to the 21 sandbox-relax entry
// points of verify-r7b-REPORT.md:14-22. Each record holds the caller image,
// the argument that matters (signal number or exception mask), the return
// value and errno. Counting starts at r7i_arm(), which the test child calls
// right after the R1 guard and the R2 self-check.
//
// Forwarding is a direct call: dyld keeps the interposer's own binds on the
// real implementation (verify-r7b/src/interposer.c). The relax entry points
// are SPI with no public prototype. They are not variadic, so each wrapper
// takes and forwards six integer registers (arm64: x0-x5), which is exact
// for any such function with six or fewer integer or pointer arguments.
#include <dlfcn.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "sealed/sealed_r7_interpose.h"

extern bool _dyld_shared_cache_contains_path(const char *path);

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int g_armed;
static r7i_hit_t g_hits[R7I_MAX_HITS];
static int g_n;
static int g_dropped;

static void note(const char *name, int kind, long arg, long ret, int err, const void *ra) {
  if (!g_armed) return;
  Dl_info info;
  const char *img = "?";
  uintptr_t off = 0;
  int cache = 0;
  if (dladdr(ra, &info) && info.dli_fname) {
    img = info.dli_fname;
    off = (uintptr_t)ra - (uintptr_t)info.dli_fbase;
    cache = _dyld_shared_cache_contains_path(info.dli_fname) ? 1 : 0;
  }
  pthread_mutex_lock(&g_lock);
  if (g_n < R7I_MAX_HITS) {
    r7i_hit_t *h = &g_hits[g_n++];
    h->name = name;
    h->kind = kind;
    h->arg = arg;
    h->ret = ret;
    h->err = err;
    h->offset = off;
    h->cache = cache;
    snprintf(h->image, sizeof h->image, "%s", img);
  } else {
    g_dropped++;
  }
  pthread_mutex_unlock(&g_lock);
}

void r7i_arm(void) { g_armed = 1; }

void r7i_mark(const char *tag) { note(tag, R7I_MARK, 0, 0, 0, __builtin_return_address(0)); }

int r7i_count(int *dropped) {
  pthread_mutex_lock(&g_lock);
  int n = g_n;
  if (dropped) *dropped = g_dropped;
  pthread_mutex_unlock(&g_lock);
  return n;
}

int r7i_get(int i, r7i_hit_t *out) {
  pthread_mutex_lock(&g_lock);
  int ok = i >= 0 && i < g_n;
  if (ok) *out = g_hits[i];
  pthread_mutex_unlock(&g_lock);
  return ok;
}

// ---- exception ports ----
static kern_return_t w_task_set_exception_ports(task_t t, exception_mask_t m, mach_port_t p,
                                                exception_behavior_t b, thread_state_flavor_t f) {
  kern_return_t kr = task_set_exception_ports(t, m, p, b, f);
  note("task_set_exception_ports", R7I_PORT, (long)m, kr, 0, __builtin_return_address(0));
  return kr;
}
static kern_return_t w_task_swap_exception_ports(task_t t, exception_mask_t m, mach_port_t p,
                                                 exception_behavior_t b, thread_state_flavor_t f,
                                                 exception_mask_array_t om, mach_msg_type_number_t *on,
                                                 exception_handler_array_t op,
                                                 exception_behavior_array_t ob,
                                                 exception_flavor_array_t of) {
  kern_return_t kr = task_swap_exception_ports(t, m, p, b, f, om, on, op, ob, of);
  note("task_swap_exception_ports", R7I_PORT, (long)m, kr, 0, __builtin_return_address(0));
  return kr;
}
static kern_return_t w_thread_set_exception_ports(thread_act_t t, exception_mask_t m, mach_port_t p,
                                                  exception_behavior_t b, thread_state_flavor_t f) {
  kern_return_t kr = thread_set_exception_ports(t, m, p, b, f);
  note("thread_set_exception_ports", R7I_PORT, (long)m, kr, 0, __builtin_return_address(0));
  return kr;
}
static kern_return_t w_thread_swap_exception_ports(thread_act_t t, exception_mask_t m, mach_port_t p,
                                                   exception_behavior_t b, thread_state_flavor_t f,
                                                   exception_mask_array_t om, mach_msg_type_number_t *on,
                                                   exception_handler_array_t op,
                                                   exception_behavior_array_t ob,
                                                   exception_flavor_array_t of) {
  kern_return_t kr = thread_swap_exception_ports(t, m, p, b, f, om, on, op, ob, of);
  note("thread_swap_exception_ports", R7I_PORT, (long)m, kr, 0, __builtin_return_address(0));
  return kr;
}

// ---- signal dispositions (queries with a null action are not counted) ----
static int w_sigaction(int s, const struct sigaction *a, struct sigaction *o) {
  int rc = sigaction(s, a, o);
  int e = errno;
  if (a) note("sigaction", R7I_SIGNAL, s, rc, rc ? e : 0, __builtin_return_address(0));
  errno = e;
  return rc;
}
static void (*w_signal(int s, void (*h)(int)))(int) {
  void (*r)(int) = signal(s, h);
  int e = errno;
  note("signal", R7I_SIGNAL, s, r == SIG_ERR ? -1 : 0, r == SIG_ERR ? e : 0, __builtin_return_address(0));
  errno = e;
  return r;
}
static void (*w_sigset(int s, void (*h)(int)))(int) {
  void (*r)(int) = sigset(s, h);
  int e = errno;
  note("sigset", R7I_SIGNAL, s, r == SIG_ERR ? -1 : 0, r == SIG_ERR ? e : 0, __builtin_return_address(0));
  errno = e;
  return r;
}
static void (*w_bsd_signal(int s, void (*h)(int)))(int) {
  void (*r)(int) = bsd_signal(s, h);
  int e = errno;
  note("bsd_signal", R7I_SIGNAL, s, r == SIG_ERR ? -1 : 0, r == SIG_ERR ? e : 0, __builtin_return_address(0));
  errno = e;
  return r;
}
static int w_sigignore(int s) {
  int rc = sigignore(s);
  int e = errno;
  note("sigignore", R7I_SIGNAL, s, rc, rc ? e : 0, __builtin_return_address(0));
  errno = e;
  return rc;
}

// ---- sandbox-relax entry points (verify-r7b-REPORT.md:14-22) ----
#define RELAX(sym)                                                                         \
  extern uint64_t sym(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);       \
  static uint64_t w_##sym(uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e,    \
                          uint64_t f) {                                                    \
    errno = 0;                                                                             \
    uint64_t r = sym(a, b, c, d, e, f);                                                    \
    int en = errno;                                                                        \
    note(#sym, R7I_RELAX, 0, (long)r, en, __builtin_return_address(0));                    \
    errno = en;                                                                            \
    return r;                                                                              \
  }
RELAX(sandbox_extension_consume)
RELAX(sandbox_consume_extension)
RELAX(sandbox_consume_fs_extension)
RELAX(sandbox_consume_mach_extension)
RELAX(sandbox_release_fs_extension)
RELAX(sandbox_issue_fs_extension)
RELAX(sandbox_issue_mach_extension)
RELAX(sandbox_suspend)
RELAX(sandbox_unsuspend)
RELAX(sandbox_extension_reap)
RELAX(sandbox_passthrough_access)
RELAX(sandbox_init_from_pid)
RELAX(sandbox_init_with_parameters)
RELAX(container_sandbox_extension_consume)
RELAX(container_acquire_sandbox_extension)
RELAX(container_object_sandbox_extension_activate)
RELAX(sandbox_extension_issue_file)
RELAX(sandbox_extension_issue_file_to_self)
RELAX(sandbox_extension_issue_generic)
RELAX(sandbox_extension_issue_mach)
RELAX(container_sandbox_issue_extension)

struct interpose { const void *replacement, *replacee; };
#define I(sym) {(const void *)w_##sym, (const void *)sym}
__attribute__((used, section("__DATA,__interpose"))) static const struct interpose interposers[] = {
    I(task_set_exception_ports), I(task_swap_exception_ports), I(thread_set_exception_ports),
    I(thread_swap_exception_ports), I(sigaction), I(signal), I(sigset), I(bsd_signal), I(sigignore),
    I(sandbox_extension_consume), I(sandbox_consume_extension), I(sandbox_consume_fs_extension),
    I(sandbox_consume_mach_extension), I(sandbox_release_fs_extension), I(sandbox_issue_fs_extension),
    I(sandbox_issue_mach_extension), I(sandbox_suspend), I(sandbox_unsuspend), I(sandbox_extension_reap),
    I(sandbox_passthrough_access), I(sandbox_init_from_pid), I(sandbox_init_with_parameters),
    I(container_sandbox_extension_consume), I(container_acquire_sandbox_extension),
    I(container_object_sandbox_extension_activate), I(sandbox_extension_issue_file),
    I(sandbox_extension_issue_file_to_self), I(sandbox_extension_issue_generic),
    I(sandbox_extension_issue_mach), I(container_sandbox_issue_extension),
};
