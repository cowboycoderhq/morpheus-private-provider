// R7-T3 interposer API (test builds only). The library is neg/R7/r7interpose.c;
// only build-r7-interpose links it (SEALED_TEST_R7_INTERPOSE).
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { R7I_MARK = 0, R7I_PORT = 1, R7I_SIGNAL = 2, R7I_RELAX = 3 };

typedef struct {
  const char *name;   // watched symbol, or the tag for R7I_MARK
  int kind;
  long arg;           // signal number (R7I_SIGNAL) or exception mask (R7I_PORT)
  long ret;           // return value (kern_return_t, rc, or the SPI's 64-bit result)
  int err;            // errno after the call (0 when not set)
  int cache;          // 1 if the caller image is in the dyld shared cache
  uintptr_t offset;   // caller address minus the caller image base
  char image[160];
} r7i_hit_t;

#define R7I_MAX_HITS 8192

void r7i_arm(void);
void r7i_mark(const char *tag);
int r7i_count(int *dropped);
int r7i_get(int i, r7i_hit_t *out);

#ifdef __cplusplus
}
#endif
